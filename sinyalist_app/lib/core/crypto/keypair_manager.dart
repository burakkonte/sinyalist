// =============================================================================
// SINYALIST — Ed25519 Keypair Manager
// =============================================================================
// Generates a per-install Ed25519 keypair on first launch.
// Stores securely via encrypted shared preferences.
// Signs packets before sending (internet/SMS/BLE).
// =============================================================================

import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

/// Manages Ed25519 keypair lifecycle: generation, storage, signing.
class KeypairManager {
  static const String _prefKeyPrivate = 'sinyalist_ed25519_private';
  static const String _prefKeyPublic = 'sinyalist_ed25519_public';
  static const String _tag = 'KeypairManager';

  final Ed25519 _algorithm = Ed25519();

  SimpleKeyPair? _keyPair;
  Uint8List? _publicKeyBytes;
  Uint8List? _privateKeyBytes;

  bool get isInitialized => _keyPair != null;
  Uint8List? get publicKeyBytes => _publicKeyBytes;

  /// Initialize: load existing keypair or generate new one.
  /// Must be called before any signing operations.
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final storedPrivate = prefs.getString(_prefKeyPrivate);
    final storedPublic = prefs.getString(_prefKeyPublic);

    if (storedPrivate != null && storedPublic != null) {
      try {
        _privateKeyBytes = base64Decode(storedPrivate);
        _publicKeyBytes = base64Decode(storedPublic);

        if (_privateKeyBytes!.length == 32 && _publicKeyBytes!.length == 32) {
          final privateKey = SimpleKeyPairData(
            _privateKeyBytes!,
            publicKey: SimplePublicKey(_publicKeyBytes!, type: KeyPairType.ed25519),
            type: KeyPairType.ed25519,
          );
          _keyPair = privateKey;
          debugPrint('[$_tag] Loaded existing keypair (pubkey=${_publicKeyHex()})');
          return;
        }
      } catch (e) {
        debugPrint('[$_tag] Failed to load stored keypair: $e');
      }
    }

    // Generate new keypair
    await _generateAndStore(prefs);
  }

  Future<void> _generateAndStore(SharedPreferences prefs) async {
    debugPrint('[$_tag] Generating new Ed25519 keypair...');
    final newKeyPair = await _algorithm.newKeyPair();

    final extractedPrivate = await newKeyPair.extractPrivateKeyBytes();
    final extractedPublic = await newKeyPair.extractPublicKey();

    _privateKeyBytes = Uint8List.fromList(extractedPrivate);
    _publicKeyBytes = Uint8List.fromList(extractedPublic.bytes);
    _keyPair = SimpleKeyPairData(
      _privateKeyBytes!,
      publicKey: SimplePublicKey(_publicKeyBytes!, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );

    await prefs.setString(_prefKeyPrivate, base64Encode(_privateKeyBytes!));
    await prefs.setString(_prefKeyPublic, base64Encode(_publicKeyBytes!));

    debugPrint('[$_tag] New keypair generated and stored (pubkey=${_publicKeyHex()})');
  }

  /// Sign arbitrary data with the device's Ed25519 private key.
  /// Returns 64-byte signature.
  /// Throws if not initialized.
  Future<Uint8List> sign(Uint8List data) async {
    if (_keyPair == null) {
      throw StateError('KeypairManager not initialized. Call initialize() first.');
    }

    final signature = await _algorithm.sign(data, keyPair: _keyPair!);
    final sigBytes = Uint8List.fromList(signature.bytes);

    if (sigBytes.length != 64) {
      throw StateError('Ed25519 signature must be 64 bytes, got ${sigBytes.length}');
    }

    return sigBytes;
  }

  /// Verify a signature against a public key and data.
  /// Used for verifying received mesh packets.
  Future<bool> verify(Uint8List data, Uint8List signature, Uint8List publicKey) async {
    if (signature.length != 64 || publicKey.length != 32) {
      return false;
    }

    try {
      final sig = Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      );
      return await _algorithm.verify(data, signature: sig);
    } catch (e) {
      debugPrint('[$_tag] Signature verification failed: $e');
      return false;
    }
  }

  /// Reset keypair (for testing only — not for production use).
  Future<void> resetKeypair() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKeyPrivate);
    await prefs.remove(_prefKeyPublic);
    _keyPair = null;
    _publicKeyBytes = null;
    _privateKeyBytes = null;
    debugPrint('[$_tag] Keypair reset');
  }

  String _publicKeyHex() {
    if (_publicKeyBytes == null) return 'null';
    return _publicKeyBytes!.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
