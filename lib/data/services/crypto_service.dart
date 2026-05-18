import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Client-side end-to-end encryption gateway.
///
/// Real production E2EE would implement the full Signal Double-Ratchet
/// protocol. For Vently's MVP we provide:
///   * an X25519 identity keypair per device,
///   * an AES-GCM-256 session key derived per chat room,
///   * encrypt/decrypt helpers that return base64 strings ready for the
///     `chat_messages.encrypted_payload` + `nonce_iv` columns.
///
/// Once moved off the device-storage seal, key material is held in memory
/// only — never persisted server-side.
class CryptoService {
  final _x25519 = X25519();
  final _aead = AesGcm.with256bits();

  Future<SimpleKeyPair> generateIdentityKeyPair() => _x25519.newKeyPair();

  Future<SecretKey> deriveRoomKey({
    required SimpleKeyPair localKeyPair,
    required SimplePublicKey peerPublicKey,
  }) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey: peerPublicKey,
    );
    final bytes = await shared.extractBytes();
    return SecretKey(bytes);
  }

  Future<EncryptedPayload> encrypt(String plaintext, SecretKey key) async {
    final box = await _aead.encrypt(utf8.encode(plaintext), secretKey: key);
    return EncryptedPayload(
      cipherText: base64Url.encode(box.cipherText),
      nonceIv:    base64Url.encode(box.nonce),
      mac:        base64Url.encode(box.mac.bytes),
    );
  }

  Future<String> decrypt(EncryptedPayload payload, SecretKey key) async {
    final box = SecretBox(
      base64Url.decode(payload.cipherText),
      nonce: base64Url.decode(payload.nonceIv),
      mac: Mac(base64Url.decode(payload.mac)),
    );
    final bytes = await _aead.decrypt(box, secretKey: key);
    return utf8.decode(bytes);
  }

  /// Helper for in-memory mock chats: yields a deterministic test key.
  Future<SecretKey> derivePresetKey(String label) async {
    final hash = await Sha256().hash(utf8.encode('vently.mock.$label'));
    return SecretKey(Uint8List.fromList(hash.bytes));
  }
}

class EncryptedPayload {
  final String cipherText;
  final String nonceIv;
  final String mac;

  const EncryptedPayload({
    required this.cipherText,
    required this.nonceIv,
    required this.mac,
  });
}
