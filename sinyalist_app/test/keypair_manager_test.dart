// =============================================================================
// SINYALIST — KeypairManager Unit Tests
// =============================================================================
// Tests Ed25519 keypair generation, persistence (mocked secure storage),
// signing, verification, and error paths.
// =============================================================================

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sinyalist/core/crypto/keypair_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // In-memory map that simulates FlutterSecureStorage on the native side.
  final Map<String, String> secureStore = {};

  setUpAll(() {
    // Mock the FlutterSecureStorage MethodChannel so tests never touch the
    // platform keystore.  All calls must handle the `options` sub-map that
    // the plugin always passes alongside the key/value.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async {
        final args = call.arguments as Map;
        switch (call.method) {
          case 'read':
            return secureStore[args['key'] as String];
          case 'write':
            secureStore[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            secureStore.remove(args['key'] as String);
            return null;
          case 'containsKey':
            return secureStore.containsKey(args['key'] as String);
          case 'readAll':
            return Map<String, String>.from(secureStore);
          case 'deleteAll':
            secureStore.clear();
            return null;
          default:
            return null;
        }
      },
    );
  });

  setUp(() {
    // Reset both stores before each test for isolation.
    secureStore.clear();
    SharedPreferences.setMockInitialValues({});
  });

  group('KeypairManager — generation', () {
    test('isInitialized is false before initialize()', () {
      final mgr = KeypairManager();
      expect(mgr.isInitialized, isFalse);
      expect(mgr.publicKeyBytes, isNull);
    });

    test('initialize() generates a 32-byte Ed25519 public key', () async {
      final mgr = KeypairManager();
      await mgr.initialize();
      expect(mgr.isInitialized, isTrue);
      expect(mgr.publicKeyBytes, isNotNull);
      expect(mgr.publicKeyBytes!.length, equals(32));
    });

    test('second initialize() reloads the same keypair from secure storage',
        () async {
      final mgr1 = KeypairManager();
      await mgr1.initialize();
      final pubKey1 = List<int>.from(mgr1.publicKeyBytes!);

      // Simulate app restart: new instance, same mocked store.
      final mgr2 = KeypairManager();
      await mgr2.initialize();
      expect(mgr2.publicKeyBytes, equals(pubKey1));
    });
  });

  group('KeypairManager — signing', () {
    test('sign() returns a 64-byte Ed25519 signature', () async {
      final mgr = KeypairManager();
      await mgr.initialize();
      final payload = Uint8List.fromList(List.generate(32, (i) => i));
      final sig = await mgr.sign(payload);
      expect(sig.length, equals(64));
    });

    test('sign() produces different signatures for different data', () async {
      final mgr = KeypairManager();
      await mgr.initialize();
      final sig1 = await mgr.sign(Uint8List.fromList([1, 2, 3]));
      final sig2 = await mgr.sign(Uint8List.fromList([4, 5, 6]));
      expect(sig1, isNot(equals(sig2)));
    });

    test('sign() throws StateError when not initialized', () async {
      final mgr = KeypairManager();
      expect(
        () async => mgr.sign(Uint8List(32)),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('KeypairManager — verification', () {
    test('verify() returns true for a valid signature', () async {
      final mgr = KeypairManager();
      await mgr.initialize();
      final data = Uint8List.fromList(List.generate(64, (i) => i ^ 0xAA));
      final sig = await mgr.sign(data);
      expect(await mgr.verify(data, sig, mgr.publicKeyBytes!), isTrue);
    });

    test('verify() returns false for tampered data', () async {
      final mgr = KeypairManager();
      await mgr.initialize();
      final data = Uint8List.fromList([10, 20, 30, 40, 50]);
      final sig = await mgr.sign(data);
      final tampered = Uint8List.fromList([10, 20, 30, 40, 99]); // last byte flipped
      expect(await mgr.verify(tampered, sig, mgr.publicKeyBytes!), isFalse);
    });

    test('verify() returns false for a tampered signature', () async {
      final mgr = KeypairManager();
      await mgr.initialize();
      final data = Uint8List.fromList([1, 2, 3, 4]);
      final sig = await mgr.sign(data);
      sig[0] ^= 0xFF; // corrupt first byte
      expect(await mgr.verify(data, sig, mgr.publicKeyBytes!), isFalse);
    });

    test('verify() returns false when signature length is not 64 bytes', () async {
      final mgr = KeypairManager();
      await mgr.initialize();
      final badSig = Uint8List(32); // wrong length
      expect(await mgr.verify(Uint8List(8), badSig, mgr.publicKeyBytes!), isFalse);
    });

    test('verify() returns false when public key length is not 32 bytes', () async {
      final mgr = KeypairManager();
      await mgr.initialize();
      final data = Uint8List.fromList([1, 2, 3]);
      final sig = await mgr.sign(data);
      final badKey = Uint8List(16); // wrong length
      expect(await mgr.verify(data, sig, badKey), isFalse);
    });

    test('verify() with a cross-instance keypair roundtrip', () async {
      // mgr1 signs, mgr2 verifies using mgr1's public key.
      final mgr1 = KeypairManager();
      await mgr1.initialize();
      final data = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      final sig = await mgr1.sign(data);
      final pubKey = Uint8List.fromList(mgr1.publicKeyBytes!);

      // mgr2 is a fresh, unrelated instance — only holds the public key.
      final mgr2 = KeypairManager();
      expect(await mgr2.verify(data, sig, pubKey), isTrue);
    });
  });

  group('KeypairManager — reset', () {
    test('resetKeypair() clears the initialized state', () async {
      final mgr = KeypairManager();
      await mgr.initialize();
      expect(mgr.isInitialized, isTrue);
      await mgr.resetKeypair();
      expect(mgr.isInitialized, isFalse);
      expect(mgr.publicKeyBytes, isNull);
    });

    test('initialize() after resetKeypair() generates a fresh keypair', () async {
      final mgr = KeypairManager();
      await mgr.initialize();
      final pubKey1 = List<int>.from(mgr.publicKeyBytes!);

      await mgr.resetKeypair();
      await mgr.initialize();
      // With a clean store the new keypair should be different (probabilistically).
      expect(mgr.publicKeyBytes, isNot(equals(pubKey1)));
    });
  });
}
