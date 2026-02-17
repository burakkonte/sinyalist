// =============================================================================
// SINYALIST — SMS Codec Unit Tests
// =============================================================================

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinyalist/core/codec/sms_codec.dart';

void main() {
  group('CRC32', () {
    test('compute returns consistent results', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final crc1 = Crc32.compute(data);
      final crc2 = Crc32.compute(data);
      expect(crc1, equals(crc2));
    });

    test('compute returns different values for different data', () {
      final data1 = Uint8List.fromList([1, 2, 3]);
      final data2 = Uint8List.fromList([4, 5, 6]);
      expect(Crc32.compute(data1), isNot(equals(Crc32.compute(data2))));
    });

    test('toHex and fromHex roundtrip', () {
      final crc = 0xDEADBEEF;
      final hex = Crc32.toHex(crc);
      expect(hex, equals('DEADBEEF'));
      expect(Crc32.fromHex(hex), equals(crc));
    });

    test('toHex pads to 8 chars', () {
      final hex = Crc32.toHex(0x0000001F);
      expect(hex.length, equals(8));
      expect(hex, equals('0000001F'));
    });

    test('known CRC32 value', () {
      // CRC32 of empty byte array
      final empty = Uint8List(0);
      final crc = Crc32.compute(empty);
      expect(crc, equals(0x00000000));
    });
  });

  group('SmsPayload', () {
    test('toBytes produces 38 bytes', () {
      final payload = SmsPayload(
        packetId: Uint8List(16),
        latitudeE7: 410000000,
        longitudeE7: 290000000,
        accuracyCm: 500,
        trappedStatus: 1,
        createdAtMs: 1700000000000,
        msgType: 1,
      );
      final bytes = payload.toBytes();
      expect(bytes.length, equals(38));
    });

    test('roundtrip encode/decode', () {
      final original = SmsPayload(
        packetId: Uint8List.fromList(List.generate(16, (i) => i)),
        latitudeE7: 410123456,
        longitudeE7: -291234567,
        accuracyCm: 1234,
        trappedStatus: 1,
        createdAtMs: 1700000000123,
        msgType: 3,
      );

      final bytes = original.toBytes();
      final decoded = SmsPayload.fromBytes(bytes);

      expect(decoded.latitudeE7, equals(original.latitudeE7));
      expect(decoded.longitudeE7, equals(original.longitudeE7));
      expect(decoded.accuracyCm, equals(original.accuracyCm));
      expect(decoded.trappedStatus, equals(original.trappedStatus));
      expect(decoded.createdAtMs, equals(original.createdAtMs));
      expect(decoded.msgType, equals(original.msgType));
      expect(decoded.packetId, equals(original.packetId));
    });

    test('negative coordinates roundtrip', () {
      final original = SmsPayload(
        packetId: Uint8List(16),
        latitudeE7: -335123456,  // Southern hemisphere
        longitudeE7: -581234567, // Western hemisphere
        accuracyCm: 999,
        trappedStatus: 2,
        createdAtMs: 1234567890123,
        msgType: 4,
      );

      final bytes = original.toBytes();
      final decoded = SmsPayload.fromBytes(bytes);

      expect(decoded.latitudeE7, equals(original.latitudeE7));
      expect(decoded.longitudeE7, equals(original.longitudeE7));
    });

    test('fromBytes rejects wrong length', () {
      expect(
        () => SmsPayload.fromBytes(Uint8List(10)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SmsCodec', () {
    test('encode single SMS fits in 160 chars', () {
      final payload = SmsPayload(
        packetId: Uint8List(16),
        latitudeE7: 410000000,
        longitudeE7: 290000000,
        accuracyCm: 500,
        trappedStatus: 1,
        createdAtMs: 1700000000000,
        msgType: 1,
      );

      final messages = SmsCodec.encode(payload);
      expect(messages.length, equals(1));
      expect(messages[0].length, lessThanOrEqualTo(160));
      expect(messages[0], startsWith('SY1|'));
    });

    test('encode/decode single roundtrip with CRC verification', () {
      final original = SmsPayload(
        packetId: Uint8List.fromList(List.generate(16, (i) => i + 10)),
        latitudeE7: 410123456,
        longitudeE7: 290654321,
        accuracyCm: 2500,
        trappedStatus: 1,
        createdAtMs: 1700000000999,
        msgType: 2,
      );

      final messages = SmsCodec.encode(original);
      expect(messages.length, equals(1));

      final decoded = SmsCodec.decodeSingle(messages[0]);
      expect(decoded, isNotNull);
      expect(decoded!.latitudeE7, equals(original.latitudeE7));
      expect(decoded.longitudeE7, equals(original.longitudeE7));
      expect(decoded.accuracyCm, equals(original.accuracyCm));
      expect(decoded.trappedStatus, equals(original.trappedStatus));
      expect(decoded.createdAtMs, equals(original.createdAtMs));
      expect(decoded.msgType, equals(original.msgType));
    });

    test('decode rejects corrupted CRC', () {
      final payload = SmsPayload(
        packetId: Uint8List(16),
        latitudeE7: 410000000,
        longitudeE7: 290000000,
        accuracyCm: 500,
        trappedStatus: 1,
        createdAtMs: 1700000000000,
        msgType: 1,
      );

      final messages = SmsCodec.encode(payload);
      // Corrupt the CRC
      final corrupted = messages[0].substring(0, messages[0].length - 2) + 'XX';

      final decoded = SmsCodec.decodeSingle(corrupted);
      expect(decoded, isNull);
    });

    test('decode rejects invalid format', () {
      expect(SmsCodec.decodeSingle('INVALID'), isNull);
      expect(SmsCodec.decodeSingle('SY1|'), isNull);
      expect(SmsCodec.decodeSingle('SY1|data'), isNull);
      expect(SmsCodec.decodeSingle(''), isNull);
    });

    test('SMS format structure', () {
      final payload = SmsPayload(
        packetId: Uint8List(16),
        latitudeE7: 410000000,
        longitudeE7: 290000000,
        accuracyCm: 500,
        trappedStatus: 1,
        createdAtMs: 1700000000000,
        msgType: 1,
      );

      final messages = SmsCodec.encode(payload);
      final parts = messages[0].split('|');
      expect(parts.length, equals(3));
      expect(parts[0], equals('SY1'));
      // CRC should be 8 hex chars
      expect(parts[2].length, equals(8));
      expect(RegExp(r'^[0-9A-F]{8}$').hasMatch(parts[2]), isTrue);
    });
  });
}
