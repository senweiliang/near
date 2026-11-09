part of '../home_page.dart';

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

