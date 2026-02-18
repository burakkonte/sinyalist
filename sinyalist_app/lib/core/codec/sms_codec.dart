// =============================================================================
// SINYALIST — SMS Codec
// =============================================================================
// Compact payload encoding for SMS transport:
//   Format: "SY1|<base64(fields)>|<CRC32_hex>"
//   Fields: packet_id(16B) + lat_e7(4B) + lon_e7(4B) + accuracy_cm(4B)
//           + trapped_status(1B) + created_at_ms(8B) + msg_type(1B)
//   Total raw: 38 bytes → ~52 chars base64 + 10 chars overhead = ~62 chars
//   Fits in a single SMS (160 chars).
//
// Multipart SMS: for payloads > 130 chars, split into parts with sequence headers:
//   "SY1M|<part>/<total>|<base64_chunk>|<CRC32_hex>"
//
// DO NOT send raw protobuf via SMS.
// =============================================================================

import 'dart:convert';
import 'dart:typed_data';

/// CRC32 implementation (IEEE 802.3 polynomial).
class Crc32 {
  static final List<int> _table = _buildTable();

  static List<int> _buildTable() {
    final table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int crc = i;
      for (int j = 0; j < 8; j++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ 0xEDB88320;
        } else {
          crc >>= 1;
        }
      }
      table[i] = crc;
    }
    return table;
  }

  /// Compute CRC32 checksum for given bytes.
  static int compute(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }

  /// Format CRC32 as 8-char hex string.
  static String toHex(int crc) {
    return crc.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase();
  }

  /// Parse CRC32 from 8-char hex string.
  static int fromHex(String hex) {
    return int.parse(hex, radix: 16).toUnsigned(32);
  }
}

/// Compact SMS field structure.
class SmsPayload {
  final Uint8List packetId;    // 16 bytes (UUID)
  final int latitudeE7;        // sint32
  final int longitudeE7;       // sint32
  final int accuracyCm;        // uint32
  final int trappedStatus;     // 1 byte (0=unknown, 1=trapped, 2=safe)
  final int createdAtMs;       // int64
  final int msgType;           // 1 byte (enum MessageType)

  const SmsPayload({
    required this.packetId,
    required this.latitudeE7,
    required this.longitudeE7,
    required this.accuracyCm,
    required this.trappedStatus,
    required this.createdAtMs,
    required this.msgType,
  });

  /// Serialize to compact binary (38 bytes).
  Uint8List toBytes() {
    // Single buffer — both writes and reads go through `result`/`bd` which
    // are views of the SAME underlying memory.  The old code wrote to a
    // throwaway `ByteData(38)` and read from a separate `Uint8List(38)`,
    // so every field except packet_id came out as all-zeros (data corruption).
    final result = Uint8List(38);
    final bd = ByteData.sublistView(result); // view over result — same memory
    int offset = 0;

    // packet_id: 16 bytes
    for (int i = 0; i < 16; i++) {
      result[i] = i < packetId.length ? packetId[i] : 0;
    }
    offset = 16;

    // lat_e7: 4 bytes (signed, big-endian)
    bd.setInt32(offset, latitudeE7, Endian.big);
    offset += 4;

    // lon_e7: 4 bytes (signed, big-endian)
    bd.setInt32(offset, longitudeE7, Endian.big);
    offset += 4;

    // accuracy_cm: 4 bytes (unsigned, big-endian)
    bd.setUint32(offset, accuracyCm, Endian.big);
    offset += 4;

    // trapped_status: 1 byte
    result[offset] = trappedStatus & 0xFF;
    offset += 1;

    // created_at_ms: 8 bytes (big-endian, split into two uint32 because
    // Dart's ByteData.setUint64 is not available on all platforms)
    final msHigh = (createdAtMs >> 32) & 0xFFFFFFFF;
    final msLow = createdAtMs & 0xFFFFFFFF;
    bd.setUint32(offset, msHigh, Endian.big);
    bd.setUint32(offset + 4, msLow, Endian.big);
    offset += 8;

    // msg_type: 1 byte
    result[offset] = msgType & 0xFF;

    return result;
  }

  /// Deserialize from compact binary (38 bytes).
  static SmsPayload fromBytes(Uint8List data) {
    if (data.length != 38) {
      throw FormatException('SMS payload must be 38 bytes, got ${data.length}');
    }

    final bd = ByteData.sublistView(data);
    int offset = 0;

    final packetId = data.sublist(0, 16);
    offset = 16;

    final latE7 = bd.getInt32(offset, Endian.big);
    offset += 4;

    final lonE7 = bd.getInt32(offset, Endian.big);
    offset += 4;

    final accCm = bd.getUint32(offset, Endian.big);
    offset += 4;

    final trapped = data[offset];
    offset += 1;

    final msHigh = bd.getUint32(offset, Endian.big);
    final msLow = bd.getUint32(offset + 4, Endian.big);
    final createdMs = (msHigh << 32) | msLow;
    offset += 8;

    final msgType = data[offset];

    return SmsPayload(
      packetId: packetId,
      latitudeE7: latE7,
      longitudeE7: lonE7,
      accuracyCm: accCm,
      trappedStatus: trapped,
      createdAtMs: createdMs,
      msgType: msgType,
    );
  }
}

/// SMS codec: encode/decode compact payloads for SMS transport.
class SmsCodec {
  static const String _prefix = 'SY1';
  static const String _multipartPrefix = 'SY1M';
  static const int _singleSmsMaxChars = 160;
  // Multipart header: "SY1M|xx/xx|" (11) + "|" (1) + CRC (8) = 20 chars
  static const int _multipartPayloadMaxChars = _singleSmsMaxChars - 20;

  /// Encode a payload into SMS message(s).
  /// Returns a list of SMS strings (usually 1, may be multiple for large payloads).
  static List<String> encode(SmsPayload payload) {
    final rawBytes = payload.toBytes();
    final b64 = base64Encode(rawBytes);
    final crc = Crc32.compute(rawBytes);
    final crcHex = Crc32.toHex(crc);

    final singleMsg = '$_prefix|$b64|$crcHex';

    if (singleMsg.length <= _singleSmsMaxChars) {
      return [singleMsg];
    }

    // Multipart: split base64 into chunks
    return _encodeMultipart(b64, crcHex);
  }

  static List<String> _encodeMultipart(String b64, String crcHex) {
    final chunks = <String>[];
    int pos = 0;
    while (pos < b64.length) {
      final end = (pos + _multipartPayloadMaxChars).clamp(0, b64.length);
      chunks.add(b64.substring(pos, end));
      pos = end;
    }

    final total = chunks.length;
    return List.generate(total, (i) {
      final partNum = (i + 1).toString().padLeft(2, '0');
      final totalNum = total.toString().padLeft(2, '0');
      return '$_multipartPrefix|$partNum/$totalNum|${chunks[i]}|$crcHex';
    });
  }

  /// Decode a single SMS message.
  /// Returns null if CRC check fails or format is invalid.
  static SmsPayload? decodeSingle(String sms) {
    final trimmed = sms.trim();

    if (!trimmed.startsWith('$_prefix|')) {
      return null;
    }

    final parts = trimmed.split('|');
    if (parts.length != 3) return null;
    if (parts[0] != _prefix) return null;

    final b64 = parts[1];
    final crcHex = parts[2];

    try {
      final rawBytes = Uint8List.fromList(base64Decode(b64));
      final computedCrc = Crc32.compute(rawBytes);
      final expectedCrc = Crc32.fromHex(crcHex);

      if (computedCrc != expectedCrc) {
        return null; // CRC mismatch
      }

      return SmsPayload.fromBytes(rawBytes);
    } catch (e) {
      return null;
    }
  }

  /// Reassemble multipart SMS messages into a single payload.
  /// [messages] should contain all parts (order doesn't matter).
  /// Returns null if reassembly fails or CRC is invalid.
  static SmsPayload? decodeMultipart(List<String> messages) {
    if (messages.isEmpty) return null;

    // Parse all parts
    final partMap = <int, String>{};
    int? totalParts;
    String? crcHex;

    for (final msg in messages) {
      final trimmed = msg.trim();
      if (!trimmed.startsWith('$_multipartPrefix|')) continue;

      final parts = trimmed.split('|');
      if (parts.length != 4) continue;

      // Parse "xx/xx"
      final seqParts = parts[1].split('/');
      if (seqParts.length != 2) continue;

      final partNum = int.tryParse(seqParts[0]);
      final total = int.tryParse(seqParts[1]);
      if (partNum == null || total == null) continue;

      totalParts ??= total;
      if (total != totalParts) continue; // Mismatched total

      crcHex ??= parts[3];
      partMap[partNum] = parts[2];
    }

    if (totalParts == null || crcHex == null) return null;
    if (partMap.length != totalParts) return null; // Missing parts

    // Reassemble in order
    final b64Buffer = StringBuffer();
    for (int i = 1; i <= totalParts; i++) {
      final chunk = partMap[i];
      if (chunk == null) return null;
      b64Buffer.write(chunk);
    }

    try {
      final rawBytes = Uint8List.fromList(base64Decode(b64Buffer.toString()));
      final computedCrc = Crc32.compute(rawBytes);
      final expectedCrc = Crc32.fromHex(crcHex);

      if (computedCrc != expectedCrc) {
        return null; // CRC mismatch
      }

      return SmsPayload.fromBytes(rawBytes);
    } catch (e) {
      return null;
    }
  }
}
