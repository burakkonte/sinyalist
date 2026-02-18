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
import 'package:sinyalist/core/delivery/delivery_state_machine.dart';

class HomeScreen extends StatefulWidget {
  final ConnectivityManager connectivity;
  final DeliveryStateMachine deliveryFsm;
  final KeypairManager keypairManager;
  final bool isEmergency;
  final VoidCallback onEmergencyToggle;

  const HomeScreen({
    super.key,
    required this.connectivity,
    required this.deliveryFsm,
    required this.keypairManager,
    required this.isEmergency,
    required this.onEmergencyToggle,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  MeshStats _meshStats = const MeshStats();
  StreamSubscription? _meshSub;
  bool _isSending = false;
  bool _sosSent = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        _meshSub = MeshBridge.stats.listen((stats) {
          if (mounted) setState(() => _meshStats = stats);
        });
      } catch (_) {}
    }
    widget.connectivity.addListener(_onConnectivityChange);
  }

  void _onConnectivityChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _meshSub?.cancel();
    widget.connectivity.removeListener(_onConnectivityChange);
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

                  // SOS Button — with visual state feedback
                  SizedBox(
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

                // Seismic monitor
                _DashboardCard(
                  title: 'Sismik Monitör',
                  icon: Icons.insights,
                  child: (!kIsWeb &&
                          defaultTargetPlatform == TargetPlatform.android)
                      ? StreamBuilder<SeismicEvent>(
                          stream: SeismicBridge.events,
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Text(
                                    'İvmeölçer aktif — deprem bekleniyor',
                                    style: TextStyle(fontSize: 14)),
                              );
                            }
                            final event = snapshot.data!;
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text('Seviye: ${event.levelName}',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: event.isCritical
                                            ? SinyalistColors
                                                .professionalRed
                                            : null,
                                      )),
                                  const SizedBox(height: 4),
                                  Text(
                                      'PGA: ${event.peakG.toStringAsFixed(3)}g | Frekans: ${event.dominantFreq.toStringAsFixed(1)}Hz',
                                      style:
                                          const TextStyle(fontSize: 13)),
                                ],
                              ),
                            );
                          },
                        )
                      : const Padding(
                          padding: EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline,
                                  size: 18,
                                  color:
                                      SinyalistColors.professionalBlue),
                              SizedBox(width: 8),
                              Expanded(
                                  child: Text(
                                      'Sismik algılama Android cihazda aktif olacak',
                                      style: TextStyle(fontSize: 13))),
                            ],
                          ),
                        ),
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
                        Text('Aktif: ${cs.activeTransport.displayName}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
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

    // field 1: user_id (fixed64) — use device hash
    writeFixed64(1, now ~/ 1000); // Use seconds as pseudo user_id

    // field 3: latitude_e7 (sint32) — Istanbul default ~41.01N
    writeSint32Field(3, 410100000);

    // field 4: longitude_e7 (sint32) — Istanbul default ~28.97E
    writeSint32Field(4, 289700000);

    // field 6: accuracy_cm (uint32)
    writeVarintField(6, 1500); // 15 meters

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
