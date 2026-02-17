// =============================================================================
// SINYALIST — SeismicEngine (Kotlin JNI Bridge)
// =============================================================================
// Bridges the C++ NDK seismic detector to the Flutter layer via EventChannel.
// Manages sensor registration, batching, and lifecycle.
// =============================================================================

package com.sinyalist.core

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class SeismicEngine(private val context: Context) : SensorEventListener {

    companion object {
        private const val TAG = "SeismicEngine"
        private const val SENSOR_DELAY_US = 20_000 // 50Hz = 20ms period

        init {
            System.loadLibrary("sinyalist_seismic")
        }
    }

    // JNI declarations — implemented in seismic_detector.hpp
    private external fun nativeInit(callback: SeismicCallback)
    private external fun nativeProcessSample(ax: Float, ay: Float, az: Float, timestampMs: Long)
    private external fun nativeReset()
    private external fun nativeDestroy()

    private var sensorManager: SensorManager? = null
    private var accelerometer: Sensor? = null
    private var sensorThread: HandlerThread? = null
    private var sensorHandler: Handler? = null
    private var eventSink: EventChannel.EventSink? = null
    private var isRunning = false

    // Callback interface invoked by C++ via JNI
    interface SeismicCallback {
        fun onSeismicEvent(
            level: Int, peakG: Float, staLtaRatio: Float,
            dominantFreq: Float, detectionTimeMs: Long, durationSamples: Int
        )
    }

    private val callback = object : SeismicCallback {
        override fun onSeismicEvent(
            level: Int, peakG: Float, staLtaRatio: Float,
            dominantFreq: Float, detectionTimeMs: Long, durationSamples: Int
        ) {
            val eventData = mapOf(
                "level" to level,
                "peakG" to peakG,
                "staLtaRatio" to staLtaRatio,
                "dominantFreq" to dominantFreq,
                "detectionTimeMs" to detectionTimeMs,
                "durationSamples" to durationSamples
            )

            Handler(context.mainLooper).post {
                eventSink?.success(eventData)
            }

            Log.w(TAG, "SEISMIC EVENT: level=$level, peakG=$peakG, freq=$dominantFreq")
        }
    }

    fun initialize() {
        sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

        if (accelerometer == null) {
            Log.e(TAG, "No accelerometer available on this device")
            return
        }

        // Dedicated sensor thread — never blocks the UI thread
        sensorThread = HandlerThread("SinyalistSensorThread").apply {
            start()
            sensorHandler = Handler(looper)
        }

        nativeInit(callback)
        Log.i(TAG, "SeismicEngine initialized")
    }

    fun start() {
        if (isRunning || accelerometer == null) return
        sensorManager?.registerListener(
            this, accelerometer, SENSOR_DELAY_US, sensorHandler
        )
        isRunning = true
        Log.i(TAG, "Sensor listening started at ${1_000_000 / SENSOR_DELAY_US}Hz")
    }

    fun stop() {
        if (!isRunning) return
        sensorManager?.unregisterListener(this)
        isRunning = false
        Log.i(TAG, "Sensor listening stopped")
    }

    fun destroy() {
        stop()
        nativeDestroy()
        sensorThread?.quitSafely()
        sensorThread = null
        sensorHandler = null
        Log.i(TAG, "SeismicEngine destroyed")
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    // --- SensorEventListener ---

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_ACCELEROMETER) return
        // Convert to g-force (Android provides m/s^2, divide by 9.81)
        val ax = event.values[0] / 9.81f
        val ay = event.values[1] / 9.81f
        val az = event.values[2] / 9.81f
        val timestampMs = System.currentTimeMillis()
        nativeProcessSample(ax, ay, az, timestampMs)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // No-op — accuracy changes don't affect our algorithm
    }

    // --- Flutter MethodChannel handler ---

    fun handleMethodCall(method: String, arguments: Any?): Any? {
        return when (method) {
            "initialize" -> { initialize(); "ok" }
            "start"      -> { start(); "ok" }
            "stop"       -> { stop(); "ok" }
            "reset"      -> { nativeReset(); "ok" }
            "destroy"    -> { destroy(); "ok" }
            "isRunning"  -> isRunning
            else -> null
        }
    }
}
