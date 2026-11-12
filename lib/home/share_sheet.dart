part of '../home_page.dart';

/// 系统分享进来的文件选择发给谁：只列在线的会话，离线的发不出去。
class _ShareTargetSheet extends StatelessWidget {
  final Chat chat;
  final int count;
  const _ShareTargetSheet({required this.chat, required this.count});

  @override
  Widget build(BuildContext context) {
    final online = chat.peers.values.where((p) => p.online).toList();
    void pick(String? peerId) => Navigator.of(context).pop((peerId: peerId));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                count == 1 ? 'Send 1 file to…' : 'Send $count files to…',
                style: AppFonts.body(size: 17, weight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  _PeerTile(
                    avatar: const _GroupAvatar(),
                    title: 'Everyone here',
                    meta: '${chat.lanPeerCount} online',
                    onTap: chat.lanPeerCount == 0 ? null : () => pick(null),
                  ),
                  for (final p in online)
                    _PeerTile(
                      avatar: _CircleAv(
                          text: _initial(p.name), kind: AvKind.normal, online: true),
                      title: p.name,
                      handle: _shortHandle(p.id),
                      chip: chat.isDirect(p.id) ? 'direct' : null,
                      meta: _peerStatusLine(chat, p),
                      onTap: () => pick(p.id),
                    ),
                  if (online.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Nobody is online on this network right now.',
                          style: AppFonts.body(size: 13, color: AppColors.ink3)),
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
