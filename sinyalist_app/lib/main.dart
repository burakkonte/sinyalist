// =============================================================================
// SINYALIST — Main Application Entry Point (v2 Field-Ready)
// =============================================================================
// Initializes: Ed25519 keypair, seismic engine, foreground service,
//              connectivity manager with real health probing.
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sinyalist/core/theme/sinyalist_theme.dart';
import 'package:sinyalist/core/bridge/native_bridge.dart';
import 'package:sinyalist/core/connectivity/connectivity_manager.dart';
import 'package:sinyalist/core/crypto/keypair_manager.dart';
import 'package:sinyalist/screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }

  runApp(const SinyalistApp());
}

class SinyalistApp extends StatefulWidget {
  const SinyalistApp({super.key});

  @override
  State<SinyalistApp> createState() => _SinyalistAppState();
}

class _SinyalistAppState extends State<SinyalistApp> with WidgetsBindingObserver {
  final ConnectivityManager _connectivity = ConnectivityManager();
  final KeypairManager _keypairManager = KeypairManager();
  bool _isEmergency = false;
  bool _isInitialized = false;
  StreamSubscription? _seismicSub;
  String _initStatus = 'Initializing...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeSystem();
  }

  Future<void> _initializeSystem() async {
    // Step 1: Initialize Ed25519 keypair
    try {
      setState(() => _initStatus = 'Generating security keys...');
      await _keypairManager.initialize();
      debugPrint('[Main] Ed25519 keypair ready');
    } catch (e) {
      debugPrint('[Main] Keypair init failed: $e');
    }

    // Step 2: Native bridges only work on Android
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        setState(() => _initStatus = 'Starting seismic engine...');
        await SeismicBridge.initialize();
        await ServiceBridge.startMonitoring();
        await SeismicBridge.start();
        _seismicSub = SeismicBridge.events.listen(_onSeismicEvent);
        debugPrint('[Main] Seismic engine started');
      }
    } catch (e) {
      debugPrint('[Main] Native init skipped (non-Android): $e');
    }

    // Step 3: Initialize connectivity with real health probing
    try {
      setState(() => _initStatus = 'Checking connectivity...');
      await _connectivity.initialize();
      debugPrint('[Main] Connectivity manager ready');
    } catch (e) {
      debugPrint('[Main] Connectivity init skipped: $e');
    }

    setState(() {
      _isInitialized = true;
      _initStatus = 'Ready';
    });
    debugPrint('[Main] System initialization complete');
  }

  void _onSeismicEvent(SeismicEvent event) {
    debugPrint('[Main] Seismic event: level=${event.level}, peakG=${event.peakG}');
    if (event.isCritical && !_isEmergency) {
      setState(() => _isEmergency = true);
      try {
        ServiceBridge.activateSurvivalMode();
        HapticFeedback.heavyImpact();
      } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[Main] App resumed — re-evaluating connectivity');
      try {
        _connectivity.initialize();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _seismicSub?.cancel();
    _connectivity.dispose();
    super.dispose();
  }

  // FIX: Toggle via postFrameCallback to prevent build-scope setState crash
  void _toggleEmergency() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _isEmergency = !_isEmergency);
    });
  }

  @override
  Widget build(BuildContext context) {
    // FIX: Use single theme (no AnimatedTheme lerp) to prevent
    // TextStyle interpolation crashes and GlobalKey conflicts
    final currentTheme = _isEmergency
        ? SinyalistTheme.oledBlack().copyWith(
            extensions: const [SinyalistSemanticColors.oled],
          )
        : SinyalistTheme.professionalWhite().copyWith(
            extensions: const [SinyalistSemanticColors.professional],
          );

    return MaterialApp(
      title: 'Sinyalist',
      debugShowCheckedModeBanner: false,
      // FIX: Single theme prop — no theme/darkTheme pair = no AnimatedTheme
      theme: currentTheme,
      home: _isInitialized
          ? HomeScreen(
              // FIX: UniqueKey forces clean rebuild — no stale GlobalKeys
              key: ValueKey<bool>(_isEmergency),
              connectivity: _connectivity,
              isEmergency: _isEmergency,
              onEmergencyToggle: _toggleEmergency,
            )
          : _SplashScreen(status: _initStatus),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  final String status;
  const _SplashScreen({required this.status});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SinyalistColors.oledBlack,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield, size: 64, color: SinyalistColors.emergencyRed),
            const SizedBox(height: 24),
            const Text(
              'SINYALIST',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              status,
              style: const TextStyle(
                  fontSize: 14, color: SinyalistColors.oledTextSecondary),
            ),
            const SizedBox(height: 32),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: SinyalistColors.emergencyRed,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
