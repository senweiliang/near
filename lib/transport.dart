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
  final void Function(String msgId, Uint8List bytes) onFileChunk;
  final void Function(String msgId) onFileEnd;

  HttpServer? _server;
  int port = 0;
  final Map<String, WebSocketChannel> _channels = {};
  final Map<String, (String host, int port)> _knownPeers = {};
  final Map<String, Completer<bool>> _pendingProbes = {};
  final Map<WebSocketChannel, Timer> _keepAlive = {};
  static const _keepAliveInterval = Duration(seconds: 10);

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
        debugPrint('[transport] ka ping → $peerId token=$token');
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
                  debugPrint('[transport] ping ← $peerId token=$token (replied)');
                } catch (_) {}
              }
            case 'pong':
              final token = m['token'] as String?;
              if (token != null) {
                final c = _pendingProbes.remove(token);
                if (c != null && !c.isCompleted) {
                  c.complete(true);
                  debugPrint('[transport] probe pong ← $peerId token=$token');
                } else {
                  debugPrint('[transport] ka pong ← $peerId token=$token');
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
              if (mid != null && data != null) {
                try {
                  onFileChunk(mid, base64Decode(data));
                } catch (e, st) {
                  debugPrint(
                      '[transport] file_chunk handler threw: $e\n$st');
                }
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

  Future<void> sendFileBytes(
    String msgId,
    File file,
    List<String> toPeerIds, {
    void Function(int sent)? onProgress,
    void Function()? onComplete,
    void Function(Object error)? onError,
  }) async {
    final channels = <WebSocketChannel>[];
    for (final pid in toPeerIds) {
      final ch = _channels[pid];
      if (ch != null) channels.add(ch);
    }
    if (channels.isEmpty) {
      onError?.call(StateError('no channel for $toPeerIds'));
      return;
    }

    debugPrint(
        '[transport] sendFileBytes id=$msgId peers=${channels.length}');

    const chunkSize = 64 * 1024;
    RandomAccessFile? raf;
    try {
      raf = await file.open();
    } catch (e, st) {
      debugPrint('[transport] sendFileBytes open failed: $e\n$st');
      onError?.call(e);
      return;
    }
    int offset = 0;
    int seq = 0;
    try {
      while (true) {
        final buf = Uint8List(chunkSize);
        final read = await raf.readInto(buf);
        if (read == 0) break;
        final bytes =
            read < chunkSize ? Uint8List.sublistView(buf, 0, read) : buf;
        final encoded = base64Encode(bytes);
        final payload = jsonEncode({
          'type': 'file_chunk',
          'id': msgId,
          'seq': seq,
          'data': encoded,
        });
        for (final ch in channels) {
          ch.sink.add(payload);
        }
        offset += read;
        seq += 1;
        onProgress?.call(offset);
        await Future<void>.delayed(Duration.zero);
      }
      final endPayload = jsonEncode({'type': 'file_end', 'id': msgId});
      for (final ch in channels) {
        ch.sink.add(endPayload);
      }
      debugPrint('[transport] sendFileBytes done id=$msgId bytes=$offset');
      onComplete?.call();
    } catch (e, st) {
      debugPrint('[transport] sendFileBytes chunk loop failed: $e\n$st');
      onError?.call(e);
    } finally {
      try {
        await raf.close();
      } catch (_) {}
    }
  }

  int get peerCount => _channels.length;

  bool hasChannelTo(String? toId) {
    if (toId == null) return _channels.isNotEmpty;
    return _channels.containsKey(toId);
  }

  void closeAllChannels() {
    final list = _channels.values.toList();
    _channels.clear();
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
