// =============================================================================
// SINYALIST — Hybrid Connectivity State Machine
// =============================================================================

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:sinyalist/core/bridge/native_bridge.dart';

// ---------------------------------------------------------------------------
// Transport priority
// ---------------------------------------------------------------------------
enum TransportMode {
  grpc(0, 'gRPC'),
  sms(1, 'SMS Gateway'),
  bleMesh(2, 'BLE Mesh'),
  wifiP2p(3, 'Wi-Fi Direct'),
  none(99, 'No Connection');

  final int priority;
  final String displayName;
  const TransportMode(this.priority, this.displayName);
}

// ---------------------------------------------------------------------------
// Connectivity state
// ---------------------------------------------------------------------------
class ConnectivityState {
  final TransportMode activeTransport;
  final bool hasInternet;
  final bool hasCellular;
  final bool hasBluetooth;
  final bool hasWifiDirect;
  final int meshPeerCount;
  final DateTime lastStateChange;

  const ConnectivityState({
    this.activeTransport = TransportMode.none,
    this.hasInternet = false,
    this.hasCellular = false,
    this.hasBluetooth = false,
    this.hasWifiDirect = false,
    this.meshPeerCount = 0,
    required this.lastStateChange,
  });

  ConnectivityState copyWith({
    TransportMode? activeTransport,
    bool? hasInternet,
    bool? hasCellular,
    bool? hasBluetooth,
    bool? hasWifiDirect,
    int? meshPeerCount,
  }) => ConnectivityState(
    activeTransport: activeTransport ?? this.activeTransport,
    hasInternet: hasInternet ?? this.hasInternet,
    hasCellular: hasCellular ?? this.hasCellular,
    hasBluetooth: hasBluetooth ?? this.hasBluetooth,
    hasWifiDirect: hasWifiDirect ?? this.hasWifiDirect,
    meshPeerCount: meshPeerCount ?? this.meshPeerCount,
    lastStateChange: DateTime.now(),
  );

  bool get isFullyOffline =>
      !hasInternet && !hasCellular && !hasBluetooth && !hasWifiDirect;
}

// ---------------------------------------------------------------------------
// Connectivity Manager
// ---------------------------------------------------------------------------
class ConnectivityManager extends ChangeNotifier {
  ConnectivityState _state = ConnectivityState(lastStateChange: DateTime.now());
  ConnectivityState get state => _state;

  Timer? _healthCheckTimer;
  StreamSubscription? _meshSubscription;

  static const _healthCheckInterval = Duration(seconds: 15);
  static const _maxRetries = 3;

  Future<void> initialize() async {
    _healthCheckTimer = Timer.periodic(_healthCheckInterval, (_) => _evaluateTransport());

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        _meshSubscription = MeshBridge.stats.listen((stats) {
          _state = _state.copyWith(
            meshPeerCount: stats.activeNodes,
            hasBluetooth: stats.activeNodes > 0,
          );
          _evaluateTransport();
        });
      } catch (e) {
        debugPrint('Mesh listener unavailable: $e');
      }
    }

    await _evaluateTransport();
  }

  Future<void> _evaluateTransport() async {
    final internetAvailable = await _checkInternet();
    _state = _state.copyWith(hasInternet: internetAvailable);

    TransportMode best;
    if (internetAvailable) {
      best = TransportMode.grpc;
    } else if (_state.hasCellular) {
      best = TransportMode.sms;
    } else if (_state.hasBluetooth && _state.meshPeerCount > 0) {
      best = TransportMode.bleMesh;
    } else if (_state.hasWifiDirect) {
      best = TransportMode.wifiP2p;
    } else {
      best = TransportMode.none;
    }

    if (best != _state.activeTransport) {
      debugPrint('[Connectivity] ${_state.activeTransport.displayName} -> ${best.displayName}');
      _state = _state.copyWith(activeTransport: best);

      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        if (best == TransportMode.bleMesh || best == TransportMode.none) {
          await _activateMesh();
        }
      }

      notifyListeners();
    }
  }

  Future<SendResult> sendPacket(Uint8List protobufBytes) async {
    switch (_state.activeTransport) {
      case TransportMode.grpc:
        return _sendViaGrpc(protobufBytes);
      case TransportMode.sms:
        return _sendViaSms(protobufBytes);
      case TransportMode.bleMesh:
      case TransportMode.wifiP2p:
      case TransportMode.none:
        return _sendViaMesh(protobufBytes);
    }
  }

  Future<SendResult> _sendViaGrpc(Uint8List data) async {
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        return SendResult.success(TransportMode.grpc);
      } catch (e) {
        if (attempt == _maxRetries - 1) {
          _state = _state.copyWith(hasInternet: false);
          return _sendViaSms(data);
        }
      }
    }
    return SendResult.failure('gRPC exhausted');
  }

  Future<SendResult> _sendViaSms(Uint8List data) async {
    try {
      return SendResult.success(TransportMode.sms);
    } catch (e) {
      return _sendViaMesh(data);
    }
  }

  Future<SendResult> _sendViaMesh(Uint8List data) async {
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        await MeshBridge.broadcastPacket(data);
      }
      return SendResult.success(TransportMode.bleMesh);
    } catch (e) {
      return SendResult.failure('All transports exhausted');
    }
  }

  Future<bool> _checkInternet() async {
    try {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _activateMesh() async {
    try {
      final initialized = await MeshBridge.initialize();
      if (initialized) await MeshBridge.startMesh();
    } catch (e) {
      debugPrint('Mesh activation failed: $e');
    }
  }

  @override
  void dispose() {
    _healthCheckTimer?.cancel();
    _meshSubscription?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Send result
// ---------------------------------------------------------------------------
class SendResult {
  final bool isSuccess;
  final TransportMode? transport;
  final String? error;

  const SendResult._({required this.isSuccess, this.transport, this.error});

  factory SendResult.success(TransportMode transport) =>
      SendResult._(isSuccess: true, transport: transport);
  factory SendResult.failure(String error) =>
      SendResult._(isSuccess: false, error: error);
}
