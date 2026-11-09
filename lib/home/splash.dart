part of '../home_page.dart';

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

