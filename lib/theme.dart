import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const bgPage = Color(0xFFF4F5F7);
  static const bgApp = Color(0xFFFFFFFF);
  static const surface = Color(0xFFF7F8FA);
  static const surface2 = Color(0xFFF0F2F5);
  static const line = Color(0xFFE8EAEF);
  static const line2 = Color(0xFFD8DCE3);
  static const ink = Color(0xFF0F1216);
  static const ink2 = Color(0xFF383D46);
  static const ink3 = Color(0xFF6D7280);
  static const inkFaint = Color(0xFFB6BAC3);
  static const accent = Color(0xFF4A6E87);
  static const accentSoft = Color(0xFFE8EEF3);
  static const accentDeep = Color(0xFF36546A);
  static const presence = Color(0xFF5FB288);
  static const danger = Color(0xFFC2503A);
}

class AppFonts {
  static TextStyle body({
    double size = 15,
    FontWeight weight = FontWeight.w400,
    Color color = AppColors.ink,
    double? letterSpacing,
    double height = 1.5,
  }) {
    return GoogleFonts.hankenGrotesk(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  static TextStyle mono({
    double size = 11,
    FontWeight weight = FontWeight.w400,
    Color color = AppColors.ink3,
    double? letterSpacing,
    double height = 1.4,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );
  }
}
