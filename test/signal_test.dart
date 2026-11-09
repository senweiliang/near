import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:near/remote.dart';
import 'package:near/secure_channel.dart';
import 'package:near/signaling.dart';

/// 起一个真实的协调服务器进程（自签证书），用 [SignalClient] 跑完整协议。
void main() {
  late Directory tmp;
  late Process server;
  late SignalServer config;
  const port = 17443;
  const stunPort = 13478;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('near_signal_test');
    final gen = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
      '-nodes', '-days', '1', '-subj', '/CN=near-test',
      '-keyout', '${tmp.path}/key.pem', '-out', '${tmp.path}/cert.pem',
    ]);
    expect(gen.exitCode, 0, reason: gen.stderr.toString());
    final der = await Process.run(
        'openssl', ['x509', '-in', '${tmp.path}/cert.pem', '-outform', 'der'],
        stdoutEncoding: null);
    final fingerprint = crypto.sha256.convert(der.stdout as List<int>).toString();
    config = SignalServer(host: '127.0.0.1', port: port, stunPort: stunPort, certSha256: fingerprint);
    server = await Process.start('dart', [
      'run', 'bin/near_signal.dart',
      '--cert', '${tmp.path}/cert.pem', '--key', '${tmp.path}/key.pem',
      '--port', '$port', '--stun-port', '$stunPort',
    ], workingDirectory: 'server');
    final ready = Completer<void>();
    server.stdout.transform(utf8.decoder).listen((line) {
      if (line.contains('stun listening') && !ready.isCompleted) ready.complete();
    });
    server.stderr.transform(utf8.decoder).listen((line) => print('server stderr: $line'));
    await ready.future.timeout(const Duration(seconds: 60));
  });

  tearDownAll(() async {
    server.kill();
    await tmp.delete(recursive: true);
  });

  group('PairCandidate', () {
    test('round-trips through the QR uri', () async {
      final identity = await NearIdentity.generate();
      final key = base64Encode(identity.publicKey);
      final original = PairCandidate(id: 'abc-123', name: 'Mac mini 林', key: key, token: 'tok_-x');
      final parsed = PairCandidate.parse(original.toUri())!;
      expect(parsed.id, 'abc-123');
      expect(parsed.name, 'Mac mini 林');
      expect(parsed.key, key);
      expect(parsed.token, 'tok_-x');
    });

    test('rejects foreign or malformed codes', () {
      expect(PairCandidate.parse('https://example.com'), isNull);
      expect(PairCandidate.parse('near://pair?id=a&n=b&t=c'), isNull);
      expect(PairCandidate.parse('near://pair?id=a&n=b&k=AAAA&t=c'), isNull);
      expect(PairCandidate.parse('not a uri at all ::'), isNull);
    });
  });

  test('STUN binding returns our mapped address', () async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final localPort = socket.port;
    final request = Uint8List(20);
    final view = ByteData.sublistView(request);
    view.setUint16(0, 0x0001);
    view.setUint32(4, 0x2112A442);
    for (var i = 8; i < 20; i++) {
      request[i] = i;
    }
    socket.send(request, InternetAddress.loopbackIPv4, stunPort);
    final response = await socket
        .where((e) => e == RawSocketEvent.read)
        .map((_) => socket.receive())
        .firstWhere((d) => d != null)
        .timeout(const Duration(seconds: 5));
    socket.close();
    final r = ByteData.sublistView(response!.data);
    expect(r.getUint16(0), 0x0101);
    expect(response.data.sublist(8, 20), request.sublist(8, 20));
    expect(r.getUint16(20), 0x0020);
    final mappedPort = r.getUint16(26) ^ 0x2112;
    final mappedIp = r.getUint32(28) ^ 0x2112A442;
    expect(mappedPort, localPort);
    expect(mappedIp, 0x7F000001);
  });

  group('signaling', () {
    late _TestClient alice, bob, eve;

    setUp(() async {
      alice = await _TestClient.create(config);
      bob = await _TestClient.create(config);
      eve = await _TestClient.create(config);
    });

    tearDown(() async {
      await alice.client.stop();
      await bob.client.stop();
      await eve.client.stop();
    });

    test('authenticates, then sees presence only when both watch each other', () async {
      alice.client.start();
      bob.client.start();
      await alice.connected.future;
      await bob.connected.future;

      alice.client.setWatch([bob.key]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(alice.presence, isEmpty, reason: 'one-sided watch must not leak presence');

      bob.client.setWatch([alice.key]);
      await alice.waitPresence(bob.key, true);
      await bob.waitPresence(alice.key, true);

      await bob.client.stop();
      await alice.waitPresence(bob.key, false);
    });

    test('relays payloads and reports undeliverable targets', () async {
      alice.client.start();
      bob.client.start();
      await alice.connected.future;
      await bob.connected.future;

      expect(alice.client.relay(bob.key, {'kind': 'hello', 'n': 1}), isTrue);
      final got = await bob.relays.stream.first.timeout(const Duration(seconds: 5));
      expect(got.from, alice.key);
      expect(got.data, {'kind': 'hello', 'n': 1});

      alice.client.relay(eve.key, {'kind': 'hello'});
      final undeliverable = await alice.undeliverable.stream.first.timeout(const Duration(seconds: 5));
      expect(undeliverable, eve.key);
    });

    test('refuses a server whose certificate is not the pinned one', () async {
      final wrong = SignalServer(
          host: config.host, port: config.port, stunPort: config.stunPort, certSha256: '00' * 32);
      final mallory = await _TestClient.create(wrong);
      mallory.client.start();
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(mallory.client.connected, isFalse);
      await mallory.client.stop();
    });
  });
}

class _TestClient {
  final NearIdentity identity;
  late final SignalClient client;
  final connected = Completer<void>();
  final presence = <String, bool>{};
  final _presenceEvents = StreamController<MapEntry<String, bool>>.broadcast();
  final relays = StreamController<({String from, Map<String, dynamic> data})>.broadcast();
  final undeliverable = StreamController<String>.broadcast();

  _TestClient._(this.identity, SignalServer server) {
    client = SignalClient(
      identity: identity,
      server: server,
      onRelay: (from, data) => relays.add((from: from, data: data)),
      onPresence: (key, online) {
        presence[key] = online;
        _presenceEvents.add(MapEntry(key, online));
      },
      onUndeliverable: undeliverable.add,
      onStateChanged: () {
        if (client.connected && !connected.isCompleted) connected.complete();
      },
    );
  }

  static Future<_TestClient> create(SignalServer server) async =>
      _TestClient._(await NearIdentity.generate(), server);

  String get key => base64Encode(identity.publicKey);

  Future<void> waitPresence(String key, bool online) async {
    if (presence[key] == online) return;
    await _presenceEvents.stream
        .firstWhere((e) => e.key == key && e.value == online)
        .timeout(const Duration(seconds: 5));
  }
}
