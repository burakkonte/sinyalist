// =============================================================================
// SINYALIST — iOS AppDelegate
// =============================================================================
// Uses FlutterImplicitEngineDelegate (new Flutter iOS embedding, scene-based)
// to register all MethodChannels and EventChannels after the engine is ready.
//
// Channel names match Android exactly — native_bridge.dart works on both
// platforms without modification.
//
// Bridges registered:
//   com.sinyalist/seismic        → SinyalistSeismicEngine (CoreMotion)
//   com.sinyalist/seismic_events → SinyalistSeismicEngine stream
//   com.sinyalist/mesh           → SinyalistMeshController (CoreBluetooth)
//   com.sinyalist/mesh_events    → SinyalistMeshController stream
//   com.sinyalist/service        → SinyalistBackgroundManager
//   com.sinyalist/sms            → Unsupported on iOS (error response)
//   com.sinyalist/sms_events     → Empty stream
// =============================================================================

import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

    private var seismicEngine: SinyalistSeismicEngine?
    private var meshController: SinyalistMeshController?
    private var backgroundManager: SinyalistBackgroundManager?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // Called by Flutter once the engine is fully initialized.
    // This is the correct hook for the scene-based Flutter embedding.
    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        // Get binary messenger through a named plugin registrar
        let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "com.sinyalist.native")
        let messenger = registrar.messenger()

        // Initialize native components
        let engine = SinyalistSeismicEngine()
        engine.initialize()
        seismicEngine = engine

        let mesh = SinyalistMeshController()
        meshController = mesh

        let bgMgr = SinyalistBackgroundManager()
        backgroundManager = bgMgr

        setupChannels(messenger: messenger)
    }

    // -------------------------------------------------------------------------
    // Channel registration
    // -------------------------------------------------------------------------

    private func setupChannels(messenger: FlutterBinaryMessenger) {
        setupSeismicChannel(messenger: messenger)
        setupMeshChannel(messenger: messenger)
        setupServiceChannel(messenger: messenger)
        setupSmsChannel(messenger: messenger)
    }

    private func setupSeismicChannel(messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: "com.sinyalist/seismic",
                             binaryMessenger: messenger)
        .setMethodCallHandler { [weak self] call, result in
            guard let engine = self?.seismicEngine else {
                result(FlutterError(code: "NOT_READY", message: "Seismic engine not initialized", details: nil))
                return
            }
            switch call.method {
            case "initialize": engine.initialize(); result("ok")
            case "start":      engine.start();      result("ok")
            case "stop":       engine.stop();       result("ok")
            case "reset":      engine.reset();      result("ok")
            case "destroy":    engine.stop();       result("ok")
            case "isRunning":  result(engine.isRunning)
            default:           result(FlutterMethodNotImplemented)
            }
        }

        FlutterEventChannel(name: "com.sinyalist/seismic_events",
                            binaryMessenger: messenger)
        .setStreamHandler(seismicEngine)
    }

    private func setupMeshChannel(messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: "com.sinyalist/mesh",
                             binaryMessenger: messenger)
        .setMethodCallHandler { [weak self] call, result in
            guard let mesh = self?.meshController else {
                result(FlutterError(code: "NOT_READY", message: "Mesh controller not initialized", details: nil))
                return
            }
            switch call.method {
            case "initialize":
                result(mesh.initialize())
            case "startMesh":
                mesh.startMesh(); result("ok")
            case "stopMesh":
                mesh.stopMesh(); result("ok")
            case "broadcastPacket":
                if let bytes = call.arguments as? FlutterStandardTypedData {
                    mesh.broadcastPacket(bytes.data)
                    result("ok")
                } else {
                    result(FlutterError(code: "INVALID_ARGS", message: "Expected byte array", details: nil))
                }
            case "getStats":
                result(mesh.getStats())
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        FlutterEventChannel(name: "com.sinyalist/mesh_events",
                            binaryMessenger: messenger)
        .setStreamHandler(meshController)
    }

    private func setupServiceChannel(messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: "com.sinyalist/service",
                             binaryMessenger: messenger)
        .setMethodCallHandler { [weak self] call, result in
            guard let bgMgr = self?.backgroundManager else {
                result(FlutterError(code: "NOT_READY", message: "Background manager not initialized", details: nil))
                return
            }
            switch call.method {
            case "startMonitoring":
                bgMgr.startMonitoring()
                self?.seismicEngine?.start()
                self?.meshController?.initialize()
                self?.meshController?.startMesh()
                result("ok")
            case "stopMonitoring":
                bgMgr.stopMonitoring()
                self?.seismicEngine?.stop()
                self?.meshController?.stopMesh()
                result("ok")
            case "activateSurvivalMode":
                bgMgr.activateSurvivalMode()
                result("ok")
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func setupSmsChannel(messenger: FlutterBinaryMessenger) {
        // SMS is not available on iOS — return error so the Dart cascade
        // falls through to BLE mesh, which is the correct fallback behavior.
        FlutterMethodChannel(name: "com.sinyalist/sms",
                             binaryMessenger: messenger)
        .setMethodCallHandler { _, result in
            result(FlutterError(
                code: "SMS_NOT_SUPPORTED",
                message: "SMS transport is not available on iOS. BLE mesh will be used as fallback.",
                details: nil
            ))
        }

        // SMS event stream — empty on iOS
        FlutterEventChannel(name: "com.sinyalist/sms_events",
                            binaryMessenger: messenger)
        .setStreamHandler(NoOpStreamHandler())
    }

    // -------------------------------------------------------------------------
    // App lifecycle
    // -------------------------------------------------------------------------

    override func applicationDidEnterBackground(_ application: UIApplication) {
        // Seismic engine continues via CMMotionManager (background-safe queue)
        // Mesh continues via bluetooth-central/peripheral background modes
        // Location keep-alive (CLLocationManager) maintains process lifetime
        print("[AppDelegate] Background — seismic+mesh continuing via background modes")
    }

    override func applicationWillTerminate(_ application: UIApplication) {
        meshController?.stopMesh()   // flushes SQLite queue
        seismicEngine?.stop()
        backgroundManager?.stopMonitoring()
        print("[AppDelegate] Terminating — state persisted to SQLite")
    }
}

// MARK: - No-op stream handler for SMS events (iOS)

private class NoOpStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }
}
