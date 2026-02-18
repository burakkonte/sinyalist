// =============================================================================
// SINYALIST — Native Bridge (Flutter ↔ Kotlin/NDK)
// =============================================================================

import 'dart:async';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// Seismic Event from C++ engine
// ---------------------------------------------------------------------------
class SeismicEvent {
  final int level;
  final double peakG;
  final double staLtaRatio;
  final double dominantFreq;
  final int detectionTimeMs;
  final int durationSamples;

  const SeismicEvent({
    required this.level,
    required this.peakG,
    required this.staLtaRatio,
    required this.dominantFreq,
    required this.detectionTimeMs,
    required this.durationSamples,
  });

  factory SeismicEvent.fromMap(Map<dynamic, dynamic> map) => SeismicEvent(
    level: map['level'] as int? ?? 0,
    peakG: (map['peakG'] as num?)?.toDouble() ?? 0.0,
    staLtaRatio: (map['staLtaRatio'] as num?)?.toDouble() ?? 0.0,
    dominantFreq: (map['dominantFreq'] as num?)?.toDouble() ?? 0.0,
    detectionTimeMs: map['detectionTimeMs'] as int? ?? 0,
    durationSamples: map['durationSamples'] as int? ?? 0,
  );

  String get levelName =>
      const ['None', 'Tremor', 'Moderate', 'Severe', 'CRITICAL'][level.clamp(0, 4)];
  bool get isCritical => level >= 3;
}

// ---------------------------------------------------------------------------
// Mesh stats from Nodus BLE layer
// ---------------------------------------------------------------------------
class MeshStats {
  final int activeNodes;
  final int bufferedPackets;
  final int totalRelayed;
  final double bloomFillRatio;

  const MeshStats({
    this.activeNodes = 0,
    this.bufferedPackets = 0,
    this.totalRelayed = 0,
    this.bloomFillRatio = 0.0,
  });

  factory MeshStats.fromMap(Map<dynamic, dynamic> map) => MeshStats(
    activeNodes: map['activeNodes'] as int? ?? 0,
    bufferedPackets: map['bufferedPackets'] as int? ?? 0,
    totalRelayed: map['totalRelayed'] as int? ?? 0,
    bloomFillRatio: (map['bloomFillRatio'] as num?)?.toDouble() ?? 0.0,
  );
}

// ---------------------------------------------------------------------------
// Seismic Engine Bridge
// ---------------------------------------------------------------------------
class SeismicBridge {
  // FIX: MethodChannel/EventChannel are NOT const constructors → use static final
  static final MethodChannel _method = MethodChannel('com.sinyalist/seismic');
  static final EventChannel _events = EventChannel('com.sinyalist/seismic_events');

  static Stream<SeismicEvent>? _eventStream;

  static Future<void> initialize() async {
    await _method.invokeMethod('initialize');
  }

  static Future<void> start() async {
    await _method.invokeMethod('start');
  }

  static Future<void> stop() async {
    await _method.invokeMethod('stop');
  }

  static Future<void> reset() async {
    await _method.invokeMethod('reset');
  }

  static Future<bool> get isRunning async {
    return await _method.invokeMethod<bool>('isRunning') ?? false;
  }

  static Stream<SeismicEvent> get events {
    _eventStream ??= _events.receiveBroadcastStream().map(
      (event) => SeismicEvent.fromMap(event as Map<dynamic, dynamic>),
    );
    return _eventStream!;
  }
}

// ---------------------------------------------------------------------------
// Mesh Network Bridge
// ---------------------------------------------------------------------------
class MeshBridge {
  static final MethodChannel _method = MethodChannel('com.sinyalist/mesh');
  static final EventChannel _events = EventChannel('com.sinyalist/mesh_events');

  static Stream<MeshStats>? _statsStream;

  static Future<bool> initialize() async {
    return await _method.invokeMethod<bool>('initialize') ?? false;
  }

  static Future<void> startMesh() async {
    await _method.invokeMethod('startMesh');
  }

  static Future<void> stopMesh() async {
    await _method.invokeMethod('stopMesh');
  }

  static Future<void> broadcastPacket(Uint8List protobufBytes) async {
    await _method.invokeMethod('broadcastPacket', protobufBytes);
  }

  static Future<MeshStats> getStats() async {
    final map = await _method.invokeMethod<Map>('getStats');
    return map != null ? MeshStats.fromMap(map) : const MeshStats();
  }

  static Stream<MeshStats> get stats {
    _statsStream ??= _events.receiveBroadcastStream().map(
      (event) => MeshStats.fromMap(event as Map<dynamic, dynamic>),
    );
    return _statsStream!;
  }
}

// ---------------------------------------------------------------------------
// Foreground Service Bridge
// ---------------------------------------------------------------------------
class ServiceBridge {
  static final MethodChannel _method = MethodChannel('com.sinyalist/service');

  static Future<void> startMonitoring() async {
    await _method.invokeMethod('startMonitoring');
  }

  static Future<void> stopMonitoring() async {
    await _method.invokeMethod('stopMonitoring');
  }

  static Future<void> activateSurvivalMode() async {
    await _method.invokeMethod('activateSurvivalMode');
  }
}
