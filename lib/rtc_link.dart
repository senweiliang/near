import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'transport.dart';

/// WebRTC DataChannel 包成 [PeerLink]。
///
/// DataChannel 单条消息上限约 256 KB，而图片消息是十几 MB 的单帧，所以二进制帧
/// 统一切片：首字节 0 = 中间片，1 = 末片。文本只用于握手 hello，体积小不切。
class RtcLink implements PeerLink {
  final RTCPeerConnection pc;
  final RTCDataChannel dc;
  final _incoming = StreamController<dynamic>();
  final _pending = BytesBuilder(copy: false);
  Future<void> _sendChain = Future.value();
  bool _closed = false;
  String _closeReason = 'open';

  static const int _kFragmentSize = 60 * 1024;
  // 超过这个缓冲量就等一等，避免 libwebrtc 缓冲超 16 MB 时直接关通道
  static const int _kMaxBuffered = 2 * 1024 * 1024;
  static const int _kFragmentMore = 0;
  static const int _kFragmentLast = 1;

  RtcLink(this.pc, this.dc) {
    dc.onMessage = _onMessage;
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed) _finish('datachannel closed');
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _finish('peer connection $state');
      }
    };
  }

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  bool get isRemote => true;

  @override
  String get closeInfo => _closeReason;

  bool get closed => _closed;

  void _onMessage(RTCDataChannelMessage message) {
    if (_closed) return;
    if (!message.isBinary) {
      _incoming.add(message.text);
      return;
    }
    final data = message.binary;
    if (data.isEmpty) return;
    _pending.add(Uint8List.sublistView(data, 1));
    if (data[0] == _kFragmentLast) _incoming.add(_pending.takeBytes());
  }

  @override
  void add(Object data) {
    if (_closed) return;
    _sendChain = _sendChain.then((_) => _send(data)).catchError((Object e) {
      debugPrint('[rtc] send failed: $e');
      _finish('send failed: $e');
    });
  }

  Future<void> _send(Object data) async {
    if (_closed) return;
    if (data is String) {
      await dc.send(RTCDataChannelMessage(data));
      return;
    }
    final bytes = data as Uint8List;
    var offset = 0;
    do {
      final end = (offset + _kFragmentSize).clamp(0, bytes.length);
      final fragment = Uint8List(end - offset + 1)
        ..[0] = end == bytes.length ? _kFragmentLast : _kFragmentMore
        ..setRange(1, end - offset + 1, bytes, offset);
      while (!_closed && (await dc.getBufferedAmount()) > _kMaxBuffered) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (_closed) return;
      await dc.send(RTCDataChannelMessage.fromBinary(fragment));
      offset = end;
    } while (offset < bytes.length);
  }

  @override
  void close() => _finish('closed locally');

  void _finish(String reason) {
    if (_closed) return;
    _closed = true;
    _closeReason = reason;
    _incoming.close();
    () async {
      try {
        await dc.close();
      } catch (_) {}
      try {
        await pc.close();
        await pc.dispose();
      } catch (_) {}
    }();
  }
}
