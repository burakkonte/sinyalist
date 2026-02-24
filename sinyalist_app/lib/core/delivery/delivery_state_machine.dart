// =============================================================================
// SINYALIST — Delivery State Machine
// =============================================================================
// States: created -> signing -> sending_internet -> sending_sms
//         -> sending_ble -> delivered / failed
// Deterministic fallback: Internet -> SMS (if allowed) -> BLE
// Rate-limits UI actions to prevent panic spam.
// =============================================================================

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:sinyalist/core/delivery/ingest_client.dart';
import 'package:sinyalist/core/crypto/keypair_manager.dart';
import 'package:sinyalist/core/bridge/native_bridge.dart';
import 'package:sinyalist/core/codec/sms_codec.dart';
import 'package:sinyalist/core/sms/sms_bridge.dart';

/// Delivery lifecycle states.
enum DeliveryState {
  created,
  signing,
  sendingInternet,
  sendingSms,
  sendingBle,
  delivered,
  failed,
}

/// Delivery attempt result.
class DeliveryResult {
  final DeliveryState finalState;
  final String? transport;     // Which transport delivered it
  final String? error;
  final double? confidence;    // From server ACK
  final int? serverTimestampMs;
  final Duration elapsed;

  const DeliveryResult({
    required this.finalState,
    this.transport,
    this.error,
    this.confidence,
    this.serverTimestampMs,
    required this.elapsed,
  });

  bool get isDelivered => finalState == DeliveryState.delivered;
  bool get isFailed => finalState == DeliveryState.failed;

  @override
  String toString() => 'DeliveryResult(state=$finalState, '
      'transport=$transport, confidence=$confidence, error=$error, '
      'elapsed=${elapsed.inMilliseconds}ms)';
}

/// Record of a delivery attempt for UI display.
class DeliveryRecord {
  final String packetId;
  final DeliveryState state;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? transport;
  final String? error;
  final double? confidence;

  DeliveryRecord({
    required this.packetId,
    required this.state,
    required this.createdAt,
    this.completedAt,
    this.transport,
    this.error,
    this.confidence,
  });

  DeliveryRecord copyWith({
    DeliveryState? state,
    DateTime? completedAt,
    String? transport,
    String? error,
    double? confidence,
  }) {
    return DeliveryRecord(
      packetId: packetId,
      state: state ?? this.state,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
      transport: transport ?? this.transport,
      error: error ?? this.error,
      confidence: confidence ?? this.confidence,
    );
  }
}

/// Configuration for the delivery state machine.
class DeliveryConfig {
  final bool smsEnabled;
  final bool bleEnabled;
  final Duration rateLimitWindow;
  final int maxSendsPerWindow;
  /// E.164 formatted SMS relay number (e.g. "+905001234567").
  /// Used when internet and BLE are unavailable.
  /// Set to empty string to disable SMS even when smsEnabled=true.
  final String smsRelayNumber;

  const DeliveryConfig({
    this.smsEnabled = true,
    this.bleEnabled = true,
    this.rateLimitWindow = const Duration(seconds: 30),
    this.maxSendsPerWindow = 5,
    this.smsRelayNumber = '',  // Must be configured in production
  });
}

/// Delivery state machine with deterministic fallback cascade.
class DeliveryStateMachine extends ChangeNotifier {
  static const String _tag = 'DeliveryFSM';

  final IngestClient _ingestClient;
  final KeypairManager _keypairManager;
  final DeliveryConfig config;

  // Rate limiting state
  final List<DateTime> _recentSends = [];

  // History for UI
  final List<DeliveryRecord> _history = [];
  List<DeliveryRecord> get history => List.unmodifiable(_history);

  // Current state
  DeliveryState _currentState = DeliveryState.created;
  DeliveryState get currentState => _currentState;

  // Internet availability (set externally by connectivity manager)
  bool internetAvailable = false;

  DeliveryStateMachine({
    required IngestClient ingestClient,
    required KeypairManager keypairManager,
    this.config = const DeliveryConfig(),
  })  : _ingestClient = ingestClient,
        _keypairManager = keypairManager;

  /// Check if sending is allowed (rate limiting).
  bool get canSend {
    _pruneRateLimitWindow();
    return _recentSends.length < config.maxSendsPerWindow;
  }

  int get remainingSends {
    _pruneRateLimitWindow();
    return (config.maxSendsPerWindow - _recentSends.length).clamp(0, config.maxSendsPerWindow);
  }

  void _pruneRateLimitWindow() {
    final cutoff = DateTime.now().subtract(config.rateLimitWindow);
    _recentSends.removeWhere((t) => t.isBefore(cutoff));
  }

  /// Execute the full delivery cascade for a protobuf-encoded packet.
  /// The packet should NOT yet have signature/public_key fields set —
  /// this method will sign it.
  ///
  /// [rawPacketWithoutSig] is the protobuf bytes WITHOUT signature fields.
  /// Returns a DeliveryResult describing the outcome.
  Future<DeliveryResult> deliver(Uint8List rawPacketWithoutSig) async {
    final stopwatch = Stopwatch()..start();
    final packetIdHex = _extractPacketIdHex(rawPacketWithoutSig);

    // Rate limit check
    if (!canSend) {
      debugPrint('[$_tag] RATE LIMITED — ${_recentSends.length}/${config.maxSendsPerWindow} sends in window');
      final record = DeliveryRecord(
        packetId: packetIdHex,
        state: DeliveryState.failed,
        createdAt: DateTime.now(),
        completedAt: DateTime.now(),
        error: 'Hız sınırı — lütfen bekleyin',
      );
      _addRecord(record);
      return DeliveryResult(
        finalState: DeliveryState.failed,
        error: 'Hız sınırı',
        elapsed: stopwatch.elapsed,
      );
    }

    _recentSends.add(DateTime.now());

    final record = DeliveryRecord(
      packetId: packetIdHex,
      state: DeliveryState.created,
      createdAt: DateTime.now(),
    );
    _addRecord(record);

    // Step 1: Sign the packet
    _transition(DeliveryState.signing, packetIdHex);
    Uint8List signedPacket;
    try {
      signedPacket = await _signPacket(rawPacketWithoutSig);
      debugPrint('[$_tag] Packet signed (${signedPacket.length} bytes)');
    } catch (e) {
      debugPrint('[$_tag] Signing failed: $e');
      _updateRecord(packetIdHex, DeliveryState.failed, error: 'İmzalama hatası: $e');
      return DeliveryResult(
        finalState: DeliveryState.failed,
        error: 'İmzalama hatası: $e',
        elapsed: stopwatch.elapsed,
      );
    }

    // Step 2: Try Internet
    if (internetAvailable) {
      _transition(DeliveryState.sendingInternet, packetIdHex);
      final ack = await _ingestClient.send(signedPacket);

      if (ack.isAccepted) {
        debugPrint('[$_tag] Delivered via INTERNET (confidence=${ack.confidence})');
        _updateRecord(packetIdHex, DeliveryState.delivered,
            transport: 'internet', confidence: ack.confidence);
        return DeliveryResult(
          finalState: DeliveryState.delivered,
          transport: 'internet',
          confidence: ack.confidence,
          serverTimestampMs: ack.serverTimestampMs,
          elapsed: stopwatch.elapsed,
        );
      }

      debugPrint('[$_tag] Internet delivery failed: ${ack.error}');
    } else {
      debugPrint('[$_tag] Internet not available, skipping');
    }

    // Step 3: Try SMS (if enabled and relay number is configured)
    if (config.smsEnabled &&
        config.smsRelayNumber.isNotEmpty &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
          final smsPermission = await SmsBridge.hasPermission();
      final hasCellularService = await SmsBridge.hasCellularService();
      if (!smsPermission) {
        debugPrint('[$_tag] SMS skipped — SEND_SMS permission missing');
      } else if (!hasCellularService) {
        debugPrint('[$_tag] SMS skipped — no cellular service');
      } else {
      _transition(DeliveryState.sendingSms, packetIdHex);
      try {
        // Build compact SMS payload from the signed packet.
        // We extract fields from the raw (pre-sign) packet bytes and encode
        // them into the compact SY1 format that fits in 160 chars.
        final smsPayload = _buildSmsPayload(rawPacketWithoutSig);
        if (smsPayload != null) {
          final smsMessages = SmsCodec.encode(smsPayload);
          debugPrint('[$_tag] SMS: encoding into ${smsMessages.length} part(s) '
              '→ ${smsMessages.map((m) => m.length).toList()} chars');

          final smsResult = await SmsBridge.send(
            address: config.smsRelayNumber,
            messages: smsMessages,
          );

          if (smsResult.isSuccess) {
            debugPrint('[$_tag] Delivered via SMS (${smsMessages.length} part(s), '
                'msgId=${smsResult.msgId})');
            _updateRecord(packetIdHex, DeliveryState.delivered,
                transport: 'sms');
            return DeliveryResult(
              finalState: DeliveryState.delivered,
              transport: 'sms',
              elapsed: stopwatch.elapsed,
            );
          } else {
            debugPrint('[$_tag] SMS delivery failed: ${smsResult.error}');
          }
        } else {
          debugPrint('[$_tag] SMS payload extraction failed — skipping SMS');
        }
      } catch (e) {
        debugPrint('[$_tag] SMS transport error: $e');
      }
      }
    } else if (config.smsEnabled && config.smsRelayNumber.isEmpty) {
      debugPrint('[$_tag] SMS skipped — no relay number configured');
    }

    // Step 4: Try BLE mesh (Android only — plugin not available on web)
    if (config.bleEnabled &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      _transition(DeliveryState.sendingBle, packetIdHex);
      try {
        await MeshBridge.broadcastPacket(signedPacket);
        debugPrint('[$_tag] Packet injected into BLE mesh');
        _updateRecord(packetIdHex, DeliveryState.delivered, transport: 'ble_mesh');
        return DeliveryResult(
          finalState: DeliveryState.delivered,
          transport: 'ble_mesh',
          elapsed: stopwatch.elapsed,
        );
      } catch (e) {
        debugPrint('[$_tag] BLE mesh injection failed: $e');
      }
    } else if (config.bleEnabled) {
      debugPrint('[$_tag] BLE mesh skipped (not supported on ${kIsWeb ? "web" : defaultTargetPlatform.name})');
    }

    // All transports exhausted
    _updateRecord(packetIdHex, DeliveryState.failed,
        error: 'Tüm kanallar tükendi');
    return DeliveryResult(
      finalState: DeliveryState.failed,
      error: 'All transports exhausted',
      elapsed: stopwatch.elapsed,
    );
  }

  /// Extract key fields from a raw protobuf SinyalistPacket and build an
  /// [SmsPayload] for compact SMS encoding.
  ///
  /// The raw packet is NOT fully parsed here — we do a best-effort linear scan
  /// for the fields we need (lat/lon/accuracy/timestamp/trapped/msg_type/packet_id).
  /// Unknown fields are ignored. Returns null if extraction fails.
  SmsPayload? _buildSmsPayload(Uint8List rawPacket) {
    try {
      int latE7 = 0;
      int lonE7 = 0;
      int accuracyCm = 0;
      int trappedStatus = 0;
      int createdAtMs = 0;
      int msgType = 0;
      Uint8List packetId = Uint8List(16);

      int pos = 0;

      int readVarint() {
        int result = 0;
        int shift = 0;
        while (pos < rawPacket.length) {
          final byte = rawPacket[pos++];
          result |= (byte & 0x7F) << shift;
          if ((byte & 0x80) == 0) break;
          shift += 7;
        }
        return result;
      }

      int readZigzag() {
        final n = readVarint();
        return (n >> 1) ^ -(n & 1);
      }

      // Read little-endian uint64 (two uint32s)
      int readFixed64() {
        if (pos + 8 > rawPacket.length) { pos += 8; return 0; }
        final bd = ByteData.sublistView(rawPacket, pos, pos + 8);
        final lo = bd.getUint32(0, Endian.little);
        final hi = bd.getUint32(4, Endian.little);
        pos += 8;
        return (hi << 32) | lo;
      }

      while (pos < rawPacket.length) {
        final tag = readVarint();
        final fieldNumber = tag >> 3;
        final wireType = tag & 0x7;

        switch (wireType) {
          case 0: // varint
            final val = readVarint();
            switch (fieldNumber) {
              case 6: accuracyCm = val; break;
              case 13: break; // battery — ignore
              case 21: trappedStatus = val > 0 ? 1 : 0; break;
              case 26: msgType = val; break;
              case 27: break; // priority — ignore
            }
                        break;
          case 1: // fixed64
            final val = readFixed64();
            switch (fieldNumber) {
              case 16: break; // timestamp_ms — prefer created_at_ms
              case 25: createdAtMs = val; break;
            }
                        break;
          case 2: // length-delimited
            final len = readVarint();
            if (fieldNumber == 24 && len >= 16) { // packet_id
              packetId = rawPacket.sublist(pos, pos + 16);
              pos += len;
            } else {
              pos += len;
            }
                        break;
          default:
            // Unknown wire type — stop parsing to avoid corruption
            pos = rawPacket.length;
                        break;
        }
      }

      // Re-scan for sint32 lat/lon (wire type 0 with zigzag)
      pos = 0;
      while (pos < rawPacket.length) {
        final tag = readVarint();
        final fieldNumber = tag >> 3;
        final wireType = tag & 0x7;
        if (wireType == 0) {
          if (fieldNumber == 3) {
            latE7 = readZigzag();
          } else if (fieldNumber == 4) {
            lonE7 = readZigzag();
          } else {
            readVarint(); // consume and discard
          }
        } else if (wireType == 1) {
          pos += 8;
        } else if (wireType == 2) {
          final len = readVarint();
          pos += len;
        } else {
          break;
        }
      }

      if (createdAtMs == 0) {
        createdAtMs = DateTime.now().millisecondsSinceEpoch;
      }

      return SmsPayload(
        packetId: packetId,
        latitudeE7: latE7,
        longitudeE7: lonE7,
        accuracyCm: accuracyCm,
        trappedStatus: trappedStatus,
        createdAtMs: createdAtMs,
        msgType: msgType,
      );
    } catch (e) {
      debugPrint('[$_tag] _buildSmsPayload error: $e');
      return null;
    }
  }

  /// Sign the packet by appending Ed25519 signature and public key fields.
  Future<Uint8List> _signPacket(Uint8List rawPacket) async {
    if (!_keypairManager.isInitialized) {
      throw StateError('KeypairManager not initialized');
    }

    final signature = await _keypairManager.sign(rawPacket);
    final pubKey = _keypairManager.publicKeyBytes!;

    // Append protobuf fields:
    //   field 28 (ed25519_signature):  tag varint = (28 << 3) | 2 = 226 → [0xE2, 0x01]
    //   field 29 (ed25519_public_key): tag varint = (29 << 3) | 2 = 234 → [0xEA, 0x01]
    // _writeProtobufField handles correct varint-encoded tag + length + data.
    // FIX: removed dead first BytesBuilder (`builder`) that was allocated but
    // never used — only `result` is needed.
    final result = BytesBuilder();
    result.add(rawPacket);

    // Encode field 28 (signature, 64 bytes)
    _writeProtobufField(result, 28, signature);

    // Encode field 29 (public key, 32 bytes)
    _writeProtobufField(result, 29, pubKey);

    return result.toBytes();
  }

  /// Write a protobuf bytes field (wire type 2).
  void _writeProtobufField(BytesBuilder builder, int fieldNumber, Uint8List data) {
    // Tag = (fieldNumber << 3) | 2
    final tag = (fieldNumber << 3) | 2;
    _writeVarint(builder, tag);
    _writeVarint(builder, data.length);
    builder.add(data);
  }

  /// Write a varint to the builder.
  void _writeVarint(BytesBuilder builder, int value) {
    var v = value;
    while (v > 0x7F) {
      builder.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    builder.addByte(v & 0x7F);
  }

  void _transition(DeliveryState newState, String packetId) {
    _currentState = newState;
    _updateRecordState(packetId, newState);
    debugPrint('[$_tag] [$packetId] -> $newState');
    notifyListeners();
  }

  void _addRecord(DeliveryRecord record) {
    _history.add(record);
    // Keep last 50 records
    while (_history.length > 50) {
      _history.removeAt(0);
    }
    notifyListeners();
  }

  void _updateRecord(String packetId, DeliveryState state,
      {String? transport, String? error, double? confidence}) {
    final idx = _history.lastIndexWhere((r) => r.packetId == packetId);
    if (idx >= 0) {
      _history[idx] = _history[idx].copyWith(
        state: state,
        completedAt: DateTime.now(),
        transport: transport,
        error: error,
        confidence: confidence,
      );
    }
    _currentState = state;
    notifyListeners();
  }

  void _updateRecordState(String packetId, DeliveryState state) {
    final idx = _history.lastIndexWhere((r) => r.packetId == packetId);
    if (idx >= 0) {
      _history[idx] = _history[idx].copyWith(state: state);
    }
  }

  String _extractPacketIdHex(Uint8List data) {
    // Try to extract packet_id from protobuf field 24 (bytes)
    // For display purposes, just use first 4 bytes of data as hex
    if (data.length >= 4) {
      return data.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }
    return 'unknown';
  }
}
