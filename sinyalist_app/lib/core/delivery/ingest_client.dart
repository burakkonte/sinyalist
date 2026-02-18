// =============================================================================
// SINYALIST — HTTP Ingest Client
// =============================================================================
// Real HTTP POST client for /v1/ingest with protobuf payload.
// ACK model:
//   - accepted = queued/persisted by server (HTTP 200, PacketAck.received=true)
//   - rejected = signature fail (403), malformed (400/422), rate limited (429),
//                queue full (503), oversized (413)
// Retry with exponential backoff on transient failures (5xx, timeout).
// =============================================================================

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// ACK status from the server.
enum IngestAckStatus {
  accepted,        // Server queued/persisted the packet
  rejected,        // Server rejected (bad sig, malformed, etc.)
  rateLimited,     // 429 — too many requests
  queueFull,       // 503 — server backpressure
  networkError,    // Could not reach server
  timeout,         // Request timed out
}

/// Parsed ACK response from the server.
class IngestAck {
  final IngestAckStatus status;
  final int httpStatus;
  final String? ingestId;       // Server-assigned ID (if accepted)
  final int? serverTimestampMs; // Server time (if accepted)
  final double? confidence;     // Geo-cluster confidence (if accepted)
  final String? error;          // Error message (if rejected)

  const IngestAck({
    required this.status,
    required this.httpStatus,
    this.ingestId,
    this.serverTimestampMs,
    this.confidence,
    this.error,
  });

  bool get isAccepted => status == IngestAckStatus.accepted;
  bool get isRetryable =>
      status == IngestAckStatus.queueFull ||
      status == IngestAckStatus.networkError ||
      status == IngestAckStatus.timeout;

  @override
  String toString() => 'IngestAck(status=$status, http=$httpStatus, '
      'confidence=$confidence, error=$error)';
}

/// HTTP client for the Sinyalist ingest endpoint.
class IngestClient {
  static const String _tag = 'IngestClient';

  final String _baseUrl;
  final http.Client _httpClient;
  final Duration _timeout;
  final int _maxRetries;

  // Backoff: 500ms, 1s, 2s, 4s, 8s
  static const List<Duration> _backoffSchedule = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  IngestClient({
    required String baseUrl,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 10),
    int maxRetries = 3,
  })  : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _maxRetries = maxRetries;

  /// Check if the backend is reachable and healthy.
  /// Returns true if /health returns 200 within timeout.
  Future<bool> checkHealth() async {
    try {
      final uri = Uri.parse('$_baseUrl/health');
      final response = await _httpClient.get(uri).timeout(
        const Duration(seconds: 5),
      );
      final healthy = response.statusCode == 200;
      debugPrint('[$_tag] Health check: ${healthy ? "OK" : "FAIL"} (${response.statusCode})');
      return healthy;
    } catch (e) {
      debugPrint('[$_tag] Health check failed: $e');
      return false;
    }
  }

  /// Send a protobuf-encoded SinyalistPacket to /v1/ingest.
  /// Retries with exponential backoff on transient failures.
  /// Returns the final ACK after all retries are exhausted.
  Future<IngestAck> send(Uint8List protobufBytes) async {
    IngestAck? lastAck;

    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      if (attempt > 0) {
        final delay = _backoffSchedule[
            attempt.clamp(0, _backoffSchedule.length - 1)];
        debugPrint('[$_tag] Retry $attempt after ${delay.inMilliseconds}ms');
        await Future.delayed(delay);
      }

      lastAck = await _sendOnce(protobufBytes);

      if (!lastAck.isRetryable) {
        return lastAck;
      }

      debugPrint('[$_tag] Attempt $attempt failed (${lastAck.status}), will retry');
    }

    return lastAck ?? const IngestAck(
      status: IngestAckStatus.networkError,
      httpStatus: 0,
      error: 'All retries exhausted',
    );
  }

  Future<IngestAck> _sendOnce(Uint8List protobufBytes) async {
    try {
      final uri = Uri.parse('$_baseUrl/v1/ingest');
      final response = await _httpClient.post(
        uri,
        headers: {
          'Content-Type': 'application/x-protobuf',
          'X-Client-Version': '2.0.0',
        },
        body: protobufBytes,
      ).timeout(_timeout);

      return _parseResponse(response);
    } on TimeoutException {
      debugPrint('[$_tag] Request timed out');
      return const IngestAck(
        status: IngestAckStatus.timeout,
        httpStatus: 0,
        error: 'Request timed out',
      );
    } catch (e) {
      debugPrint('[$_tag] Network error: $e');
      return IngestAck(
        status: IngestAckStatus.networkError,
        httpStatus: 0,
        error: e.toString(),
      );
    }
  }

  IngestAck _parseResponse(http.Response response) {
    final status = response.statusCode;

    switch (status) {
      case 200:
        // Parse PacketAck protobuf from response body
        // The server returns a protobuf-encoded PacketAck
        double? confidence;
        int? serverTs;
        if (response.bodyBytes.isNotEmpty) {
          // Minimal parsing of PacketAck fields:
          // field 2 (fixed64 timestamp_ms), field 3 (bool received), field 5 (float confidence)
          try {
            final ackData = _parsePacketAck(response.bodyBytes);
            confidence = ackData['confidence'] as double?;
            serverTs = ackData['timestamp_ms'] as int?;
          } catch (e) {
            debugPrint('[$_tag] Failed to parse ACK body: $e');
          }
        }
        debugPrint('[$_tag] Accepted (confidence=$confidence)');
        return IngestAck(
          status: IngestAckStatus.accepted,
          httpStatus: 200,
          serverTimestampMs: serverTs,
          confidence: confidence,
        );

      case 400:
        return IngestAck(
          status: IngestAckStatus.rejected,
          httpStatus: 400,
          error: 'Malformed packet',
        );

      case 403:
        return IngestAck(
          status: IngestAckStatus.rejected,
          httpStatus: 403,
          error: 'Signature verification failed',
        );

      case 413:
        return IngestAck(
          status: IngestAckStatus.rejected,
          httpStatus: 413,
          error: 'Packet too large',
        );

      case 422:
        return IngestAck(
          status: IngestAckStatus.rejected,
          httpStatus: 422,
          error: 'Missing required fields',
        );

      case 429:
        return IngestAck(
          status: IngestAckStatus.rateLimited,
          httpStatus: 429,
          error: 'Rate limited — slow down',
        );

      case 503:
        return IngestAck(
          status: IngestAckStatus.queueFull,
          httpStatus: 503,
          error: 'Server queue full — retrying',
        );

      default:
        if (status >= 500) {
          return IngestAck(
            status: IngestAckStatus.queueFull, // Treat all 5xx as retryable
            httpStatus: status,
            error: 'Server error $status',
          );
        }
        return IngestAck(
          status: IngestAckStatus.rejected,
          httpStatus: status,
          error: 'Unexpected status $status',
        );
    }
  }

  /// Minimal protobuf parser for PacketAck.
  /// PacketAck fields:
  ///   1: fixed64 user_id
  ///   2: fixed64 timestamp_ms
  ///   3: bool received
  ///   5: float confidence
  Map<String, dynamic> _parsePacketAck(Uint8List data) {
    final result = <String, dynamic>{};
    int pos = 0;

    while (pos < data.length) {
      if (pos >= data.length) break;
      final tag = data[pos];
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x07;
      pos++;

      switch (wireType) {
        case 0: // Varint
          int value = 0;
          int shift = 0;
          while (pos < data.length) {
            final byte = data[pos++];
            value |= (byte & 0x7F) << shift;
            if ((byte & 0x80) == 0) break;
            shift += 7;
          }
          if (fieldNumber == 3) {
            result['received'] = value != 0;
          }
          break;

        case 1: // 64-bit (fixed64)
          if (pos + 8 <= data.length) {
            final bd = ByteData.sublistView(data, pos, pos + 8);
            // FIX: getUint64 is not supported by dart2js (web). Reconstruct
            // the 64-bit value from two 32-bit reads.  Timestamps fit safely
            // in 53 bits so no precision is lost on JS.
            final lo = bd.getUint32(0, Endian.little);
            final hi = bd.getUint32(4, Endian.little);
            final value = (hi * 0x100000000) + lo; // hi<<32 | lo, JS-safe
            if (fieldNumber == 2) {
              result['timestamp_ms'] = value;
            }
            pos += 8;
          }
          break;

        case 2: // Length-delimited
          int len = 0;
          int shift = 0;
          while (pos < data.length) {
            final byte = data[pos++];
            len |= (byte & 0x7F) << shift;
            if ((byte & 0x80) == 0) break;
            shift += 7;
          }
          pos += len; // Skip
          break;

        case 5: // 32-bit (float)
          if (pos + 4 <= data.length) {
            final bd = ByteData.sublistView(data, pos, pos + 4);
            final value = bd.getFloat32(0, Endian.little);
            if (fieldNumber == 5) {
              result['confidence'] = value.toDouble();
            }
            pos += 4;
          }
          break;

        default:
          // Unknown wire type, bail out
          return result;
      }
    }

    return result;
  }

  void dispose() {
    _httpClient.close();
  }
}
