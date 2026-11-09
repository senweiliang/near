import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'secure_channel.dart';

/// 协调服务器地址。证书是自签的，客户端只认这一张（按 DER 的 SHA-256 固定）。
class SignalServer {
  final String host;
  final int port;
  final int stunPort;
  final String certSha256;
  const SignalServer({
    required this.host,
    required this.port,
    required this.stunPort,
    required this.certSha256,
  });

  String get stunUrl => 'stun:$host:$stunPort';
}

const SignalServer kSignalServer = SignalServer(
  host: '101.200.167.45',
  port: 7443,
  stunPort: 3478,
  certSha256: 'bc59dc3c5457c0c79c921ecf22cbc782d831ff7af1f209fb6fd03f54a82226b0',
);

/// 协调服务器客户端：只用来交换配对消息和 WebRTC 信令，聊天 / 文件数据从不经过它。
/// 以本机 Ed25519 身份公钥（base64）为地址。
class SignalClient {
  final NearIdentity identity;
  final SignalServer server;
  final void Function(String fromKey, Map<String, dynamic> data) onRelay;
  final void Function(String key, bool online) onPresence;
  final void Function(String toKey) onUndeliverable;
  final VoidCallback onStateChanged;

  SignalClient({
    required this.identity,
    this.server = kSignalServer,
    required this.onRelay,
    required this.onPresence,
    required this.onUndeliverable,
    required this.onStateChanged,
  });

  WebSocket? _ws;
  bool _ready = false;
  bool _running = false;
  bool _connecting = false;
  Timer? _retryTimer;
  int _failures = 0;
  Set<String> _watch = {};

  bool get connected => _ready;
  String get myKey => base64Encode(identity.publicKey);

  void start() {
    if (_running) return;
    _running = true;
    _connect();
  }

  Future<void> stop() async {
    _running = false;
    _retryTimer?.cancel();
    await _ws?.close();
    _ws = null;
    _setReady(false);
  }

  /// app 回前台时调用：断着就立刻重连，不等退避计时。
  void kick() {
    if (!_running || _ready || _connecting) return;
    _retryTimer?.cancel();
    _connect();
  }

  void setWatch(Iterable<String> keys) {
    _watch = keys.toSet();
    if (_ready) _send({'type': 'watch', 'keys': _watch.toList()});
  }

  /// 对端不在线时返回 true 但随后触发 [onUndeliverable]；自己没连上服务器返回 false。
  bool relay(String toKey, Map<String, dynamic> data) {
    if (!_ready) return false;
    _send({'type': 'relay', 'to': toKey, 'data': data});
    return true;
  }

  void _send(Map<String, dynamic> json) {
    try {
      _ws?.add(jsonEncode(json));
    } catch (e) {
      debugPrint('[signal] send failed: $e');
    }
  }

  void _setReady(bool v) {
    if (_ready == v) return;
    _ready = v;
    onStateChanged();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    try {
      final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
        ..connectionTimeout = const Duration(seconds: 8)
        ..badCertificateCallback = (cert, host, port) =>
            crypto.sha256.convert(cert.der).toString() == server.certSha256;
      final ws = await WebSocket.connect('wss://${server.host}:${server.port}/signal',
          customClient: client);
      ws.pingInterval = const Duration(seconds: 20);
      _ws = ws;
      debugPrint('[signal] connected');
      ws.listen(
        (data) => _handle(ws, data).catchError((Object e) {
          debugPrint('[signal] handle error: $e');
        }),
        onDone: () => _onClosed(ws, 'closed code=${ws.closeCode} ${ws.closeReason ?? ''}'),
        onError: (Object e) => _onClosed(ws, 'error $e'),
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[signal] connect failed: $e');
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _handle(WebSocket ws, dynamic data) async {
    if (data is! String) return;
    final m = jsonDecode(data) as Map<String, dynamic>;
    switch (m['type']) {
      case 'challenge':
        final signature = await Ed25519().sign(
          utf8.encode('near-signal-v1|${m['nonce']}'),
          keyPair: identity.keyPair,
        );
        ws.add(jsonEncode({
          'type': 'auth',
          'key': myKey,
          'sig': base64Encode(signature.bytes),
        }));
      case 'ready':
        _failures = 0;
        _setReady(true);
        _send({'type': 'watch', 'keys': _watch.toList()});
      case 'presence':
        onPresence(m['key'] as String, m['online'] as bool);
      case 'relay':
        onRelay(m['from'] as String, (m['data'] as Map).cast<String, dynamic>());
      case 'undeliverable':
        onUndeliverable(m['to'] as String);
      case 'error':
        debugPrint('[signal] server error: ${m['reason']}');
    }
  }

  void _onClosed(WebSocket ws, String reason) {
    if (_ws != ws) return;
    debugPrint('[signal] disconnected: $reason');
    _ws = null;
    _setReady(false);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_running) return;
    _retryTimer?.cancel();
    // 2s 起步指数退避，封顶 60s
    final seconds = (2 << _failures.clamp(0, 5)).clamp(2, 60);
    _failures++;
    _retryTimer = Timer(Duration(seconds: seconds), _connect);
  }
}
