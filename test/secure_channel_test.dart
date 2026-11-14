import 'package:cryptography/cryptography.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:near/peer.dart';
import 'package:near/secure_channel.dart';

Future<(SecureSession, SecureSession)> _pair() async {
  final alice = await SecureSession.create(await NearIdentity.generate(), 'alice');
  final bob = await SecureSession.create(await NearIdentity.generate(), 'bob');
  await alice.acceptHello(await bob.hello());
  await bob.acceptHello(await alice.hello());
  return (alice, bob);
}

void main() {
  test('sealed frames round-trip in both directions', () async {
    final (alice, bob) = await _pair();
    for (var i = 0; i < 3; i++) {
      final sealed = await alice.seal([1, 2, 3, i]);
      expect(await bob.open(sealed), [1, 2, 3, i]);
    }
    expect(await alice.open(await bob.seal([9])), [9]);
  });

  test('tampered frame is rejected', () async {
    final (alice, bob) = await _pair();
    final sealed = await alice.seal([1, 2, 3]);
    sealed[0] ^= 0xff;
    expect(() => bob.open(sealed), throwsA(anything));
  });

  test('hello with forged signature is rejected', () async {
    final alice = await SecureSession.create(await NearIdentity.generate(), 'alice');
    final mallory = await SecureSession.create(await NearIdentity.generate(), 'mallory');
    final hello = await mallory.hello();
    hello['fromId'] = 'bob';
    expect(() => alice.acceptHello(hello), throwsA(isA<HandshakeException>()));
  });

  test('old protocol hello is rejected', () async {
    final alice = await SecureSession.create(await NearIdentity.generate(), 'alice');
    expect(() => alice.acceptHello({'type': 'hello', 'fromId': 'x'}),
        throwsA(isA<HandshakeException>()));
  });

  test('identity is stable across seed reload', () async {
    final identity = await NearIdentity.generate();
    final reloaded = await NearIdentity.fromSeed(await identity.seed());
    expect(reloaded.fingerprint, identity.fingerprint);
    expect(identity.fingerprint, matches(RegExp(r'^([0-9a-f]{4} ){7}[0-9a-f]{4}$')));
  });

  test('inner frames encode and decode', () {
    final chunk = ChunkFrame('msg-1', 5 * 1024 * 1024 * 1024, Uint8List.fromList([7, 8, 9]));
    final decoded = InnerFrame.decode(chunk.encode()) as ChunkFrame;
    expect(decoded.msgId, 'msg-1');
    expect(decoded.offset, 5 * 1024 * 1024 * 1024);
    expect(decoded.data, [7, 8, 9]);
    final json = InnerFrame.decode(const JsonFrame({'type': 'ping'}).encode()) as JsonFrame;
    expect(json.json['type'], 'ping');
  });

  test('fanout aggregation', () {
    const s = FanoutState.values;
    expect(aggregateFanout([s[0], FanoutState.delivered]), FanoutOutcome.inProgress);
    expect(aggregateFanout([FanoutState.paused]), FanoutOutcome.inProgress);
    expect(aggregateFanout([FanoutState.declined, FanoutState.delivered]),
        FanoutOutcome.delivered);
    expect(aggregateFanout([FanoutState.declined, FanoutState.declined]),
        FanoutOutcome.allDeclined);
    expect(aggregateFanout([FanoutState.declined, FanoutState.failed]),
        FanoutOutcome.failed);
  });

  test('a zero salt derives the same key as the empty salt older versions used', () async {
    final secret = SecretKey(List<int>.generate(32, (i) => i));
    Future<List<int>> derive(List<int> salt) async =>
        (await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
                .deriveKey(secretKey: secret, nonce: salt, info: [1, 2, 3]))
            .extractBytes();
    expect(await derive(List<int>.filled(32, 0)), await derive(const []));
  });
}
