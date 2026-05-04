import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'home_page.dart';
import 'log.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final originalPrint = debugPrint;
  debugPrint = (String? msg, {int? wrapWidth}) {
    if (msg != null && msg.startsWith('[')) {
      AppLog.add(msg);
    }
    originalPrint(msg, wrapWidth: wrapWidth);
  };
  if (Platform.isMacOS) {
    const channel = MethodChannel('near.window/ready');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      channel.invokeMethod('ready');
    });
  }
  runApp(const NearApp());
}

class NearApp extends StatelessWidget {
  const NearApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Near',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.bgApp,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          primary: AppColors.accent,
          surface: AppColors.bgApp,
        ),
        textTheme: TextTheme(
          bodyMedium: AppFonts.body(),
          bodyLarge: AppFonts.body(),
        ),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      home: const HomePage(),
    );
  }
}
