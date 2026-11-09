import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

const int kProtocolVersion = 2;

/// 本机长期身份：Ed25519 密钥对。公钥指纹给用户做带外核对，对端按 TOFU 记住。
class NearIdentity {
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  NearIdentity._(this.keyPair, this.publicKey);

  String get fingerprint => fingerprintOf(publicKey);

  static Future<NearIdentity> fromSeed(List<int> seed) async {
    final keyPair = await Cryptography.instance.ed25519().newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return NearIdentity._(keyPair, Uint8List.fromList(publicKey.bytes));
  }

  static Future<NearIdentity> generate() async {
    final keyPair = await Cryptography.instance.ed25519().newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    return fromSeed(seed);
  }

  Future<List<int>> seed() => keyPair.extractPrivateKeyBytes();
}

/// 公钥 SHA-256 前 16 字节，按 4 位 hex 一组展示。
String fingerprintOf(List<int> publicKey) {
  final digest = crypto.sha256.convert(publicKey).bytes.sublist(0, 16);
  final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final groups = <String>[];
  for (var i = 0; i < hex.length; i += 4) {
    groups.add(hex.substring(i, i + 4));
  }
  return groups.join(' ');
}

class HandshakeException implements Exception {
  final String message;
  HandshakeException(this.message);
  @override
  String toString() => 'HandshakeException: $message';
}

/// 单条连接的加密会话。hello 明文交换「身份公钥 + 临时 X25519 公钥 + 签名」，
/// 之后每一帧都是 ChaCha20-Poly1305 密文，两个方向各用独立的 key 和递增 nonce。
class SecureSession {
  final NearIdentity identity;
  final String myId;
  final SimpleKeyPair _ephemeral;
  final Uint8List _ephemeralPublic;
  final Cipher _aead = Cryptography.instance.chacha20Poly1305Aead();

  SecretKey? _sendKey;
  SecretKey? _receiveKey;
  int _sendCounter = 0;
  int _receiveCounter = 0;
  Uint8List? peerIdentityKey;

  SecureSession._(this.identity, this.myId, this._ephemeral, this._ephemeralPublic);

  static Future<SecureSession> create(NearIdentity identity, String myId) async {
    final ephemeral = await Cryptography.instance.x25519().newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    return SecureSession._(
        identity, myId, ephemeral, Uint8List.fromList(ephemeralPublic.bytes));
  }

  bool get established => _sendKey != null;

  static List<int> _signedPayload(String fromId, List<int> ephemeralPublic) =>
      [...utf8.encode('near-hello-v$kProtocolVersion|$fromId|'), ...ephemeralPublic];

  Future<Map<String, dynamic>> hello() async {
    final signature = await Cryptography.instance
        .ed25519()
        .sign(_signedPayload(myId, _ephemeralPublic), keyPair: identity.keyPair);
    return {
      'type': 'hello',
      'v': kProtocolVersion,
      'fromId': myId,
      'idKey': base64Encode(identity.publicKey),
      'eph': base64Encode(_ephemeralPublic),
      'sig': base64Encode(signature.bytes),
    };
  }

  /// 校验对端 hello 的签名并派生会话密钥。返回对端身份公钥，供调用方做 TOFU 比对。
  Future<Uint8List> acceptHello(Map<String, dynamic> hello) async {
    final version = hello['v'];
    if (version != kProtocolVersion) {
      throw HandshakeException('peer protocol v$version, need v$kProtocolVersion');
    }
    final fromId = hello['fromId'] as String;
    final idKey = base64Decode(hello['idKey'] as String);
    final peerEphemeral = base64Decode(hello['eph'] as String);
    final signature = base64Decode(hello['sig'] as String);
    final peerIdKey = SimplePublicKey(idKey, type: KeyPairType.ed25519);
    final valid = await Cryptography.instance.ed25519().verify(
          _signedPayload(fromId, peerEphemeral),
          signature: Signature(signature, publicKey: peerIdKey),
        );
    if (!valid) throw HandshakeException('bad hello signature from $fromId');

    final shared = await Cryptography.instance.x25519().sharedSecretKey(
          keyPair: _ephemeral,
          remotePublicKey: SimplePublicKey(peerEphemeral, type: KeyPairType.x25519),
        );
    _sendKey = await _directionKey(shared, _ephemeralPublic);
    _receiveKey = await _directionKey(shared, peerEphemeral);
    peerIdentityKey = Uint8List.fromList(idKey);
    return peerIdentityKey!;
  }

  static Future<SecretKey> _directionKey(SecretKey shared, List<int> senderEphemeral) {
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: const [],
      info: [...utf8.encode('near-v$kProtocolVersion send '), ...senderEphemeral],
    );
  }

  static List<int> _nonce(int counter) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, counter);
    return nonce;
  }

  /// 调用方须保证按发送顺序串行调用（nonce 计数器与线上顺序一一对应）。
  Future<Uint8List> seal(List<int> plain) async {
    final key = _sendKey;
    if (key == null) throw StateError('handshake not complete');
    final box = await _aead.encrypt(plain, secretKey: key, nonce: _nonce(_sendCounter++));
    return box.concatenation(nonce: false);
  }

  Future<Uint8List> open(Uint8List sealed) async {
    final key = _receiveKey;
    if (key == null) throw StateError('handshake not complete');
    final macLength = _aead.macAlgorithm.macLength;
    if (sealed.length < macLength) throw const FormatException('frame too short');
    final box = SecretBox(
      Uint8List.sublistView(sealed, 0, sealed.length - macLength),
      nonce: _nonce(_receiveCounter++),
      mac: Mac(Uint8List.sublistView(sealed, sealed.length - macLength)),
    );
    final clear = await _aead.decrypt(box, secretKey: key);
    return clear is Uint8List ? clear : Uint8List.fromList(clear);
  }
}

/// 加密层内部的明文帧：首字节区分 JSON 控制消息与二进制文件块。
sealed class InnerFrame {
  const InnerFrame();

  static const int _kindJson = 0;
  static const int _kindChunk = 1;

  Uint8List encode();

  static InnerFrame decode(Uint8List bytes) {
    if (bytes.isEmpty) throw const FormatException('empty frame');
    switch (bytes[0]) {
      case _kindJson:
        return JsonFrame(
            jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 1)))
                as Map<String, dynamic>);
      case _kindChunk:
        final view = ByteData.sublistView(bytes);
        final idLength = bytes[1];
        final msgId = utf8.decode(Uint8List.sublistView(bytes, 2, 2 + idLength));
        final offset = view.getUint64(2 + idLength);
        return ChunkFrame(msgId, offset, Uint8List.sublistView(bytes, 10 + idLength));
      default:
        throw FormatException('unknown frame kind ${bytes[0]}');
    }
  }
}

class JsonFrame extends InnerFrame {
  final Map<String, dynamic> json;
  const JsonFrame(this.json);

  @override
  Uint8List encode() {
    final body = utf8.encode(jsonEncode(json));
    return Uint8List(body.length + 1)
      ..[0] = InnerFrame._kindJson
      ..setRange(1, body.length + 1, body);
  }
}

/// 文件块按绝对字节偏移寻址：接收方只接 offset == 已写字节数 的块，
/// 断线重连、旧连接残留帧造成的重复 / 乱序块会被自然丢弃。
class ChunkFrame extends InnerFrame {
  final String msgId;
  final int offset;
  final Uint8List data;
  const ChunkFrame(this.msgId, this.offset, this.data);

  @override
  Uint8List encode() {
    final id = utf8.encode(msgId);
    if (id.length > 255) throw ArgumentError('msgId too long');
    final out = Uint8List(10 + id.length + data.length);
    out[0] = InnerFrame._kindChunk;
    out[1] = id.length;
    out.setRange(2, 2 + id.length, id);
    ByteData.sublistView(out).setUint64(2 + id.length, offset);
    out.setRange(10 + id.length, out.length, data);
    return out;
  }
}
