import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统分享菜单 / 「用 Near 打开」/ 拖到 Dock 图标进来的文件路径。
class ShareIntake {
  static const MethodChannel _channel = MethodChannel('near/share');
  final StreamController<List<String>> _controller = StreamController.broadcast();

  Stream<List<String>> get stream => _controller.stream;

  /// 返回冷启动时就带进来的文件；之后到达的走 [stream]。
  Future<List<String>> init() async {
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) return const [];
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') {
        _controller.add(List<String>.from(call.arguments as List));
      }
    });
    try {
      final initial = await _channel.invokeListMethod<String>('getInitial');
      return initial ?? const [];
    } catch (e) {
      debugPrint('[share] getInitial failed: $e');
      return const [];
    }
  }
}
