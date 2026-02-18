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

  const DeliveryConfig({
    this.smsEnabled = false,   // SMS requires explicit opt-in
    this.bleEnabled = true,
    this.rateLimitWindow = const Duration(seconds: 30),
    this.maxSendsPerWindow = 5,
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
        error: 'Rate limited — please wait',
      );
      _addRecord(record);
      return DeliveryResult(
        finalState: DeliveryState.failed,
        error: 'Rate limited',
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
      _updateRecord(packetIdHex, DeliveryState.failed, error: 'Signing failed: $e');
      return DeliveryResult(
        finalState: DeliveryState.failed,
        error: 'Signing failed: $e',
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

    // Step 3: Try SMS (if enabled)
    if (config.smsEnabled) {
      _transition(DeliveryState.sendingSms, packetIdHex);
      // SMS sending is platform-specific and requires native bridge
      // For now, we log the attempt and fall through
      debugPrint('[$_tag] SMS transport: would send ${signedPacket.length} bytes');
      // TODO: integrate with platform SMS sender when available
      debugPrint('[$_tag] SMS not yet integrated with native sender');
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
        error: 'All transports exhausted');
    return DeliveryResult(
      finalState: DeliveryState.failed,
      error: 'All transports exhausted',
      elapsed: stopwatch.elapsed,
    );
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
