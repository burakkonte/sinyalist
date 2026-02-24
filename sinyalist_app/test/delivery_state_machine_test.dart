// =============================================================================
// SINYALIST — DeliveryStateMachine Unit Tests
// =============================================================================
// Tests pure-Dart logic: DeliveryConfig defaults, DeliveryResult properties,
// DeliveryRecord.copyWith(), and rate-limiting (canSend / remainingSends).
//
// The deliver() calls below use an uninitialized KeypairManager on purpose:
// signing fails immediately, but _recentSends is already incremented at that
// point — which is exactly what we need to drive the rate-limit tests without
// any network I/O or platform channels.
// =============================================================================

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinyalist/core/delivery/delivery_state_machine.dart';
import 'package:sinyalist/core/delivery/ingest_client.dart';
import 'package:sinyalist/core/crypto/keypair_manager.dart';

/// Helper: build a DeliveryStateMachine with SMS/BLE disabled and a custom
/// rate-limit config so tests never touch platform channels.
DeliveryStateMachine _makeFsm({
  int maxSends = 5,
  Duration window = const Duration(seconds: 30),
}) {
  return DeliveryStateMachine(
    ingestClient: IngestClient(baseUrl: ''),   // empty URL → no real HTTP
    keypairManager: KeypairManager(),           // uninitialized → sign() throws
    config: DeliveryConfig(
      smsEnabled: false,
      bleEnabled: false,
      rateLimitWindow: window,
      maxSendsPerWindow: maxSends,
    ),
  );
}

/// Dummy 4-byte packet used for deliver() calls.
final _dummyPacket = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);

void main() {
  // -------------------------------------------------------------------------
  // DeliveryConfig
  // -------------------------------------------------------------------------
  group('DeliveryConfig', () {
    test('default values are correct', () {
      const cfg = DeliveryConfig();
      expect(cfg.smsEnabled, isTrue);
      expect(cfg.bleEnabled, isTrue);
      expect(cfg.rateLimitWindow, equals(const Duration(seconds: 30)));
      expect(cfg.maxSendsPerWindow, equals(5));
      expect(cfg.smsRelayNumber, isEmpty);
    });

    test('custom values override every field', () {
      const cfg = DeliveryConfig(
        smsEnabled: false,
        bleEnabled: false,
        rateLimitWindow: Duration(minutes: 1),
        maxSendsPerWindow: 10,
        smsRelayNumber: '+905001234567',
      );
      expect(cfg.smsEnabled, isFalse);
      expect(cfg.bleEnabled, isFalse);
      expect(cfg.rateLimitWindow, equals(const Duration(minutes: 1)));
      expect(cfg.maxSendsPerWindow, equals(10));
      expect(cfg.smsRelayNumber, equals('+905001234567'));
    });
  });

  // -------------------------------------------------------------------------
  // DeliveryResult
  // -------------------------------------------------------------------------
  group('DeliveryResult', () {
    test('isDelivered is true only for delivered state', () {
      final r = DeliveryResult(
        finalState: DeliveryState.delivered,
        elapsed: Duration.zero,
      );
      expect(r.isDelivered, isTrue);
      expect(r.isFailed, isFalse);
    });

    test('isFailed is true only for failed state', () {
      final r = DeliveryResult(
        finalState: DeliveryState.failed,
        error: 'network error',
        elapsed: const Duration(milliseconds: 120),
      );
      expect(r.isFailed, isTrue);
      expect(r.isDelivered, isFalse);
    });

    test('optional fields are stored and exposed correctly', () {
      final r = DeliveryResult(
        finalState: DeliveryState.delivered,
        transport: 'internet',
        confidence: 0.97,
        serverTimestampMs: 1700000000000,
        elapsed: const Duration(milliseconds: 300),
      );
      expect(r.transport, equals('internet'));
      expect(r.confidence, closeTo(0.97, 0.001));
      expect(r.serverTimestampMs, equals(1700000000000));
      expect(r.elapsed.inMilliseconds, equals(300));
    });

    test('toString() contains state and transport', () {
      final r = DeliveryResult(
        finalState: DeliveryState.delivered,
        transport: 'sms',
        elapsed: Duration.zero,
      );
      expect(r.toString(), contains('delivered'));
      expect(r.toString(), contains('sms'));
    });
  });

  // -------------------------------------------------------------------------
  // DeliveryRecord.copyWith
  // -------------------------------------------------------------------------
  group('DeliveryRecord.copyWith', () {
    final createdAt = DateTime(2024, 3, 15, 10, 0);

    test('preserves all fields when nothing is overridden', () {
      final rec = DeliveryRecord(
        packetId: 'aabbccdd',
        state: DeliveryState.created,
        createdAt: createdAt,
      );
      final copy = rec.copyWith();
      expect(copy.packetId, equals('aabbccdd'));
      expect(copy.state, equals(DeliveryState.created));
      expect(copy.createdAt, equals(createdAt));
      expect(copy.completedAt, isNull);
      expect(copy.transport, isNull);
      expect(copy.error, isNull);
      expect(copy.confidence, isNull);
    });

    test('overrides only specified fields', () {
      final rec = DeliveryRecord(
        packetId: 'deadbeef',
        state: DeliveryState.sendingInternet,
        createdAt: createdAt,
      );
      final completedAt = DateTime(2024, 3, 15, 10, 0, 5);
      final updated = rec.copyWith(
        state: DeliveryState.delivered,
        completedAt: completedAt,
        transport: 'internet',
        confidence: 0.92,
      );

      expect(updated.packetId, equals('deadbeef'));     // unchanged
      expect(updated.createdAt, equals(createdAt));     // unchanged
      expect(updated.state, equals(DeliveryState.delivered));
      expect(updated.completedAt, equals(completedAt));
      expect(updated.transport, equals('internet'));
      expect(updated.confidence, closeTo(0.92, 0.001));
      expect(updated.error, isNull);                    // not overridden
    });

    test('error field is set independently', () {
      final rec = DeliveryRecord(
        packetId: 'cafebabe',
        state: DeliveryState.sendingInternet,
        createdAt: createdAt,
      );
      final withError = rec.copyWith(
        state: DeliveryState.failed,
        error: 'Connection refused',
      );
      expect(withError.state, equals(DeliveryState.failed));
      expect(withError.error, equals('Connection refused'));
      expect(withError.transport, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Rate limiting — canSend / remainingSends
  // -------------------------------------------------------------------------
  group('DeliveryStateMachine rate limiting', () {
    test('canSend is true and remainingSends equals maxSends initially', () {
      final fsm = _makeFsm(maxSends: 5);
      expect(fsm.canSend, isTrue);
      expect(fsm.remainingSends, equals(5));
    });

    test('remainingSends decrements after each deliver() call', () async {
      final fsm = _makeFsm(maxSends: 5);

      await fsm.deliver(_dummyPacket); // fails at signing, but counts
      expect(fsm.remainingSends, equals(4));

      await fsm.deliver(_dummyPacket);
      expect(fsm.remainingSends, equals(3));
    });

    test('canSend becomes false after maxSends deliver() calls', () async {
      final fsm = _makeFsm(maxSends: 3);
      for (int i = 0; i < 3; i++) {
        await fsm.deliver(_dummyPacket);
      }
      expect(fsm.canSend, isFalse);
      expect(fsm.remainingSends, equals(0));
    });

    test('deliver() returns rate-limited failure when window is exhausted',
        () async {
      final fsm = _makeFsm(maxSends: 2);
      await fsm.deliver(_dummyPacket);
      await fsm.deliver(_dummyPacket);

      final result = await fsm.deliver(_dummyPacket);
      expect(result.isFailed, isTrue);
      expect(result.error, contains('Rate limited'));
    });

    test('remainingSends clamps to 0, never goes negative', () async {
      final fsm = _makeFsm(maxSends: 2);
      for (int i = 0; i < 5; i++) {
        await fsm.deliver(_dummyPacket);
      }
      expect(fsm.remainingSends, equals(0));
    });

    test('canSend resets to true after rate-limit window expires', () async {
      // Use a very short window so tests do not need to sleep long.
      final fsm = _makeFsm(maxSends: 2, window: const Duration(milliseconds: 80));

      await fsm.deliver(_dummyPacket);
      await fsm.deliver(_dummyPacket);
      expect(fsm.canSend, isFalse);

      await Future.delayed(const Duration(milliseconds: 120));
      expect(fsm.canSend, isTrue);
      expect(fsm.remainingSends, equals(2));
    });

    test('history records are added for each deliver() call', () async {
      final fsm = _makeFsm(maxSends: 5);
      expect(fsm.history, isEmpty);
      await fsm.deliver(_dummyPacket);
      expect(fsm.history.length, equals(1));
      await fsm.deliver(_dummyPacket);
      expect(fsm.history.length, equals(2));
    });

    test('rate-limited deliver() adds a history record with failed state',
        () async {
      final fsm = _makeFsm(maxSends: 1);
      await fsm.deliver(_dummyPacket); // consumes the quota

      final result = await fsm.deliver(_dummyPacket); // rate-limited
      expect(result.isFailed, isTrue);
      // The rate-limit branch still adds a DeliveryRecord to history.
      expect(fsm.history.last.state, equals(DeliveryState.failed));
    });
  });
}
