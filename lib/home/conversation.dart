part of '../home_page.dart';

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
  // 列表 reverse：offset 0 就是底部，进入会话和键盘弹起都天然停在最新消息，无需 jumpTo
  final _scroll = ScrollController();
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChange);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _scrollToBottomAfterSend() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        0,
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
        allowMultiple: true,
      );
    } catch (e, st) {
      debugPrint('[image] picker threw: $e\n$st');
      return;
    }
    if (result == null || result.files.isEmpty) {
      debugPrint('[image] picker cancelled / empty');
      return;
    }
    var sent = 0;
    var tooLarge = 0;
    for (final file in result.files) {
      var bytes = file.bytes;
      if (bytes == null && file.path != null) {
        try {
          bytes = await File(file.path!).readAsBytes();
        } catch (_) {}
      }
      if (bytes == null) continue;
      if (bytes.length > _maxImageBytes) {
        tooLarge++;
        continue;
      }
      final raw = bytes;
      final mime = _isPngBytes(raw) ? 'image/png' : 'image/jpeg';
      final msg = widget.chat.prepareImage(
        toId: widget.recipientId,
        previewBytes: raw,
        imageMime: mime,
      );
      widget.chat.completeImage(msg, raw, imageMime: mime);
      sent++;
    }
    if (sent > 0) _scrollToBottomAfterSend();
    if (tooLarge > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tooLarge == 1
                ? 'Skipped 1 image over 10 MB'
                : 'Skipped $tooLarge images over 10 MB',
            style: AppFonts.body(size: 13, color: Colors.white),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _pickAndSendFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: true);
    } catch (e, st) {
      debugPrint('[file] picker threw: $e\n$st');
      return;
    }
    if (result == null) return;
    await _sendPaths(result.files.map((f) => f.path).whereType<String>().toList());
  }

  Future<void> _pickAndSendFolder() async {
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath();
    } catch (e, st) {
      debugPrint('[file] directory picker threw: $e\n$st');
      return;
    }
    if (path != null) await _sendPaths([path]);
  }

  Future<void> _sendPaths(List<String> paths) async {
    final sent = await _sendPathsTo(widget.chat, paths, widget.recipientId,
        onNote: _showPasteSnack);
    if (sent > 0) _scrollToBottomAfterSend();
  }

  Future<void> _showAttachMenu(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    PopupMenuItem<String> item(String value, IconData icon, String label) =>
        PopupMenuItem<String>(
          value: value,
          height: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: AppColors.ink2),
              const SizedBox(width: 10),
              Text(label, style: AppFonts.body(size: 13, color: AppColors.ink)),
            ],
          ),
        );
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
        Rect.fromLTWH(origin.dx, origin.dy - 8, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        item('files', Icons.insert_drive_file_outlined, 'Files'),
        if (_isDesktop) item('folder', Icons.folder_outlined, 'Folder'),
        item('clipboard', Icons.content_paste_rounded, 'Clipboard'),
      ],
    );
    switch (selected) {
      case 'files':
        await _pickAndSendFile();
      case 'folder':
        await _pickAndSendFolder();
      case 'clipboard':
        await _sendClipboard();
    }
  }

  /// 把剪贴板内容整个推给对方：文件 > 图片 > 文本，文本直接发出而不是贴进输入框。
  Future<void> _sendClipboard() async {
    if (await _tryPasteFiles()) return;
    if (await _tryPasteImage()) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.trim().isEmpty) {
      _showPasteSnack('Clipboard is empty');
      return;
    }
    widget.chat.send(text, toId: widget.recipientId);
    _scrollToBottomAfterSend();
  }

  Future<void> _showSecurityInfo() async {
    final peerId = widget.recipientId;
    if (peerId == null) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgApp,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (_) => _SecuritySheet(chat: widget.chat, peerId: peerId),
    );
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
    await _sendPaths(paths);
    return true;
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
      var mime = 'image/jpeg';
      if (item.canProvide(Formats.png)) {
        bytes = await _readClipboardFile(item, Formats.png);
        if (bytes != null) mime = 'image/png';
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
      final raw = bytes;
      final msg = widget.chat.prepareImage(
        toId: widget.recipientId,
        previewBytes: raw,
        imageMime: mime,
      );
      _scrollToBottomAfterSend();
      widget.chat.completeImage(msg, raw, imageMime: mime);
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

    final keyConflict =
        isEveryone ? null : chat.conflictingFingerprint(widget.recipientId!);
    final page = Scaffold(
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
                    child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: isEveryone ? null : _showSecurityInfo,
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
                  ),
                ],
              ),
            ),
          ),
          if (keyConflict != null)
            _KeyConflictBanner(
              name: title,
              onTap: _showSecurityInfo,
            ),
          Expanded(
            child: visible.isEmpty
                ? _EmptyState(isEveryone: isEveryone, name: title)
                : SelectionArea(
                    // reverse + shrinkWrap + 顶部对齐：消息少时贴顶，多时从底部开始
                    child: Align(
                    alignment: Alignment.topCenter,
                    child: ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    itemCount: visible.length,
                    itemBuilder: (_, reversedIndex) {
                      final i = visible.length - 1 - reversedIndex;
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
            onPickFile: _showAttachMenu,
            onPaste: _handlePaste,
          ),
        ],
      ),
    );
    if (!_isDesktop) return page;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _sendPaths(details.files.map((f) => f.path).toList());
      },
      child: Stack(
        children: [
          page,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accentSoft.withValues(alpha: 0.85),
                    border: Border.all(color: AppColors.accent, width: 1.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'Drop to send to ${isEveryone ? 'everyone' : title}',
                    style: AppFonts.body(
                        size: 15, weight: FontWeight.w600, color: AppColors.accentDeep),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _KeyConflictBanner extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  const _KeyConflictBanner({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(bottom: BorderSide(color: AppColors.line)),
        ),
        child: Text(
          "$name's security key changed · connection blocked · tap to review",
          style: AppFonts.mono(size: 11, color: AppColors.ink2),
        ),
      ),
    );
  }
}

class _SecuritySheet extends StatelessWidget {
  final Chat chat;
  final String peerId;
  const _SecuritySheet({required this.chat, required this.peerId});

  @override
  Widget build(BuildContext context) {
    final name = chat.peers[peerId]?.name ?? 'Peer';
    final conflicting = chat.conflictingFingerprint(peerId);
    final trusted = chat.peerFingerprint(peerId);
    Widget row(String label, String? value) => Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label.toUpperCase(),
                  style: AppFonts.mono(size: 10.5, color: AppColors.ink3, letterSpacing: 0.66)),
              const SizedBox(height: 4),
              SelectableText(value ?? '—',
                  style: AppFonts.mono(size: 13, color: AppColors.ink)),
            ],
          ),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Encryption',
                style: AppFonts.body(size: 17, weight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'Messages and files are end-to-end encrypted. Compare these keys on both devices to make sure nobody is in the middle.',
              style: AppFonts.body(size: 13, color: AppColors.ink2, height: 1.4),
            ),
            row('Your key', chat.myFingerprint),
            row(conflicting == null ? "$name's key" : "$name's previous key", trusted),
            if (conflicting != null) ...[
              row("$name's new key", conflicting),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                  onPressed: () {
                    chat.trustNewKey(peerId);
                    Navigator.of(context).pop();
                  },
                  child: const Text('Trust new key'),
                ),
              ),
            ],
          ],
        ),
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

