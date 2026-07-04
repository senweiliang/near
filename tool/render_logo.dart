// 用 Flutter 同款字体（Hanken Grotesk Bold）渲染 App 图标母图。
// 跑法：flutter test tool/render_logo.dart
// 产物：
//   tool/logo_master.png  圆角白卡 + 透明四角 + "Near."（macOS / Windows / Android legacy mipmap 用）
//   tool/logo_fg.png      透明底 + 仅 "Near." 文字（Android adaptive icon 前景层用，背景层走纯白）
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const double kSize = 1024;
const Color kInk = Color(0xFF0F1216); // 启动页 "Near" 深墨
const Color kAccent = Color(0xFF4A6E87); // 启动页点号 accent
const Color kCard = Color(0xFFFFFFFF); // 纯白底

// "Near." —— 与启动页 _NearMark 同字体/字重/配色
Widget _nearMark() {
  const base = 200.0; // FittedBox 整体缩放，base 仅决定 letterSpacing 比例
  final style = TextStyle(
    fontFamily: 'Hanken',
    fontWeight: FontWeight.w700,
    fontVariations: const [FontVariation('wght', 700)],
    letterSpacing: -1.2 / 44 * base, // 照搬启动页 44pt/-1.2 的比例
    height: 1.0,
    fontSize: base,
  );
  return Text.rich(
    TextSpan(children: [
      TextSpan(text: 'Near', style: style.copyWith(color: kInk)),
      TextSpan(text: '.', style: style.copyWith(color: kAccent)),
    ]),
    textAlign: TextAlign.center,
  );
}

// card=true：圆角白卡（透明四角）。card=false：透明底纯文字。
// hPad/vPad 给 FittedBox 紧约束，contain 才能把文字放大填满。
Widget _logo({required bool card, required double hPad, required double vPad}) {
  final inner = Padding(
    padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
    child: FittedBox(fit: BoxFit.contain, child: _nearMark()),
  );
  return Directionality(
    textDirection: TextDirection.ltr,
    child: SizedBox(
      width: kSize,
      height: kSize,
      child: card
          ? Padding(
              padding: const EdgeInsets.all(90),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(190),
                ),
                child: inner,
              ),
            )
          : inner, // 透明背景，仅文字
    ),
  );
}

Future<void> _save(WidgetTester tester, Widget w, String path) async {
  final key = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(key: key, child: w));
  await tester.pumpAndSettle();
  final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.0);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('WROTE $path  ${png.lengthInBytes} bytes');
}

void main() {
  setUpAll(() async {
    final bytes = File('tool/HankenGrotesk.ttf').readAsBytesSync();
    final loader = FontLoader('Hanken')
      ..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    await loader.load();
  });

  // 圆角白卡母图（macOS / Windows / Android legacy）
  testWidgets('logo_master', (tester) async {
    tester.view.physicalSize = const Size(kSize, kSize);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _save(tester, _logo(card: true, hPad: 110, vPad: 120), 'tool/logo_master.png');
  });

  // adaptive 前景：透明底，文字约占 78% 宽；flutter_launcher_icons 会再 inset 16%，
  // 合成后文字约占图标 65%，落在 Android adaptive 安全区内、不至过小。
  testWidgets('logo_fg', (tester) async {
    tester.view.physicalSize = const Size(kSize, kSize);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _save(tester, _logo(card: false, hPad: 113, vPad: 150), 'tool/logo_fg.png');
  });
}
