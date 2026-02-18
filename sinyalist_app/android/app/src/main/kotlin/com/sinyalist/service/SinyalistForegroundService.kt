// =============================================================================
// SINYALIST — Emergency Foreground Service (v2 Field-Ready)
// =============================================================================
// B4: Added watchdog timer to restart scanning/advertising if stopped.
//     Logs state transitions and reasons (stopped_by_os, restarted, etc.).
// =============================================================================

package com.sinyalist.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import com.sinyalist.core.SeismicEngine
import com.sinyalist.mesh.NodusMeshController

class SinyalistForegroundService : Service() {

    companion object {
        private const val TAG = "SinyalistService"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "sinyalist_emergency"
        private const val CHANNEL_NAME = "Sinyalist Emergency Monitor"
        private const val WATCHDOG_INTERVAL_MS = 30_000L // Check every 30 seconds

        const val ACTION_START = "com.sinyalist.action.START"
        const val ACTION_STOP = "com.sinyalist.action.STOP"
        const val ACTION_ACTIVATE_SURVIVAL = "com.sinyalist.action.SURVIVAL"

        fun start(context: Context) {
            val intent = Intent(context, SinyalistForegroundService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, SinyalistForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    private var seismicEngine: SeismicEngine? = null
    private var meshController: NodusMeshController? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var isSurvivalMode = false
    private var watchdogHandler: Handler? = null
    private var watchdogRunnable: Runnable? = null
    private var startCount = 0
    private var restartCount = 0
    private var lastWatchdogCheckMs = 0L

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        Log.i(TAG, "Foreground service created")
        logState("created", "Service.onCreate()")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startCount++
        Log.i(TAG, "onStartCommand: action=${intent?.action}, startCount=$startCount")

        when (intent?.action) {
            ACTION_START -> startMonitoring()
            ACTION_STOP -> stopMonitoring()
            ACTION_ACTIVATE_SURVIVAL -> activateSurvivalMode()
            null -> {
                // System restart (START_STICKY triggered) — no intent
                Log.w(TAG, "SYSTEM RESTART detected (null intent) — restarting monitoring")
                logState("system_restart", "START_STICKY triggered, startCount=$startCount")
                startMonitoring()
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // -----------------------------------------------------------------------
    // Core monitoring lifecycle
    // -----------------------------------------------------------------------

    private fun startMonitoring() {
        // Request battery optimization exemption so the OS does not kill the
        // service during deep sleep (Doze mode).  This opens the system dialog
        // asking the user to allow unrestricted background activity for Sinyalist.
        // Required for reliable background seismic monitoring on Xiaomi, Samsung,
        // Oppo and other OEMs that aggressively kill background processes.
        requestBatteryOptimizationExemption()

        // Acquire partial wake lock
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        // FIX: acquire for 1 hour instead of 24 hours.  The watchdog (every 30s)
        // renews the lock via renewWakeLock() as long as monitoring is active.
        // A 24-hour hold would permanently drain the battery even when unused.
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "sinyalist:seismic_monitor"
        ).apply {
            acquire(60 * 60 * 1000L) // 1 hour; renewed by watchdog
        }
        logState("wakelock_acquired", "1h partial wake lock (renewable)")

        // Initialize seismic engine
        seismicEngine = SeismicEngine(this).apply {
            initialize()
            start()
        }
        logState("seismic_started", "SeismicEngine initialized and started")

        // Initialize mesh controller
        meshController = NodusMeshController(this).apply {
            // B4: Wire state transition logging
            onStateTransition = { from, to ->
                logState("mesh_transition", "$from -> $to")
            }
            if (initialize()) {
                startMesh()
                logState("mesh_started", "NodusMeshController initialized and mesh started")
            } else {
                logState("mesh_init_failed", "Bluetooth not available or not enabled")
            }
        }

        // Start foreground with notification
        val notification = buildNotification(
            title = "Sinyalist Active",
            body = "Earthquake monitoring is running",
            isSurvival = false
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // B4: Start watchdog
        startWatchdog()

        Log.i(TAG, "Monitoring STARTED — seismic + mesh active")
        logState("monitoring_started", "All subsystems active, watchdog running")
    }

    private fun requestBatteryOptimizationExemption() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val pkg = packageName
            if (!pm.isIgnoringBatteryOptimizations(pkg)) {
                // Open the system "Battery optimization" dialog for this app.
                // This is an explicit user-facing action — cannot be granted silently.
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$pkg")
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(intent)
                logState("battery_opt_dialog", "Requested battery optimization exemption")
            } else {
                logState("battery_opt_ok", "Already exempt from battery optimizations")
            }
        } catch (e: Exception) {
            // Some OEMs restrict this intent; log and continue
            Log.w(TAG, "Battery optimization exemption request failed: $e")
            logState("battery_opt_failed", e.message ?: "unknown")
        }
    }

    private fun stopMonitoring() {
        // Stop watchdog
        stopWatchdog()

        seismicEngine?.destroy()
        seismicEngine = null
        meshController?.stopMesh()
        meshController = null
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()

        Log.i(TAG, "Monitoring STOPPED — all services released")
        logState("monitoring_stopped", "All subsystems stopped, restarts=$restartCount")
    }

    // -----------------------------------------------------------------------
    // B4: Watchdog — restart scanning/advertising if stopped
    // -----------------------------------------------------------------------

    private fun startWatchdog() {
        watchdogHandler = Handler(Looper.getMainLooper())
        watchdogRunnable = object : Runnable {
            override fun run() {
                performWatchdogCheck()
                watchdogHandler?.postDelayed(this, WATCHDOG_INTERVAL_MS)
            }
        }
        watchdogHandler?.postDelayed(watchdogRunnable!!, WATCHDOG_INTERVAL_MS)
        logState("watchdog_started", "interval=${WATCHDOG_INTERVAL_MS}ms")
    }

    private fun stopWatchdog() {
        watchdogRunnable?.let { watchdogHandler?.removeCallbacks(it) }
        watchdogHandler = null
        watchdogRunnable = null
        logState("watchdog_stopped", "")
    }

    private fun performWatchdogCheck() {
        lastWatchdogCheckMs = System.currentTimeMillis()

        // FIX: renew the 1-hour wake lock so it never expires while monitoring is active.
        // We acquired it for only 1 hour (not 24h), so the watchdog must keep it alive.
        wakeLock?.let { wl ->
            if (wl.isHeld) {
                wl.release()
            }
            wl.acquire(60 * 60 * 1000L) // renew for another hour
            logState("wakelock_renewed", "1h wake lock renewed by watchdog")
        }

        // Check seismic engine
        val seismicOk = seismicEngine != null
        if (!seismicOk) {
            Log.w(TAG, "WATCHDOG: SeismicEngine is null — restarting")
            logState("watchdog_restart_seismic", "SeismicEngine was null")
            try {
                seismicEngine = SeismicEngine(this).apply {
                    initialize()
                    start()
                }
                restartCount++
                logState("seismic_restarted", "restartCount=$restartCount")
            } catch (e: Exception) {
                Log.e(TAG, "WATCHDOG: Failed to restart SeismicEngine: $e")
                logState("seismic_restart_failed", e.toString())
            }
        }

        // Check mesh controller
        val meshOk = meshController?.isHealthy() ?: false
        if (!meshOk && meshController != null) {
            Log.w(TAG, "WATCHDOG: Mesh not healthy — restarting")
            logState("watchdog_restart_mesh", "isHealthy=false")
            try {
                val restarted = meshController?.restartIfNeeded() ?: false
                if (restarted) {
                    restartCount++
                    logState("mesh_restarted", "restartCount=$restartCount")
                }
            } catch (e: Exception) {
                Log.e(TAG, "WATCHDOG: Failed to restart mesh: $e")
                logState("mesh_restart_failed", e.toString())
            }
        }

        // Update notification with health status
        val statusText = buildString {
            append("Seismic: ${if (seismicOk) "OK" else "RESTART"}")
            append(" | Mesh: ${if (meshOk) "OK" else "RESTART"}")
            if (restartCount > 0) append(" | Restarts: $restartCount")
        }

        val notification = buildNotification(
            title = if (isSurvivalMode) "DEPREM ALGILANDI" else "Sinyalist Active",
            body = statusText,
            isSurvival = isSurvivalMode
        )
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, notification)
    }

    // -----------------------------------------------------------------------
    // Survival Mode
    // -----------------------------------------------------------------------

    private fun activateSurvivalMode() {
        if (isSurvivalMode) return
        isSurvivalMode = true

        val notification = buildNotification(
            title = "DEPREM ALGILANDI",
            body = "Hayatta kalma modu aktif. Konum paylasildi.",
            isSurvival = true
        )

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, notification)

        Log.w(TAG, "SURVIVAL MODE ACTIVATED — power conservation engaged")
        logState("survival_mode", "activated")
    }

    // -----------------------------------------------------------------------
    // State logging (B4)
    // -----------------------------------------------------------------------

    private fun logState(event: String, detail: String) {
        val timestamp = System.currentTimeMillis()
        Log.i(TAG, "STATE_LOG t=$timestamp event=$event detail=$detail " +
                "starts=$startCount restarts=$restartCount survival=$isSurvivalMode")
    }

    // -----------------------------------------------------------------------
    // Notification builder
    // -----------------------------------------------------------------------

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Continuous earthquake monitoring"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }

            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, body: String, isSurvival: Boolean): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(!isSurvival)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        if (isSurvival) {
            builder.setPriority(NotificationCompat.PRIORITY_MAX)
            builder.setCategory(NotificationCompat.CATEGORY_ALARM)
        }

        return builder.build()
    }

    override fun onDestroy() {
        super.onDestroy()
        logState("service_destroyed", "Scheduling restart via startForegroundService")

        // Emergency restart
        val restartIntent = Intent(this, SinyalistForegroundService::class.java).apply {
            action = ACTION_START
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(restartIntent)
            } else {
                startService(restartIntent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to schedule restart: $e")
            logState("restart_failed", e.toString())
        }
        Log.w(TAG, "Service destroyed — restart scheduled")
    }
}
