// =============================================================================
// SINYALIST — SMS Bridge (Kotlin)
// =============================================================================
// Handles sending SMS packets via Android SmsManager.
// Registered as MethodChannel "com.sinyalist/sms" in MainActivity.
//
// Methods:
//   sendSms({"address": "+905...", "messages": ["SY1|...|CRC"]})
//     → {"sent": true} or {"sent": false, "error": "reason"}
//
//   checkPermission() → {"granted": true/false}
//
// SMS is intentionally fire-and-forget at the platform level.
// Delivery receipts (sentIntent / deliveryIntent) are tracked via
// PendingIntent broadcasts and echoed back through the EventChannel
// "com.sinyalist/sms_events".
// =============================================================================

package com.sinyalist.sms

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.ServiceState
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.util.Log
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

private const val TAG = "SmsBridge"
private const val ACTION_SMS_SENT = "com.sinyalist.SMS_SENT"
private const val ACTION_SMS_DELIVERED = "com.sinyalist.SMS_DELIVERED"

class SmsBridge(private val context: Context) {

    // EventChannel sink — receives sent/delivery receipts
    var eventSink: EventChannel.EventSink? = null

    // Map of message-id → part count for tracking multi-part SMS
    private val pendingMap = mutableMapOf<String, Int>()

    // Broadcast receiver for sent/delivery reports
    private val sentReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val msgId = intent?.getStringExtra("msg_id") ?: return
            val partIdx = intent.getIntExtra("part", 0)
            val success = resultCode == Activity.RESULT_OK
            Log.d(TAG, "SMS_SENT [$msgId] part=$partIdx success=$success resultCode=$resultCode")
            eventSink?.success(mapOf(
                "event" to "sent",
                "msg_id" to msgId,
                "part" to partIdx,
                "success" to success,
                "result_code" to resultCode,
            ))
        }
    }

    private val deliveredReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val msgId = intent?.getStringExtra("msg_id") ?: return
            val partIdx = intent.getIntExtra("part", 0)
            Log.d(TAG, "SMS_DELIVERED [$msgId] part=$partIdx")
            eventSink?.success(mapOf(
                "event" to "delivered",
                "msg_id" to msgId,
                "part" to partIdx,
            ))
        }
    }

    init {
        // Register broadcast receivers
        val sentFilter = IntentFilter(ACTION_SMS_SENT)
        val deliveredFilter = IntentFilter(ACTION_SMS_DELIVERED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(sentReceiver, sentFilter, Context.RECEIVER_NOT_EXPORTED)
            context.registerReceiver(deliveredReceiver, deliveredFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(sentReceiver, sentFilter)
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(deliveredReceiver, deliveredFilter)
        }
    }

    fun unregister() {
        try { context.unregisterReceiver(sentReceiver) } catch (_: Exception) {}
        try { context.unregisterReceiver(deliveredReceiver) } catch (_: Exception) {}
    }

    // -------------------------------------------------------------------------
    // MethodChannel handler
    // -------------------------------------------------------------------------
    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sendSms" -> handleSendSms(call, result)
            "checkPermission" -> result.success(mapOf("granted" to hasPermission()))
                   "checkCellular" -> result.success(mapOf("available" to hasCellularService()))
            
            else -> result.notImplemented()
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun handleSendSms(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<String, Any>
        if (args == null) {
            result.error("INVALID_ARGS", "Expected map argument", null)
            return
        }

        val address = args["address"] as? String
        val messages = args["messages"] as? List<String>
        val msgId = args["msg_id"] as? String ?: System.currentTimeMillis().toString()

        if (address.isNullOrBlank()) {
            result.error("INVALID_ARGS", "address is required", null)
            return
        }
        if (messages.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "messages list is empty", null)
            return
        }
        if (!hasPermission()) {
            result.error("PERMISSION_DENIED", "SEND_SMS permission not granted", null)
            return
        }

        try {
            sendMessages(address, messages, msgId)
            result.success(mapOf("sent" to true, "msg_id" to msgId, "parts" to messages.size))
        } catch (e: Exception) {
            Log.e(TAG, "sendMessages failed: ${e.message}", e)
            result.error("SMS_FAILED", e.message ?: "Unknown error", null)
        }
    }

    private fun sendMessages(address: String, messages: List<String>, msgId: String) {
        val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }

        pendingMap[msgId] = messages.size

        messages.forEachIndexed { index, text ->
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                        PendingIntent.FLAG_IMMUTABLE else 0

            val sentIntent = Intent(ACTION_SMS_SENT).apply {
                putExtra("msg_id", msgId)
                putExtra("part", index)
            }.let { PendingIntent.getBroadcast(context, index, it, flags) }

            val deliveryIntent = Intent(ACTION_SMS_DELIVERED).apply {
                putExtra("msg_id", msgId)
                putExtra("part", index)
            }.let { PendingIntent.getBroadcast(context, 100 + index, it, flags) }

            smsManager.sendTextMessage(
                address,
                null,   // scAddress — use default
                text,
                sentIntent,
                deliveryIntent,
            )

            Log.d(TAG, "Queued SMS part ${index + 1}/${messages.size} to $address (${text.length} chars)")
        }
    }

    private fun hasCellularService(): Boolean {
        return try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val activeNetwork = cm.activeNetwork
            if (activeNetwork != null) {
                val caps = cm.getNetworkCapabilities(activeNetwork)
                if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true) {
                    return true
                }
            }

            val tm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(TelephonyManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            }

            val state = tm?.serviceState?.state
            state == ServiceState.STATE_IN_SERVICE || state == ServiceState.STATE_EMERGENCY_ONLY
        } catch (e: Exception) {
            Log.w(TAG, "hasCellularService check failed: ${e.message}")
            false
        }
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) ==
                PackageManager.PERMISSION_GRANTED
}
