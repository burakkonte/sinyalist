// =============================================================================
// SINYALIST — Home Screen (Responsive Emergency Dashboard)
// =============================================================================

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sinyalist/core/theme/sinyalist_theme.dart';
import 'package:sinyalist/core/bridge/native_bridge.dart';
import 'package:sinyalist/core/connectivity/connectivity_manager.dart';
import 'package:sinyalist/core/crypto/keypair_manager.dart';
import 'package:sinyalist/core/delivery/delivery_state_machine.dart' show DeliveryStateMachine, DeliveryResult;
import 'package:sinyalist/core/location/location_manager.dart';

class HomeScreen extends StatefulWidget {
  final ConnectivityManager connectivity;
  final DeliveryStateMachine deliveryFsm;
  final KeypairManager keypairManager;
  final LocationManager locationManager;
  final bool isEmergency;
  final VoidCallback onEmergencyToggle;

  const HomeScreen({
    super.key,
    required this.connectivity,
    required this.deliveryFsm,
    required this.keypairManager,
    required this.locationManager,
    required this.isEmergency,
    required this.onEmergencyToggle,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  MeshStats _meshStats = const MeshStats();
  StreamSubscription? _meshSub;
  bool _isSending = false;
  bool _sosSent = false;
  DeliveryResult? _lastResult;
  SeismicEvent? _lastSeismicEvent;
  StreamSubscription? _seismicSub;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        _meshSub = MeshBridge.stats.listen((stats) {
          if (mounted) setState(() => _meshStats = stats);
        });
        _seismicSub = SeismicBridge.events.listen((event) {
          if (mounted) setState(() => _lastSeismicEvent = event);
        });
      } catch (_) {}
    }
    widget.connectivity.addListener(_onConnectivityChange);
    widget.locationManager.addListener(_onLocationChange);
  }

  void _onConnectivityChange() {
    if (mounted) setState(() {});
  }

  void _onLocationChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _meshSub?.cancel();
    _seismicSub?.cancel();
    widget.connectivity.removeListener(_onConnectivityChange);
    widget.locationManager.removeListener(_onLocationChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.isEmergency
        ? _buildSurvivalMode(context)
        : _buildDailyMode(context);
  }

  // =========================================================================
  // SURVIVAL MODE — OLED Black
  // =========================================================================
  Widget _buildSurvivalMode(BuildContext context) {
    final cs = widget.connectivity.state;
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(SinyalistSpacing.pagePadding),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: screenWidth > 600 ? 480 : double.infinity),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  const Icon(Icons.warning_amber_rounded,
                      size: 64, color: SinyalistColors.emergencyRed),
                  const SizedBox(height: 12),
                  const Text(
                    'DEPREM ALGILANDI',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: SinyalistColors.emergencyRed),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Konumunuz paylaşılıyor',
                    style: TextStyle(
                        fontSize: 16,
                        color: SinyalistColors.oledTextSecondary),
                  ),
                  const SizedBox(height: 32),
                  _StatusCard(
                    icon: _transportIcon(cs.activeTransport),
                    iconColor: cs.activeTransport == TransportMode.none
                        ? SinyalistColors.emergencyRed
                        : SinyalistColors.safeGreen,
                    title: cs.activeTransport.displayName,
                    subtitle: cs.activeTransport == TransportMode.none
                        ? 'Veri tamponlanıyor — yakın cihaz bekliyor'
                        : 'Konum ve durum iletiliyor',
                  ),
                  const SizedBox(height: 8),
                  _GpsStatusCard(locationManager: widget.locationManager),
                  if (_lastResult != null) ...[
                    const SizedBox(height: 8),
                    _DeliveryResultCard(result: _lastResult!),
                  ],
                  const SizedBox(height: 12),
                  if (_meshStats.activeNodes > 0)
                    _StatusCard(
                      icon: Icons.hub,
                      iconColor: SinyalistColors.signalBlue,
                      title: '${_meshStats.activeNodes} mesh düğümü aktif',
                      subtitle:
                          '${_meshStats.bufferedPackets} paket tamponlandı',
                    ),
                  const Spacer(),

                  // SOS Button — with visual state feedback and pulse animation
                  AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) => Transform.scale(
                      scale: (_isSending || _sosSent) ? 1.0 : _pulseAnimation.value,
                      child: child,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      height: 80,
                      child: ElevatedButton.icon(
                      onPressed: (_isSending || _sosSent) ? null : () {
                        try {
                          HapticFeedback.heavyImpact();
                        } catch (_) {}
                        _sendSosPacket();
                      },
                      icon: _isSending
                          ? const SizedBox(
                              width: 28, height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 3, color: Colors.white))
                          : _sosSent
                              ? const Icon(Icons.check_circle, size: 32)
                              : const Icon(Icons.sos, size: 32),
                      label: Text(
                          _isSending ? 'SİNYAL GÖNDERİLİYOR...'
                              : _sosSent ? 'SİNYAL GÖNDERİLDİ ✓'
                              : 'MAHSUR KALDIM',
                          style: const TextStyle(
                              inherit: true,
                              fontSize: 22, fontWeight: FontWeight.w900)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _sosSent
                            ? SinyalistColors.emergencyAmber
                            : SinyalistColors.emergencyRed,
                        disabledBackgroundColor: _isSending
                            ? SinyalistColors.emergencyRed.withValues(alpha: 0.7)
                            : SinyalistColors.emergencyAmber,
                        foregroundColor: Colors.white,
                        disabledForegroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Safe button
                  SizedBox(
                    width: double.infinity,
                    height: 64,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        try {
                          HapticFeedback.mediumImpact();
                        } catch (_) {}
                        widget.onEmergencyToggle();
                      },
                      icon:
                          const Icon(Icons.check_circle_outline, size: 28),
                      label: const Text('GÜVENDEYİM',
                          style: TextStyle(
                              inherit: true,
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: SinyalistColors.safeGreen,
                        side: const BorderSide(
                            color: SinyalistColors.safeGreen, width: 2),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // DAILY MODE — Professional White
  // =========================================================================
  Widget _buildDailyMode(BuildContext context) {
    final cs = widget.connectivity.state;
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sinyalist',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.warning_amber),
            onPressed: widget.onEmergencyToggle,
            tooltip: 'Test emergency mode',
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: screenWidth > 600 ? 520 : double.infinity),
            child: ListView(
              padding: const EdgeInsets.all(SinyalistSpacing.pagePadding),
              children: [
                _DailyStatusHeader(connectivity: cs),
                const SizedBox(height: 20),

                // GPS card
                _DashboardCard(
                  title: 'Konum (GPS)',
                  icon: Icons.location_on,
                  child: _GpsDetailPanel(locationManager: widget.locationManager),
                ),
                const SizedBox(height: 12),

                // Last delivery card
                if (_lastResult != null) ...[
                  _DashboardCard(title: 'Son Sinyal', icon: Icons.send,
                      child: _DeliveryDetailPanel(result: _lastResult!)),
                  const SizedBox(height: 12),
                ],

                // Seismic monitor
                _DashboardCard(
                  title: 'Sismik Monitör',
                  icon: Icons.insights,
                  child: _SeismicPanel(lastEvent: _lastSeismicEvent),
                ),
                const SizedBox(height: 12),
// Mesh
                _DashboardCard(
                  title: 'Mesh Ağı',
                  icon: Icons.hub,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _MetricTile(
                            value: '${_meshStats.activeNodes}',
                            label: 'Düğüm'),
                        _MetricTile(
                            value: '${_meshStats.bufferedPackets}',
                            label: 'Tampon'),
                        _MetricTile(
                            value: '${_meshStats.totalRelayed}',
                            label: 'İletilen'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Connectivity
                _DashboardCard(
                  title: 'Bağlantı',
                  icon: _transportIcon(cs.activeTransport),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ConnRow(label: 'İnternet', active: cs.hasInternet),
                        _ConnRow(label: 'Hücresel', active: cs.hasCellular),
                        _ConnRow(
                            label: 'BLE Mesh', active: cs.hasBluetooth),
                        _ConnRow(
                            label: 'Wi-Fi P2P', active: cs.hasWifiDirect),
                        const SizedBox(height: 8),
                        _TransportBadge(mode: cs.activeTransport),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _transportIcon(TransportMode mode) {
    switch (mode) {
      case TransportMode.grpc:
        return Icons.cloud_done;
      case TransportMode.sms:
        return Icons.sms;
      case TransportMode.bleMesh:
        return Icons.bluetooth;
      case TransportMode.wifiP2p:
        return Icons.wifi;
      case TransportMode.none:
        return Icons.signal_wifi_off;
    }
  }

  /// Build a proper protobuf-encoded SinyalistPacket (without signature fields).
  /// The DeliveryStateMachine will append Ed25519 signature and public key.
  Uint8List _buildTrappedPacket() {
    final builder = BytesBuilder();
    final now = DateTime.now().millisecondsSinceEpoch;
    final rng = Random.secure();

    // Generate 16-byte packet_id (UUID v4)
    final packetId = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      packetId[i] = rng.nextInt(256);
    }
    // Set version (4) and variant (RFC 4122)
    packetId[6] = (packetId[6] & 0x0F) | 0x40;
    packetId[8] = (packetId[8] & 0x3F) | 0x80;

    // Helper: write varint
    void writeVarint(int value) {
      var v = value;
      while (v > 0x7F) {
        builder.addByte((v & 0x7F) | 0x80);
        v >>= 7;
      }
      builder.addByte(v & 0x7F);
    }

    // Helper: write a protobuf field tag
    void writeTag(int fieldNumber, int wireType) {
      writeVarint((fieldNumber << 3) | wireType);
    }

    // Helper: write fixed64 (little-endian, 8 bytes).
    // Uses two setUint32 calls instead of setUint64 because dart2js (web)
    // does not support ByteData.setUint64 / getUint64.
    void writeFixed64(int fieldNumber, int value) {
      writeTag(fieldNumber, 1); // wire type 1 = 64-bit
      final bd = ByteData(8);
      // Dart int is 64-bit on VM but 53-bit on JS — timestamps fit in 53 bits.
      final lo = value & 0xFFFFFFFF;
      final hi = (value >> 32) & 0xFFFFFFFF;
      bd.setUint32(0, lo, Endian.little); // low 32 bits first (little-endian)
      bd.setUint32(4, hi, Endian.little); // high 32 bits second
      builder.add(bd.buffer.asUint8List());
    }

    // Helper: write varint field
    void writeVarintField(int fieldNumber, int value) {
      if (value == 0) return; // protobuf default, skip
      writeTag(fieldNumber, 0);
      writeVarint(value);
    }

    // Helper: write bytes field
    void writeBytesField(int fieldNumber, Uint8List data) {
      writeTag(fieldNumber, 2);
      writeVarint(data.length);
      builder.add(data);
    }

    // Helper: write sint32 (zigzag encoded)
    void writeSint32Field(int fieldNumber, int value) {
      writeTag(fieldNumber, 0);
      final zigzag = (value << 1) ^ (value >> 31);
      writeVarint(zigzag & 0xFFFFFFFF);
    }

    // Get real GPS location (or fallback if unavailable)
    final loc = widget.locationManager.getOrFallback();
    if (!loc.isReal) {
      debugPrint('[HomeScreen] WARNING: using Istanbul fallback coords — GPS unavailable');
    }

    // field 1: user_id (fixed64) — use device hash
    writeFixed64(1, now ~/ 1000); // Use seconds as pseudo user_id

    // field 3: latitude_e7 (sint32) — real GPS or fallback
    writeSint32Field(3, loc.latitudeE7);

    // field 4: longitude_e7 (sint32) — real GPS or fallback
    writeSint32Field(4, loc.longitudeE7);

    // field 6: accuracy_cm (uint32) — from GPS fix or 999999 for fallback
    writeVarintField(6, loc.accuracyCm);

    // field 13: battery_percent
    writeVarintField(13, 50); // placeholder

    // field 16: timestamp_ms (fixed64)
    writeFixed64(16, now);

    // field 21: is_trapped (bool/varint) = true
    writeVarintField(21, 1);

    // field 24: packet_id (bytes, 16B UUID)
    writeBytesField(24, packetId);

    // field 25: created_at_ms (fixed64)
    writeFixed64(25, now);

    // field 26: msg_type = MSG_TRAPPED (1)
    writeVarintField(26, 1);

    // field 27: priority = PRIORITY_CRITICAL (1)
    writeVarintField(27, 1);

    return builder.toBytes();
  }

  Future<void> _sendSosPacket() async {
    if (_isSending || _sosSent) return;

    // Check rate limit via DeliveryStateMachine
    if (!widget.deliveryFsm.canSend) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lütfen bekleyin (${widget.deliveryFsm.remainingSends} hak kaldı)',
              style: const TextStyle(inherit: true, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            backgroundColor: SinyalistColors.emergencyAmber,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    setState(() => _isSending = true);

    // Update internet availability on the FSM
    widget.deliveryFsm.internetAvailable = widget.connectivity.state.hasInternet;

    try {
      // Build a real protobuf packet (without signature — FSM signs it)
      final rawPacket = _buildTrappedPacket();
      debugPrint('[HomeScreen] Built TRAPPED packet: ${rawPacket.length} bytes');

      // Deliver through the state machine (signs -> internet -> SMS -> BLE)
      final result = await widget.deliveryFsm.deliver(rawPacket);

      if (mounted) {
        setState(() {
          _isSending = false;
          _sosSent = true;
          _lastResult = result;
        });

        final message = result.isDelivered
            ? 'Acil sinyal gönderildi (${result.transport ?? "?"}) '
                '${result.confidence != null ? "güven=${(result.confidence! * 100).toInt()}%" : ""}'
            : result.error == 'Rate limited'
                ? 'Çok hızlı gönderiyorsunuz — lütfen bekleyin'
                : kIsWeb
                    ? 'Web demo: SMS ve BLE desteklenmiyor. Backend çalışıyorsa internet üzerinden gönderilir.'
                    : 'Sinyal tamponlandı — bağlantı kurulunca iletilecek';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              message,
              style: const TextStyle(inherit: true, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            backgroundColor: result.isDelivered
                ? SinyalistColors.safeGreen
                : SinyalistColors.emergencyAmber,
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );

        debugPrint('[HomeScreen] Delivery result: $result');

        // Allow re-sending after 10 seconds
        Future.delayed(const Duration(seconds: 10), () {
          if (mounted) setState(() => _sosSent = false);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sinyal hatası: $e',
                style: const TextStyle(inherit: true)),
            backgroundColor: SinyalistColors.emergencyAmber,
          ),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Reusable widgets
// ---------------------------------------------------------------------------

class _StatusCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;

  const _StatusCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: SinyalistColors.oledSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SinyalistColors.oledBorder, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, size: 32, color: iconColor),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 13,
                        color: SinyalistColors.oledTextSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyStatusHeader extends StatelessWidget {
  final ConnectivityState connectivity;
  const _DailyStatusHeader({required this.connectivity});

  @override
  Widget build(BuildContext context) {
    // FIX: withValues(alpha:) → withOpacity() for Flutter <3.27 compat
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: SinyalistColors.professionalGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: SinyalistColors.professionalGreen.withValues(alpha: 0.2)),
      ),
      child: const Row(
        children: [
          Icon(Icons.shield,
              color: SinyalistColors.professionalGreen, size: 28),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sistem Aktif',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                SizedBox(height: 2),
                Text('Deprem izleme devam ediyor',
                    style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const _DashboardCard(
      {required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String value;
  final String label;
  const _MetricTile({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style:
                const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

class _ConnRow extends StatelessWidget {
  final String label;
  final bool active;
  const _ConnRow({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            active ? Icons.check_circle : Icons.cancel,
            size: 16,
            color: active
                ? SinyalistColors.professionalGreen
                : SinyalistColors.whiteTextDisabled,
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }
}
class _GpsStatusCard extends StatelessWidget {
  final LocationManager locationManager;
  const _GpsStatusCard({required this.locationManager});
  @override
  Widget build(BuildContext context) {
    final loc = locationManager.getOrFallback();
    final hasReal = locationManager.hasRealLocation;
    final isDenied = locationManager.isPermissionDenied;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: SinyalistColors.oledSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasReal ? SinyalistColors.safeGreen.withValues(alpha: 0.4) : SinyalistColors.emergencyAmber.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Row(children: [
        Icon(hasReal ? Icons.gps_fixed : Icons.gps_off, size: 24,
            color: hasReal ? SinyalistColors.safeGreen : SinyalistColors.emergencyAmber),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(hasReal ? 'GPS Aktif' : isDenied ? 'GPS İzni Yok' : 'GPS Aranıyor...',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            hasReal
                ? '${(loc.latitudeE7 / 1e7).toStringAsFixed(4)}°, ${(loc.longitudeE7 / 1e7).toStringAsFixed(4)}° (±${(loc.accuracyCm / 100).toStringAsFixed(0)}m)'
                : 'İstanbul merkezi — yedek konum aktif',
            style: const TextStyle(fontSize: 12, color: SinyalistColors.oledTextSecondary),
          ),
        ])),
      ]),
    );
  }
}

class _GpsDetailPanel extends StatelessWidget {
  final LocationManager locationManager;
  const _GpsDetailPanel({required this.locationManager});
  @override
  Widget build(BuildContext context) {
    final loc = locationManager.getOrFallback();
    final hasReal = locationManager.hasRealLocation;
    final isDenied = locationManager.isPermissionDenied;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(hasReal ? Icons.gps_fixed : Icons.gps_off, size: 15,
              color: hasReal ? SinyalistColors.professionalGreen : SinyalistColors.professionalAmber),
          const SizedBox(width: 6),
          Text(
            hasReal ? 'Gerçek GPS Konumu' : isDenied ? 'İzin verilmedi — yedek konum' : 'GPS aranıyor — yedek konum',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                color: hasReal ? SinyalistColors.professionalGreen : SinyalistColors.professionalAmber),
          ),
        ]),
        const SizedBox(height: 8),
        _InfoRow(label: 'Enlem', value: hasReal ? '${(loc.latitudeE7 / 1e7).toStringAsFixed(6)}°' : '41.010000° (yedek)'),
        _InfoRow(label: 'Boylam', value: hasReal ? '${(loc.longitudeE7 / 1e7).toStringAsFixed(6)}°' : '28.953000° (yedek)'),
        _InfoRow(label: 'Doğruluk', value: hasReal ? '±${(loc.accuracyCm / 100).toStringAsFixed(1)}m' : '±9999m (yedek)'),
      ]),
    );
  }
}

class _DeliveryResultCard extends StatelessWidget {
  final DeliveryResult result;
  const _DeliveryResultCard({required this.result});
  String _tl(String? t) => switch(t) { 'internet' => '🌐 İnternet', 'sms' => '📱 SMS', 'ble_mesh' => '📡 BLE Mesh', _ => t ?? '?' };
  @override
  Widget build(BuildContext context) {
    final isOk = result.isDelivered;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: SinyalistColors.oledSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isOk ? SinyalistColors.safeGreen.withValues(alpha: 0.4) : SinyalistColors.emergencyAmber.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(children: [
        Icon(isOk ? Icons.check_circle : Icons.pending, size: 24,
            color: isOk ? SinyalistColors.safeGreen : SinyalistColors.emergencyAmber),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(isOk ? 'Sinyal İletildi' : 'Sinyal Tamponlandı',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            isOk ? _tl(result.transport) + (result.confidence != null ? ' · güven=${(result.confidence! * 100).toInt()}%' : '') : result.error ?? 'Bağlantı bekleniyor',
            style: const TextStyle(fontSize: 12, color: SinyalistColors.oledTextSecondary),
          ),
        ])),
        Text('${result.elapsed.inMilliseconds}ms', style: const TextStyle(fontSize: 11, color: SinyalistColors.oledTextSecondary)),
      ]),
    );
  }
}

class _DeliveryDetailPanel extends StatelessWidget {
  final DeliveryResult result;
  const _DeliveryDetailPanel({required this.result});
  @override
  Widget build(BuildContext context) {
    final isOk = result.isDelivered;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(isOk ? Icons.check_circle : Icons.pending, size: 15,
              color: isOk ? SinyalistColors.professionalGreen : SinyalistColors.professionalAmber),
          const SizedBox(width: 6),
          Text(isOk ? 'İletildi' : 'Tamponlandı',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                  color: isOk ? SinyalistColors.professionalGreen : SinyalistColors.professionalAmber)),
        ]),
        const SizedBox(height: 8),
        if (result.transport != null)
          _InfoRow(label: 'Kanal', value: switch(result.transport) { 'internet' => 'İnternet', 'sms' => 'SMS', 'ble_mesh' => 'BLE Mesh', _ => result.transport! }),
        if (result.confidence != null) _InfoRow(label: 'Güven', value: '${(result.confidence! * 100).toInt()}%'),
        _InfoRow(label: 'Süre', value: '${result.elapsed.inMilliseconds}ms'),
        if (result.error != null) _InfoRow(label: 'Hata', value: result.error!),
      ]),
    );
  }
}

class _SeismicPanel extends StatelessWidget {
  final SeismicEvent? lastEvent;
  const _SeismicPanel({this.lastEvent});
  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final event = lastEvent;
      if (event == null) {
        return const Padding(padding: EdgeInsets.all(16), child: Row(children: [
          SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 10),
          Text('İvmeölçer aktif — deprem bekleniyor', style: TextStyle(fontSize: 13)),
        ]));
      }
      return Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(event.isCritical ? Icons.warning_amber : Icons.check_circle_outline, size: 15,
              color: event.isCritical ? SinyalistColors.professionalRed : SinyalistColors.professionalGreen),
          const SizedBox(width: 6),
          Text('Seviye: ${event.levelName}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: event.isCritical ? SinyalistColors.professionalRed : null)),
        ]),
        const SizedBox(height: 6),
        _InfoRow(label: 'PGA', value: '${event.peakG.toStringAsFixed(4)}g'),
        _InfoRow(label: 'Frekans', value: '${event.dominantFreq.toStringAsFixed(1)}Hz'),
      ]));
    }
    return const Padding(padding: EdgeInsets.all(16), child: Row(children: [
      Icon(Icons.info_outline, size: 15, color: SinyalistColors.professionalBlue),
      SizedBox(width: 8),
      Expanded(child: Text('Sismik algılama yalnızca Android cihazda aktif olur', style: TextStyle(fontSize: 13))),
    ]));
  }
}

class _TransportBadge extends StatelessWidget {
  final TransportMode mode;
  const _TransportBadge({required this.mode});
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (mode) {
      TransportMode.grpc    => ('İnternet Aktif', SinyalistColors.professionalGreen),
      TransportMode.sms     => ('SMS Aktif', SinyalistColors.professionalAmber),
      TransportMode.bleMesh => ('BLE Mesh Aktif', SinyalistColors.professionalBlue),
      TransportMode.wifiP2p => ('Wi-Fi P2P Aktif', SinyalistColors.professionalBlue),
      TransportMode.none    => ('Bağlantı Yok', SinyalistColors.professionalRed),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 70, child: Text('$label:', style: const TextStyle(fontSize: 12, color: SinyalistColors.whiteTextDisabled))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
      ]),
    );
  }
}

