import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'chat.dart';
import 'remote.dart';
import 'secure_channel.dart';
import 'theme.dart';

/// 扫码配对。手机默认扫码（也可切到展示自己的码），桌面没有摄像头只展示码。
class PairPage extends StatefulWidget {
  final Chat chat;
  const PairPage({super.key, required this.chat});

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  static final bool _canScan = Platform.isAndroid || Platform.isIOS;
  late bool _showingCode = !_canScan;
  PairedDevice? _pairedWith;

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_onChatChanged);
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChatChanged);
    widget.chat.remote.hideCode();
    super.dispose();
  }

  void _onChatChanged() {
    if (!mounted) return;
    final paired = widget.chat.remote.codePairedWith;
    if (_showingCode && paired != null && _pairedWith == null) {
      setState(() => _pairedWith = paired);
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final paired = _pairedWith;
    final Widget body;
    if (paired != null) {
      body = _PairedView(device: paired, onDone: () => Navigator.of(context).pop());
    } else if (_showingCode) {
      body = _ShowCodeView(
        chat: widget.chat,
        onScanInstead: _canScan ? () => setState(() => _showingCode = false) : null,
      );
    } else {
      body = _ScanView(
        chat: widget.chat,
        onShowCode: () => setState(() => _showingCode = true),
        onPaired: (device) => setState(() => _pairedWith = device),
      );
    }
    final dark = paired == null && !_showingCode;
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF0D1013) : AppColors.bgApp,
      appBar: AppBar(
        backgroundColor: dark ? Colors.transparent : AppColors.bgApp,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          'Pair a device',
          style: AppFonts.body(
            size: 17,
            weight: FontWeight.w700,
            color: dark ? Colors.white : AppColors.ink,
          ),
        ),
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: Icon(dark ? Icons.close_rounded : Icons.chevron_left_rounded,
              color: dark ? Colors.white : AppColors.ink2, size: dark ? 24 : 28),
        ),
      ),
      extendBodyBehindAppBar: dark,
      body: body,
    );
  }
}

String _shortFingerprint(String key) {
  final groups = fingerprintOf(base64Decode(key)).split(' ');
  return groups.take(2).join('·').toUpperCase();
}

String _shortId(String id) => '@${id.length <= 4 ? id : id.substring(0, 4)}';

String _initialOf(String name) => name.isEmpty ? '?' : name.characters.first.toUpperCase();

class _Avatar extends StatelessWidget {
  final String name;
  final bool you;
  final double size;
  const _Avatar({required this.name, this.you = false, this.size = 34});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: you ? AppColors.accent : AppColors.surface2,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        _initialOf(name),
        style: AppFonts.body(
          size: size * 0.38,
          weight: FontWeight.w700,
          color: you ? Colors.white : AppColors.ink2,
          height: 1,
        ),
      ),
    );
  }
}

// ───────────── show code ─────────────

class _ShowCodeView extends StatefulWidget {
  final Chat chat;
  final VoidCallback? onScanInstead;
  const _ShowCodeView({required this.chat, this.onScanInstead});

  @override
  State<_ShowCodeView> createState() => _ShowCodeViewState();
}

class _ShowCodeViewState extends State<_ShowCodeView> {
  late PairCode _code;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _code = widget.chat.remote.showCode();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // 过期自动换新码，展示页一直开着也能用
      if (DateTime.now().isAfter(_code.expiresAt)) _code = widget.chat.remote.showCode();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = widget.chat.remote;
    final left = _code.expiresAt.difference(DateTime.now());
    final seconds = left.inSeconds.clamp(0, 999);
    final countdown = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final serverUp = remote.serverReachable;
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Scan with Near on your other device.',
                textAlign: TextAlign.center,
                style: AppFonts.body(size: 13.5, color: AppColors.ink3, height: 1.45),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: serverUp ? 1 : 0.15,
                      child: QrImageView(
                        data: _code.candidate.toUri(),
                        size: 196,
                        padding: EdgeInsets.zero,
                        errorCorrectionLevel: QrErrorCorrectLevel.H,
                        eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: AppColors.ink),
                        dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square, color: AppColors.ink),
                      ),
                    ),
                    if (serverUp)
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: const [BoxShadow(color: Colors.white, spreadRadius: 4)],
                        ),
                        alignment: Alignment.center,
                        child: Text.rich(TextSpan(children: [
                          TextSpan(
                              text: 'N',
                              style: AppFonts.body(size: 16, weight: FontWeight.w700, color: AppColors.ink)),
                          TextSpan(
                              text: '.',
                              style: AppFonts.body(size: 16, weight: FontWeight.w700, color: AppColors.accent)),
                        ])),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Avatar(name: widget.chat.myName, you: true),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.chat.myName,
                            style: AppFonts.body(size: 14, weight: FontWeight.w600, height: 1.2)),
                        Text(
                          '${_shortId(widget.chat.myId)} · key ${_shortFingerprint(remote.myKey)}',
                          style: AppFonts.mono(size: 11, color: AppColors.ink3),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (serverUp) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _PulseDot(),
                    const SizedBox(width: 8),
                    Text('waiting for scan',
                        style: AppFonts.mono(size: 11.5, color: AppColors.ink3, letterSpacing: 0.2)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('code expires in $countdown',
                    style: AppFonts.mono(size: 11, color: AppColors.inkFaint)),
              ] else
                Text(
                  "Can't reach the coordination server.\nCheck your connection and try again.",
                  textAlign: TextAlign.center,
                  style: AppFonts.mono(size: 11.5, color: AppColors.ink3, height: 1.6),
                ),
              if (widget.onScanInstead != null) ...[
                const SizedBox(height: 18),
                TextButton(
                  onPressed: widget.onScanInstead,
                  child: Text('Scan a code instead',
                      style: AppFonts.body(size: 13.5, weight: FontWeight.w600, color: AppColors.accent)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.25, end: 1.0).animate(_controller),
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
      ),
    );
  }
}

// ───────────── scan ─────────────

class _ScanView extends StatefulWidget {
  final Chat chat;
  final VoidCallback onShowCode;
  final void Function(PairedDevice device) onPaired;
  const _ScanView({required this.chat, required this.onShowCode, required this.onPaired});

  @override
  State<_ScanView> createState() => _ScanViewState();
}

class _ScanViewState extends State<_ScanView> {
  final MobileScannerController _controller =
      MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _handling = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling) return;
    for (final barcode in capture.barcodes) {
      final candidate = PairCandidate.parse(barcode.rawValue ?? '');
      if (candidate == null || candidate.key == widget.chat.remote.myKey) continue;
      _handling = true;
      await _controller.stop();
      if (!mounted) return;
      final device = await showModalBottomSheet<PairedDevice>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.bgApp,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (_) => _ConfirmSheet(chat: widget.chat, candidate: candidate),
      );
      if (!mounted) return;
      if (device != null) {
        widget.onPaired(device);
        return;
      }
      _handling = false;
      await _controller.start();
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        IgnorePointer(
          child: Center(
            child: SizedBox(
              width: 260,
              height: 260,
              child: CustomPaint(painter: _ViewfinderPainter()),
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, 0.55),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Point at the code on your other device',
                  style: AppFonts.body(size: 14.5, color: Colors.white.withValues(alpha: 0.88))),
              const SizedBox(height: 6),
              Text('Settings → Pair a device',
                  style: AppFonts.mono(size: 11, color: Colors.white.withValues(alpha: 0.5))),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 40,
          child: SafeArea(
            child: Center(
              child: TextButton.icon(
                onPressed: widget.onShowCode,
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                ),
                icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                label: Text('Show my code instead',
                    style: AppFonts.body(size: 13.5, weight: FontWeight.w500, color: Colors.white)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ViewfinderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const arm = 34.0;
    const radius = 14.0;
    final w = size.width, h = size.height;
    for (final corner in [Offset.zero, Offset(w, 0), Offset(0, h), Offset(w, h)]) {
      final dx = corner.dx == 0 ? 1.0 : -1.0;
      final dy = corner.dy == 0 ? 1.0 : -1.0;
      final path = Path()
        ..moveTo(corner.dx, corner.dy + dy * arm)
        ..lineTo(corner.dx, corner.dy + dy * radius)
        ..quadraticBezierTo(corner.dx, corner.dy, corner.dx + dx * radius, corner.dy)
        ..lineTo(corner.dx + dx * arm, corner.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ConfirmSheet extends StatefulWidget {
  final Chat chat;
  final PairCandidate candidate;
  const _ConfirmSheet({required this.chat, required this.candidate});

  @override
  State<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<_ConfirmSheet> {
  bool _pairing = false;
  String? _error;

  Future<void> _pair() async {
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      final device = await widget.chat.remote.pairWith(widget.candidate);
      if (mounted) Navigator.of(context).pop(device);
    } on PairException catch (e) {
      if (!mounted) return;
      setState(() {
        _pairing = false;
        _error = switch (e.reason) {
          PairFailure.noServer => "Can't reach the coordination server. Check your connection.",
          PairFailure.peerOffline =>
            "${widget.candidate.name} isn't reachable. Keep its pairing code open and try again.",
          PairFailure.rejected => 'This code has expired. Ask for a fresh one.',
          PairFailure.timeout => "${widget.candidate.name} didn't answer. Try again.",
        };
      });
    }
  }

  Widget _factRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: AppFonts.body(size: 14, weight: FontWeight.w500, color: AppColors.ink2)),
            ),
            Text(value, style: AppFonts.mono(size: 13, color: AppColors.ink3)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: AppColors.line2, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Avatar(name: widget.chat.myName, you: true, size: 64),
                SizedBox(
                  width: 54,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      5,
                      (_) => Container(
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: const BoxDecoration(color: AppColors.inkFaint, shape: BoxShape.circle),
                      ),
                    ),
                  ),
                ),
                _Avatar(name: candidate.name, size: 64),
              ],
            ),
            const SizedBox(height: 16),
            Text('Pair with ${candidate.name}?',
                textAlign: TextAlign.center,
                style: AppFonts.body(size: 20, weight: FontWeight.w700, letterSpacing: -0.4)),
            const SizedBox(height: 4),
            Text(
              "You'll be able to reach each other\nfrom any network, device to device.",
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 13.5, color: AppColors.ink3, height: 1.45),
            ),
            const SizedBox(height: 18),
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  _factRow('Handle', _shortId(candidate.id)),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: Divider(height: 1, color: AppColors.line),
                  ),
                  _factRow('Identity', _shortFingerprint(candidate.key)),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: AppFonts.body(size: 13, color: AppColors.danger, height: 1.4)),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _pairing ? null : _pair,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _pairing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text('Pair', style: AppFonts.body(size: 15.5, weight: FontWeight.w600, color: Colors.white)),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: AppFonts.body(size: 15, weight: FontWeight.w500, color: AppColors.ink2)),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────── paired ─────────────

class _PairedView extends StatelessWidget {
  final PairedDevice device;
  final VoidCallback onDone;
  const _PairedView({required this.device, required this.onDone});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(color: AppColors.accentSoft, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, size: 32, color: AppColors.accent),
              ),
              const SizedBox(height: 16),
              Text('Paired with ${device.name}',
                  textAlign: TextAlign.center,
                  style: AppFonts.body(size: 20, weight: FontWeight.w700, letterSpacing: -0.4)),
              const SizedBox(height: 4),
              Text('${_shortId(device.id)} · key ${_shortFingerprint(device.key)}',
                  style: AppFonts.mono(size: 11.5, color: AppColors.ink3)),
              const SizedBox(height: 12),
              Text(
                "You'll find ${device.name} in your conversations.\nIt connects directly whenever you're both online.",
                textAlign: TextAlign.center,
                style: AppFonts.body(size: 13.5, color: AppColors.ink3, height: 1.45),
              ),
              const SizedBox(height: 22),
              TextButton(
                onPressed: onDone,
                child: Text('Done', style: AppFonts.body(size: 15, weight: FontWeight.w600, color: AppColors.accent)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
