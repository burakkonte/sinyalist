// =============================================================================
// SINYALIST — SMS Bridge (Dart side)
// =============================================================================
// Wraps the "com.sinyalist/sms" MethodChannel and
// "com.sinyalist/sms_events" EventChannel.
//
// Usage:
//   final ok = await SmsBridge.send(
//     address: '+905001234567',
//     messages: ['SY1|...|CRC'],
//   );
//
// Only available on Android. On web / iOS, all calls return false immediately.
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of an SMS send attempt.
class SmsSendResult {
  final bool sent;
  final String? msgId;
  final int parts;
  final String? error;

  const SmsSendResult({
    required this.sent,
    this.msgId,
    this.parts = 0,
    this.error,
  });

  bool get isSuccess => sent;

  @override
  String toString() =>
      'SmsSendResult(sent=$sent, msgId=$msgId, parts=$parts, error=$error)';
}

/// Delivery receipt event from the native SMS layer.
class SmsReceiptEvent {
  /// 'sent' or 'delivered'
  final String event;
  final String msgId;
  final int part;
  final bool? success;
  final int? resultCode;

  const SmsReceiptEvent({
    required this.event,
    required this.msgId,
    required this.part,
    this.success,
    this.resultCode,
  });

  factory SmsReceiptEvent.fromMap(Map<Object?, Object?> map) {
    return SmsReceiptEvent(
      event: map['event'] as String? ?? 'unknown',
      msgId: map['msg_id'] as String? ?? '',
      part: map['part'] as int? ?? 0,
      success: map['success'] as bool?,
      resultCode: map['result_code'] as int?,
    );
  }

  @override
  String toString() =>
      'SmsReceiptEvent(event=$event, msgId=$msgId, part=$part, success=$success)';
}

class SmsBridge {
  static const _methodChannel = MethodChannel('com.sinyalist/sms');
  static const _eventChannel = EventChannel('com.sinyalist/sms_events');

  static bool get _isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Stream of sent/delivery receipt events from Android SmsManager.
  static Stream<SmsReceiptEvent> get receipts {
    if (!_isSupported) return const Stream.empty();
    return _eventChannel.receiveBroadcastStream().map((event) {
      return SmsReceiptEvent.fromMap(event as Map<Object?, Object?>);
    });
  }

  /// Send one or more SMS messages to [address].
  /// [messages] is typically the output of [SmsCodec.encode()].
  /// [msgId] is optional; auto-generated if not provided.
  ///
  /// Returns [SmsSendResult] with success/failure and metadata.
  static Future<SmsSendResult> send({
    required String address,
    required List<String> messages,
    String? msgId,
  }) async {
    if (!_isSupported) {
      debugPrint('[SmsBridge] SMS not supported on this platform');
      return const SmsSendResult(
        sent: false,
        error: 'SMS not supported on this platform',
      );
    }

    if (address.isEmpty) {
      return const SmsSendResult(sent: false, error: 'Empty address');
    }
    if (messages.isEmpty) {
      return const SmsSendResult(sent: false, error: 'No messages to send');
    }

    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        'sendSms',
        {
          'address': address,
          'messages': messages,
          if (msgId != null) 'msg_id': msgId,
        },
      );

      final sent = result?['sent'] as bool? ?? false;
      debugPrint('[SmsBridge] sendSms result: $result');

      return SmsSendResult(
        sent: sent,
        msgId: result?['msg_id'] as String?,
        parts: result?['parts'] as int? ?? messages.length,
      );
    } on PlatformException catch (e) {
      debugPrint('[SmsBridge] PlatformException: ${e.code} — ${e.message}');
      return SmsSendResult(
        sent: false,
        error: '${e.code}: ${e.message}',
      );
    } catch (e) {
      debugPrint('[SmsBridge] Unexpected error: $e');
      return SmsSendResult(sent: false, error: e.toString());
    }
  }

  /// Check whether SEND_SMS permission is granted.
  static Future<bool> hasPermission() async {
    if (!_isSupported) return false;
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        'checkPermission',
      );
      return result?['granted'] as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort check for cellular service presence on Android.
  /// Returns false on unsupported platforms or bridge errors.
  static Future<bool> hasCellularService() async {
    if (!_isSupported) return false;
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        'checkCellular',
      );
      return result?['available'] as bool? ?? false;
    } catch (_) {
      return false;
    }
  }
}
