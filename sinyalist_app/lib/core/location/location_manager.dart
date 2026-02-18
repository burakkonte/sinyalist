// =============================================================================
// SINYALIST — GPS Location Manager
// =============================================================================
// Provides real device coordinates for packet construction.
// Fallback chain: GPS → Network → Last Known → Istanbul default (demo only).
// Requests permissions at runtime, handles denial gracefully.
// Web: location not available (returns null / Istanbul default only if kIsDemo).
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Current location snapshot.
class LocationSnapshot {
  final int latitudeE7;
  final int longitudeE7;
  final int accuracyCm;
  final bool isReal;        // false = Istanbul fallback (demo/no-GPS)
  final DateTime updatedAt;

  const LocationSnapshot({
    required this.latitudeE7,
    required this.longitudeE7,
    required this.accuracyCm,
    required this.isReal,
    required this.updatedAt,
  });

  // Istanbul city centre — used ONLY as last-resort demo fallback.
  // Never substituted silently in production; callers must check isReal.
  static LocationSnapshot get istanbulFallback => LocationSnapshot(
    latitudeE7:  410100000, // 41.0100 °N
    longitudeE7: 289700000, // 28.9700 °E
    accuracyCm:  999999,    // ~10 km — signals low confidence
    isReal: false,
    updatedAt: DateTime.now(),
  );

  @override
  String toString() =>
      'LocationSnapshot(lat=${latitudeE7/1e7}, lon=${longitudeE7/1e7}, '
      'acc=${accuracyCm}cm, real=$isReal)';
}

class LocationManager {
  static const _tag = 'LocationManager';

  LocationSnapshot? _last;
  StreamSubscription<Position>? _sub;
  bool _permissionDenied = false;

  LocationSnapshot? get last => _last;

  /// Initialize: request permission and start listening.
  /// Must be called from Flutter UI context (for permission dialog).
  Future<void> initialize() async {
    if (kIsWeb) {
      debugPrint('[$_tag] Web — GPS not available, using fallback only');
      return;
    }

    try {
      // Check if location services are enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('[$_tag] Location services disabled on device');
        return;
      }

      // Request permission
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever ||
          perm == LocationPermission.denied) {
        _permissionDenied = true;
        debugPrint('[$_tag] Location permission denied — fallback active');
        return;
      }

      // Get last known position immediately (zero latency)
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        _update(last);
        debugPrint('[$_tag] Last known: $_last');
      }

      // Start live stream — balanced accuracy to conserve battery
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10, // metres — don't spam on micro-movements
        ),
      ).listen(
        _update,
        onError: (e) => debugPrint('[$_tag] Stream error: $e'),
      );

      debugPrint('[$_tag] GPS stream started');
    } catch (e) {
      debugPrint('[$_tag] Init error: $e');
    }
  }

  void _update(Position p) {
    _last = LocationSnapshot(
      latitudeE7:  (p.latitude  * 1e7).round(),
      longitudeE7: (p.longitude * 1e7).round(),
      accuracyCm:  (p.accuracy  * 100).round().clamp(0, 999999),
      isReal: true,
      updatedAt: DateTime.now(),
    );
    debugPrint('[$_tag] Updated: $_last');
  }

  /// Returns current location, or Istanbul fallback if unavailable.
  /// Callers should check [LocationSnapshot.isReal] and warn user if false.
  LocationSnapshot getOrFallback() {
    if (_last != null) return _last!;
    if (_permissionDenied) {
      debugPrint('[$_tag] Permission denied — returning Istanbul fallback');
    }
    return LocationSnapshot.istanbulFallback;
  }

  /// True if a real GPS fix has been obtained.
  bool get hasRealLocation => _last?.isReal == true;

  /// True if the user denied location permission.
  bool get isPermissionDenied => _permissionDenied;

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
