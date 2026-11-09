part of '../home_page.dart';

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
  final item = DataWriterItem();
  item.add(_isPngBytes(bytes) ? Formats.png(bytes) : Formats.jpeg(bytes));
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

