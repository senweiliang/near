import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Near 协调服务器：只做信令转发 + STUN，不中转任何聊天 / 文件数据。
/// 客户端以 Ed25519 身份公钥（base64）为地址；连接时用签名证明持有对应私钥。
///
/// 用法：near_signal --cert cert.pem --key key.pem [--port 7443] [--stun-port 3478]
Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final certPath = options['cert'];
  final keyPath = options['key'];
  if (certPath == null || keyPath == null) {
    stderr.writeln('usage: near_signal --cert cert.pem --key key.pem [--port 7443] [--stun-port 3478]');
    exit(64);
  }
  final port = int.parse(options['port'] ?? '7443');
  final stunPort = int.parse(options['stun-port'] ?? '3478');

  final context = SecurityContext()
    ..useCertificateChain(certPath)
    ..usePrivateKey(keyPath);
  final server = await HttpServer.bindSecure(InternetAddress.anyIPv4, port, context);
  _log('signal listening on :$port');
  await _startStun(stunPort);

  final hub = _Hub();
  await for (final request in server) {
    if (request.uri.path != '/signal' || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      continue;
    }
    final remote = request.connectionInfo?.remoteAddress.address ?? '?';
    WebSocketTransformer.upgrade(request).then<void>((ws) {
      ws.pingInterval = const Duration(seconds: 20);
      hub.accept(ws, remote);
    }, onError: (Object e) => _log('upgrade failed from $remote: $e'));
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    if (args[i].startsWith('--')) out[args[i].substring(2)] = args[i + 1];
  }
  return out;
}

void _log(String line) => stdout.writeln('${DateTime.now().toUtc().toIso8601String()} $line');

String _short(String key) => key.length <= 8 ? key : key.substring(0, 8);

class _Client {
  final WebSocket ws;
  final String remote;
  final String nonce;
  String? key;
  Set<String> watching = {};
  // 简单令牌桶，防止单个客户端刷 relay
  double tokens = _kRelayBurst;
  DateTime lastRefill = DateTime.now();

  _Client(this.ws, this.remote, this.nonce);

  void send(Map<String, dynamic> json) {
    try {
      ws.add(jsonEncode(json));
    } catch (_) {}
  }

  bool takeRelayToken() {
    final now = DateTime.now();
    tokens = min(_kRelayBurst,
        tokens + now.difference(lastRefill).inMilliseconds / 1000 * _kRelayPerSecond);
    lastRefill = now;
    if (tokens < 1) return false;
    tokens -= 1;
    return true;
  }
}

// ICE 候选在建连开始时成批出现，突发额度要够一次握手
const double _kRelayBurst = 200;
const double _kRelayPerSecond = 20;
const int _kMaxMessageBytes = 64 * 1024;
const int _kMaxWatch = 256;
const Duration _kAuthTimeout = Duration(seconds: 10);

class _Hub {
  final Map<String, _Client> _online = {};
  final Random _random = Random.secure();

  void accept(WebSocket ws, String remote) {
    final nonce = base64Encode(List<int>.generate(24, (_) => _random.nextInt(256)));
    final client = _Client(ws, remote, nonce);
    client.send({'type': 'challenge', 'nonce': nonce});
    final authTimer = Timer(_kAuthTimeout, () {
      if (client.key == null) ws.close(4001, 'auth timeout');
    });
    ws.listen(
      (data) {
        if (data is! String || data.length > _kMaxMessageBytes) {
          ws.close(4002, 'bad frame');
          return;
        }
        Map<String, dynamic> m;
        try {
          m = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          ws.close(4002, 'bad json');
          return;
        }
        _handle(client, m).catchError((Object e) {
          _log('handler error ${client.remote}: $e');
          ws.close(4002, 'bad message');
        });
      },
      onDone: () {
        authTimer.cancel();
        _drop(client);
      },
      onError: (_) {
        authTimer.cancel();
        _drop(client);
      },
      cancelOnError: true,
    );
  }

  Future<void> _handle(_Client client, Map<String, dynamic> m) async {
    final type = m['type'];
    if (client.key == null) {
      if (type != 'auth') throw const FormatException('expected auth');
      await _auth(client, m);
      return;
    }
    switch (type) {
      case 'watch':
        final keys = (m['keys'] as List).cast<String>();
        if (keys.length > _kMaxWatch) throw const FormatException('watch list too long');
        _setWatch(client, keys.toSet());
      case 'relay':
        final to = m['to'] as String;
        if (!client.takeRelayToken()) {
          client.send({'type': 'error', 'reason': 'rate limited'});
          return;
        }
        final target = _online[to];
        if (target == null) {
          client.send({'type': 'undeliverable', 'to': to, 'ref': m['ref']});
          return;
        }
        target.send({'type': 'relay', 'from': client.key, 'data': m['data']});
      default:
        throw FormatException('unknown type $type');
    }
  }

  Future<void> _auth(_Client client, Map<String, dynamic> m) async {
    final keyText = m['key'] as String;
    final key = base64Decode(keyText);
    final signature = base64Decode(m['sig'] as String);
    if (key.length != 32) throw const FormatException('bad key');
    final valid = await Ed25519().verify(
      utf8.encode('near-signal-v1|${client.nonce}'),
      signature: Signature(signature, publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)),
    );
    if (!valid) {
      client.ws.close(4003, 'bad signature');
      return;
    }
    final previous = _online[keyText];
    client.key = keyText;
    _online[keyText] = client;
    if (previous != null && previous != client) {
      // 同一身份新连接顶替旧连接（典型：手机切网络后旧 socket 还没超时）
      previous.key = null;
      previous.ws.close(4004, 'replaced');
    }
    _log('online ${_short(keyText)} from ${client.remote} (total ${_online.length})');
    client.send({'type': 'ready'});
    _announce(client, true);
  }

  // 只有双方互相 watch（即都把对方存为已配对设备）才互相可见在线状态
  bool _mutual(_Client a, _Client b) =>
      a.watching.contains(b.key) && b.watching.contains(a.key);

  void _setWatch(_Client client, Set<String> keys) {
    final before = {
      for (final k in client.watching)
        if (_online[k] != null && _mutual(client, _online[k]!)) k
    };
    client.watching = keys;
    for (final k in keys.union(before)) {
      final other = _online[k];
      if (other == null || other == client) continue;
      final now = _mutual(client, other);
      if (now == before.contains(k)) continue;
      client.send({'type': 'presence', 'key': k, 'online': now});
      other.send({'type': 'presence', 'key': client.key, 'online': now});
    }
  }

  void _announce(_Client client, bool online) {
    for (final k in client.watching) {
      final other = _online[k];
      if (other == null || other == client || !_mutual(client, other)) continue;
      other.send({'type': 'presence', 'key': client.key, 'online': online});
      if (online) client.send({'type': 'presence', 'key': k, 'online': true});
    }
  }

  void _drop(_Client client) {
    final key = client.key;
    if (key == null || _online[key] != client) return;
    _online.remove(key);
    _log('offline ${_short(key)} (total ${_online.length})');
    _announce(client, false);
  }
}

/// 最小 STUN（RFC 5389）：只应答 Binding Request，回 XOR-MAPPED-ADDRESS。
Future<void> _startStun(int port) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
  _log('stun listening on udp :$port');
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    final response = stunBindingResponse(datagram.data, datagram.address, datagram.port);
    if (response != null) socket.send(response, datagram.address, datagram.port);
  });
}

const int _kStunMagicCookie = 0x2112A442;

Uint8List? stunBindingResponse(Uint8List request, InternetAddress address, int port) {
  if (request.length < 20 || address.type != InternetAddressType.IPv4) return null;
  final view = ByteData.sublistView(request);
  if (view.getUint16(0) != 0x0001 || view.getUint32(4) != _kStunMagicCookie) return null;
  final out = Uint8List(32);
  final o = ByteData.sublistView(out);
  o.setUint16(0, 0x0101); // Binding Success Response
  o.setUint16(2, 12); // 属性总长：一个 XOR-MAPPED-ADDRESS
  o.setUint32(4, _kStunMagicCookie);
  out.setRange(8, 20, request, 8); // transaction id 原样带回
  o.setUint16(20, 0x0020);
  o.setUint16(22, 8);
  o.setUint8(25, 0x01); // IPv4
  o.setUint16(26, port ^ (_kStunMagicCookie >> 16));
  final raw = address.rawAddress;
  final ip = (raw[0] << 24) | (raw[1] << 16) | (raw[2] << 8) | raw[3];
  o.setUint32(28, ip ^ _kStunMagicCookie);
  return out;
}
