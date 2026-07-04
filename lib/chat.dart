import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'discovery.dart';
import 'peer.dart';
import 'transport.dart';

class Chat extends ChangeNotifier {
  late final String myId;
  String myName = 'Me';

  final List<ChatMessage> messages = [];
  final Map<String, Peer> peers = {};
  final Map<String, Timer> _ackTimers = {};
  final Map<String, IOSink> _incomingSinks = {};
  final Map<String, String> _androidSessions = {};
  final Map<String, Future<void>> _androidChain = {};
  final Map<String, File> _outgoingFiles = {};
  // msgId → 发送方 peerId，用于 channel 关闭时清理对应方向的 incoming sink
  final Map<String, String> _incomingFrom = {};
  // bonsoir_android 的 lost 事件 attrs 不可靠（拿到的是本机自己的 attrs），
  // 需要按 mDNS service.name 反查真实 peerId。`_onPeerFound` 时维护映射。
  final Map<String, String> _svcNameToPeerId = {};

  bool autoAcceptFiles = true;
  bool autoSaveImages = false;
  bool stayConnectedInBackground = false;
  int _autoSaveSeq = 0;

  late final Transport _transport;
  late final Discovery _discovery;
  Directory? _fileCacheDir;

  static const String _kAutoAcceptFiles = 'autoAcceptFiles';
  static const String _kAutoSaveImages = 'autoSaveImages';
  static const String _kStayConnected = 'stayConnectedInBackground';
  static const Duration _ackTimeout = Duration(milliseconds: 500);
  static const MethodChannel _platform = MethodChannel('near/files');
  static const MethodChannel _bgPlatform = MethodChannel('near/background');

  Future<void> start(String displayName) async {
    final testId = Platform.environment['NEAR_TEST_ID'];
    final isTestMode = testId != null && testId.isNotEmpty;
    if (isTestMode) {
      myId = 'test-$testId-${DateTime.now().millisecondsSinceEpoch}';
      myName = testId;
      autoAcceptFiles = true;
      debugPrint('[chat] TEST MODE id=$myId name=$myName');
    } else {
      final prefs = await SharedPreferences.getInstance();
      final storedName = prefs.getString('myName');
      myName = storedName ?? displayName;
      if (storedName == null && myName.trim().isNotEmpty) {
        await prefs.setString('myName', myName);
      }
      var stored = prefs.getString('myId');
      if (stored == null) {
        stored = const Uuid().v4();
        await prefs.setString('myId', stored);
      }
      myId = stored;
      autoAcceptFiles = prefs.getBool(_kAutoAcceptFiles) ?? true;
      autoSaveImages = prefs.getBool(_kAutoSaveImages) ?? false;
      stayConnectedInBackground = prefs.getBool(_kStayConnected) ?? false;
    }
    final base = await getApplicationDocumentsDirectory();
    final cacheSuffix = isTestMode ? '_$testId' : '';
    _fileCacheDir = Directory('${base.path}/near_files$cacheSuffix');
    if (!await _fileCacheDir!.exists()) {
      await _fileCacheDir!.create(recursive: true);
    }
    _transport = Transport(
      myId: myId,
      onMessage: _onIncoming,
      onAck: _onAck,
      onFileOffer: _onFileOffer,
      onFileAccept: _onFileAccept,
      onFileDecline: _onFileDecline,
      onFileChunk: _onFileChunk,
      onFileEnd: _onFileEnd,
      onChannelEstablished: _onChannelEstablished,
      onChannelClosed: _onChannelClosed,
    );
    final port = await _transport.startServer();

    _discovery = Discovery(myId: myId, myName: myName, port: port);
    await _discovery.start(
      onPeerFound: _onPeerFound,
      onPeerLost: _onPeerLost,
    );
    if (stayConnectedInBackground) {
      await _ensureBackgroundService();
    }
  }

  Future<void> setStayConnectedInBackground(bool v) async {
    if (stayConnectedInBackground == v) return;
    stayConnectedInBackground = v;
    final isTestMode = (Platform.environment['NEAR_TEST_ID'] ?? '').isNotEmpty;
    if (!isTestMode) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kStayConnected, v);
    }
    if (v) {
      await _ensureBackgroundService();
    } else {
      await _stopBackgroundService();
    }
    notifyListeners();
  }

  Future<void> _ensureBackgroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _bgPlatform.invokeMethod<void>('start');
    } catch (e) {
      debugPrint('[chat] foreground service start failed: $e');
    }
  }

  Future<void> _stopBackgroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _bgPlatform.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('[chat] foreground service stop failed: $e');
    }
  }

  Future<void> setAutoAcceptFiles(bool v) async {
    if (autoAcceptFiles == v) return;
    autoAcceptFiles = v;
    final isTestMode = (Platform.environment['NEAR_TEST_ID'] ?? '').isNotEmpty;
    if (!isTestMode) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoAcceptFiles, v);
    }
    notifyListeners();
  }

  Future<void> setAutoSaveImages(bool v) async {
    if (autoSaveImages == v) return;
    autoSaveImages = v;
    final isTestMode = (Platform.environment['NEAR_TEST_ID'] ?? '').isNotEmpty;
    if (!isTestMode) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoSaveImages, v);
    }
    // 打开时在移动端预取相册权限，避免后续收图时突兀弹窗
    if (v && (Platform.isAndroid || Platform.isIOS)) {
      try {
        if (!await Gal.hasAccess()) await Gal.requestAccess();
      } catch (e) {
        debugPrint('[image] gal access request failed: $e');
      }
    }
    notifyListeners();
  }

  /// 静默把收到的图片落盘：移动端进相册，桌面端写 Downloads。
  /// 手动保存（fullscreen viewer 的 save 按钮）另有一套带 SnackBar 反馈的路径，
  /// 这里刻意不弹任何对话框 / 提示，是「自动」的应有之义。
  Future<void> _autoSaveImage(Uint8List bytes, String? mime) async {
    final stamp = '${DateTime.now().millisecondsSinceEpoch}-${_autoSaveSeq++}';
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // 没权限就静默跳过，不在收消息时突然弹权限框（开关打开时已预取过）
        if (!await Gal.hasAccess()) return;
        await Gal.putImageBytes(bytes, name: 'near-$stamp');
      } else {
        final dir = await getDownloadsDirectory();
        if (dir == null) return;
        final ext = mime == 'image/png' ? 'png' : 'jpg';
        await File('${dir.path}/near-$stamp.$ext').writeAsBytes(bytes);
      }
      debugPrint('[image] auto-saved near-$stamp');
    } catch (e) {
      debugPrint('[image] auto-save failed: $e');
    }
  }

  Future<void> updateMyName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == myName) return;
    myName = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('myName', trimmed);
    notifyListeners();
    // 重新广播 mDNS attributes，对端会触发 lost → found，刷新成新名字
    try {
      await _discovery.updateName(trimmed);
    } catch (e) {
      debugPrint('[chat] discovery rebroadcast failed: $e');
    }
  }

  Future<void> onAppResumed() async {
    final ids = _transport.connectedPeerIds.toList();
    debugPrint('[chat] onAppResumed probing ${ids.length} peer(s)');
    var changed = false;
    await Future.wait(ids.map((pid) async {
      final alive = await _transport.probePeer(pid);
      if (!alive) {
        debugPrint('[chat] probe dead, dropping $pid');
        _transport.dropPeer(pid);
        changed = true;
      } else {
        debugPrint('[chat] probe alive $pid');
      }
    }));
    _transport.redialAll();
    if (changed) notifyListeners();
  }

  void _onPeerFound(ResolvedBonsoirService svc) {
    final attrs = svc.attributes;
    final id = attrs['id'];
    if (id == null) return;
    final host = svc.host;
    if (host == null) return;
    _svcNameToPeerId[svc.name] = id;
    // 保留之前的 lastActiveAt（同一 peer 重新发现，保留聊天活跃记录用于 LRU 排序）
    final prev = peers[id];
    final peer = Peer(
      id: id,
      name: attrs['name'] ?? '?',
      host: host,
      port: svc.port,
      lastActiveAt: prev?.lastActiveAt,
    );
    peers[peer.id] = peer;
    _transport.connectTo(peer.host, peer.port, peer.id);
    notifyListeners();
  }

  void _bumpPeerActivity(String? peerId) {
    if (peerId == null) {
      // 群发：所有 connected peer 一起 bump
      final now = DateTime.now();
      for (final pid in _transport.connectedPeerIds) {
        final p = peers[pid];
        if (p != null) p.lastActiveAt = now;
      }
      return;
    }
    final p = peers[peerId];
    if (p != null) p.lastActiveAt = DateTime.now();
  }

  void _onPeerLost(BonsoirService svc) {
    // bonsoir_android 在 lost 事件里 attrs 是本机自己的（broadcast attrs），
    // 不能拿来当 peerId。先按 svc.name 反查 _onPeerFound 时记的真实 id。
    final id = _svcNameToPeerId[svc.name] ?? svc.attributes['id'];
    if (id == null) return;
    // Channel 还活着说明对端真的在线，mDNS 的 lost 事件可能是重广播抖动 —— 忽略
    if (_transport.hasChannelTo(id)) {
      debugPrint('[chat] mDNS lost $id ignored (channel still alive)');
      return;
    }
    // 不删除 peer，保留聊天记录入口；只标 offline，UI 把 presence 点变灰
    final p = peers[id];
    if (p != null && p.online) {
      debugPrint('[chat] mDNS lost $id (svc=${svc.name}) → mark offline');
      p.online = false;
      notifyListeners();
    }
  }

  void _onChannelEstablished(String peerId) {
    final p = peers[peerId];
    if (p != null && !p.online) {
      debugPrint('[chat] channel up $peerId → mark online');
      p.online = true;
      notifyListeners();
    }
  }

  void _onChannelClosed(String peerId) {
    // 清掉这个 peer 方向上还在进行中的接收任务 — channel 一断对端不会再发 chunk，
    // sink 留着只会泄漏；msg 标 failed 让 UI 给用户反馈。sender 那边的 _outgoingFlows
    // 已经由 transport 自己 fail 掉了。
    final affected = _incomingFrom.entries
        .where((e) => e.value == peerId)
        .map((e) => e.key)
        .toList();
    for (final msgId in affected) {
      _incomingFrom.remove(msgId);
      _androidSessions.remove(msgId);
      _androidChain.remove(msgId);
      final sink = _incomingSinks.remove(msgId);
      if (sink != null) {
        () async {
          try {
            await sink.flush();
          } catch (_) {}
          try {
            await sink.close();
          } catch (_) {}
        }();
      }
      final idx = messages.lastIndexWhere((m) => m.id == msgId);
      if (idx != -1) {
        final m = messages[idx];
        if (m.status == SendStatus.pending || m.awaitingAccept) {
          m.status = SendStatus.failed;
          m.awaitingAccept = false;
        }
      }
    }
    final p = peers[peerId];
    if (p != null && p.online) {
      debugPrint('[chat] channel down $peerId → mark offline');
      p.online = false;
    }
    if (affected.isNotEmpty || (p != null && !p.online)) notifyListeners();
  }

  void _onIncoming(ChatMessage msg) {
    _refreshPeerName(msg.fromId, msg.fromName);
    _bumpPeerActivity(msg.fromId);
    messages.add(msg);
    notifyListeners();
    if (msg.imageBase64 != null) {
      final bytes = base64Decode(msg.imageBase64!);
      _resolveAspect(msg, bytes);
      if (autoSaveImages) _autoSaveImage(bytes, msg.imageMime);
    }
  }

  void _refreshPeerName(String fromId, String fromName) {
    final p = peers[fromId];
    if (p == null) return;
    if (fromName.isNotEmpty && p.name != fromName) {
      peers[fromId] = Peer(
        id: p.id,
        name: fromName,
        host: p.host,
        port: p.port,
        online: true,
      );
    } else if (!p.online) {
      p.online = true;
    }
  }

  void _onFileOffer(ChatMessage msg, String fromPeerId) {
    _refreshPeerName(msg.fromId, msg.fromName);
    _bumpPeerActivity(msg.fromId);
    msg.status = SendStatus.pending;
    debugPrint(
        '[chat] incoming file_offer id=${msg.id} name=${msg.fileName} size=${msg.fileSize} autoAccept=$autoAcceptFiles');
    _incomingFrom[msg.id] = fromPeerId;
    if (autoAcceptFiles) {
      messages.add(msg);
      notifyListeners();
      _prepareIncomingSink(msg);
      _transport.sendFileResponse(fromPeerId, msg.id, true);
    } else {
      msg.awaitingAccept = true;
      messages.add(msg);
      notifyListeners();
    }
  }

  void _prepareIncomingSink(ChatMessage msg) {
    if (Platform.isAndroid) {
      _androidChain[msg.id] = _beginAndroidIncoming(msg);
    } else {
      _openIncomingPrivate(msg);
    }
  }

  void acceptOffer(String msgId) {
    final idx = messages.lastIndexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    final msg = messages[idx];
    if (!msg.awaitingAccept) return;
    msg.awaitingAccept = false;
    msg.status = SendStatus.pending;
    notifyListeners();
    _prepareIncomingSink(msg);
    _transport.sendFileResponse(msg.fromId, msg.id, true);
  }

  void declineOffer(String msgId) {
    final idx = messages.lastIndexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    final msg = messages[idx];
    if (!msg.awaitingAccept) return;
    msg.awaitingAccept = false;
    msg.status = SendStatus.failed;
    msg.declined = true;
    _incomingFrom.remove(msgId);
    notifyListeners();
    _transport.sendFileResponse(msg.fromId, msg.id, false);
  }

  void _onFileAccept(String msgId, String fromPeerId) {
    final file = _outgoingFiles[msgId];
    final idx = messages.lastIndexWhere((m) => m.id == msgId);
    if (file == null || idx == -1) {
      debugPrint('[chat] file_accept for unknown id=$msgId');
      return;
    }
    final msg = messages[idx];
    final entry = msg.fanout[fromPeerId];
    if (entry == null) {
      debugPrint('[chat] file_accept from $fromPeerId not in fanout for $msgId');
      return;
    }
    if (entry.state != FanoutState.offered) {
      debugPrint(
          '[chat] file_accept dup id=$msgId from=$fromPeerId state=${entry.state}');
      return;
    }
    entry.state = FanoutState.sending;
    msg.offerPending = false;
    notifyListeners();
    debugPrint('[chat] file_accept id=$msgId from=$fromPeerId, sending bytes');
    _transport.sendFileBytes(
      msgId,
      file,
      fromPeerId,
      onProgress: (acked) {
        entry.bytesTransferred = acked;
        msg.bytesTransferred = _maxFanoutBytes(msg);
        notifyListeners();
      },
      onComplete: () {
        entry.state = FanoutState.delivered;
        entry.bytesTransferred = msg.fileSize ?? entry.bytesTransferred;
        msg.bytesTransferred = _maxFanoutBytes(msg);
        _maybeFinalizeFanout(msg);
        notifyListeners();
      },
      onError: (e) {
        debugPrint('[chat] sendFileBytes error id=$msgId peer=$fromPeerId: $e');
        entry.state = FanoutState.failed;
        _maybeFinalizeFanout(msg);
        notifyListeners();
      },
    );
  }

  void _onFileDecline(String msgId, String fromPeerId) {
    final idx = messages.lastIndexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    final msg = messages[idx];
    final entry = msg.fanout[fromPeerId];
    if (entry == null) {
      debugPrint('[chat] file_decline $fromPeerId not in fanout for $msgId');
      return;
    }
    if (entry.state != FanoutState.offered) return;
    debugPrint('[chat] file_decline id=$msgId from=$fromPeerId');
    entry.state = FanoutState.declined;
    _maybeFinalizeFanout(msg);
    notifyListeners();
  }

  Future<void> _beginAndroidIncoming(ChatMessage msg) async {
    try {
      final res = await _platform.invokeMapMethod<String, dynamic>(
        'beginIncoming',
        {
          'displayName': msg.fileName,
          'mimeType': msg.fileMime,
        },
      );
      if (res == null) {
        throw StateError('beginIncoming returned null');
      }
      final sid = res['sessionId'] as String;
      final uri = res['uri'] as String;
      _androidSessions[msg.id] = sid;
      msg.cachePath = uri;
      notifyListeners();
      debugPrint(
          '[chat] beginIncoming ok id=${msg.id} session=$sid uri=$uri');
    } catch (e, st) {
      debugPrint(
          '[chat] beginIncoming failed, falling back to private path: $e\n$st');
      _openIncomingPrivate(msg);
    }
  }

  void _openIncomingPrivate(ChatMessage msg) {
    final dir = _fileCacheDir;
    if (dir == null) {
      debugPrint('[chat] incoming file: cache dir not ready');
      msg.status = SendStatus.failed;
      notifyListeners();
      return;
    }
    try {
      final safe = (msg.fileName ?? 'file').replaceAll(RegExp(r'[/\\]'), '_');
      final path = '${dir.path}/${msg.id}__$safe';
      msg.cachePath = path;
      final sink = File(path).openWrite();
      _incomingSinks[msg.id] = sink;
      notifyListeners();
      debugPrint('[chat] incoming private sink open path=$path');
    } catch (e, st) {
      debugPrint('[chat] incoming private open failed: $e\n$st');
      msg.status = SendStatus.failed;
      notifyListeners();
    }
  }

  void _onFileChunk(String msgId, int seq, Uint8List bytes, String fromPeerId) {
    if (Platform.isAndroid && _androidChain.containsKey(msgId)) {
      final prev = _androidChain[msgId]!;
      _androidChain[msgId] = prev.then((_) async {
        final sid = _androidSessions[msgId];
        if (sid == null) return;
        await _platform.invokeMethod<void>('appendChunk', {
          'sessionId': sid,
          'bytes': bytes,
        });
        // 写盘成功后才 ack — 让 sender 的窗口反映 receiver 的真实处理速度
        _transport.sendChunkAck(fromPeerId, msgId, seq);
        final idx = messages.lastIndexWhere((m) => m.id == msgId);
        if (idx != -1) {
          messages[idx].bytesTransferred += bytes.length;
          notifyListeners();
        }
      }).catchError((e, st) {
        debugPrint('[chat] appendChunk failed id=$msgId: $e\n$st');
        // 故意不 ack — sender 端 idle watchdog 会在 15s 后判 fail
      });
      return;
    }
    final sink = _incomingSinks[msgId];
    if (sink == null) return;
    sink.add(bytes);
    _transport.sendChunkAck(fromPeerId, msgId, seq);
    final idx = messages.lastIndexWhere((m) => m.id == msgId);
    if (idx != -1) {
      messages[idx].bytesTransferred += bytes.length;
      notifyListeners();
    }
  }

  Future<void> _onFileEnd(String msgId) async {
    if (Platform.isAndroid && _androidChain.containsKey(msgId)) {
      final prev = _androidChain.remove(msgId)!;
      try {
        await prev;
        final sid = _androidSessions.remove(msgId);
        if (sid != null) {
          final uri = await _platform
              .invokeMethod<String>('finishIncoming', {'sessionId': sid});
          final idx = messages.lastIndexWhere((m) => m.id == msgId);
          if (idx != -1) {
            final m = messages[idx];
            if (uri != null) m.cachePath = uri;
            if (m.fileSize != null) m.bytesTransferred = m.fileSize!;
            m.status = SendStatus.delivered;
            notifyListeners();
            debugPrint('[chat] finishIncoming ok id=$msgId uri=$uri');
          }
        }
      } catch (e, st) {
        debugPrint('[chat] finishIncoming failed id=$msgId: $e\n$st');
        final idx = messages.lastIndexWhere((m) => m.id == msgId);
        if (idx != -1) {
          messages[idx].status = SendStatus.failed;
          notifyListeners();
        }
      } finally {
        _incomingFrom.remove(msgId);
      }
      return;
    }
    final sink = _incomingSinks.remove(msgId);
    if (sink != null) {
      await sink.flush();
      await sink.close();
    }
    _incomingFrom.remove(msgId);
    final idx = messages.lastIndexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    final m = messages[idx];
    if (m.fileSize != null) m.bytesTransferred = m.fileSize!;
    m.status = SendStatus.delivered;
    notifyListeners();
  }

  void _resolveAspect(ChatMessage msg, Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    completer.future.then((img) {
      msg.imageAspect = img.width / img.height;
      img.dispose();
      notifyListeners();
    }).catchError((_) {});
  }

  ChatMessage send(String text,
      {String? toId, Uint8List? imageBytes, String? imageMime}) {
    final msg = ChatMessage(
      id: const Uuid().v4(),
      fromId: myId,
      fromName: myName,
      text: text,
      ts: DateTime.now(),
      toId: toId,
      imageBase64: imageBytes != null ? base64Encode(imageBytes) : null,
      imageMime: imageMime,
      status: SendStatus.pending,
    );
    messages.add(msg);
    _bumpPeerActivity(toId);
    notifyListeners();
    _dispatch(msg);
    return msg;
  }

  /// Add a message to local history first, then dispatch later via [completeImage].
  /// Used when the image needs async compression but the bubble should appear now.
  ChatMessage prepareImage({
    String? toId,
    required Uint8List previewBytes,
    String? imageMime,
  }) {
    final msg = ChatMessage(
      id: const Uuid().v4(),
      fromId: myId,
      fromName: myName,
      text: '',
      ts: DateTime.now(),
      toId: toId,
      imageBase64: base64Encode(previewBytes),
      imageMime: imageMime,
      status: SendStatus.pending,
    );
    messages.add(msg);
    _bumpPeerActivity(toId);
    notifyListeners();
    _resolveAspect(msg, previewBytes);
    return msg;
  }

  /// Replace the image bytes (e.g. with a compressed version) and dispatch.
  void completeImage(ChatMessage msg, Uint8List finalBytes, {String? imageMime}) {
    msg.imageBase64 = base64Encode(finalBytes);
    if (imageMime != null) msg.imageMime = imageMime;
    notifyListeners();
    _dispatch(msg);
  }

  ChatMessage sendFile({required File file, String? toId}) {
    debugPrint('[chat] sendFile entry path=${file.path} toId=$toId');
    FileStat stat;
    try {
      stat = file.statSync();
    } catch (e, st) {
      debugPrint('[chat] sendFile statSync threw: $e\n$st');
      rethrow;
    }
    debugPrint(
        '[chat] sendFile stat type=${stat.type} size=${stat.size} modified=${stat.modified}');
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : 'file';
    final mime = _guessMime(name);
    final msg = ChatMessage(
      id: const Uuid().v4(),
      fromId: myId,
      fromName: myName,
      text: '',
      ts: DateTime.now(),
      toId: toId,
      fileName: name,
      fileSize: stat.size,
      fileMime: mime,
      cachePath: file.path,
      bytesTransferred: 0,
      status: SendStatus.pending,
      offerPending: true,
    );
    final initialPeers = toId == null
        ? _transport.connectedPeerIds.toList()
        : (_transport.hasChannelTo(toId) ? [toId] : <String>[]);
    debugPrint(
        '[chat] sendFile id=${msg.id} initialPeers=$initialPeers peerCount=${_transport.peerCount}');
    if (initialPeers.isEmpty) {
      msg.offerPending = false;
      msg.status = SendStatus.failed;
      messages.add(msg);
      notifyListeners();
      return msg;
    }
    for (final pid in initialPeers) {
      msg.fanout[pid] = FanoutEntry();
    }
    messages.add(msg);
    _bumpPeerActivity(toId);
    notifyListeners();
    _outgoingFiles[msg.id] = file;
    _transport.sendFileOffer(msg);
    return msg;
  }

  int _maxFanoutBytes(ChatMessage msg) {
    int m = 0;
    for (final e in msg.fanout.values) {
      if (e.bytesTransferred > m) m = e.bytesTransferred;
    }
    return m;
  }

  void _maybeFinalizeFanout(ChatMessage msg) {
    final allDone = msg.fanout.values.every((e) =>
        e.state == FanoutState.delivered ||
        e.state == FanoutState.declined ||
        e.state == FanoutState.failed);
    if (!allDone) return;
    final anyDelivered = msg.fanout.values
        .any((e) => e.state == FanoutState.delivered);
    final allDeclined = msg.fanout.values
        .every((e) => e.state == FanoutState.declined);
    msg.offerPending = false;
    if (anyDelivered) {
      msg.status = SendStatus.delivered;
      msg.declined = false;
      msg.bytesTransferred = msg.fileSize ?? msg.bytesTransferred;
    } else if (allDeclined) {
      // 全部接收方主动拒绝 — 不算发送失败，只是流程到此结束
      msg.status = SendStatus.delivered;
      msg.declined = true;
    } else {
      // 没人收到且至少有传输失败 — 真正的发送失败
      msg.status = SendStatus.failed;
      msg.declined = false;
    }
    _outgoingFiles.remove(msg.id);
  }

  static String _guessMime(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return 'application/octet-stream';
    final ext = name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'mp3' => 'audio/mpeg',
      'm4a' => 'audio/mp4',
      'zip' => 'application/zip',
      'apk' => 'application/vnd.android.package-archive',
      'json' => 'application/json',
      'txt' || 'md' => 'text/plain',
      'doc' => 'application/msword',
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt' => 'application/vnd.ms-powerpoint',
      'pptx' =>
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      _ => 'application/octet-stream',
    };
  }

  void _dispatch(ChatMessage msg) {
    if (!_transport.hasChannelTo(msg.toId)) {
      msg.status = SendStatus.failed;
      notifyListeners();
      return;
    }
    _transport.send(msg);
    _ackTimers[msg.id] = Timer(_ackTimeout, () {
      _ackTimers.remove(msg.id);
      if (msg.status == SendStatus.pending) {
        msg.status = SendStatus.failed;
        notifyListeners();
      }
    });
  }

  void _onAck(String msgId) {
    final timer = _ackTimers.remove(msgId);
    timer?.cancel();
    final idx = messages.lastIndexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    final m = messages[idx];
    if (m.hasFile) return; // file delivery decided by sendFile lifecycle
    if (m.status != SendStatus.pending) return;
    m.status = SendStatus.delivered;
    notifyListeners();
  }
}
