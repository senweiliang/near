import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'rtc_link.dart';
import 'signaling.dart';
import 'transport.dart';

/// 扫码配对过的设备。key 是对端 Ed25519 身份公钥（标准 base64），也是它在协调服务器上的地址。
class PairedDevice {
  final String id;
  final String key;
  String name;

  PairedDevice({required this.id, required this.key, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'key': key, 'name': name};

  factory PairedDevice.fromJson(Map<String, dynamic> j) =>
      PairedDevice(id: j['id'] as String, key: j['key'] as String, name: j['name'] as String);
}

/// 跨网络直连状态。lan 表示同一局域网已连上，不需要打洞。
enum DirectStatus { offline, connecting, connected, failed, lan }

/// 二维码内容：near://pair?id=…&n=…&k=…&t=…（k 为 base64url 公钥，t 为一次性 token）
class PairCandidate {
  final String id;
  final String name;
  final String key;
  final String token;

  const PairCandidate({required this.id, required this.name, required this.key, required this.token});

  String toUri() => Uri(scheme: 'near', host: 'pair', queryParameters: {
        'id': id,
        'n': name,
        'k': base64Url.encode(base64Decode(key)),
        't': token,
      }).toString();

  static PairCandidate? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'near' || uri.host != 'pair') return null;
    final q = uri.queryParameters;
    final id = q['id'], name = q['n'], key = q['k'], token = q['t'];
    if (id == null || name == null || key == null || token == null) return null;
    try {
      final raw = base64Url.decode(base64Url.normalize(key));
      if (raw.length != 32) return null;
      return PairCandidate(id: id, name: name, key: base64Encode(raw), token: token);
    } catch (_) {
      return null;
    }
  }
}

enum PairFailure { noServer, peerOffline, rejected, timeout }

class PairException implements Exception {
  final PairFailure reason;
  PairException(this.reason);
  @override
  String toString() => 'PairException: $reason';
}

class PairCode {
  final PairCandidate candidate;
  final DateTime expiresAt;
  PairCode(this.candidate, this.expiresAt);
}

/// 管理已配对设备、扫码配对，以及经协调服务器交换信令后的 WebRTC 打洞直连。
/// 打洞失败就是失败：不配 TURN，数据永不经服务器中转。
class Remote {
  final String myId;
  final String Function() myName;
  final SignalClient signal;
  final Future<void> Function(PeerLink link, bool outgoing) attachLink;
  final bool Function(String peerId) hasChannel;
  final bool Function(String peerId) hasLanChannel;
  final void Function(PairedDevice device) onPaired;
  final void Function(PairedDevice device) onUnpaired;
  final VoidCallback onChanged;
  final void Function(List<PairedDevice> devices) persist;

  final Map<String, PairedDevice> _paired = {};
  final Set<String> _onlineKeys = {};
  final Map<String, _Attempt> _attempts = {};
  final Set<String> _failedKeys = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, Completer<PairedDevice>> _pendingPairs = {};
  PairCode? _code;
  PairedDevice? codePairedWith;
  final Random _random = Random.secure();

  static const Duration _kAttemptTimeout = Duration(seconds: 20);
  static const Duration _kRetryDelay = Duration(seconds: 60);
  static const Duration _kCodeLifetime = Duration(minutes: 5);
  static const Duration _kPairTimeout = Duration(seconds: 10);
  Map<String, dynamic> get _rtcConfig => {
        'iceServers': [
          {'urls': signal.server.stunUrl},
        ],
        'sdpSemantics': 'unified-plan',
      };

  Remote({
    required this.myId,
    required this.myName,
    required this.signal,
    required this.attachLink,
    required this.hasChannel,
    required this.hasLanChannel,
    required this.onPaired,
    required this.onUnpaired,
    required this.onChanged,
    required this.persist,
    required List<PairedDevice> initial,
  }) {
    for (final d in initial) {
      _paired[d.key] = d;
    }
    signal.setWatch(_paired.keys);
  }

  String get myKey => signal.myKey;
  bool get serverReachable => signal.connected;
  List<PairedDevice> get devices => _paired.values.toList(growable: false);

  PairedDevice? deviceById(String peerId) {
    for (final d in _paired.values) {
      if (d.id == peerId) return d;
    }
    return null;
  }

  DirectStatus statusOf(String peerId) {
    final device = deviceById(peerId);
    if (device == null) return DirectStatus.offline;
    if (hasLanChannel(peerId)) return DirectStatus.lan;
    if (hasChannel(peerId)) return DirectStatus.connected;
    if (_attempts.containsKey(device.key)) return DirectStatus.connecting;
    if (!signal.connected || !_onlineKeys.contains(device.key)) return DirectStatus.offline;
    if (_failedKeys.contains(device.key)) return DirectStatus.failed;
    return DirectStatus.connecting;
  }

  // ───────────── signaling events ─────────────

  void onSignalStateChanged() {
    if (!signal.connected) {
      _onlineKeys.clear();
      for (final attempt in _attempts.values.toList()) {
        attempt.fail('signal lost');
      }
    }
    onChanged();
  }

  void onPresence(String key, bool online) {
    if (!_paired.containsKey(key)) return;
    debugPrint('[remote] presence ${_short(key)} online=$online');
    if (online) {
      _onlineKeys.add(key);
      _failedKeys.remove(key);
      _maybeConnect(key);
    } else {
      _onlineKeys.remove(key);
      _attempts[key]?.fail('peer went offline');
      _retryTimers.remove(key)?.cancel();
    }
    onChanged();
  }

  void onUndeliverable(String toKey) {
    _pendingPairs.remove(toKey)?.completeError(PairException(PairFailure.peerOffline));
  }

  void onRelay(String fromKey, Map<String, dynamic> data) {
    final kind = data['kind'];
    switch (kind) {
      case 'pair':
        _onPairRequest(fromKey, data);
        return;
      case 'pair_ok':
        _onPairOk(fromKey, data);
        return;
      case 'pair_reject':
        _pendingPairs.remove(fromKey)?.completeError(PairException(PairFailure.rejected));
        return;
    }
    // 以下消息只接受已配对设备发来的
    if (!_paired.containsKey(fromKey)) {
      debugPrint('[remote] drop $kind from unpaired ${_short(fromKey)}');
      return;
    }
    switch (kind) {
      case 'unpair':
        _removeDevice(fromKey, notifyPeer: false);
      case 'rtc_request':
        _maybeConnect(fromKey, force: true);
      case 'rtc_offer':
        _onOffer(fromKey, data);
      case 'rtc_answer':
        _attempts[fromKey]?.onAnswer(data);
      case 'rtc_ice':
        _attempts[fromKey]?.onRemoteCandidate(data);
      case 'rtc_bye':
        final attempt = _attempts[fromKey];
        if (attempt != null && attempt.sid == data['sid']) attempt.fail('peer gave up');
    }
  }

  // ───────────── pairing ─────────────

  /// 展示方：生成新的一次性二维码，旧码作废。
  PairCode showCode() {
    final token = base64Url.encode(List<int>.generate(16, (_) => _random.nextInt(256)));
    codePairedWith = null;
    _code = PairCode(
      PairCandidate(id: myId, name: myName(), key: myKey, token: token),
      DateTime.now().add(_kCodeLifetime),
    );
    return _code!;
  }

  void hideCode() {
    _code = null;
  }

  void _onPairRequest(String fromKey, Map<String, dynamic> data) {
    final code = _code;
    final valid = code != null &&
        DateTime.now().isBefore(code.expiresAt) &&
        data['token'] == code.candidate.token &&
        data['id'] is String &&
        data['name'] is String;
    if (!valid) {
      debugPrint('[remote] reject pair request from ${_short(fromKey)}');
      signal.relay(fromKey, {'kind': 'pair_reject'});
      return;
    }
    _code = null; // 一次性
    final device = PairedDevice(id: data['id'] as String, key: fromKey, name: data['name'] as String);
    signal.relay(fromKey, {'kind': 'pair_ok', 'id': myId, 'name': myName()});
    _addDevice(device);
    codePairedWith = device;
    onChanged();
  }

  void _onPairOk(String fromKey, Map<String, dynamic> data) {
    final completer = _pendingPairs.remove(fromKey);
    if (completer == null) return;
    final device = PairedDevice(id: data['id'] as String, key: fromKey, name: data['name'] as String);
    _addDevice(device);
    completer.complete(device);
  }

  /// 扫码方：把二维码里的 token 交给展示方校验，成功后双方都记下对方。
  Future<PairedDevice> pairWith(PairCandidate candidate) async {
    if (!signal.connected) throw PairException(PairFailure.noServer);
    final completer = Completer<PairedDevice>();
    _pendingPairs[candidate.key]?.completeError(PairException(PairFailure.timeout));
    _pendingPairs[candidate.key] = completer;
    signal.relay(candidate.key, {
      'kind': 'pair',
      'token': candidate.token,
      'id': myId,
      'name': myName(),
    });
    return completer.future.timeout(_kPairTimeout, onTimeout: () {
      _pendingPairs.remove(candidate.key);
      throw PairException(PairFailure.timeout);
    });
  }

  void unpair(String peerId) {
    final device = deviceById(peerId);
    if (device != null) _removeDevice(device.key, notifyPeer: true);
  }

  void _addDevice(PairedDevice device) {
    // 同一 id 换了 key（对方重装后重新配对）：旧记录作废
    _paired.removeWhere((k, d) => d.id == device.id && k != device.key);
    _paired[device.key] = device;
    _failedKeys.remove(device.key);
    persist(devices);
    signal.setWatch(_paired.keys);
    debugPrint('[remote] paired with ${device.name} ${_short(device.key)}');
    onPaired(device);
    onChanged();
  }

  void _removeDevice(String key, {required bool notifyPeer}) {
    final device = _paired.remove(key);
    if (device == null) return;
    if (notifyPeer) signal.relay(key, {'kind': 'unpair'});
    _onlineKeys.remove(key);
    _failedKeys.remove(key);
    _retryTimers.remove(key)?.cancel();
    _attempts[key]?.fail('unpaired');
    persist(devices);
    signal.setWatch(_paired.keys);
    debugPrint('[remote] unpaired ${device.name}');
    onUnpaired(device);
    onChanged();
  }

  // ───────────── connection lifecycle ─────────────

  /// 通道断开后 / app 回前台时调用，按需重新打洞。
  void onChannelClosed(String peerId) {
    final device = deviceById(peerId);
    if (device == null) return;
    Timer(const Duration(seconds: 2), () => _maybeConnect(device.key));
  }

  void onResumed() {
    signal.kick();
    for (final key in _paired.keys) {
      _failedKeys.remove(key);
      _maybeConnect(key);
    }
  }

  /// 只由公钥较小的一方发 offer；较大一方发 rtc_request 请对方发起，避免双方同时 offer。
  void _maybeConnect(String key, {bool force = false}) {
    final device = _paired[key];
    if (device == null || !signal.connected || !_onlineKeys.contains(key)) return;
    if (hasChannel(device.id) || _attempts.containsKey(key)) return;
    if (!force && _failedKeys.contains(key)) return;
    if (myKey.compareTo(key) < 0) {
      _startAttempt(device, offerer: true);
    } else {
      signal.relay(key, {'kind': 'rtc_request'});
    }
  }

  Future<void> _startAttempt(PairedDevice device, {required bool offerer, String? sid}) async {
    final attempt = _Attempt(
      remote: this,
      device: device,
      offerer: offerer,
      sid: sid ?? base64Url.encode(List<int>.generate(9, (_) => _random.nextInt(256))),
    );
    _attempts[device.key] = attempt;
    onChanged();
    debugPrint('[remote] attempt ${attempt.sid} with ${device.name} offerer=$offerer');
    try {
      await attempt.begin();
    } catch (e) {
      attempt.fail('setup error: $e');
    }
  }

  void _onOffer(String fromKey, Map<String, dynamic> data) {
    final existing = _attempts[fromKey];
    if (existing != null) {
      // 理论上只有较小公钥一方 offer；真撞上时较小一方坚持自己的
      if (existing.offerer && myKey.compareTo(fromKey) < 0) return;
      existing.fail('superseded by peer offer');
    }
    final device = _paired[fromKey]!;
    if (hasLanChannel(device.id)) return;
    _startAttempt(device, offerer: false, sid: data['sid'] as String).then((_) {
      _attempts[fromKey]?.onOffer(data);
    });
  }

  void _attemptEnded(_Attempt attempt, {required bool success, String? reason}) {
    if (_attempts[attempt.device.key] != attempt) return;
    _attempts.remove(attempt.device.key);
    final key = attempt.device.key;
    if (success) {
      _failedKeys.remove(key);
    } else {
      debugPrint('[remote] attempt ${attempt.sid} with ${attempt.device.name} failed: $reason');
      if (!hasChannel(attempt.device.id) && _onlineKeys.contains(key)) {
        _failedKeys.add(key);
        _retryTimers.remove(key)?.cancel();
        _retryTimers[key] = Timer(_kRetryDelay, () {
          _retryTimers.remove(key);
          _maybeConnect(key, force: true);
        });
      }
    }
    onChanged();
  }

  static String _short(String key) => key.length <= 8 ? key : key.substring(0, 8);
}

class _Attempt {
  final Remote remote;
  final PairedDevice device;
  final bool offerer;
  final String sid;
  RTCPeerConnection? _pc;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _queuedCandidates = [];
  Timer? _timeout;
  bool _done = false;

  _Attempt({required this.remote, required this.device, required this.offerer, required this.sid});

  void _relay(Map<String, dynamic> data) => remote.signal.relay(device.key, {...data, 'sid': sid});

  Future<void> begin() async {
    _timeout = Timer(Remote._kAttemptTimeout, () => fail('timeout'));
    final pc = await createPeerConnection(remote._rtcConfig);
    if (_done) {
      await pc.close();
      return;
    }
    _pc = pc;
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      _relay({
        'kind': 'rtc_ice',
        'c': candidate.candidate,
        'mid': candidate.sdpMid,
        'idx': candidate.sdpMLineIndex,
      });
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) fail('ice failed');
    };
    if (offerer) {
      final dc = await pc.createDataChannel('near', RTCDataChannelInit()..ordered = true);
      _watchChannel(pc, dc);
      final offer = await pc.createOffer({});
      await pc.setLocalDescription(offer);
      _relay({'kind': 'rtc_offer', 'sdp': offer.sdp});
    } else {
      pc.onDataChannel = (dc) => _watchChannel(pc, dc);
    }
  }

  void _watchChannel(RTCPeerConnection pc, RTCDataChannel dc) {
    void opened() {
      if (_done) return;
      _done = true;
      _timeout?.cancel();
      debugPrint('[remote] datachannel open with ${device.name}');
      final link = RtcLink(pc, dc);
      remote._attemptEnded(this, success: true);
      remote.attachLink(link, offerer);
    }

    if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
      opened();
      return;
    }
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) opened();
    };
  }

  Future<void> onOffer(Map<String, dynamic> data) async {
    final pc = _pc;
    if (pc == null || _done) return;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(data['sdp'] as String, 'offer'));
      await _flushCandidates();
      final answer = await pc.createAnswer({});
      await pc.setLocalDescription(answer);
      _relay({'kind': 'rtc_answer', 'sdp': answer.sdp});
    } catch (e) {
      fail('offer handling: $e');
    }
  }

  Future<void> onAnswer(Map<String, dynamic> data) async {
    final pc = _pc;
    if (pc == null || _done || data['sid'] != sid) return;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(data['sdp'] as String, 'answer'));
      await _flushCandidates();
    } catch (e) {
      fail('answer handling: $e');
    }
  }

  Future<void> onRemoteCandidate(Map<String, dynamic> data) async {
    if (data['sid'] != sid) return;
    final candidate =
        RTCIceCandidate(data['c'] as String?, data['mid'] as String?, data['idx'] as int?);
    if (!_remoteDescriptionSet) {
      _queuedCandidates.add(candidate);
      return;
    }
    try {
      await _pc?.addCandidate(candidate);
    } catch (e) {
      debugPrint('[remote] addCandidate failed: $e');
    }
  }

  Future<void> _flushCandidates() async {
    _remoteDescriptionSet = true;
    for (final c in _queuedCandidates) {
      try {
        await _pc?.addCandidate(c);
      } catch (e) {
        debugPrint('[remote] addCandidate failed: $e');
      }
    }
    _queuedCandidates.clear();
  }

  void fail(String reason) {
    if (_done) return;
    _done = true;
    _timeout?.cancel();
    _relay({'kind': 'rtc_bye'});
    final pc = _pc;
    if (pc != null) {
      () async {
        try {
          await pc.close();
          await pc.dispose();
        } catch (_) {}
      }();
    }
    remote._attemptEnded(this, success: false, reason: reason);
  }
}
