import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:near/peer.dart';
import 'package:near/secure_channel.dart';
import 'package:near/transport.dart';

class _Node {
  final String id;
  late final Transport transport;
  final messages = <ChatMessage>[];
  final received = BytesBuilder();
  final established = <String>[];
  final closed = <String>[];
  Completer<void> fileEnd = Completer();
  bool Function(String, Uint8List) verify = (_, _) => true;

  _Node(this.id);

  Future<void> start() async {
    transport = Transport(
      myId: id,
      identity: await NearIdentity.generate(),
      verifyPeerKey: (peer, key) => verify(peer, key),
      onMessage: messages.add,
      onAck: (_) {},
      onFileOffer: (_, _) {},
      onFileAccept: (_, _) {},
      onFileDecline: (_, _) {},
      onFileChunk: (msgId, offset, bytes, from) {
        if (offset != received.length) return;
        received.add(bytes);
        transport.sendChunkAck(from, msgId, offset);
      },
      onFileEnd: (_) => fileEnd.complete(),
      onFileResume: (_, _, _) {},
      onFileCancel: (_, _) {},
      onChannelEstablished: established.add,
      onChannelClosed: closed.add,
    );
    await transport.startServer(address: InternetAddress.loopbackIPv4);
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

void main() {
  late _Node alice;
  late _Node bob;
  late Directory tmp;

  setUp(() async {
    alice = _Node('a-alice');
    bob = _Node('b-bob');
    await alice.start();
    await bob.start();
    tmp = await Directory.systemTemp.createTemp('near_test');
  });

  tearDown(() async {
    await alice.transport.stop();
    await bob.transport.stop();
    await tmp.delete(recursive: true);
  });

  Future<void> connect() async {
    await alice.transport.connectTo('127.0.0.1', bob.transport.port, bob.id, force: true);
    await _until(() => alice.established.contains(bob.id) && bob.established.contains(alice.id));
  }

  test('encrypted text message is delivered', () async {
    await connect();
    alice.transport.send(ChatMessage(
        id: 'm1', fromId: alice.id, fromName: 'alice', text: 'hi', ts: DateTime.now(), toId: bob.id));
    await _until(() => bob.messages.isNotEmpty);
    expect(bob.messages.single.text, 'hi');
  });

  test('message with spoofed fromId is dropped', () async {
    await connect();
    alice.transport.send(ChatMessage(
        id: 'm1', fromId: 'someone-else', fromName: 'x', text: 'hi', ts: DateTime.now(), toId: bob.id));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(bob.messages, isEmpty);
  });

  test('file transfers from an offset as binary chunks', () async {
    await connect();
    final random = Random(1);
    final content = Uint8List.fromList(
        List.generate(3 * 1024 * 1024 + 123, (_) => random.nextInt(256)));
    final file = File('${tmp.path}/f.bin')..writeAsBytesSync(content);
    const start = 64 * 1024 * 5;
    bob.received.add(content.sublist(0, start));
    final done = Completer<void>();
    await alice.transport.sendFileBytes('file-1', file, bob.id,
        startOffset: start,
        onProgress: (_) {},
        onComplete: done.complete,
        onError: done.completeError);
    await done.future;
    await bob.fileEnd.future;
    expect(bob.received.toBytes(), content);
  });

  test('dropping the channel fails the flow with ChannelLostException', () async {
    await connect();
    final file = File('${tmp.path}/big.bin')..writeAsBytesSync(Uint8List(20 * 1024 * 1024));
    final error = Completer<Object>();
    unawaited(alice.transport.sendFileBytes('file-2', file, bob.id,
        onProgress: (acked) {
          if (acked > 1024 * 1024 && alice.transport.hasChannelTo(bob.id)) {
            alice.transport.dropPeer(bob.id);
          }
        },
        onComplete: () => error.complete(StateError('completed')),
        onError: error.complete));
    expect(await error.future, isA<ChannelLostException>());
  });

  test('peer with rejected identity key never establishes', () async {
    bob.verify = (_, _) => false;
    await alice.transport.connectTo('127.0.0.1', bob.transport.port, bob.id, force: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(bob.established, isEmpty);
    expect(alice.transport.hasChannelTo(bob.id), isFalse);
  });
}
