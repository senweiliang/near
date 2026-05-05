import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:url_launcher/url_launcher.dart';
import 'chat.dart';
import 'peer.dart';
import 'settings_page.dart';
import 'theme.dart';

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

const int _maxImageBytes = 10 * 1024 * 1024; // input cap before compression
const int _maxLongSide = 1280;
const int _jpegQuality = 80;

Uint8List _compressImageSync(Uint8List input) {
  final decoded = img.decodeImage(input);
  if (decoded == null) return input;
  final w = decoded.width, h = decoded.height;
  img.Image resized = decoded;
  if (w > _maxLongSide || h > _maxLongSide) {
    if (w >= h) {
      resized = img.copyResize(decoded, width: _maxLongSide);
    } else {
      resized = img.copyResize(decoded, height: _maxLongSide);
    }
  }
  return Uint8List.fromList(img.encodeJpg(resized, quality: _jpegQuality));
}

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
    _chat.removeListener(_onChange);
    _heroCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[lifecycle] $state');
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
    await Navigator.of(context).push(_FastCupertinoRoute(
      builder: (_) => _ConversationPage(
        chat: _chat,
        recipientId: recipientId,
      ),
    ));
    if (!mounted) return;
    setState(() {
      _inConvo = false;
      _viewing = null;
    });
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

// ===================================================================
// Peer list (Screen 1)
// ===================================================================

class _PeerListView extends StatelessWidget {
  final Chat chat;
  final Map<String?, int> unread;
  final VoidCallback onTapEveryone;
  final void Function(Peer) onTapPeer;
  const _PeerListView({
    required this.chat,
    required this.unread,
    required this.onTapEveryone,
    required this.onTapPeer,
  });

  @override
  Widget build(BuildContext context) {
    // 排序规则（mergesort 稳定，平局保持 Map 插入顺序 = mDNS 发现顺序）：
    //   - 有 lastActiveAt 的 peer 在前，按时间倒序（最近聊过的最前 = LRU）
    //   - 无 lastActiveAt 的 peer 在后，保持发现顺序（新 found 加在最后）
    final peers = chat.peers.values.toList()
      ..sort((a, b) {
        final aT = a.lastActiveAt;
        final bT = b.lastActiveAt;
        if (aT != null && bT != null) return bT.compareTo(aT);
        if (aT != null) return -1;
        if (bT != null) return 1;
        return 0;
      });
    final onlinePeers = peers.where((p) => p.online).toList(growable: false);
    final onlineCount = onlinePeers.length + 1;
    final totalCount = peers.length + 1;
    final everyoneUnread = unread[null] ?? 0;

    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Hero header — own avatar + display name on the left, taps open Settings
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Navigator.of(context).push(_FastCupertinoRoute(
                    builder: (_) => SettingsPage(chat: chat),
                  ));
                },
                child: Row(
                  children: [
                    _CircleAv(
                      text: _initial(chat.myName),
                      kind: AvKind.you,
                      size: 42,
                      presence: false,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            chat.myName,
                            style: AppFonts.body(
                              size: 18,
                              weight: FontWeight.w700,
                              color: AppColors.ink,
                              letterSpacing: -0.3,
                              height: 1.15,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _shortHandle(chat.myId),
                            style: AppFonts.mono(
                              size: 11,
                              color: AppColors.ink3,
                              letterSpacing: 0.18,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Room meta card — body row + hairline divider + centered footer tagline
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: Row(
                        children: [
                          _PresenceStack(tiles: [
                            _MiniAv(text: _initial(chat.myName), you: true),
                            for (final p in onlinePeers.take(4))
                              _MiniAv(text: _initial(p.name)),
                            if (onlinePeers.length > 4)
                              _MiniAv(
                                text: '+${onlinePeers.length - 4}',
                                overflow: true,
                              ),
                          ]),
                          const SizedBox(width: 12),
                          Expanded(
                            child: onlinePeers.isEmpty
                                ? Text(
                                    'no one nearby yet',
                                    style: AppFonts.body(
                                      size: 13.5,
                                      weight: FontWeight.w600,
                                      color: AppColors.ink2,
                                      height: 1.2,
                                    ),
                                  )
                                : Text.rich(TextSpan(children: [
                                    TextSpan(
                                      text: '${onlinePeers.length} nearby',
                                      style: AppFonts.body(
                                        size: 13.5,
                                        weight: FontWeight.w700,
                                        color: AppColors.accent,
                                        height: 1.2,
                                      ),
                                    ),
                                    TextSpan(
                                      text: ' on this network',
                                      style: AppFonts.body(
                                        size: 13.5,
                                        weight: FontWeight.w600,
                                        color: AppColors.ink,
                                        height: 1.2,
                                      ),
                                    ),
                                  ])),
                          ),
                        ],
                      ),
                    ),
                    const Divider(
                        height: 1, thickness: 1, color: AppColors.line),
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(14, 8, 14, 10),
                      child: Center(
                        child: Text(
                          'link-local · peer-to-peer · no record',
                          style: AppFonts.mono(
                            size: 10.5,
                            color: AppColors.ink3,
                            letterSpacing: 0.08,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Section header
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'CONVERSATIONS',
                    style: AppFonts.mono(
                      size: 11,
                      color: AppColors.ink3,
                      letterSpacing: 0.66,
                    ),
                  ),
                  Text(
                    onlineCount == totalCount
                        ? '$onlineCount'
                        : '$onlineCount / $totalCount',
                    style: AppFonts.mono(
                      size: 11,
                      color: AppColors.ink2,
                      weight: FontWeight.w500,
                      letterSpacing: 0.66,
                    ),
                  ),
                ],
              ),
            ),

            // Peer list
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _PeerTile(
                    avatar: const _GroupAvatar(),
                    title: 'Everyone here',
                    meta: _peerPreview(chat, null) ??
                        '$onlineCount in the room · open to all',
                    unread: everyoneUnread,
                    onTap: onTapEveryone,
                  ),
                  for (final p in peers)
                    _PeerTile(
                      avatar: _CircleAv(
                          text: _initial(p.name),
                          kind: AvKind.normal,
                          online: p.online),
                      title: p.name,
                      handle: _shortHandle(p.id),
                      meta: _peerPreview(chat, p) ??
                          (p.online ? p.host : 'offline'),
                      unread: unread[p.id] ?? 0,
                      onTap: () => onTapPeer(p),
                    ),
                ],
              ),
            ),

          ],
        ),
      ),
    );
  }
}

// ===================================================================
// Avatars / mini chips
// ===================================================================

class _PresenceStack extends StatelessWidget {
  final List<Widget> tiles;
  const _PresenceStack({required this.tiles});

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox(width: 0, height: 22);
    const tile = 22.0;
    const overlap = 6.0;
    final width = tile + (tiles.length - 1) * (tile - overlap);
    return SizedBox(
      width: width,
      height: tile,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < tiles.length; i++)
            Positioned(
              left: i * (tile - overlap),
              top: 0,
              child: tiles[i],
            ),
        ],
      ),
    );
  }
}

class _MiniAv extends StatelessWidget {
  final String text;
  final bool you;
  final bool overflow;
  const _MiniAv({required this.text, this.you = false, this.overflow = false});

  @override
  Widget build(BuildContext context) {
    final bg = overflow
        ? AppColors.bgApp
        : (you ? AppColors.accent : AppColors.surface2);
    final fg = overflow
        ? AppColors.ink3
        : (you ? Colors.white : AppColors.ink2);
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(
          color: overflow ? AppColors.line : AppColors.bgApp,
          width: overflow ? 1 : 2,
        ),
      ),
      alignment: Alignment.center,
      child: overflow
          ? Text(
              text,
              style: AppFonts.mono(
                size: 9,
                color: fg,
                height: 1,
                letterSpacing: 0,
              ),
            )
          : Text(
              text,
              style: AppFonts.body(
                size: 9.5,
                weight: FontWeight.w600,
                color: fg,
                height: 1,
              ),
            ),
    );
  }
}

class _CircleAv extends StatelessWidget {
  final String text;
  final AvKind kind;
  final bool presence;
  final bool online;
  final double size;
  const _CircleAv({
    required this.text,
    required this.kind,
    this.presence = true,
    this.online = true,
    this.size = 42,
  });

  @override
  Widget build(BuildContext context) {
    final isYou = kind == AvKind.you;
    final bg = isYou ? AppColors.accent : AppColors.surface2;
    final fg = isYou ? Colors.white : AppColors.ink2;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(
              text,
              style: AppFonts.body(
                size: size * 0.38,
                weight: FontWeight.w700,
                color: fg,
                height: 1,
              ),
            ),
          ),
          if (presence)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: online ? AppColors.presence : AppColors.inkFaint,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.bgApp, width: 2.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupAvatar extends StatelessWidget {
  final double size;
  const _GroupAvatar({this.size = 42});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.accentSoft,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.group_outlined,
        size: size * 0.45,
        color: AppColors.accentDeep,
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  final Widget avatar;
  final String title;
  final String? handle;
  final String? meta;
  final int unread;
  final VoidCallback? onTap;
  const _PeerTile({
    required this.avatar,
    required this.title,
    this.handle,
    this.meta,
    this.unread = 0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              avatar,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: title,
                          style: AppFonts.body(
                            size: 15.5,
                            weight: FontWeight.w600,
                            letterSpacing: -0.15,
                            color: AppColors.ink,
                            height: 1.2,
                          ),
                        ),
                        if (handle != null)
                          TextSpan(
                            text: '  ${handle!}',
                            style: AppFonts.mono(
                              size: 12,
                              color: AppColors.ink3,
                              letterSpacing: 0.24,
                            ),
                          ),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (meta != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          meta!,
                          style: AppFonts.body(
                              size: 13,
                              color: AppColors.ink3,
                              height: 1.3),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              if (unread > 0) ...[
                const SizedBox(width: 8),
                Container(
                  constraints: const BoxConstraints(minWidth: 22),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    unread > 99 ? '99+' : '$unread',
                    style: AppFonts.body(
                      size: 12,
                      weight: FontWeight.w700,
                      color: Colors.white,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ===================================================================
// Conversation (Screen 2)
// ===================================================================

class _ConversationPage extends StatefulWidget {
  final Chat chat;
  final String? recipientId;
  const _ConversationPage({required this.chat, required this.recipientId});

  @override
  State<_ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<_ConversationPage> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();

  bool _initialSettled = false;
  double _lastBottomInset = 0;

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_onChange);
    // List is rendered with opacity 0 until the first jumpTo completes,
    // so the user never sees a "scroll-down-from-top" flash during the
    // route transition. With few messages the jumpTo is a no-op and the
    // list reveals in its natural top-anchored position.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _jumpToEnd();
      setState(() => _initialSettled = true);
    });
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChange);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset == _lastBottomInset) return;
    final delta = inset - _lastBottomInset;
    _lastBottomInset = inset;
    if (delta <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = (_scroll.position.pixels + delta)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(target);
    });
  }

  void _onChange() {
    if (!mounted) return;
    final stickyBottom = !_scroll.hasClients ||
        _scroll.position.pixels >=
            _scroll.position.maxScrollExtent - 60;
    setState(() {});
    if (stickyBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
    }
  }

  void _jumpToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _scrollToBottomAfterSend() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  bool _belongs(ChatMessage m) {
    if (widget.recipientId == null) return m.toId == null;
    final myId = widget.chat.myId;
    final r = widget.recipientId!;
    return (m.fromId == r && m.toId == myId) ||
        (m.fromId == myId && m.toId == r);
  }

  void _send() {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    widget.chat.send(t, toId: widget.recipientId);
    _input.clear();
    _scrollToBottomAfterSend();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  Future<void> _pickAndSendImage() async {
    debugPrint('[image] picker opening…');
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
    } catch (e, st) {
      debugPrint('[image] picker threw: $e\n$st');
      return;
    }
    if (result == null || result.files.isEmpty) {
      debugPrint('[image] picker cancelled / empty');
      return;
    }
    final file = result.files.single;
    var bytes = file.bytes;
    if (bytes == null && file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } catch (_) {}
    }
    if (bytes == null) return;
    if (bytes.length > _maxImageBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Image too large (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB), max 10 MB',
            style: AppFonts.body(size: 13, color: Colors.white),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final raw = bytes;
    final msg = widget.chat.prepareImage(
      toId: widget.recipientId,
      previewBytes: raw,
      imageMime: 'image/jpeg',
    );
    _scrollToBottomAfterSend();
    Uint8List compressed;
    try {
      compressed = await compute(_compressImageSync, raw);
    } catch (e) {
      debugPrint('[image] compress failed: $e, sending original');
      compressed = raw;
    }
    if (!mounted) return;
    widget.chat.completeImage(msg, compressed, imageMime: 'image/jpeg');
  }

  Future<void> _pickAndSendFile() async {
    debugPrint('[file] picker opening…');
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(type: FileType.any);
    } catch (e, st) {
      debugPrint('[file] picker threw: $e\n$st');
      return;
    }
    if (result == null || result.files.isEmpty) {
      debugPrint('[file] picker cancelled / empty');
      return;
    }
    final picked = result.files.single;
    debugPrint(
        '[file] picked name=${picked.name} path=${picked.path} size=${picked.size} identifier=${picked.identifier}');
    final path = picked.path;
    if (path == null) {
      debugPrint('[file] picked.path is null — aborting');
      return;
    }
    final f = File(path);
    bool exists;
    try {
      exists = await f.exists();
    } catch (e, st) {
      debugPrint('[file] f.exists() threw: $e\n$st');
      return;
    }
    debugPrint('[file] f.exists()=$exists for path=$path');
    if (!exists) return;
    FileStat stat;
    try {
      stat = await f.stat();
    } catch (e, st) {
      debugPrint('[file] f.stat() threw: $e\n$st');
      return;
    }
    debugPrint(
        '[file] stat type=${stat.type} size=${stat.size} mode=${stat.mode}');
    if (stat.size > 100 * 1024 * 1024) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'File too large (${(stat.size / 1024 / 1024).toStringAsFixed(1)} MB), max 100 MB',
            style: AppFonts.body(size: 13, color: Colors.white),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    debugPrint(
        '[file] dispatching to chat.sendFile recipientId=${widget.recipientId}');
    widget.chat.sendFile(file: f, toId: widget.recipientId);
    _scrollToBottomAfterSend();
  }

  /// Reads file URIs from the system clipboard and sends each as a file
  /// message. Returns true when the clipboard contained at least one file
  /// reference, so the caller skips the text-paste fallback (even if every
  /// reference turned out to be unsendable, like a directory).
  Future<bool> _tryPasteFiles() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;
    ClipboardReader reader;
    try {
      reader = await clipboard.read();
    } catch (e) {
      debugPrint('[paste] clipboard.read failed: $e');
      return false;
    }
    final paths = <String>[];
    for (final item in reader.items) {
      if (!item.canProvide(Formats.fileUri)) continue;
      try {
        final uri = await item.readValue(Formats.fileUri);
        if (uri == null || uri.scheme != 'file') continue;
        paths.add(uri.toFilePath());
      } catch (e) {
        debugPrint('[paste] readValue threw: $e');
      }
    }
    if (paths.isEmpty) return false;
    var dispatched = 0;
    for (final p in paths) {
      final type = FileSystemEntity.typeSync(p, followLinks: true);
      final name = _basename(p);
      if (type == FileSystemEntityType.directory) {
        _showPasteSnack("can't send a folder ($name)");
        continue;
      }
      if (type == FileSystemEntityType.notFound) {
        _showPasteSnack("can't read $name");
        continue;
      }
      final f = File(p);
      FileStat stat;
      try {
        stat = await f.stat();
      } catch (_) {
        _showPasteSnack("can't read $name");
        continue;
      }
      if (stat.size > 100 * 1024 * 1024) {
        _showPasteSnack(
            '$name: too large (${(stat.size / 1024 / 1024).toStringAsFixed(1)} MB), max 100 MB');
        continue;
      }
      widget.chat.sendFile(file: f, toId: widget.recipientId);
      dispatched++;
    }
    if (dispatched > 0) _scrollToBottomAfterSend();
    return true;
  }

  String _basename(String path) {
    final trimmed =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final i = trimmed.lastIndexOf('/');
    return i < 0 ? trimmed : trimmed.substring(i + 1);
  }

  void _showPasteSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: AppFonts.body(size: 13, color: Colors.white),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// super_clipboard 的 [DataReader.getFile] 是 callback 风格（不让 await 是为了
  /// 不阻塞拖放 handle），这里包装成 Future 让 paste 流程能顺序读多个 format。
  Future<Uint8List?> _readClipboardFile(
      ClipboardDataReader item, FileFormat format) {
    final completer = Completer<Uint8List?>();
    final progress = item.getFile(
      format,
      (file) async {
        try {
          final bytes = await file.readAll();
          if (!completer.isCompleted) completer.complete(bytes);
        } catch (e) {
          debugPrint('[paste] readAll threw: $e');
          if (!completer.isCompleted) completer.complete(null);
        }
      },
      onError: (e) {
        debugPrint('[paste] getFile error: $e');
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    if (progress == null && !completer.isCompleted) {
      completer.complete(null);
    }
    return completer.future;
  }

  /// 剪贴板里有图片字节（macOS 截图 ⌘+Shift+4 / Preview ⌘+C / 浏览器 Copy
  /// Image 都走这条），按 image 消息发送。返回 true 让 caller 跳过文本 fallback。
  /// 优先级在 file URI 之后、文本之前 — file URI 也能产生 image bytes（双 format
  /// 项），但用户复制文件时显然想发文件而不是图片。
  Future<bool> _tryPasteImage() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;
    ClipboardReader reader;
    try {
      reader = await clipboard.read();
    } catch (e) {
      debugPrint('[paste] clipboard.read failed: $e');
      return false;
    }
    for (final item in reader.items) {
      Uint8List? bytes;
      if (item.canProvide(Formats.png)) {
        bytes = await _readClipboardFile(item, Formats.png);
      }
      if (bytes == null && item.canProvide(Formats.jpeg)) {
        bytes = await _readClipboardFile(item, Formats.jpeg);
      }
      if (bytes == null) continue;
      if (bytes.length > _maxImageBytes) {
        _showPasteSnack(
            'Image too large (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB), max 10 MB');
        return true;
      }
      if (!mounted) return true;
      // 跟 _pickImage 同路径：先 prepareImage 立即建 bubble，后台 compress 再 completeImage
      final raw = bytes;
      final msg = widget.chat.prepareImage(
        toId: widget.recipientId,
        previewBytes: raw,
        imageMime: 'image/jpeg',
      );
      _scrollToBottomAfterSend();
      Uint8List compressed;
      try {
        compressed = await compute(_compressImageSync, raw);
      } catch (e) {
        debugPrint('[paste-image] compress failed: $e, sending original');
        compressed = raw;
      }
      if (!mounted) return true;
      widget.chat.completeImage(msg, compressed, imageMime: 'image/jpeg');
      return true;
    }
    return false;
  }

  Future<void> _handlePaste() async {
    if (await _tryPasteFiles()) return;
    if (await _tryPasteImage()) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    if (!mounted) return;
    final v = _input.value;
    final sel = v.selection;
    if (sel.isValid) {
      final newText = v.text.replaceRange(sel.start, sel.end, text);
      _input.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + text.length),
      );
    } else {
      final newText = v.text + text;
      _input.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final visible = chat.messages.where(_belongs).toList();
    final imageGallery =
        visible.where((m) => m.imageBase64 != null).toList(growable: false);
    final isEveryone = widget.recipientId == null;
    final peer = isEveryone ? null : chat.peers[widget.recipientId];
    final title = isEveryone ? 'Everyone here' : (peer?.name ?? 'Unknown');
    final sub = isEveryone
        ? '${chat.peers.length + 1} in the room · open to all'
        : (peer == null
            ? 'unknown peer'
            : (peer.online
                ? '${_shortHandle(peer.id)} · ${peer.host}'
                : '${_shortHandle(peer.id)} · offline'));

    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(4, 6, 16, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.line)),
              ),
              child: Row(
                children: [
                  IconButton(
                    splashRadius: 22,
                    icon: const Icon(Icons.chevron_left,
                        size: 26, color: AppColors.ink2),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  if (isEveryone)
                    const _GroupAvatar(size: 36)
                  else
                    _CircleAv(
                      text: _initial(title),
                      kind: AvKind.normal,
                      size: 36,
                      presence: peer != null,
                      online: peer?.online ?? false,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: AppFonts.body(
                            size: 16,
                            weight: FontWeight.w700,
                            letterSpacing: -0.16,
                            height: 1.1,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          sub,
                          style: AppFonts.mono(
                            size: 11,
                            color: AppColors.ink3,
                            letterSpacing: 0.22,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? _EmptyState(isEveryone: isEveryone, name: title)
                : SelectionArea(
                    child: Opacity(
                    opacity: _initialSettled ? 1.0 : 0.0,
                    child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    itemCount: visible.length,
                    itemBuilder: (_, i) {
                      final m = visible[i];
                      final ChatMessage? prev =
                          i >= 1 ? visible[i - 1] : null;
                      final showTimeSep = prev == null ||
                          m.ts.difference(prev.ts).inMinutes >= 5;
                      final hideAuthor = prev != null &&
                          !showTimeSep &&
                          prev.fromId == m.fromId;
                      final mine = m.fromId == chat.myId;
                      final isPrivate = m.toId != null;
                      final showPrivateTag = isPrivate && isEveryone;
                      final imgBytes = m.cachedImageBytes;
                      final galleryIndex = imgBytes != null
                          ? imageGallery.indexWhere((g) => g.id == m.id)
                          : -1;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (showTimeSep) _TimeSeparator(time: m.ts),
                          _MessageBubble(
                            text: m.text,
                            name: m.fromName,
                            handle: _shortHandle(m.fromId),
                            mine: mine,
                            chat: chat,
                            hideAuthor: hideAuthor,
                            imageBytes: imgBytes,
                            imageHeroTag:
                                imgBytes != null ? 'img-${m.id}' : null,
                            imageAspect: m.imageAspect,
                            imageGallery:
                                imgBytes != null ? imageGallery : null,
                            imageGalleryIndex: galleryIndex,
                            fileMessage: m.hasFile ? m : null,
                            onFileAccept: m.hasFile && m.awaitingAccept
                                ? () => widget.chat.acceptOffer(m.id)
                                : null,
                            onFileDecline: m.hasFile && m.awaitingAccept
                                ? () => widget.chat.declineOffer(m.id)
                                : null,
                            status: mine ? m.status : null,
                            showPrivateTag: showPrivateTag,
                            privateTo: showPrivateTag && mine
                                ? (chat.peers[m.toId!]?.name ?? 'someone')
                                : null,
                          ),
                        ],
                      );
                    },
                  ),
                  ),
                  ),
          ),
          _Compose(
            controller: _input,
            focusNode: _inputFocus,
            recipientLabel: isEveryone ? 'everyone here' : title,
            placeholder:
                isEveryone ? 'Message…' : 'Message $title…',
            onSend: _send,
            onPickImage: _pickAndSendImage,
            onPickFile: _pickAndSendFile,
            onPaste: _handlePaste,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool isEveryone;
  final String name;
  const _EmptyState({required this.isEveryone, required this.name});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          isEveryone ? 'no messages yet — say hi' : 'just you and $name',
          style: AppFonts.body(size: 14, color: AppColors.ink3),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _TimeSeparator extends StatelessWidget {
  final DateTime time;
  const _TimeSeparator({required this.time});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          _fmtSeparator(time),
          style: AppFonts.mono(
            size: 11,
            color: AppColors.ink3,
            letterSpacing: 0.44,
          ),
        ),
      ),
    );
  }
}

Future<void> _showMessageMenu(
  BuildContext context,
  Offset globalPosition,
  String text,
) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final selected = await showMenu<String>(
    context: context,
    color: AppColors.bgApp,
    surfaceTintColor: Colors.transparent,
    elevation: 6,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: AppColors.line, width: 1),
    ),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: [
      PopupMenuItem<String>(
        value: 'copy',
        height: 36,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.content_copy, size: 14, color: AppColors.ink2),
            const SizedBox(width: 10),
            Text(
              'Copy',
              style: AppFonts.body(size: 13, color: AppColors.ink),
            ),
          ],
        ),
      ),
    ],
  );
  if (selected == 'copy') {
    await Clipboard.setData(ClipboardData(text: text));
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Copied',
          style: AppFonts.body(size: 13, color: Colors.white),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }
}

Future<void> _showImageMenu(
  BuildContext context,
  Offset globalPosition,
  Uint8List bytes,
) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final selected = await showMenu<String>(
    context: context,
    color: AppColors.bgApp,
    surfaceTintColor: Colors.transparent,
    elevation: 6,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: AppColors.line, width: 1),
    ),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: [
      PopupMenuItem<String>(
        value: 'copy',
        height: 36,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.content_copy, size: 14, color: AppColors.ink2),
            const SizedBox(width: 10),
            Text(
              'Copy',
              style: AppFonts.body(size: 13, color: AppColors.ink),
            ),
          ],
        ),
      ),
    ],
  );
  if (selected != 'copy') return;
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return;
  final isPng = bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;
  final item = DataWriterItem();
  item.add(isPng ? Formats.png(bytes) : Formats.jpeg(bytes));
  try {
    await clipboard.write([item]);
  } catch (e) {
    debugPrint('[image-copy] write failed: $e');
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Copy failed',
          style: AppFonts.body(size: 13, color: Colors.white),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1200),
      ),
    );
    return;
  }
  messenger?.showSnackBar(
    SnackBar(
      content: Text(
        'Copied',
        style: AppFonts.body(size: 13, color: Colors.white),
      ),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(milliseconds: 1200),
    ),
  );
}

class _MessageBubble extends StatelessWidget {
  final String text;
  final String name;
  final String handle;
  final bool mine;
  final Chat chat;
  final bool hideAuthor;
  final Uint8List? imageBytes;
  final String? imageHeroTag;
  final double? imageAspect;
  final List<ChatMessage>? imageGallery;
  final int imageGalleryIndex;
  final ChatMessage? fileMessage;
  final VoidCallback? onFileAccept;
  final VoidCallback? onFileDecline;
  final SendStatus? status;
  final bool showPrivateTag;
  final String? privateTo;
  const _MessageBubble({
    required this.text,
    required this.name,
    required this.handle,
    required this.mine,
    required this.chat,
    this.hideAuthor = false,
    this.imageBytes,
    this.imageHeroTag,
    this.imageAspect,
    this.imageGallery,
    this.imageGalleryIndex = -1,
    this.fileMessage,
    this.onFileAccept,
    this.onFileDecline,
    this.status,
    this.showPrivateTag = false,
    this.privateTo,
  });

  @override
  Widget build(BuildContext context) {
    final radius = mine
        ? const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(4),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          );

    final priv = showPrivateTag;
    final hasText = text.trim().isNotEmpty;
    final hasImage = imageBytes != null;
    final hasFile = fileMessage != null;
    final imageOnly = hasImage && !hasText && !priv;
    final fileOnly = hasFile && !hasText && !hasImage && !priv;
    final bareBubble = imageOnly || fileOnly;
    final bubbleBg = priv
        ? AppColors.accentSoft
        : (mine ? AppColors.accent : AppColors.surface);
    final textColor =
        priv ? AppColors.ink : (mine ? Colors.white : AppColors.ink);
    final border = priv ? Border.all(color: AppColors.accent, width: 1) : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!mine && !hideAuthor)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 3),
              child: Text.rich(TextSpan(children: [
                TextSpan(
                  text: name,
                  style: AppFonts.body(
                    size: 12.5,
                    weight: FontWeight.w600,
                    color: AppColors.ink,
                    height: 1.2,
                  ),
                ),
                TextSpan(
                  text: '  $handle',
                  style: AppFonts.mono(
                    size: 10.5,
                    color: AppColors.ink3,
                    letterSpacing: 0.16,
                  ),
                ),
              ])),
            ),
          Row(
            mainAxisAlignment:
                mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (mine && status == SendStatus.failed) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 4),
                  child: Tooltip(
                    message: 'Send failed',
                    child: Icon(Icons.error_outline,
                        size: 16, color: const Color(0xFFE53935)),
                  ),
                ),
              ],
              Flexible(
                child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: bareBubble ? Colors.transparent : bubbleBg,
                borderRadius: radius,
                border: bareBubble ? null : border,
              ),
              child: Padding(
                padding: bareBubble
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (priv) ...[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_outline,
                              size: 11, color: AppColors.accent),
                          const SizedBox(width: 4),
                          Text(
                            mine
                                ? 'private to ${privateTo ?? "someone"}'
                                : 'private to you',
                            style: AppFonts.body(
                              size: 11,
                              weight: FontWeight.w600,
                              color: AppColors.accentDeep,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],
                    if (hasImage)
                      _BubbleImage(
                        bytes: imageBytes!,
                        radius: radius,
                        marginBottom: hasText ? 6 : 0,
                        heroTag: imageHeroTag,
                        aspect: imageAspect,
                        gallery: imageGallery,
                        galleryIndex: imageGalleryIndex,
                      ),
                    if (hasFile)
                      Padding(
                        padding: EdgeInsets.only(bottom: hasText ? 6 : 0),
                        child: _FileBubble(
                          msg: fileMessage!,
                          mine: mine,
                          chat: chat,
                          onAccept: onFileAccept,
                          onDecline: onFileDecline,
                        ),
                      ),
                    if (hasText)
                      Builder(builder: (context) {
                        final textStyle = AppFonts.body(
                          size: 15,
                          color: textColor,
                          height: 1.5,
                        );
                        final linkStyle = textStyle.copyWith(
                          decoration: TextDecoration.underline,
                          decorationColor: textColor,
                        );
                        final themed = Theme.of(context).copyWith(
                          textSelectionTheme: TextSelectionThemeData(
                            selectionColor: mine
                                ? Colors.white.withValues(alpha: 0.35)
                                : AppColors.accent.withValues(alpha: 0.28),
                          ),
                        );
                        if (Platform.isAndroid) {
                          return Theme(
                            data: themed,
                            child: SelectableLinkify(
                              text: text,
                              onOpen: _openLink,
                              options: const LinkifyOptions(humanize: false),
                              style: textStyle,
                              linkStyle: linkStyle,
                              contextMenuBuilder: (context, editableState) {
                                return AdaptiveTextSelectionToolbar
                                    .editableText(
                                  editableTextState: editableState,
                                );
                              },
                            ),
                          );
                        }
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onSecondaryTapUp: (d) => _showMessageMenu(
                              context, d.globalPosition, text),
                          onLongPressStart: (d) => _showMessageMenu(
                              context, d.globalPosition, text),
                          child: Theme(
                            data: themed,
                            child: Linkify(
                              text: text,
                              onOpen: _openLink,
                              options: const LinkifyOptions(humanize: false),
                              style: textStyle,
                              linkStyle: linkStyle,
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
          ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BubbleImage extends StatelessWidget {
  final Uint8List bytes;
  final BorderRadius radius;
  final double marginBottom;
  final String? heroTag;
  final double? aspect;
  final List<ChatMessage>? gallery;
  final int galleryIndex;
  const _BubbleImage({
    required this.bytes,
    required this.radius,
    this.marginBottom = 0,
    this.heroTag,
    this.aspect,
    this.gallery,
    this.galleryIndex = -1,
  });

  @override
  Widget build(BuildContext context) {
    const w = 240.0;
    final h = ((w / (aspect ?? 4 / 3)).clamp(120.0, 320.0));
    Widget image = ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: w,
        height: h,
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      ),
    );
    if (heroTag != null) {
      image = Hero(
        tag: heroTag!,
        flightShuttleBuilder: _flightShuttle,
        child: image,
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: marginBottom),
      child: GestureDetector(
        onTap: () => _openFullscreen(context),
        onSecondaryTapUp: (d) =>
            _showImageMenu(context, d.globalPosition, bytes),
        child: image,
      ),
    );
  }

  Widget _flightShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromContext,
    BuildContext toContext,
  ) {
    final curve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return AnimatedBuilder(
      animation: curve,
      builder: (_, _) {
        final t = curve.value;
        return ClipRRect(
          borderRadius: BorderRadius.lerp(
            radius,
            BorderRadius.zero,
            direction == HeroFlightDirection.push ? t : 1 - t,
          )!,
          child: Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }

  void _openFullscreen(BuildContext context) {
    FocusManager.instance.primaryFocus?.unfocus();
    final hasGallery = gallery != null && gallery!.isNotEmpty && galleryIndex >= 0;
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, animation, _) => _FullscreenImage(
        gallery: hasGallery
            ? gallery!
            : [
                ChatMessage(
                  id: heroTag ?? 'standalone',
                  fromId: '',
                  fromName: '',
                  text: '',
                  ts: DateTime.now(),
                  imageBase64: '',
                )..imageAspect = aspect,
              ],
        initialIndex: hasGallery ? galleryIndex : 0,
        initialBytes: bytes,
        initialAspect: aspect,
        initialHeroTag: heroTag,
        animation: animation,
      ),
    ));
  }
}

class _FullscreenImage extends StatefulWidget {
  final List<ChatMessage> gallery;
  final int initialIndex;
  final Uint8List initialBytes;
  final double? initialAspect;
  final String? initialHeroTag;
  final Animation<double> animation;
  const _FullscreenImage({
    required this.gallery,
    required this.initialIndex,
    required this.initialBytes,
    required this.initialAspect,
    required this.initialHeroTag,
    required this.animation,
  });

  @override
  State<_FullscreenImage> createState() => _FullscreenImageState();
}

class _FullscreenImageState extends State<_FullscreenImage> {
  late final PageController _ctrl;
  late int _index;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _ctrl = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _setZoomed(bool z) {
    if (_zoomed != z) setState(() => _zoomed = z);
  }

  Uint8List _bytesAt(int i) {
    if (i == widget.initialIndex) return widget.initialBytes;
    return widget.gallery[i].cachedImageBytes ?? widget.initialBytes;
  }

  Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    void notify(String msg) {
      messenger?.showSnackBar(SnackBar(
        content:
            Text(msg, style: AppFonts.body(size: 13, color: Colors.white)),
        behavior: SnackBarBehavior.floating,
      ));
    }

    final bytes = _bytesAt(_index);
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final access = await Gal.hasAccess();
        if (!access) {
          final granted = await Gal.requestAccess();
          if (!granted) {
            notify('Permission denied');
            return;
          }
        }
        await Gal.putImageBytes(bytes,
            name: 'near-${DateTime.now().millisecondsSinceEpoch}');
        notify('Saved to photos');
      } else if (Platform.isMacOS) {
        final dir = await getDownloadsDirectory();
        if (dir == null) {
          notify('Downloads folder unavailable');
          return;
        }
        final path =
            '${dir.path}/near-${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(path).writeAsBytes(bytes);
        notify('Saved to Downloads');
      } else {
        final path = await FilePicker.platform.saveFile(
          fileName: 'near-${DateTime.now().millisecondsSinceEpoch}.jpg',
          bytes: bytes,
        );
        if (path == null) return;
        if (!path.endsWith('.jpg') && !path.endsWith('.jpeg')) {
          await File(path).writeAsBytes(bytes);
        }
        notify('Saved');
      }
    } catch (e) {
      notify('Save failed');
    }
  }

  Widget _buildPage(int i) {
    final m = widget.gallery[i];
    final bytes = _bytesAt(i);
    final aspect = i == widget.initialIndex
        ? widget.initialAspect
        : m.imageAspect;
    Widget image = Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    Widget content = aspect != null
        ? AspectRatio(aspectRatio: aspect, child: image)
        : image;
    final heroTag = i == widget.initialIndex
        ? widget.initialHeroTag
        : 'img-${m.id}';
    if (heroTag != null) {
      content = Hero(tag: heroTag, child: content);
    }
    return _ZoomablePage(
      key: ValueKey('zoom-${m.id}'),
      onTap: () => Navigator.of(context).pop(),
      onZoomChanged: _setZoomed,
      onSecondaryTap: (pos) => _showImageMenu(context, pos, bytes),
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bgFade = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, 0.6, curve: Curves.easeOut),
      reverseCurve: const Interval(0.4, 1, curve: Curves.easeIn),
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: bgFade,
            builder: (_, _) => ColoredBox(
              color: Colors.black.withValues(alpha: bgFade.value * 0.92),
            ),
          ),
          PageView.builder(
            controller: _ctrl,
            itemCount: widget.gallery.length,
            physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
            onPageChanged: (i) => setState(() {
              _index = i;
              _zoomed = false;
            }),
            itemBuilder: (_, i) => _buildPage(i),
          ),
          Positioned(
            right: 16,
            bottom: 42, // 36px 按钮上移半个按钮高度（24 → 42），离 home indicator 远一点
            child: FadeTransition(
              opacity: bgFade,
              child: Material(
                color: const Color(0xFF8E8E93).withValues(alpha: 0.32),
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _save(context),
                  child: const SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(Icons.download_outlined,
                        color: Colors.white, size: 18),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomablePage extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;
  final void Function(Offset globalPosition)? onSecondaryTap;
  const _ZoomablePage({
    super.key,
    required this.child,
    required this.onTap,
    required this.onZoomChanged,
    this.onSecondaryTap,
  });

  @override
  State<_ZoomablePage> createState() => _ZoomablePageState();
}

class _ZoomablePageState extends State<_ZoomablePage> {
  final TransformationController _controller = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTransform);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTransform);
    _controller.dispose();
    super.dispose();
  }

  void _onTransform() {
    final scale = _controller.value.getMaxScaleOnAxis();
    final z = scale > 1.01;
    if (z != _zoomed) {
      setState(() => _zoomed = z);
      widget.onZoomChanged(z);
    }
  }

  void _handleDoubleTap() {
    if (_zoomed) {
      _controller.value = Matrix4.identity();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: _handleDoubleTap,
      onSecondaryTapUp: widget.onSecondaryTap == null
          ? null
          : (d) => widget.onSecondaryTap!(d.globalPosition),
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 1,
        maxScale: 5,
        panEnabled: _zoomed,
        clipBehavior: Clip.hardEdge,
        boundaryMargin: EdgeInsets.zero,
        child: Center(child: widget.child),
      ),
    );
  }
}

// ===================================================================
// Compose
// ===================================================================

class _PasteOverrideAction extends Action<PasteTextIntent> {
  _PasteOverrideAction(this.onPaste);
  final Future<void> Function() onPaste;

  @override
  Object? invoke(PasteTextIntent intent) {
    onPaste();
    return null;
  }
}

class _Compose extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String recipientLabel;
  final String placeholder;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final VoidCallback onPickFile;
  final Future<void> Function() onPaste;
  const _Compose({
    required this.controller,
    this.focusNode,
    required this.recipientLabel,
    required this.placeholder,
    required this.onSend,
    required this.onPickImage,
    required this.onPickFile,
    required this.onPaste,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgApp,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                child: Row(
                  children: [
                    Text(
                      'To ',
                      style:
                          AppFonts.body(size: 12, color: AppColors.ink3),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.accentSoft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        recipientLabel,
                        style: AppFonts.body(
                          size: 11.5,
                          weight: FontWeight.w600,
                          color: AppColors.accentDeep,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onPickImage,
                      customBorder: const CircleBorder(),
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: Icon(Icons.image_outlined,
                              color: AppColors.ink2, size: 22),
                        ),
                      ),
                    ),
                  ),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onPickFile,
                      customBorder: const CircleBorder(),
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: Icon(Icons.attach_file_rounded,
                              color: AppColors.ink2, size: 22),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          border: Border.all(color: AppColors.line),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Actions(
                          actions: <Type, Action<Intent>>{
                            PasteTextIntent: _PasteOverrideAction(onPaste),
                          },
                          child: TextField(
                            controller: controller,
                            focusNode: focusNode,
                            minLines: 1,
                            maxLines: 5,
                            style: AppFonts.body(
                                size: 15,
                                color: AppColors.ink,
                                height: 1.4),
                            decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: placeholder,
                              hintStyle: AppFonts.body(
                                  size: 15, color: AppColors.ink3),
                            ),
                            onSubmitted: (_) => onSend(),
                            textInputAction: TextInputAction.send,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: onSend,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.send,
                          color: Colors.white, size: 18),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===================================================================
// Splash
// ===================================================================

class _SplashView extends StatelessWidget {
  const _SplashView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: Center(child: _NearMark(fontSize: 44, letterSpacing: -1.2)),
    );
  }
}

class _NearMark extends StatelessWidget {
  final double fontSize;
  final double letterSpacing;
  const _NearMark({required this.fontSize, required this.letterSpacing, super.key});

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: 'Near',
          style: AppFonts.body(
            size: fontSize,
            weight: FontWeight.w700,
            letterSpacing: letterSpacing,
            height: 1,
          ),
        ),
        TextSpan(
          text: '.',
          style: AppFonts.body(
            size: fontSize,
            weight: FontWeight.w700,
            color: AppColors.accent,
            height: 1,
          ),
        ),
      ]),
      textAlign: TextAlign.center,
    );
  }
}

/// Splash overlay that morphs the centered "Near." mark into the
/// NamePrompt's top mark while fading the white background out.
class _SplashHero extends StatelessWidget {
  final AnimationController controller;
  final Rect? targetRect;
  const _SplashHero({required this.controller, required this.targetRect});

  static const double _initialFontSize = 44;
  static const double _initialLetterSpacing = -1.2;
  static const double _finalFontSize = 36;
  static const double _finalLetterSpacing = -1.0;

  @override
  Widget build(BuildContext context) {
    final tr = targetRect;
    if (tr == null) {
      // Target rect not measured yet — keep the static splash visible.
      return const _SplashView();
    }
    final positionAnim = CurvedAnimation(
      parent: controller,
      curve: Curves.easeInOutCubic,
    );
    final bgFadeAnim = CurvedAnimation(
      parent: controller,
      curve: const Interval(0.0, 0.7, curve: Curves.easeIn),
    );
    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation: controller,
        builder: (ctx, _) {
          final size = MediaQuery.of(ctx).size;
          final t = positionAnim.value;
          final initialCenterY = size.height / 2;
          final centerY = initialCenterY + (tr.center.dy - initialCenterY) * t;
          final fontSize = _initialFontSize +
              (_finalFontSize - _initialFontSize) * t;
          final letterSpacing = _initialLetterSpacing +
              (_finalLetterSpacing - _initialLetterSpacing) * t;
          return Stack(
            children: [
              Positioned.fill(
                child: Opacity(
                  opacity: 1.0 - bgFadeAnim.value,
                  child: const ColoredBox(color: AppColors.bgApp),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: centerY - fontSize / 2,
                child: Center(
                  child: _NearMark(
                    fontSize: fontSize,
                    letterSpacing: letterSpacing,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ===================================================================
// Name prompt
// ===================================================================

class _NamePrompt extends StatefulWidget {
  final void Function(String) onSubmit;
  final String? error;
  final Animation<double>? entryAnim;
  final Key? nearKey;
  const _NamePrompt({
    required this.onSubmit,
    this.error,
    this.entryAnim,
    this.nearKey,
  });

  @override
  State<_NamePrompt> createState() => _NamePromptState();
}

class _NamePromptState extends State<_NamePrompt> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    final entry = widget.entryAnim;
    if (entry == null) {
      // No hero animation in flight — focus immediately so the keyboard
      // can come up while the user is reading the prompt.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    } else {
      // Wait for the hero to finish before focusing. Otherwise the
      // soft keyboard pops up mid-animation, the layout reflows, and
      // the measured target rect goes stale → "Near." jumps at the end.
      void onStatus(AnimationStatus s) {
        if (s == AnimationStatus.completed) {
          entry.removeStatusListener(onStatus);
          if (mounted) _focus.requestFocus();
        }
      }
      entry.addStatusListener(onStatus);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _go() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    widget.onSubmit(v);
  }

  Widget _wrapEntry(Widget child) {
    final entry = widget.entryAnim;
    if (entry == null) return child;
    final fade = CurvedAnimation(
      parent: entry,
      curve: const Interval(0.35, 1.0, curve: Curves.easeIn),
    );
    final slide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: entry,
      curve: const Interval(0.35, 1.0, curve: Curves.easeOutCubic),
    ));
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(position: slide, child: child),
    );
  }

  Widget _buildNearMark() {
    final mark = _NearMark(
      key: widget.nearKey,
      fontSize: 36,
      letterSpacing: -1,
    );
    final entry = widget.entryAnim;
    if (entry == null) return mark;
    // Stay invisible while the splash hero is in flight; pop to full opacity
    // the moment the controller reaches 1.0 and the splash overlay is removed.
    return AnimatedBuilder(
      animation: entry,
      builder: (_, child) =>
          Opacity(opacity: entry.value >= 1.0 ? 1.0 : 0.0, child: child),
      child: mark,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildNearMark(),
                const SizedBox(height: 8),
                _wrapEntry(Text(
                  'a quiet room on this network',
                  style: AppFonts.mono(
                      size: 11,
                      color: AppColors.ink3,
                      letterSpacing: 0.66),
                  textAlign: TextAlign.center,
                )),
                const SizedBox(height: 32),
                _wrapEntry(Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    border: Border.all(color: AppColors.line),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    style: AppFonts.body(size: 15, color: AppColors.ink),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: 'pick a name',
                      hintStyle:
                          AppFonts.body(size: 15, color: AppColors.ink3),
                    ),
                    onSubmitted: (_) => _go(),
                  ),
                )),
                const SizedBox(height: 12),
                _wrapEntry(GestureDetector(
                  onTap: _go,
                  child: Container(
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      'enter',
                      style: AppFonts.body(
                        size: 15,
                        weight: FontWeight.w600,
                        color: Colors.white,
                        height: 1,
                      ),
                    ),
                  ),
                )),
                if (widget.error != null) ...[
                  const SizedBox(height: 16),
                  _wrapEntry(Text(
                    widget.error!,
                    style: AppFonts.body(
                        size: 12, color: const Color(0xFFE53935)),
                    textAlign: TextAlign.center,
                  )),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ===================================================================
// File bubble
// ===================================================================

String _fileExtLabel(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return 'FILE';
  final ext = name.substring(dot + 1).toUpperCase();
  return ext.length > 4 ? ext.substring(0, 4) : ext;
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

class _FileBubble extends StatefulWidget {
  final ChatMessage msg;
  final bool mine;
  final Chat chat;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  const _FileBubble({
    required this.msg,
    required this.mine,
    required this.chat,
    this.onAccept,
    this.onDecline,
  });

  @override
  State<_FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends State<_FileBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final msg = widget.msg;
    final mine = widget.mine;
    final onAccept = widget.onAccept;
    final onDecline = widget.onDecline;

    final size = msg.fileSize ?? 0;
    final transferred = msg.bytesTransferred;
    final ready = msg.fileReady;
    final awaitingAccept = !mine && msg.awaitingAccept;
    final offerPending = mine && msg.offerPending;
    final isDeclined = msg.declined;
    final fanoutSize = msg.fanout.length;
    final isGroup = mine && fanoutSize > 1;
    final deliveredCount = msg.fanout.values
        .where((e) => e.state == FanoutState.delivered)
        .length;
    // 群聊 fanout 全部进入终态（每个 entry 都是 delivered/declined/failed）— 用于
    // 隐藏副标脉冲点（活跃 vs 已结束）。bubble 颜色不再因终态 dim，K=0 终态也维持
    // 原色，由展开 detail 行说明每个 acceptor 的 declined/failed。
    final isFanoutTerminal = isGroup &&
        msg.fanout.values.every((e) =>
            e.state == FanoutState.delivered ||
            e.state == FanoutState.declined ||
            e.state == FanoutState.failed);
    final isFailed = mine && msg.status == SendStatus.failed && !isDeclined;
    final isPending = msg.status == SendStatus.pending;
    // 群聊不显示底部 progress bar（按 27-fanout.html 注释 01）— 由展开 detail 列表
    // 里的 per-peer mini bar 承担。私聊 / receiver 维持原行为。
    final showProgress = isPending &&
        !ready &&
        size > 0 &&
        !awaitingAccept &&
        !offerPending &&
        !isGroup;
    final progress =
        size > 0 ? (transferred / size).clamp(0.0, 1.0) : 0.0;

    final bg = mine ? AppColors.accent : AppColors.surface;
    final fg = mine ? Colors.white : AppColors.ink;
    final mutedFg = mine
        ? Colors.white.withValues(alpha: 0.72)
        : AppColors.ink3;
    final iconBg =
        mine ? Colors.white.withValues(alpha: 0.18) : Colors.white;
    final iconFg = mine ? Colors.white : AppColors.ink2;
    final extColor = mine ? AppColors.accentDeep : AppColors.accent;
    final extBg = mine ? Colors.white : AppColors.bgApp;

    Widget? actionButtons;
    if (awaitingAccept) {
      actionButtons = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _OfferActionButton(
            icon: Icons.close_rounded,
            filled: false,
            onTap: onDecline,
          ),
          const SizedBox(width: 6),
          _OfferActionButton(
            icon: Icons.check_rounded,
            filled: true,
            onTap: onAccept,
          ),
        ],
      );
    }

    final pathSet = msg.cachePath != null;
    final isContentUri =
        pathSet && msg.cachePath!.startsWith('content://');
    final exists = pathSet &&
        (isContentUri || File(msg.cachePath!).existsSync());
    final isMissing = ready && pathSet && !exists;

    String? statusLabel;
    if (mine) {
      if (isGroup) {
        // 折叠态群聊 sub-line 只看 K = deliveredCount，不报分母也不写整体
        // declined/failed 字样（终态降饱和由 isDimmed 表达，单个 acceptor 状态
        // 在展开 detail 行里分别显示）。两条规则：
        //   K == 0 → "offered to N"
        //   K > 0  → "delivered to K"   (含 K == fanoutSize 的 clean 终态)
        if (deliveredCount == 0) {
          statusLabel = 'offered to $fanoutSize';
        } else {
          statusLabel = 'delivered to $deliveredCount';
        }
      } else if (offerPending) {
        statusLabel = 'offered';
      } else if (isDeclined) {
        statusLabel = 'declined';
      } else if (msg.status == SendStatus.delivered) {
        statusLabel = isMissing ? 'missing' : 'delivered';
      } else if (isFailed) {
        statusLabel = 'failed';
      }
    } else {
      if (awaitingAccept) {
        statusLabel = 'offered';
      } else if (isDeclined) {
        statusLabel = 'declined';
      } else if (ready) {
        statusLabel = isMissing ? 'missing' : 'downloaded';
      }
    }

    final canOpen = ready && exists;

    Future<void> shareFile() async {
      if (msg.cachePath == null) return;
      try {
        await Share.shareXFiles(
          [
            XFile(
              msg.cachePath!,
              name: msg.fileName,
              mimeType: msg.fileMime,
            ),
          ],
        );
      } catch (e) {
        debugPrint('[file] share failed: $e');
      }
    }

    void notifyMissing(BuildContext ctx) {
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
        SnackBar(
          content: Text(
            mine
                ? 'Source file gone · pick again to resend'
                : 'File no longer on this device · ask sender to resend',
            style: AppFonts.body(size: 13, color: Colors.white),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    Future<void> handleTap() async {
      if (isMissing) {
        notifyMissing(context);
        return;
      }
      if (!canOpen) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (isContentUri) {
        try {
          await const MethodChannel('near/files').invokeMethod<bool>(
            'openContent',
            {
              'uri': msg.cachePath,
              'mimeType': msg.fileMime,
            },
          );
          return;
        } catch (e) {
          debugPrint('[file] openContent threw: $e');
          await shareFile();
          return;
        }
      }
      try {
        final result = await OpenFilex.open(
          msg.cachePath!,
          type: msg.fileMime,
        );
        debugPrint(
            '[file] open id=${msg.id} result=${result.type} message=${result.message}');
        if (result.type == ResultType.fileNotFound) {
          messenger?.showSnackBar(
            SnackBar(
              content: Text(
                mine
                    ? 'Source file gone · pick again to resend'
                    : 'File no longer on this device · ask sender to resend',
                style: AppFonts.body(size: 13, color: Colors.white),
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else if (result.type != ResultType.done) {
          await shareFile();
        }
      } catch (e) {
        debugPrint('[file] open threw: $e');
        await shareFile();
      }
    }

    Future<void> handleLongPress() async {
      if (isMissing) {
        notifyMissing(context);
        return;
      }
      if (!canOpen) return;
      await shareFile();
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: handleTap,
      onLongPress: handleLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              color: bg,
              border: mine ? null : Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(12, 12, isGroup ? 36 : 14, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: iconBg,
                          borderRadius: BorderRadius.circular(11),
                          border: mine
                              ? null
                              : Border.all(color: AppColors.line),
                        ),
                        child: Stack(
                          children: [
                            Center(
                              child: Icon(
                                Icons.insert_drive_file_outlined,
                                size: 22,
                                color: iconFg,
                              ),
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 4,
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: extBg,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    _fileExtLabel(msg.fileName ?? ''),
                                    style: AppFonts.mono(
                                      size: 8.5,
                                      weight: FontWeight.w700,
                                      color: extColor,
                                      letterSpacing: 0.04,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              msg.fileName ?? 'file',
                              style: AppFonts.body(
                                size: 14,
                                weight: FontWeight.w600,
                                color: fg,
                                height: 1.25,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                if ((isGroup
                                        ? (!isFanoutTerminal &&
                                            deliveredCount == 0)
                                        : (offerPending || awaitingAccept))) ...[
                                  _PulseDot(
                                    color: mine ? Colors.white : AppColors.accent,
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Flexible(
                                  child: Text(
                                    statusLabel == null
                                        ? _formatFileSize(size)
                                        : '${_formatFileSize(size)} · $statusLabel',
                                    style: AppFonts.mono(
                                      size: 11,
                                      color: mutedFg,
                                      letterSpacing: 0.04,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (actionButtons != null) ...[
                        const SizedBox(width: 10),
                        actionButtons,
                      ],
                    ],
                  ),
                ),
                if (showProgress)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SizedBox(
                      height: 2,
                      child: Stack(
                        children: [
                          Container(
                            color: mine
                                ? Colors.white.withValues(alpha: 0.18)
                                : Colors.black.withValues(alpha: 0.05),
                          ),
                          FractionallySizedBox(
                            widthFactor: progress,
                            child: Container(
                              color:
                                  mine ? Colors.white : AppColors.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (isGroup)
                  Positioned(
                    right: -3,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _ChevExpandButton(
                        expanded: _expanded,
                        color: mine
                            ? Colors.white.withValues(alpha: 0.65)
                            : AppColors.inkFaint,
                        onTap: () =>
                            setState(() => _expanded = !_expanded),
                      ),
                    ),
                  ),
              ],
            ),
                if (isGroup)
                  AnimatedSize(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: _expanded
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  height: 1,
                                  margin: const EdgeInsets.fromLTRB(
                                      4, 0, 4, 4),
                                  color: mine
                                      ? Colors.white
                                          .withValues(alpha: 0.16)
                                      : AppColors.line,
                                ),
                                for (final entry
                                    in widget.msg.fanout.entries)
                                  _PeerFanoutRow(
                                    peerId: entry.key,
                                    entry: entry.value,
                                    fileSize: size,
                                    mine: mine,
                                    chat: widget.chat,
                                  ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 右中绝对定位的展开按钮（仅 fanout > 1 的 sender 文件 bubble 显示）。
/// 22×22 hit area，跟 incoming bubble 的 save 按钮共用同一个视觉 slot。
/// 展开态 chev 旋转 180°，translateY(-50%) 由父 Center 自动处理（widget 自身居中）。
class _ChevExpandButton extends StatelessWidget {
  final bool expanded;
  final Color color;
  final VoidCallback onTap;
  const _ChevExpandButton({
    required this.expanded,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          onTap: onTap,
          radius: 18,
          containedInkWell: true,
          highlightShape: BoxShape.circle,
          customBorder: const CircleBorder(),
          child: Center(
            child: AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// fanout 详情面板里的单行：状态 dot + 名字/handle + 右侧 per-peer 状态。
/// 颜色规则按 27-fanout.html 注释 06：sending=accent（不脉冲）、其余统一 inkFaint，
/// 只有 failed 用红 — 文字 word 承担语义。
class _PeerFanoutRow extends StatelessWidget {
  final String peerId;
  final FanoutEntry entry;
  final int fileSize;
  final bool mine;
  final Chat chat;
  const _PeerFanoutRow({
    required this.peerId,
    required this.entry,
    required this.fileSize,
    required this.mine,
    required this.chat,
  });

  @override
  Widget build(BuildContext context) {
    final peer = chat.peers[peerId];
    final name = peer?.name ?? _shortHandle(peerId);
    final mutedFg = mine
        ? Colors.white.withValues(alpha: 0.62)
        : AppColors.ink3;
    final faintFg = mine
        ? Colors.white.withValues(alpha: 0.4)
        : AppColors.inkFaint;
    // 进度条用墨灰不用 accent —— 状态颜色一律去掉，文字 word 承担语义
    final barFg = mine
        ? Colors.white.withValues(alpha: 0.55)
        : AppColors.ink3;
    final barTrack = mine
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.06);

    // Dot 规则（最简版）：
    //   delivered → 实心圆
    //   其他所有状态 (offered / sending / declined / failed) → 空心圆
    // 颜色统一 inkFaint，状态语义靠右侧文字 word + sending 时的 mini bar 表达
    Widget dot;
    Widget rightSlot;
    switch (entry.state) {
      case FanoutState.offered:
        dot = _StateDot(color: faintFg, hollow: true);
        rightSlot = Text('offered',
            style: AppFonts.mono(size: 11, color: mutedFg));
      case FanoutState.sending:
        dot = _StateDot(color: faintFg, hollow: true);
        final pct = fileSize > 0
            ? (entry.bytesTransferred / fileSize).clamp(0.0, 1.0)
            : 0.0;
        rightSlot = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 64,
              height: 3,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: barTrack,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: pct,
                    child: Container(
                      decoration: BoxDecoration(
                        color: barFg,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 32,
              child: Text(
                '${(pct * 100).toStringAsFixed(0)}%',
                textAlign: TextAlign.right,
                style: AppFonts.mono(size: 10.5, color: mutedFg),
              ),
            ),
          ],
        );
      case FanoutState.delivered:
        // 实心 dot 用纯白（mine 永远 true — fanout 只在 sender 端），比
        // faintFg 的 40% 白更亮，跟空心圈形成"完成 vs 未完成"对比
        dot = _StateDot(color: mine ? Colors.white : AppColors.ink);
        rightSlot = Text('delivered',
            style: AppFonts.mono(size: 11, color: mutedFg));
      case FanoutState.declined:
        dot = _StateDot(color: faintFg, hollow: true);
        rightSlot = Text('declined',
            style: AppFonts.mono(size: 11, color: mutedFg));
      case FanoutState.failed:
        dot = _StateDot(color: faintFg, hollow: true);
        rightSlot = Text('failed',
            style: AppFonts.mono(size: 11, color: mutedFg));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 14, child: Center(child: dot)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: AppFonts.body(
                    size: 13,
                    weight: FontWeight.w600,
                    color: mine ? Colors.white : AppColors.ink,
                    letterSpacing: -0.005,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _shortHandle(peerId),
                  style: AppFonts.mono(
                    size: 10,
                    color: mutedFg,
                    letterSpacing: 0.04,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          rightSlot,
        ],
      ),
    );
  }
}

class _StateDot extends StatelessWidget {
  final Color color;
  final bool hollow;
  const _StateDot({required this.color, this.hollow = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: hollow ? Colors.transparent : color,
        shape: BoxShape.circle,
        border: hollow ? Border.all(color: color, width: 1.5) : null,
      ),
    );
  }
}

class _OfferActionButton extends StatelessWidget {
  final IconData icon;
  final bool filled;
  final VoidCallback? onTap;
  const _OfferActionButton({
    required this.icon,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: filled ? AppColors.accent : AppColors.bgApp,
            shape: BoxShape.circle,
            border: filled
                ? null
                : Border.all(color: AppColors.line, width: 1),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 16,
            color: filled ? Colors.white : AppColors.ink3,
          ),
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        final t = _ctrl.value;
        final opacity = 0.35 + 0.65 * (1 - (t - 0.5).abs() * 2);
        return Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: opacity.clamp(0.0, 1.0)),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}
