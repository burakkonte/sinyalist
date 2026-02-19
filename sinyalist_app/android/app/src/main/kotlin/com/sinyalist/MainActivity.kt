// =============================================================================
// SINYALIST — MainActivity (Flutter ↔ Kotlin Channel Registration)
// =============================================================================
// This is the bridge file that flutter create doesn't know about.
// It registers MethodChannels and EventChannels for:
//   - Seismic Engine (C++ NDK via JNI)
//   - Nodus BLE Mesh
//   - Foreground Service control
//   - SMS transport (SmsManager)
// =============================================================================

package com.sinyalist

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.sinyalist.core.SeismicEngine
import com.sinyalist.mesh.NodusMeshController
import com.sinyalist.service.SinyalistForegroundService
import com.sinyalist.sms.SmsBridge

class MainActivity : FlutterActivity() {

    private lateinit var seismicEngine: SeismicEngine
    private lateinit var meshController: NodusMeshController
    private lateinit var smsBridge: SmsBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        seismicEngine = SeismicEngine(this)
        meshController = NodusMeshController(this)
        smsBridge = SmsBridge(this)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // --- Seismic MethodChannel ---
        MethodChannel(messenger, "com.sinyalist/seismic").setMethodCallHandler { call, result ->
            val response = seismicEngine.handleMethodCall(call.method, call.arguments)
            if (response != null) result.success(response)
            else result.notImplemented()
        }

        // --- Seismic EventChannel (stream of SeismicEvent) ---
        EventChannel(messenger, "com.sinyalist/seismic_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    seismicEngine.setEventSink(events)
                }
                override fun onCancel(arguments: Any?) {
                    seismicEngine.setEventSink(null)
                }
            }
        )

        // --- Mesh MethodChannel ---
        MethodChannel(messenger, "com.sinyalist/mesh").setMethodCallHandler { call, result ->
            val response = meshController.handleMethodCall(call.method, call.arguments)
            if (response != null) result.success(response)
            else result.notImplemented()
        }

        // --- Mesh EventChannel (stream of MeshStats) ---
        EventChannel(messenger, "com.sinyalist/mesh_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    meshController.onMeshStatsUpdate = { stats ->
                        runOnUiThread {
                            events?.success(mapOf(
                                "activeNodes" to stats.activeNodes,
                                "bufferedPackets" to stats.bufferedPackets,
                                "totalRelayed" to stats.totalRelayed,
                                "bloomFillRatio" to stats.bloomFillRatio
                            ))
                        }
                    }
                }
                override fun onCancel(arguments: Any?) {
                    meshController.onMeshStatsUpdate = null
                }
            }
        )

        // --- Service MethodChannel ---
        MethodChannel(messenger, "com.sinyalist/service").setMethodCallHandler { call, result ->
            when (call.method) {
                "startMonitoring" -> {
                    SinyalistForegroundService.start(this)
                    result.success("ok")
                }
                "stopMonitoring" -> {
                    SinyalistForegroundService.stop(this)
                    result.success("ok")
                }
                "activateSurvivalMode" -> {
                    val intent = android.content.Intent(this, SinyalistForegroundService::class.java).apply {
                        action = SinyalistForegroundService.ACTION_ACTIVATE_SURVIVAL
                    }
                    startService(intent)
                    result.success("ok")
                }
                else -> result.notImplemented()
            }
        }

        // --- SMS MethodChannel ---
        MethodChannel(messenger, "com.sinyalist/sms").setMethodCallHandler { call, result ->
            smsBridge.handleMethodCall(call, result)
        }

        // --- SMS EventChannel (sent/delivery receipts) ---
        EventChannel(messenger, "com.sinyalist/sms_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    smsBridge.eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    smsBridge.eventSink = null
                }
            }
        )
    }

    override fun onDestroy() {
        seismicEngine.destroy()
        meshController.stopMesh()
        smsBridge.unregister()
        super.onDestroy()
    }
}
