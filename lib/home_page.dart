import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:url_launcher/url_launcher.dart';
import 'chat.dart';
import 'file_utils.dart';
import 'peer.dart';
import 'settings_page.dart';
import 'share_intake.dart';
import 'theme.dart';

part 'home/peer_list.dart';
part 'home/conversation.dart';
part 'home/message_bubble.dart';
part 'home/compose.dart';
part 'home/splash.dart';
part 'home/file_bubble.dart';
part 'home/share_sheet.dart';

class _FastCupertinoRoute<T> extends CupertinoPageRoute<T> {
  _FastCupertinoRoute({required super.builder});
  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 260);
}

Future<void> _openLink(LinkableElement link) async {
  final uri = Uri.tryParse(link.url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

const int _maxImageBytes = 10 * 1024 * 1024; // input cap, sent uncompressed
const int _maxFileBytes = 100 * 1024 * 1024;

final bool _isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// 文件直接发，文件夹先打成 zip 再发；拖放 / 粘贴 / 选择器 / 系统分享共用。返回成功发出的个数。
Future<int> _sendPathsTo(Chat chat, List<String> paths, String? toId,
    {required void Function(String note) onNote}) async {
  var dispatched = 0;
  for (final path in paths) {
    final name = path.split(RegExp(r'[/\\]')).lastWhere((s) => s.isNotEmpty, orElse: () => path);
    final type = FileSystemEntity.typeSync(path, followLinks: true);
    File file;
    if (type == FileSystemEntityType.directory) {
      onNote('Compressing $name…');
      try {
        file = await zipDirectory(path);
      } catch (e) {
        debugPrint('[file] zip $path failed: $e');
        onNote("can't compress $name");
        continue;
      }
    } else if (type == FileSystemEntityType.file) {
      file = File(path);
    } else {
      onNote("can't read $name");
      continue;
    }
    final size = await file.length();
    if (size > _maxFileBytes) {
      onNote('$name: too large (${(size / 1024 / 1024).toStringAsFixed(1)} MB), max 100 MB');
      continue;
    }
    chat.sendFile(file: file, toId: toId);
    dispatched++;
  }
  return dispatched;
}

bool _isPngBytes(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

String _shortHandle(String id) {
  final s = id.replaceAll('-', '');
  return '@${s.substring(s.length - 4)}';
}

String _initial(String s) =>
    s.trim().isEmpty ? '?' : s.trim().characters.first.toUpperCase();

String _fmtTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _fmtSeparator(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(t.year, t.month, t.day);
  final time = _fmtTime(t);
  final daysDiff = today.difference(that).inDays;
  if (daysDiff == 0) return 'Today $time';
  if (daysDiff == 1) return 'Yesterday $time';
  return '${t.month}/${t.day} $time';
}

enum AvKind { you, normal }

/// 给 peer 列表的 meta 行算「最近一条消息预览」。peer == null 表示 Everyone here。
/// 没有匹配消息时返回 null，调用方 fallback 到默认 meta（host/offline 等）。
String? _peerPreview(Chat chat, Peer? peer) {
  ChatMessage? recent;
  for (var i = chat.messages.length - 1; i >= 0; i--) {
    final m = chat.messages[i];
    if (peer == null) {
      if (m.toId == null) {
        recent = m;
        break;
      }
    } else {
      final isPrivate = (m.fromId == chat.myId && m.toId == peer.id) ||
          (m.fromId == peer.id && m.toId == chat.myId);
      if (isPrivate) {
        recent = m;
        break;
      }
    }
  }
  if (recent == null) return null;
  final mine = recent.fromId == chat.myId;
  String body;
  if (recent.hasFile) {
    body = '[${recent.fileName ?? 'File'}]';
  } else if (recent.hasImage) {
    body = '[Image]';
  } else {
    body = recent.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
  if (body.isEmpty) return null;
  if (peer == null && !mine) {
    return '${recent.fromName}: $body';
  }
  return body;
}

// ===================================================================
// Root
// ===================================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _chat = Chat();
  bool _started = false;
  bool _bootstrapping = true;
  bool _splashVisible = true;
  double _splashOpacity = 1.0;
  String? _error;

  late final AnimationController _heroCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  final GlobalKey _namePromptNearKey = GlobalKey();
  Rect? _nearTargetRect;

  // 未读：null 表示全员；其他为 peerId
  final Map<String?, int> _unread = {};
  int _lastProcessed = 0;
  bool _inConvo = false;
  String? _viewing;

  final _shareIntake = ShareIntake();
  StreamSubscription<List<String>>? _shareSub;

  @override
  void initState() {
    super.initState();
    _chat.addListener(_onChange);
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final minSplash = Future<void>.delayed(const Duration(seconds: 2));
    final testId = Platform.environment['NEAR_TEST_ID'];
    if (testId != null && testId.isNotEmpty) {
      await _join(testId);
    } else {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('myName');
      if (stored != null && stored.trim().isNotEmpty) {
        await _join(stored);
      }
    }
    await minSplash;
    if (!mounted) return;

    if (!_started) {
      // First-run: render NamePrompt below splash, measure Near. target,
      // then run hero animation while other elements fade in.
      setState(() => _bootstrapping = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final ctx = _namePromptNearKey.currentContext;
      if (ctx != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          _nearTargetRect = box.localToGlobal(Offset.zero) & box.size;
        }
      }
      setState(() {});
      await _heroCtrl.forward();
      if (!mounted) return;
      setState(() => _splashVisible = false);
    } else {
      setState(() {
        _bootstrapping = false;
        _splashOpacity = 0.0;
      });
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted) return;
      setState(() => _splashVisible = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareSub?.cancel();
    _chat.removeListener(_onChange);
    _heroCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[lifecycle] $state');
    _chat.appInForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed && _started) {
      _chat.onAppResumed();
    }
  }

  String? _convoKey(ChatMessage m) => m.toId == null ? null : m.fromId;

  void _onChange() {
    if (!mounted) return;
    for (var i = _lastProcessed; i < _chat.messages.length; i++) {
      final m = _chat.messages[i];
      if (m.fromId == _chat.myId) continue;
      final k = _convoKey(m);
      final viewing = _inConvo && k == _viewing;
      if (!viewing) _unread[k] = (_unread[k] ?? 0) + 1;
    }
    _lastProcessed = _chat.messages.length;
    setState(() {});
  }

  Future<void> _join(String name) async {
    try {
      await _chat.start(name);
      setState(() => _started = true);
      _shareSub = _shareIntake.stream.listen(_handleShared);
      final initial = await _shareIntake.init();
      if (initial.isNotEmpty) _handleShared(initial);
    } catch (e) {
      setState(() => _error = '启动失败：$e');
    }
  }

  Future<void> _open(String? recipientId) async {
    setState(() {
      _inConvo = true;
      _viewing = recipientId;
      _unread.remove(recipientId);
    });
    _chat.activeConversation = recipientId ?? Chat.everyoneKey;
    await Navigator.of(context).push(_FastCupertinoRoute(
      builder: (_) => _ConversationPage(
        chat: _chat,
        recipientId: recipientId,
      ),
    ));
    _chat.activeConversation = null;
    if (!mounted) return;
    setState(() {
      _inConvo = false;
      _viewing = null;
    });
  }


  Future<void> _handleShared(List<String> paths) async {
    while (mounted && _splashVisible) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted || paths.isEmpty) return;
    final target = await showModalBottomSheet<({String? peerId})>(
      context: context,
      backgroundColor: AppColors.bgApp,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (_) => _ShareTargetSheet(chat: _chat, count: paths.length),
    );
    if (target == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).popUntil((route) => route.isFirst);
    await _sendPathsTo(_chat, paths, target.peerId,
        onNote: (note) => messenger.showSnackBar(SnackBar(
              content: Text(note, style: AppFonts.body(size: 13, color: Colors.white)),
              behavior: SnackBarBehavior.floating,
            )));
    if (mounted) _open(target.peerId);
  }

  @override
  Widget build(BuildContext context) {
    final Widget base = _bootstrapping
        ? const SizedBox.shrink()
        : (!_started
            ? _NamePrompt(
                onSubmit: _join,
                error: _error,
                entryAnim: _heroCtrl,
                nearKey: _namePromptNearKey,
              )
            : _PeerListView(
                chat: _chat,
                unread: _unread,
                onTapEveryone: () => _open(null),
                onTapPeer: (p) => _open(p.id),
              ));
    return ColoredBox(
      color: AppColors.bgApp,
      child: Stack(
        children: [
          Positioned.fill(child: base),
          if (_splashVisible)
            Positioned.fill(
              child: IgnorePointer(
                child: _started
                    ? AnimatedOpacity(
                        opacity: _splashOpacity,
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeIn,
                        child: const _SplashView(),
                      )
                    : _SplashHero(
                        controller: _heroCtrl,
                        targetRect: _nearTargetRect,
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

