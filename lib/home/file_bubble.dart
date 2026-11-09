part of '../home_page.dart';

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
    final isFanoutTerminal =
        isGroup && msg.fanout.values.every((e) => e.state.isTerminal);
    final isPaused = mine
        ? msg.fanout.values.any((e) => e.state == FanoutState.paused)
        : msg.transferPaused;
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
      } else if (isPaused) {
        statusLabel = 'paused';
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
      } else if (isPaused) {
        statusLabel = 'paused';
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
      case FanoutState.paused:
        dot = _StateDot(color: faintFg, hollow: true);
        rightSlot = Text('paused',
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
