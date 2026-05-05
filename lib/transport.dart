import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'peer.dart';

class Transport {
  final String myId;
  final void Function(ChatMessage) onMessage;
  final void Function(String msgId) onAck;
  final void Function(ChatMessage msg, String fromPeerId) onFileOffer;
  final void Function(String msgId, String fromPeerId) onFileAccept;
  final void Function(String msgId, String fromPeerId) onFileDecline;
  final void Function(String msgId, int seq, Uint8List bytes, String fromPeerId)
      onFileChunk;
  final void Function(String msgId) onFileEnd;
  final void Function(String peerId)? onChannelEstablished;
  final void Function(String peerId)? onChannelClosed;

  HttpServer? _server;
  int port = 0;
  final Map<String, WebSocketChannel> _channels = {};
  final Map<String, (String host, int port)> _knownPeers = {};
  final Map<String, Completer<bool>> _pendingProbes = {};
  final Map<WebSocketChannel, Timer> _keepAlive = {};
  // 每个进行中的文件发送流（sender 端），按 (msgId, peerId) 复合 key 索引。
  // 群聊 fanout 时同一 msgId 会对每个 acceptor 各跑一个独立 sendFileBytes（每个
  // acceptor 一份独立流），所以单 msgId 不足以唯一标识。
  final Map<String, _OutgoingFlow> _outgoingFlows = {};
  static String _flowKey(String msgId, String peerId) => '$msgId|$peerId';
  static const _keepAliveInterval = Duration(seconds: 10);
  // 文件传输窗口大小：sender 持续塞 chunk 直到在途未 ack 字节达到上限，然后等 ack 腾位。
  // 1 MB 在 LAN BDP 之上、又能保证背压可控，单 peer 单文件场景内存占用 ≈ 1 MB。
  static const _kInflightBytesLimit = 1 * 1024 * 1024;
  static const _kFileChunkSize = 64 * 1024;
  // 单条流多久没收到任何 chunk_ack 视为对端假死 / 写盘卡死，整体 fail。
  // LAN 场景下正常 ack 间隔 = receiver 单 chunk 处理时间（base64Decode + 写盘），
  // iOS/macOS 通常 < 1ms，Android MediaStore 串行链最差 ~50ms。2s 足以覆盖正常
  // 处理延迟，超过基本就是真假死（对端 crash / 网线拔了 / Wi-Fi 切换中）。
  static const _kAckIdleTimeout = Duration(seconds: 2);

  Iterable<String> get connectedPeerIds => _channels.keys;

  Transport({
    required this.myId,
    required this.onMessage,
    required this.onAck,
    required this.onFileOffer,
    required this.onFileAccept,
    required this.onFileDecline,
    required this.onFileChunk,
    required this.onFileEnd,
    this.onChannelEstablished,
    this.onChannelClosed,
  });

  String? _peerIdOf(WebSocketChannel ws) {
    for (final entry in _channels.entries) {
      if (entry.value == ws) return entry.key;
    }
    return null;
  }

  Future<int> startServer() async {
    final handler = webSocketHandler(
      (WebSocketChannel ws, _) {
        debugPrint('[transport] incoming connection');
        _attach(ws);
      },
    );
    // 监听 IPv6 + 兼容 IPv4（dual-stack），避免 mDNS 解析到 IPv6 时连不上
    _server = await shelf_io.serve(handler, InternetAddress.anyIPv6, 0);
    port = _server!.port;
    debugPrint('[transport] server listening on $port (dual-stack)');
    return port;
  }

  Future<void> connectTo(String host, int peerPort, String peerId,
      {bool force = false}) async {
    _knownPeers[peerId] = (host, peerPort);
    if (_channels.containsKey(peerId)) {
      debugPrint('[transport] already connected to $peerId, skip');
      return;
    }
    if (!force && myId.compareTo(peerId) > 0) {
      debugPrint('[transport] $peerId has lower id, waiting for them to connect');
      return;
    }
    final cleanHost = host.endsWith('.') ? host.substring(0, host.length - 1) : host;

    // 把 mDNS 主机名解析成 IPv4，避免 IPv6 / 系统代理导致连不上
    String dialHost = cleanHost;
    try {
      final addrs = await InternetAddress.lookup(cleanHost, type: InternetAddressType.IPv4);
      if (addrs.isNotEmpty) dialHost = addrs.first.address;
    } catch (e) {
      debugPrint('[transport] lookup failed for $cleanHost: $e (fallback to hostname)');
    }

    final url = 'ws://$dialHost:$peerPort';
    debugPrint('[transport] dialing $url (peer=$peerId, original host=$host)');
    runZonedGuarded(() {
      final ws = IOWebSocketChannel.connect(url);
      _attach(ws);
    }, (e, st) {
      debugPrint('[transport] dial error: $e');
    });
  }

  void _attach(WebSocketChannel ws) {
    String? peerId; // 只有这条连接被正式纳入 _channels 后才设置，避免 dedupe 关闭时误删
    ws.sink.add(jsonEncode({'type': 'hello', 'fromId': myId}));
    _keepAlive[ws] = Timer.periodic(_keepAliveInterval, (_) {
      try {
        final token = 'ka-${DateTime.now().microsecondsSinceEpoch}';
        ws.sink.add(jsonEncode({'type': 'ping', 'token': token}));
      } catch (e) {
        debugPrint('[transport] keepalive send failed peerId=$peerId: $e');
      }
    });
    ws.stream.listen(
      (data) {
        try {
          final m = jsonDecode(data as String) as Map<String, dynamic>;
          final type = m['type'];
          switch (type) {
            case 'hello':
              final id = m['fromId'] as String;
              debugPrint('[transport] hello from $id');
              if (_channels.containsKey(id)) {
                debugPrint('[transport] dedupe close (already have $id)');
                ws.sink.close();
                return;
              }
              peerId = id;
              _channels[id] = ws;
              debugPrint(
                  '[transport] channel established with $id, total=${_channels.length}');
              onChannelEstablished?.call(id);
            case 'msg':
              final inner = m['msg'] as Map<String, dynamic>;
              onMessage(ChatMessage.fromJson(inner));
              final mid = inner['id'] as String?;
              if (mid != null && mid.isNotEmpty) {
                ws.sink.add(jsonEncode({'type': 'ack', 'id': mid}));
              }
            case 'ack':
              final mid = m['id'] as String?;
              if (mid != null) onAck(mid);
            case 'ping':
              final token = m['token'] as String?;
              if (token != null) {
                try {
                  ws.sink.add(jsonEncode({'type': 'pong', 'token': token}));
                } catch (_) {}
              }
            case 'pong':
              final token = m['token'] as String?;
              if (token != null) {
                final c = _pendingProbes.remove(token);
                if (c != null && !c.isCompleted) {
                  c.complete(true);
                }
              }
            case 'file_offer':
              final inner = m['msg'] as Map<String, dynamic>;
              final mid = inner['id'] as String?;
              final from = peerId ?? _peerIdOf(ws);
              debugPrint(
                  '[transport] recv file_offer id=$mid name=${inner['fileName']} size=${inner['fileSize']} from=$from');
              if (from == null) break;
              try {
                onFileOffer(ChatMessage.fromJson(inner), from);
              } catch (e, st) {
                debugPrint(
                    '[transport] file_offer handler threw: $e\n$st');
              }
            case 'file_accept':
              final mid = m['id'] as String?;
              final from = peerId ?? _peerIdOf(ws);
              debugPrint('[transport] recv file_accept id=$mid from=$from');
              if (mid != null && from != null) onFileAccept(mid, from);
            case 'file_decline':
              final mid = m['id'] as String?;
              final from = peerId ?? _peerIdOf(ws);
              debugPrint('[transport] recv file_decline id=$mid from=$from');
              if (mid != null && from != null) onFileDecline(mid, from);
            case 'file_chunk':
              final mid = m['id'] as String?;
              final data = m['data'] as String?;
              final seq = m['seq'] as int?;
              if (mid != null && data != null && seq != null) {
                final from = peerId ?? _peerIdOf(ws);
                if (from == null) break;
                try {
                  onFileChunk(mid, seq, base64Decode(data), from);
                } catch (e, st) {
                  debugPrint(
                      '[transport] file_chunk handler threw: $e\n$st');
                }
              }
            case 'file_chunk_ack':
              final mid = m['id'] as String?;
              final seq = m['seq'] as int?;
              if (mid != null && seq != null) {
                final from = peerId ?? _peerIdOf(ws);
                if (from != null) _handleChunkAck(mid, from, seq);
              }
            case 'file_end':
              final mid = m['id'] as String?;
              debugPrint('[transport] recv file_end id=$mid');
              if (mid != null) {
                try {
                  onFileEnd(mid);
                } catch (e, st) {
                  debugPrint(
                      '[transport] file_end handler threw: $e\n$st');
                }
              }
            default:
              debugPrint('[transport] unknown message type: $type');
          }
        } catch (e, st) {
          debugPrint('[transport] data handler error: $e\n$st');
        }
      },
      onDone: () {
        debugPrint(
            '[transport] channel done peerId=$peerId code=${ws.closeCode} reason="${ws.closeReason}" '
            'codeMeaning=${_closeCodeMeaning(ws.closeCode)}');
        _keepAlive.remove(ws)?.cancel();
        if (peerId != null && _channels[peerId] == ws) {
          _channels.remove(peerId);
          _failFlowsOf(peerId!, StateError('channel closed'));
          onChannelClosed?.call(peerId!);
          _scheduleRedial(peerId!);
        }
      },
      onError: (e, st) {
        debugPrint(
            '[transport] channel error peerId=$peerId type=${e.runtimeType} detail=$e');
        if (e is WebSocketChannelException) {
          final inner = e.inner;
          if (inner != null) {
            debugPrint(
                '[transport] inner type=${inner.runtimeType} detail=$inner');
            if (inner is SocketException) {
              debugPrint(
                  '[transport] socket osError=${inner.osError} address=${inner.address?.address} port=${inner.port}');
            }
          }
        } else if (e is SocketException) {
          debugPrint(
              '[transport] socket osError=${e.osError} address=${e.address?.address} port=${e.port}');
        }
        _keepAlive.remove(ws)?.cancel();
        if (peerId != null && _channels[peerId] == ws) {
          _channels.remove(peerId);
          _failFlowsOf(peerId!, e);
          onChannelClosed?.call(peerId!);
          _scheduleRedial(peerId!);
        }
      },
    );
  }

  void send(ChatMessage msg) {
    final payload = jsonEncode({'type': 'msg', 'msg': msg.toJson()});
    if (msg.toId == null) {
      for (final ch in _channels.values) {
        ch.sink.add(payload);
      }
    } else {
      final ch = _channels[msg.toId];
      if (ch != null) {
        ch.sink.add(payload);
      } else {
        debugPrint('[transport] no channel for ${msg.toId}, drop');
      }
    }
  }

  void sendFileOffer(ChatMessage msg) {
    final payload = jsonEncode({'type': 'file_offer', 'msg': msg.toJson()});
    if (msg.toId == null) {
      debugPrint(
          '[transport] sendFileOffer id=${msg.id} broadcast peers=${_channels.length}');
      for (final ch in _channels.values) {
        ch.sink.add(payload);
      }
    } else {
      final ch = _channels[msg.toId];
      if (ch == null) {
        debugPrint(
            '[transport] sendFileOffer no channel for ${msg.toId}, drop');
        return;
      }
      debugPrint('[transport] sendFileOffer id=${msg.id} to=${msg.toId}');
      ch.sink.add(payload);
    }
  }

  void sendFileResponse(String toPeerId, String msgId, bool accept) {
    final ch = _channels[toPeerId];
    if (ch == null) {
      debugPrint(
          '[transport] sendFileResponse no channel for $toPeerId, drop');
      return;
    }
    final type = accept ? 'file_accept' : 'file_decline';
    debugPrint('[transport] sendFileResponse $type id=$msgId to=$toPeerId');
    try {
      ch.sink.add(jsonEncode({'type': type, 'id': msgId}));
    } catch (e) {
      debugPrint('[transport] sendFileResponse send failed: $e');
    }
  }

  /// 发送文件给单个 peer。窗口化 ack 协议：
  /// - sender 把 chunk 塞 sink 直到在途未 ack 字节达到 [_kInflightBytesLimit]，然后等 ack 腾位
  /// - receiver 每写完一个 chunk 回 file_chunk_ack(id, seq)，sender 端 [_handleChunkAck] 推进窗口
  /// - [_kAckIdleTimeout] 内没收到任何新 ack 视为对端假死，整体 fail（无须依赖 onAppResumed probe）
  ///
  /// fanout 群聊场景由 chat 层按 acceptor 独立调用本函数实现 — 每个 acceptor 一份独立流
  /// 一份独立 [_OutgoingFlow]。
  Future<void> sendFileBytes(
    String msgId,
    File file,
    String toPeerId, {
    required void Function(int ackedBytes) onProgress,
    required void Function() onComplete,
    required void Function(Object error) onError,
  }) async {
    final ch = _channels[toPeerId];
    if (ch == null) {
      onError(StateError('no channel for $toPeerId'));
      return;
    }
    final flowKey = _flowKey(msgId, toPeerId);
    if (_outgoingFlows.containsKey(flowKey)) {
      onError(StateError(
          'flow already running for msg=$msgId peer=$toPeerId'));
      return;
    }

    RandomAccessFile? raf;
    try {
      raf = await file.open();
    } catch (e, st) {
      debugPrint('[transport] sendFileBytes open failed: $e\n$st');
      onError(e);
      return;
    }

    final flow = _OutgoingFlow(
      msgId: msgId,
      peerId: toPeerId,
      onProgress: onProgress,
    );
    _outgoingFlows[flowKey] = flow;
    flow.watchdog =
        Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (flow.failed) return;
      if (flow.inflight.isEmpty) return;
      final idle = DateTime.now().difference(flow.lastAckAt);
      if (idle > _kAckIdleTimeout) {
        debugPrint(
            '[transport] sendFileBytes idle timeout id=$msgId peer=$toPeerId idle=${idle.inSeconds}s');
        _markFlowFailed(
            flow,
            TimeoutException(
                'no chunk ack for ${_kAckIdleTimeout.inSeconds}s'));
      }
    });

    debugPrint(
        '[transport] sendFileBytes id=$msgId peer=$toPeerId start');
    int seq = 0;
    try {
      while (true) {
        // 等待窗口腾位
        while (!flow.failed &&
            _inflightBytes(flow) >= _kInflightBytesLimit) {
          flow.slotWaiter ??= Completer<void>();
          await flow.slotWaiter!.future;
        }
        if (flow.failed) {
          throw flow.failReason ?? StateError('flow failed');
        }
        final buf = Uint8List(_kFileChunkSize);
        final read = await raf.readInto(buf);
        if (read == 0) break;
        final bytes = read < _kFileChunkSize
            ? Uint8List.sublistView(buf, 0, read)
            : buf;
        final encoded = base64Encode(bytes);
        final payload = jsonEncode({
          'type': 'file_chunk',
          'id': msgId,
          'seq': seq,
          'data': encoded,
        });
        ch.sink.add(payload);
        flow.inflight[seq] = read;
        seq += 1;
        await Future<void>.delayed(Duration.zero);
      }
      // 主循环读完后 drain：等所有在途 chunk 收到 ack 才发 file_end
      while (!flow.failed && flow.inflight.isNotEmpty) {
        flow.slotWaiter ??= Completer<void>();
        await flow.slotWaiter!.future;
      }
      if (flow.failed) {
        throw flow.failReason ?? StateError('flow failed');
      }
      ch.sink.add(jsonEncode({'type': 'file_end', 'id': msgId}));
      debugPrint(
          '[transport] sendFileBytes done id=$msgId acked=${flow.ackedBytes}');
      onComplete();
    } catch (e, st) {
      debugPrint('[transport] sendFileBytes failed id=$msgId: $e\n$st');
      onError(e);
    } finally {
      flow.watchdog?.cancel();
      _outgoingFlows.remove(flowKey);
      try {
        await raf.close();
      } catch (_) {}
    }
  }

  void sendChunkAck(String toPeerId, String msgId, int seq) {
    final ch = _channels[toPeerId];
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode({
        'type': 'file_chunk_ack',
        'id': msgId,
        'seq': seq,
      }));
    } catch (e) {
      debugPrint(
          '[transport] sendChunkAck failed peer=$toPeerId id=$msgId seq=$seq: $e');
    }
  }

  void _handleChunkAck(String msgId, String fromPeerId, int seq) {
    final flow = _outgoingFlows[_flowKey(msgId, fromPeerId)];
    if (flow == null || flow.failed) return;
    final bytes = flow.inflight.remove(seq);
    if (bytes == null) return;
    flow.ackedBytes += bytes;
    flow.lastAckAt = DateTime.now();
    flow.onProgress(flow.ackedBytes);
    final waiter = flow.slotWaiter;
    flow.slotWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  int _inflightBytes(_OutgoingFlow flow) {
    var sum = 0;
    for (final b in flow.inflight.values) {
      sum += b;
    }
    return sum;
  }

  void _failFlowsOf(String peerId, Object reason) {
    for (final flow in _outgoingFlows.values) {
      if (flow.peerId == peerId && !flow.failed) {
        _markFlowFailed(flow, reason);
      }
    }
  }

  void _markFlowFailed(_OutgoingFlow flow, Object reason) {
    flow.failed = true;
    flow.failReason = reason;
    flow.watchdog?.cancel();
    flow.watchdog = null;
    final waiter = flow.slotWaiter;
    flow.slotWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  int get peerCount => _channels.length;

  bool hasChannelTo(String? toId) {
    if (toId == null) return _channels.isNotEmpty;
    return _channels.containsKey(toId);
  }

  void closeAllChannels() {
    final ids = _channels.keys.toList();
    final list = _channels.values.toList();
    _channels.clear();
    for (final id in ids) {
      _failFlowsOf(id, StateError('all channels closed'));
    }
    for (final ch in list) {
      _keepAlive.remove(ch)?.cancel();
      try {
        ch.sink.close();
      } catch (_) {}
    }
  }

  void dropPeer(String peerId) {
    final ch = _channels.remove(peerId);
    if (ch != null) {
      _keepAlive.remove(ch)?.cancel();
      _failFlowsOf(peerId, StateError('peer dropped'));
      try {
        ch.sink.close();
      } catch (_) {}
    }
  }

  Future<bool> probePeer(
    String peerId, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    final ch = _channels[peerId];
    if (ch == null) return Future.value(false);
    final token = '${DateTime.now().microsecondsSinceEpoch}-$peerId';
    final completer = Completer<bool>();
    _pendingProbes[token] = completer;
    try {
      ch.sink.add(jsonEncode({'type': 'ping', 'token': token}));
    } catch (e) {
      _pendingProbes.remove(token);
      debugPrint('[transport] probe send failed for $peerId: $e');
      return Future.value(false);
    }
    Future.delayed(timeout, () {
      final c = _pendingProbes.remove(token);
      if (c != null && !c.isCompleted) c.complete(false);
    });
    return completer.future;
  }

  void redialAll() {
    for (final entry in _knownPeers.entries) {
      if (_channels.containsKey(entry.key)) continue;
      connectTo(entry.value.$1, entry.value.$2, entry.key, force: true);
    }
  }

  String _closeCodeMeaning(int? code) {
    switch (code) {
      case null:
        return 'no-close-frame (transport torn down)';
      case 1000:
        return 'normal';
      case 1001:
        return 'going-away';
      case 1002:
        return 'protocol-error (or surfaced from socket-tear-down)';
      case 1003:
        return 'unsupported-data';
      case 1005:
        return 'no-status';
      case 1006:
        return 'abnormal-closure (no close-frame received)';
      case 1007:
        return 'invalid-payload';
      case 1008:
        return 'policy-violation';
      case 1009:
        return 'message-too-big';
      case 1010:
        return 'mandatory-ext';
      case 1011:
        return 'internal-error';
      case 1015:
        return 'tls-handshake';
      default:
        return 'unknown';
    }
  }

  void _scheduleRedial(String peerId) {
    final endpoint = _knownPeers[peerId];
    if (endpoint == null) return;
    if (myId.compareTo(peerId) > 0) {
      debugPrint('[transport] not redialing $peerId (lower id, expecting them to dial)');
      return;
    }
    Future.delayed(const Duration(seconds: 2), () {
      if (_channels.containsKey(peerId)) return;
      debugPrint('[transport] redialing $peerId');
      connectTo(endpoint.$1, endpoint.$2, peerId);
    });
  }
}

class _OutgoingFlow {
  final String msgId;
  final String peerId;
  final void Function(int ackedBytes) onProgress;
  // 已塞 sink 但未收到 ack 的 chunk: seq → bytes
  final Map<int, int> inflight = {};
  int ackedBytes = 0;
  // sender 主循环窗口满 / drain 时挂在这个 Completer 上，每收到一个 ack 唤醒一次
  Completer<void>? slotWaiter;
  Timer? watchdog;
  DateTime lastAckAt = DateTime.now();
  bool failed = false;
  Object? failReason;

  _OutgoingFlow({
    required this.msgId,
    required this.peerId,
    required this.onProgress,
  });
}
