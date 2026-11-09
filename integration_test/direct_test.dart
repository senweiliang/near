import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:near/peer.dart';
import 'package:near/remote.dart';
import 'package:near/secure_channel.dart';
import 'package:near/signaling.dart';
import 'package:near/transport.dart';

/// 端到端：两个节点经协调服务器扫码配对 → WebRTC 打洞 → 在 DataChannel 上跑完整的
/// 加密握手、文本、大消息（切片）和文件窗口化传输。需要先起服务器，用 dart-define 传地址：
///   flutter test integration_test/direct_test.dart -d macos \
///     --dart-define=SIGNAL_HOST=127.0.0.1 --dart-define=SIGNAL_PORT=17443 \
///     --dart-define=STUN_PORT=13478 --dart-define=SIGNAL_CERT=<sha256>
const _server = SignalServer(
  host: String.fromEnvironment('SIGNAL_HOST', defaultValue: '127.0.0.1'),
  port: int.fromEnvironment('SIGNAL_PORT', defaultValue: 17443),
  stunPort: int.fromEnvironment('STUN_PORT', defaultValue: 13478),
  certSha256: String.fromEnvironment('SIGNAL_CERT'),
);

class _Node {
  final String id;
  final String name;
  late final NearIdentity identity;
  late final Transport transport;
  late final SignalClient signal;
  late final Remote remote;
  final messages = <ChatMessage>[];
  final acks = <String>[];
  final established = <String>[];
  final closed = <String>[];
  final received = BytesBuilder();
  Completer<void> fileEnd = Completer();
  final trusted = <String, String>{};

  _Node(this.id, this.name);

  Future<void> start() async {
    identity = await NearIdentity.generate();
    transport = Transport(
      myId: id,
      identity: identity,
      verifyPeerKey: (peer, key) {
        final known = trusted[peer];
        return known == null || known == base64Encode(key);
      },
      onMessage: messages.add,
      onAck: acks.add,
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
      onChannelClosed: (peerId) {
        closed.add(peerId);
        remote.onChannelClosed(peerId);
      },
    );
    late final Remote created;
    signal = SignalClient(
      identity: identity,
      server: _server,
      onRelay: (from, data) => created.onRelay(from, data),
      onPresence: (key, online) => created.onPresence(key, online),
      onUndeliverable: (to) => created.onUndeliverable(to),
      onStateChanged: () => created.onSignalStateChanged(),
    );
    created = Remote(
      myId: id,
      myName: () => name,
      signal: signal,
      attachLink: (link, outgoing) => transport.attachLink(link, outgoing: outgoing),
      hasChannel: transport.hasChannelTo,
      hasLanChannel: transport.hasLanChannelTo,
      onPaired: (device) => trusted[device.id] = device.key,
      onUnpaired: (device) {
        if (transport.isRemote(device.id)) transport.dropPeer(device.id);
      },
      onChanged: () {},
      persist: (_) {},
      initial: const [],
    );
    remote = created;
    signal.start();
  }

  Future<void> stop() async {
    await signal.stop();
    await transport.stop();
  }
}

Future<void> _until(bool Function() condition, {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late _Node alice;
  late _Node bob;

  setUp(() async {
    alice = _Node('a-alice', 'Alice');
    bob = _Node('b-bob', 'Bob');
    await alice.start();
    await bob.start();
    await _until(() => alice.signal.connected && bob.signal.connected, timeout: const Duration(seconds: 15));
  });

  tearDown(() async {
    await alice.stop();
    await bob.stop();
  });

  testWidgets('pair by code, punch through, then chat and transfer over the DataChannel', (_) async {
    final code = alice.remote.showCode();
    final scanned = PairCandidate.parse(code.candidate.toUri())!;
    final device = await bob.remote.pairWith(scanned);
    expect(device.id, alice.id);
    expect(alice.remote.codePairedWith?.id, bob.id);
    expect(alice.remote.devices.single.key, base64Encode(bob.identity.publicKey));

    await _until(() => alice.established.contains(bob.id) && bob.established.contains(alice.id));
    expect(alice.transport.isRemote(bob.id), isTrue);
    expect(bob.remote.statusOf(alice.id), DirectStatus.connected);
    // 跨网络 peer 不算进「Everyone here」
    expect(alice.transport.lanPeerIds, isEmpty);
    expect(alice.transport.hasChannelTo(null), isFalse);

    final text = ChatMessage(
        id: 'm1', fromId: alice.id, fromName: 'Alice', text: 'hi over the internet', ts: DateTime.now(), toId: bob.id);
    alice.transport.send(text);
    await _until(() => bob.messages.any((m) => m.id == 'm1') && alice.acks.contains('m1'));

    // 远超 DataChannel 单条消息上限的大帧（图片消息就是这种），验证切片重组
    final random = Random(7);
    final imageBytes = Uint8List.fromList(List.generate(3 * 1024 * 1024, (_) => random.nextInt(256)));
    final image = ChatMessage(
      id: 'm2',
      fromId: alice.id,
      fromName: 'Alice',
      text: '',
      ts: DateTime.now(),
      toId: bob.id,
      imageBase64: base64Encode(imageBytes),
      imageMime: 'image/png',
    );
    alice.transport.send(image);
    await _until(() => bob.messages.any((m) => m.id == 'm2'));
    expect(base64Decode(bob.messages.firstWhere((m) => m.id == 'm2').imageBase64!), imageBytes);

    final tmp = await Directory.systemTemp.createTemp('near_direct');
    final file = File('${tmp.path}/payload.bin');
    final payload = Uint8List.fromList(List.generate(5 * 1024 * 1024 + 123, (_) => random.nextInt(256)));
    await file.writeAsBytes(payload);
    final done = Completer<void>();
    await alice.transport.sendFileBytes('f1', file, bob.id,
        onProgress: (_) {}, onComplete: done.complete, onError: done.completeError);
    await done.future.timeout(const Duration(seconds: 60));
    await bob.fileEnd.future.timeout(const Duration(seconds: 10));
    expect(bob.received.toBytes(), payload);
    await tmp.delete(recursive: true);

    alice.remote.unpair(bob.id);
    await _until(() => bob.remote.devices.isEmpty && alice.closed.contains(bob.id) && bob.closed.contains(alice.id));
  });

  testWidgets('pairing fails cleanly for a stale code or an absent device', (_) async {
    final code = alice.remote.showCode();
    final forged = PairCandidate(
        id: alice.id, name: 'Alice', key: code.candidate.key, token: 'not-the-token');
    await expectLater(bob.remote.pairWith(forged),
        throwsA(isA<PairException>().having((e) => e.reason, 'reason', PairFailure.rejected)));

    final ghost = await NearIdentity.generate();
    final absent = PairCandidate(id: 'ghost', name: 'Ghost', key: base64Encode(ghost.publicKey), token: 't');
    await expectLater(bob.remote.pairWith(absent),
        throwsA(isA<PairException>().having((e) => e.reason, 'reason', PairFailure.peerOffline)));

    // 一次性：用过的码不能再配第二台
    final real = alice.remote.showCode();
    await bob.remote.pairWith(PairCandidate.parse(real.candidate.toUri())!);
    final carol = _Node('c-carol', 'Carol');
    await carol.start();
    await _until(() => carol.signal.connected);
    await expectLater(carol.remote.pairWith(PairCandidate.parse(real.candidate.toUri())!),
        throwsA(isA<PairException>().having((e) => e.reason, 'reason', PairFailure.rejected)));
    await carol.stop();
  });

  testWidgets('reconnects after the direct channel drops while both stay paired', (_) async {
    final code = alice.remote.showCode();
    await bob.remote.pairWith(PairCandidate.parse(code.candidate.toUri())!);
    await _until(() => alice.established.contains(bob.id) && bob.established.contains(alice.id));

    alice.transport.dropPeer(bob.id);
    await _until(() => bob.closed.contains(alice.id));
    await _until(
        () => alice.established.where((id) => id == bob.id).length >= 2 && alice.transport.isRemote(bob.id),
        timeout: const Duration(seconds: 40));
  });
}
