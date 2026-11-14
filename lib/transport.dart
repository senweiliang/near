import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'peer.dart';
import 'secure_channel.dart';

/// 发送流因连接断开 / 被替换而中止。chat 层据此进入「暂停等续传」而不是直接判失败。
class ChannelLostException implements Exception {
  final String reason;
  ChannelLostException(this.reason);
  @override
  String toString() => 'ChannelLostException: $reason';
}

/// 一条到对端的字节通道：局域网是 WebSocket，跨网络是 WebRTC DataChannel。
/// 上层的加密握手 / 帧格式与通道类型无关。
abstract class PeerLink {
  /// String（握手 hello）或 Uint8List（加密帧）
  Stream<dynamic> get stream;
  void add(Object data);
  void close();
  /// 跨网络打洞直连（非局域网）
  bool get isRemote;
  String get closeInfo;
}

class WsLink implements PeerLink {
  final WebSocketChannel ws;
  WsLink(this.ws);

  @override
  Stream<dynamic> get stream => ws.stream;
  @override
  void add(Object data) => ws.sink.add(data);
  @override
  void close() => ws.sink.close();
  @override
  bool get isRemote => false;
  @override
  String get closeInfo =>
      'code=${ws.closeCode} reason="${ws.closeReason}" codeMeaning=${_closeCodeMeaning(ws.closeCode)}';
}

String _closeCodeMeaning(int? code) {
  return switch (code) {
    null => 'no-close-frame (transport torn down)',
    1000 => 'normal',
    1001 => 'going-away',
    1002 => 'protocol-error (or surfaced from socket-tear-down)',
    1003 => 'unsupported-data',
    1005 => 'no-status',
    1006 => 'abnormal-closure (no close-frame received)',
    1007 => 'invalid-payload',
    1008 => 'policy-violation',
    1009 => 'message-too-big',
    1010 => 'mandatory-ext',
    1011 => 'internal-error',
    1015 => 'tls-handshake',
    _ => 'unknown',
  };
}

class Transport {
  final String myId;
  final NearIdentity identity;
  /// TOFU 校验：返回 false 则拒绝这条连接。
  final bool Function(String peerId, Uint8List identityKey) verifyPeerKey;
  final void Function(ChatMessage) onMessage;
  final void Function(String msgId) onAck;
  final void Function(ChatMessage msg, String fromPeerId) onFileOffer;
  final void Function(String msgId, String fromPeerId) onFileAccept;
  final void Function(String msgId, String fromPeerId) onFileDecline;
  final void Function(String msgId, int offset, Uint8List bytes, String fromPeerId)
      onFileChunk;
  final void Function(String msgId) onFileEnd;
  final void Function(String msgId, int offset, String fromPeerId) onFileResume;
  final void Function(String msgId, String fromPeerId) onFileCancel;
  final void Function(String peerId)? onChannelEstablished;
  final void Function(String peerId)? onChannelClosed;
  /// 写进 hello 的昵称：对端收不到本机 mDNS 广播时，靠它在列表里显示我们。
  final String Function()? myName;

  HttpServer? _server;
  int port = 0;
  final Map<String, _Connection> _channels = {};
  final Map<String, ({String host, int port, List<String> addresses})>
      _knownPeers = {};
  final Set<String> _dialing = {};
  final Map<String, Timer> _fallbackDials = {};
  final Map<String, Completer<bool>> _pendingProbes = {};
  // 群聊 fanout 时同一 msgId 对每个 acceptor 各跑一条流，所以按 (msgId, peerId) 索引。
  final Map<String, _OutgoingFlow> _outgoingFlows = {};
  static String _flowKey(String msgId, String peerId) => '$msgId|$peerId';
  static const _keepAliveInterval = Duration(seconds: 10);
  static const _kDialTimeout = Duration(seconds: 3);
  static const _kFallbackDialDelay = Duration(seconds: 5);
  // 1 MB 在 LAN BDP 之上、又能保证背压可控，单 peer 单文件场景内存占用 ≈ 1 MB。
  static const _kInflightBytesLimit = 1 * 1024 * 1024;
  static const _kFileChunkSize = 64 * 1024;
  // 正常 ack 间隔 = 对端单块解密 + 写盘时间（Android MediaStore 串行链最差约 50ms），
  // 超过 2s 基本就是对端假死。
  static const _kAckIdleTimeout = Duration(seconds: 2);

  Iterable<String> get connectedPeerIds => _channels.keys;

  /// 群聊只覆盖同一局域网的 peer：「Everyone here」指这个网络里的人。
  Iterable<String> get lanPeerIds =>
      _channels.entries.where((e) => !e.value.link.isRemote).map((e) => e.key);

  bool isRemote(String peerId) => _channels[peerId]?.link.isRemote ?? false;

  /// 对端 hello 里带的昵称（旧版本不带则为 null）
  String? helloNameOf(String peerId) => _channels[peerId]?.peerName;

  bool hasLanChannelTo(String peerId) {
    final conn = _channels[peerId];
    return conn != null && !conn.link.isRemote;
  }

  Transport({
    required this.myId,
    required this.identity,
    required this.verifyPeerKey,
    required this.onMessage,
    required this.onAck,
    required this.onFileOffer,
    required this.onFileAccept,
    required this.onFileDecline,
    required this.onFileChunk,
    required this.onFileEnd,
    required this.onFileResume,
    required this.onFileCancel,
    this.onChannelEstablished,
    this.onChannelClosed,
    this.myName,
  });

  Future<int> startServer({InternetAddress? address}) async {
    final handler = webSocketHandler(
      (WebSocketChannel ws, _) {
        debugPrint('[transport] incoming connection');
        attachLink(WsLink(ws));
      },
    );
    // 监听 IPv6 + 兼容 IPv4（dual-stack），避免 mDNS 解析到 IPv6 时连不上
    _server = await shelf_io.serve(handler, address ?? InternetAddress.anyIPv6, 0);
    port = _server!.port;
    debugPrint('[transport] server listening on $port (dual-stack)');
    return port;
  }

  Future<void> stop() async {
    closeAllChannels();
    for (final timer in _fallbackDials.values) {
      timer.cancel();
    }
    _fallbackDials.clear();
    await _server?.close(force: true);
  }

  /// [addresses] 是对端在 mDNS attrs 里自报的局域网 IPv4，优先于解析 hostname 拨号。
  Future<void> connectTo(String host, int peerPort, String peerId,
      {List<String> addresses = const [], bool force = false}) async {
    _knownPeers[peerId] = (host: host, port: peerPort, addresses: addresses);
    if (hasLanChannelTo(peerId)) {
      debugPrint('[transport] already connected to $peerId, skip');
      return;
    }
    if (!force && myId.compareTo(peerId) > 0) {
      debugPrint(
          '[transport] $peerId has lower id, waiting for them to connect (fallback dial in ${_kFallbackDialDelay.inSeconds}s)');
      _scheduleFallbackDial(peerId);
      return;
    }
    if (!_dialing.add(peerId)) {
      debugPrint('[transport] already dialing $peerId, skip');
      return;
    }
    try {
      for (final candidate in await _dialCandidates(host, addresses)) {
        if (hasLanChannelTo(peerId)) return;
        final url = 'ws://$candidate:$peerPort';
        debugPrint('[transport] dialing $url (peer=$peerId, original host=$host)');
        final ws = IOWebSocketChannel.connect(url, connectTimeout: _kDialTimeout);
        try {
          await ws.ready;
        } catch (e) {
          debugPrint('[transport] dial $url failed: $e');
          continue;
        }
        attachLink(WsLink(ws), outgoing: true);
        return;
      }
      debugPrint('[transport] all dial candidates failed for $peerId');
    } finally {
      _dialing.remove(peerId);
    }
  }

  Future<List<String>> _dialCandidates(String host, List<String> addresses) async {
    final candidates = addresses.where(isDialableIPv4).toList();
    final cleanHost = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
    // 强制 IPv4：.local 在某些网络下优先解析到 IPv6 导致拨不通
    try {
      final resolved =
          await InternetAddress.lookup(cleanHost, type: InternetAddressType.IPv4);
      for (final addr in resolved) {
        if (!isDialableIPv4(addr.address)) {
          debugPrint('[transport] skip resolved ${addr.address} for $cleanHost (proxy fake-ip / unusable)');
          continue;
        }
        if (!candidates.contains(addr.address)) candidates.add(addr.address);
      }
    } catch (e) {
      debugPrint('[transport] lookup failed for $cleanHost: $e');
    }
    if (candidates.isEmpty) candidates.add(cleanHost);
    return candidates;
  }

  // id 较大的一方本该等对方拨过来；对方拨不通（如被代理劫持）时超时后反向拨一次
  void _scheduleFallbackDial(String peerId) {
    if (_fallbackDials.containsKey(peerId)) return;
    _fallbackDials[peerId] = Timer(_kFallbackDialDelay, () {
      _fallbackDials.remove(peerId);
      final endpoint = _knownPeers[peerId];
      if (endpoint == null || hasLanChannelTo(peerId)) return;
      debugPrint('[transport] $peerId did not dial us, dialing them instead');
      connectTo(endpoint.host, endpoint.port, peerId,
          addresses: endpoint.addresses, force: true);
    });
  }

  /// [outgoing]：本端主动发起（LAN 拨号方 / WebRTC offer 方），用于双连接去重。
  Future<void> attachLink(PeerLink link, {bool outgoing = false}) async {
    final session = await SecureSession.create(identity, myId);
    final conn = _Connection(link, session, outgoing: outgoing);
    try {
      final name = myName?.call();
      // name 不在签名范围内：只用于展示，身份仍由 idKey + TOFU 保证
      link.add(jsonEncode({...await session.hello(), 'name': ?name}));
    } catch (e) {
      debugPrint('[transport] hello send failed: $e');
    }
    link.stream.listen(
      (data) {
        // 解密是异步的，串成链保证按到达顺序处理
        conn.receiveChain = conn.receiveChain
            .then((_) => _handleRaw(conn, data))
            .catchError((Object e, StackTrace st) {
          debugPrint('[transport] data handler error peer=${conn.peerId}: $e\n$st');
        });
      },
      onDone: () {
        debugPrint(
            '[transport] channel done peerId=${conn.peerId} remote=${link.isRemote} ${link.closeInfo}');
        _onConnectionGone(conn, 'channel closed');
      },
      onError: (Object e, StackTrace st) {
        debugPrint(
            '[transport] channel error peerId=${conn.peerId} type=${e.runtimeType} detail=$e');
        if (e is WebSocketChannelException && e.inner is SocketException) {
          final inner = e.inner as SocketException;
          debugPrint(
              '[transport] socket osError=${inner.osError} address=${inner.address?.address} port=${inner.port}');
        }
        _onConnectionGone(conn, 'channel error: $e');
      },
    );
  }

  void _onConnectionGone(_Connection conn, String reason) {
    if (conn.closed) return;
    conn.closed = true;
    conn.keepAlive?.cancel();
    _failFlowsOn(conn, ChannelLostException(reason));
    final peerId = conn.peerId;
    if (peerId != null && _channels[peerId] == conn) {
      _channels.remove(peerId);
      onChannelClosed?.call(peerId);
      _scheduleRedial(peerId);
    }
  }

  Future<void> _handleRaw(_Connection conn, dynamic data) async {
    if (conn.closed) return;
    if (!conn.session.established) {
      if (data is! String) throw const FormatException('binary frame before hello');
      await _handleHello(conn, jsonDecode(data) as Map<String, dynamic>);
      return;
    }
    if (data is String) {
      debugPrint('[transport] ignoring plaintext frame after handshake');
      return;
    }
    final plain = await conn.session.open(
        data is Uint8List ? data : Uint8List.fromList(data as List<int>));
    switch (InnerFrame.decode(plain)) {
      case ChunkFrame(:final msgId, :final offset, data: final bytes):
        final from = conn.peerId;
        if (from != null) onFileChunk(msgId, offset, bytes, from);
      case JsonFrame(:final json):
        _handleJson(conn, json);
    }
  }

  Future<void> _handleHello(_Connection conn, Map<String, dynamic> m) async {
    final id = m['fromId'] as String?;
    if (m['type'] != 'hello' || id == null) {
      throw const FormatException('expected hello');
    }
    if (m['v'] == null) {
      debugPrint('[transport] $id runs an old unencrypted protocol, closing');
      conn.link.close();
      return;
    }
    final Uint8List identityKey;
    try {
      identityKey = await conn.session.acceptHello(m);
    } on HandshakeException catch (e) {
      debugPrint('[transport] handshake with $id failed: $e');
      conn.link.close();
      return;
    }
    if (!verifyPeerKey(id, identityKey)) {
      debugPrint('[transport] identity key of $id rejected, closing');
      conn.link.close();
      return;
    }
    debugPrint('[transport] secure hello from $id');
    final existing = _channels[id];
    if (existing != null) {
      // 局域网与跨网络并存时留局域网那条；同类型双向同时拨通时两端须保留同一条，
      // 否则各关一条会两条全断：统一留 id 较小一方拨出的
      final keepNew = existing.link.isRemote != conn.link.isRemote
          ? !conn.link.isRemote
          : conn.outgoing == (myId.compareTo(id) < 0);
      if (!keepNew) {
        debugPrint('[transport] dedupe close (already have $id)');
        conn.link.close();
        return;
      }
      debugPrint('[transport] dedupe replace existing channel with $id');
      _channels.remove(id);
      existing.closed = true;
      existing.keepAlive?.cancel();
      _failFlowsOn(existing, ChannelLostException('channel replaced'));
      existing.link.close();
    }
    conn.peerId = id;
    conn.peerName = m['name'] as String?;
    _channels[id] = conn;
    conn.keepAlive = Timer.periodic(_keepAliveInterval, (_) {
      conn.post({'type': 'ping', 'token': 'ka-${DateTime.now().microsecondsSinceEpoch}'});
    });
    debugPrint(
        '[transport] channel established with $id remote=${conn.link.isRemote}, total=${_channels.length}');
    onChannelEstablished?.call(id);
  }

  void _handleJson(_Connection conn, Map<String, dynamic> m) {
    final from = conn.peerId;
    if (from == null) return;
    final type = m['type'];
    final msgId = m['id'] as String?;
    switch (type) {
      case 'msg':
        final inner = m['msg'] as Map<String, dynamic>;
        final msg = ChatMessage.fromJson(inner);
        // fromId 以握手身份为准，防止伪造他人发言
        if (msg.fromId != from) {
          debugPrint('[transport] drop msg claiming fromId=${msg.fromId} on channel of $from');
          return;
        }
        onMessage(msg);
        if (msg.id.isNotEmpty) conn.post({'type': 'ack', 'id': msg.id});
      case 'ack':
        if (msgId != null) onAck(msgId);
      case 'ping':
        final token = m['token'] as String?;
        if (token != null) conn.post({'type': 'pong', 'token': token});
      case 'pong':
        final token = m['token'] as String?;
        final completer = token == null ? null : _pendingProbes.remove(token);
        if (completer != null && !completer.isCompleted) completer.complete(true);
      case 'file_offer':
        final inner = m['msg'] as Map<String, dynamic>;
        debugPrint(
            '[transport] recv file_offer id=${inner['id']} name=${inner['fileName']} size=${inner['fileSize']} from=$from');
        final msg = ChatMessage.fromJson(inner);
        if (msg.fromId != from) return;
        onFileOffer(msg, from);
      case 'file_accept':
        debugPrint('[transport] recv file_accept id=$msgId from=$from');
        if (msgId != null) onFileAccept(msgId, from);
      case 'file_decline':
        debugPrint('[transport] recv file_decline id=$msgId from=$from');
        if (msgId != null) onFileDecline(msgId, from);
      case 'file_chunk_ack':
        final offset = m['offset'] as int?;
        if (msgId != null && offset != null) _handleChunkAck(msgId, from, offset);
      case 'file_end':
        debugPrint('[transport] recv file_end id=$msgId');
        if (msgId != null) onFileEnd(msgId);
      case 'file_resume':
        final offset = m['offset'] as int?;
        debugPrint('[transport] recv file_resume id=$msgId offset=$offset from=$from');
        if (msgId != null && offset != null) onFileResume(msgId, offset, from);
      case 'file_cancel':
        debugPrint('[transport] recv file_cancel id=$msgId from=$from');
        if (msgId != null) onFileCancel(msgId, from);
      default:
        debugPrint('[transport] unknown message type: $type');
    }
  }

  void _postTo(String peerId, Map<String, dynamic> json) {
    final conn = _channels[peerId];
    if (conn == null) {
      debugPrint('[transport] no channel for $peerId, drop ${json['type']}');
      return;
    }
    conn.post(json);
  }

  void send(ChatMessage msg) {
    final payload = {'type': 'msg', 'msg': msg.toJson()};
    if (msg.toId == null) {
      for (final conn in _channels.values) {
        if (!conn.link.isRemote) conn.post(payload);
      }
    } else {
      _postTo(msg.toId!, payload);
    }
  }

  void sendFileOffer(ChatMessage msg, Iterable<String> peerIds) {
    final payload = {'type': 'file_offer', 'msg': msg.toJson()};
    debugPrint('[transport] sendFileOffer id=${msg.id} to=${peerIds.toList()}');
    for (final peerId in peerIds) {
      _postTo(peerId, payload);
    }
  }

  void sendFileResponse(String toPeerId, String msgId, bool accept) {
    final type = accept ? 'file_accept' : 'file_decline';
    debugPrint('[transport] sendFileResponse $type id=$msgId to=$toPeerId');
    _postTo(toPeerId, {'type': type, 'id': msgId});
  }

  void sendFileResume(String toPeerId, String msgId, int offset) {
    debugPrint('[transport] sendFileResume id=$msgId offset=$offset to=$toPeerId');
    _postTo(toPeerId, {'type': 'file_resume', 'id': msgId, 'offset': offset});
  }

  void sendFileCancel(String toPeerId, String msgId) {
    _postTo(toPeerId, {'type': 'file_cancel', 'id': msgId});
  }

  void sendChunkAck(String toPeerId, String msgId, int offset) {
    _channels[toPeerId]?.post({'type': 'file_chunk_ack', 'id': msgId, 'offset': offset});
  }

  /// 发送文件给单个 peer，从 [startOffset] 开始（续传时非 0）。窗口化 ack：
  /// 在途未 ack 字节达到 [_kInflightBytesLimit] 就等对端 ack 腾位；
  /// [_kAckIdleTimeout] 内没有任何新 ack 视为对端假死。
  /// 连接断开时 [onError] 收到 [ChannelLostException]。
  Future<void> sendFileBytes(
    String msgId,
    File file,
    String toPeerId, {
    int startOffset = 0,
    required void Function(int ackedBytes) onProgress,
    required void Function() onComplete,
    required void Function(Object error) onError,
  }) async {
    final conn = _channels[toPeerId];
    if (conn == null) {
      onError(ChannelLostException('no channel for $toPeerId'));
      return;
    }
    final flowKey = _flowKey(msgId, toPeerId);
    if (_outgoingFlows.containsKey(flowKey)) {
      onError(StateError('flow already running for msg=$msgId peer=$toPeerId'));
      return;
    }
    final flow = _OutgoingFlow(
      msgId: msgId,
      peerId: toPeerId,
      conn: conn,
      onProgress: onProgress,
    )..ackedBytes = startOffset;
    _outgoingFlows[flowKey] = flow;

    RandomAccessFile? raf;
    try {
      raf = await file.open();
      await raf.setPosition(startOffset);
      flow.watchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (flow.failed || flow.inflight.isEmpty) return;
        final idle = DateTime.now().difference(flow.lastAckAt);
        if (idle > _kAckIdleTimeout) {
          debugPrint(
              '[transport] sendFileBytes idle timeout id=$msgId peer=$toPeerId idle=${idle.inSeconds}s');
          _markFlowFailed(flow,
              TimeoutException('no chunk ack for ${_kAckIdleTimeout.inSeconds}s'));
        }
      });
      debugPrint('[transport] sendFileBytes id=$msgId peer=$toPeerId start offset=$startOffset');
      final buffer = Uint8List(_kFileChunkSize);
      var offset = startOffset;
      while (true) {
        while (!flow.failed && flow.inflightBytes >= _kInflightBytesLimit) {
          await flow.waitForAck();
        }
        if (flow.failed) throw flow.failReason ?? StateError('flow failed');
        final read = await raf.readInto(buffer);
        if (read == 0) break;
        flow.inflight[offset] = read;
        if (flow.inflight.length == 1) flow.lastAckAt = DateTime.now();
        await conn.send(ChunkFrame(msgId, offset, Uint8List.sublistView(buffer, 0, read)));
        offset += read;
      }
      // 所有在途块都 ack 后才发 file_end，确保对端已落盘全部字节
      while (!flow.failed && flow.inflight.isNotEmpty) {
        await flow.waitForAck();
      }
      if (flow.failed) throw flow.failReason ?? StateError('flow failed');
      await conn.send(JsonFrame({'type': 'file_end', 'id': msgId}));
      debugPrint('[transport] sendFileBytes done id=$msgId acked=${flow.ackedBytes}');
      onComplete();
    } catch (e) {
      final error = conn.closed && e is! ChannelLostException
          ? ChannelLostException('$e')
          : e;
      debugPrint('[transport] sendFileBytes failed id=$msgId: $error');
      onError(error);
    } finally {
      flow.watchdog?.cancel();
      if (_outgoingFlows[flowKey] == flow) _outgoingFlows.remove(flowKey);
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// 立即中止一条发送流并让出 key，续传时用新流替换旧流。
  void cancelFlow(String msgId, String peerId) {
    final flow = _outgoingFlows.remove(_flowKey(msgId, peerId));
    if (flow != null) _markFlowFailed(flow, StateError('flow superseded'));
  }

  void _handleChunkAck(String msgId, String fromPeerId, int offset) {
    final flow = _outgoingFlows[_flowKey(msgId, fromPeerId)];
    if (flow == null || flow.failed) return;
    final bytes = flow.inflight.remove(offset);
    if (bytes == null) return;
    flow.ackedBytes += bytes;
    flow.lastAckAt = DateTime.now();
    flow.onProgress(flow.ackedBytes);
    flow.wake();
  }

  void _failFlowsOn(_Connection conn, Object reason) {
    for (final flow in _outgoingFlows.values) {
      if (flow.conn == conn && !flow.failed) _markFlowFailed(flow, reason);
    }
  }

  void _markFlowFailed(_OutgoingFlow flow, Object reason) {
    flow.failed = true;
    flow.failReason = reason;
    flow.watchdog?.cancel();
    flow.watchdog = null;
    flow.wake();
  }

  int get lanPeerCount => lanPeerIds.length;

  /// [toId] 为 null 表示群聊，只看局域网 peer。
  bool hasChannelTo(String? toId) {
    if (toId == null) return lanPeerIds.isNotEmpty;
    return _channels.containsKey(toId);
  }

  void closeAllChannels() {
    final list = _channels.values.toList();
    _channels.clear();
    for (final conn in list) {
      conn.closed = true;
      conn.keepAlive?.cancel();
      _failFlowsOn(conn, ChannelLostException('all channels closed'));
      try {
        conn.link.close();
      } catch (_) {}
    }
  }

  void dropPeer(String peerId) {
    final conn = _channels.remove(peerId);
    if (conn == null) return;
    conn.closed = true;
    conn.keepAlive?.cancel();
    _failFlowsOn(conn, ChannelLostException('peer dropped'));
    try {
      conn.link.close();
    } catch (_) {}
    // _channels 已移除，onDone 的守卫会跳过回调，这里显式补一次让 chat 侧一致清理
    onChannelClosed?.call(peerId);
  }

  Future<bool> probePeer(
    String peerId, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    final conn = _channels[peerId];
    if (conn == null) return Future.value(false);
    final token = '${DateTime.now().microsecondsSinceEpoch}-$peerId';
    final completer = Completer<bool>();
    _pendingProbes[token] = completer;
    conn.post({'type': 'ping', 'token': token});
    Future.delayed(timeout, () {
      final pending = _pendingProbes.remove(token);
      if (pending != null && !pending.isCompleted) pending.complete(false);
    });
    return completer.future;
  }

  void redialAll() {
    for (final entry in _knownPeers.entries) {
      if (hasLanChannelTo(entry.key)) continue;
      connectTo(entry.value.host, entry.value.port, entry.key,
          addresses: entry.value.addresses, force: true);
    }
  }

  void _scheduleRedial(String peerId) {
    final endpoint = _knownPeers[peerId];
    if (endpoint == null) return;
    if (myId.compareTo(peerId) > 0) {
      debugPrint('[transport] not redialing $peerId (lower id, expecting them to dial)');
      _scheduleFallbackDial(peerId);
      return;
    }
    Future.delayed(const Duration(seconds: 2), () {
      if (hasLanChannelTo(peerId)) return;
      debugPrint('[transport] redialing $peerId');
      connectTo(endpoint.host, endpoint.port, peerId,
          addresses: endpoint.addresses);
    });
  }
}

/// 排除 loopback、169.254 link-local，以及 Clash / Surge 等代理 TUN 模式的 fake-ip 段 198.18.0.0/15。
bool isDialableIPv4(String address) {
  final parsed = InternetAddress.tryParse(address);
  if (parsed == null || parsed.type != InternetAddressType.IPv4) return false;
  if (parsed.isLoopback || parsed.isLinkLocal) return false;
  final raw = parsed.rawAddress;
  if (raw[0] == 198 && (raw[1] == 18 || raw[1] == 19)) return false;
  return true;
}

class _Connection {
  final PeerLink link;
  final SecureSession session;
  final bool outgoing;
  String? peerId; // 握手完成并纳入 _channels 后才设置
  String? peerName;
  bool closed = false;
  Timer? keepAlive;
  Future<void> receiveChain = Future.value();
  Future<void> _sendChain = Future.value();

  _Connection(this.link, this.session, {required this.outgoing});

  /// 加密是异步的：串行化保证 nonce 计数与线上顺序一致。
  Future<void> send(InnerFrame frame) {
    final next = _sendChain.then((_) async {
      if (closed) throw ChannelLostException('channel closed');
      link.add(await session.seal(frame.encode()));
    });
    _sendChain = next.catchError((_) {});
    return next;
  }

  void post(Map<String, dynamic> json) {
    send(JsonFrame(json)).catchError((Object e) {
      debugPrint('[transport] send ${json['type']} to $peerId failed: $e');
    });
  }
}

class _OutgoingFlow {
  final String msgId;
  final String peerId;
  final _Connection conn;
  final void Function(int ackedBytes) onProgress;
  // 已发出但未 ack 的块：offset → bytes
  final Map<int, int> inflight = {};
  int ackedBytes = 0;
  Completer<void>? _ackWaiter;
  Timer? watchdog;
  DateTime lastAckAt = DateTime.now();
  bool failed = false;
  Object? failReason;

  _OutgoingFlow({
    required this.msgId,
    required this.peerId,
    required this.conn,
    required this.onProgress,
  });

  int get inflightBytes => inflight.values.fold(0, (sum, b) => sum + b);

  Future<void> waitForAck() => (_ackWaiter ??= Completer<void>()).future;

  void wake() {
    final waiter = _ackWaiter;
    _ackWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }
}
