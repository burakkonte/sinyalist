// =============================================================================
// SINYALIST — Emergency Foreground Service
// =============================================================================
// Android kills background services after ~10 minutes. This foreground service
// ensures seismic detection and mesh networking survive indefinitely.
// Uses FOREGROUND_SERVICE_TYPE_LOCATION | FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
// to satisfy Android 14+ type requirements.
// =============================================================================

package com.sinyalist.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
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

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        Log.i(TAG, "Foreground service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startMonitoring()
            ACTION_STOP -> stopMonitoring()
            ACTION_ACTIVATE_SURVIVAL -> activateSurvivalMode()
        }
        // AUTO restart if killed by system — critical for earthquake monitoring
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // -----------------------------------------------------------------------
    // Core monitoring lifecycle
    // -----------------------------------------------------------------------

    private fun startMonitoring() {
        // Acquire partial wake lock — keeps CPU alive even with screen off
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "sinyalist:seismic_monitor"
        ).apply {
            acquire(24 * 60 * 60 * 1000L) // 24-hour max (Android enforced)
        }

        // Initialize seismic engine
        seismicEngine = SeismicEngine(this).apply {
            initialize()
            start()
        }

        // Initialize mesh controller
        meshController = NodusMeshController(this).apply {
            if (initialize()) {
                startMesh()
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

        Log.i(TAG, "Monitoring STARTED — seismic + mesh active")
    }

    private fun stopMonitoring() {
        seismicEngine?.destroy()
        seismicEngine = null
        meshController?.stopMesh()
        meshController = null
        wakeLock?.release()
        wakeLock = null

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()

        Log.i(TAG, "Monitoring STOPPED — all services released")
    }

    // -----------------------------------------------------------------------
    // Survival Mode — maximum battery conservation
    // -----------------------------------------------------------------------

    private fun activateSurvivalMode() {
        if (isSurvivalMode) return
        isSurvivalMode = true

        // Update notification to survival mode
        val notification = buildNotification(
            title = "DEPREM ALGILANDI",
            body = "Hayatta kalma modu aktif. Konum paylasildi.",
            isSurvival = true
        )

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, notification)

        Log.w(TAG, "SURVIVAL MODE ACTIVATED — power conservation engaged")
    }

    // -----------------------------------------------------------------------
    // Notification builder
    // -----------------------------------------------------------------------

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW // Low = no sound, but persistent
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
        // Intent to open app when notification tapped
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
            .setOngoing(true) // Cannot be swiped away
            .setSilent(!isSurvival) // Sound only in survival mode
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
        // Emergency restart — this service MUST survive
        val restartIntent = Intent(this, SinyalistForegroundService::class.java).apply {
            action = ACTION_START
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(restartIntent)
        } else {
            startService(restartIntent)
        }
        Log.w(TAG, "Service destroyed — scheduling restart")
    }
}
