// =============================================================================
// SINYALIST — Theme Engine (FIXED)
// =============================================================================
// FIX 1: Both themes define ALL 12 TextTheme entries with inherit:true
// FIX 2: ElevatedButton textStyle removed (inherits from theme cleanly)
// FIX 3: No explicit color on TextStyles — let ColorScheme handle it
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SinyalistColors {
  SinyalistColors._();

  static const Color oledBlack       = Color(0xFF000000);
  static const Color oledSurface     = Color(0xFF0A0A0A);
  static const Color oledSurfaceHigh = Color(0xFF1A1A1A);
  static const Color oledBorder      = Color(0xFF2A2A2A);
  static const Color emergencyRed    = Color(0xFFFF3B30);
  static const Color emergencyAmber  = Color(0xFFFFCC00);
  static const Color safeGreen       = Color(0xFF30D158);
  static const Color signalBlue      = Color(0xFF0A84FF);
  static const Color oledTextPrimary = Color(0xFFFFFFFF);
  static const Color oledTextSecondary = Color(0xFFAEAEB2);
  static const Color oledTextDisabled  = Color(0xFF636366);

  static const Color whiteBackground = Color(0xFFFAFAFA);
  static const Color whiteSurface    = Color(0xFFFFFFFF);
  static const Color whiteSurfaceHigh = Color(0xFFF2F2F7);
  static const Color whiteBorder     = Color(0xFFE5E5EA);
  static const Color professionalBlue  = Color(0xFF1A73E8);
  static const Color professionalRed   = Color(0xFFD93025);
  static const Color professionalGreen = Color(0xFF1E8E3E);
  static const Color professionalAmber = Color(0xFFF9AB00);
  static const Color whiteTextPrimary  = Color(0xFF1C1C1E);
  static const Color whiteTextSecondary = Color(0xFF636366);
  static const Color whiteTextDisabled  = Color(0xFFAEAEB2);
}

class SinyalistSpacing {
  SinyalistSpacing._();
  static const double panicButtonHeight  = 72.0;
  static const double panicButtonRadius  = 16.0;
  static const double panicTouchTarget   = 56.0;
  static const double standardButtonHeight = 48.0;
  static const double pagePadding    = 20.0;
  static const double cardPadding    = 16.0;
  static const double elementSpacing = 12.0;
}

class SinyalistTheme {
  SinyalistTheme._();

  // =========================================================================
  // OLED BLACK — Survival Mode
  // =========================================================================
  static ThemeData oledBlack() {
    const cs = ColorScheme(
      brightness: Brightness.dark,
      primary: SinyalistColors.emergencyRed,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFF3A0A08),
      onPrimaryContainer: SinyalistColors.emergencyRed,
      secondary: SinyalistColors.emergencyAmber,
      onSecondary: Colors.black,
      secondaryContainer: Color(0xFF3A2E00),
      onSecondaryContainer: SinyalistColors.emergencyAmber,
      tertiary: SinyalistColors.signalBlue,
      onTertiary: Colors.white,
      error: SinyalistColors.emergencyRed,
      onError: Colors.white,
      surface: SinyalistColors.oledBlack,
      onSurface: SinyalistColors.oledTextPrimary,
      surfaceContainerHighest: SinyalistColors.oledSurfaceHigh,
      onSurfaceVariant: SinyalistColors.oledTextSecondary,
      outline: SinyalistColors.oledBorder,
      outlineVariant: Color(0xFF1C1C1E),
      shadow: Colors.transparent,
    );

    // ALL 12 keys, ALL inherit:true, NO explicit color (ColorScheme provides it)
    const textTheme = TextTheme(
      displayLarge:  TextStyle(inherit: true, fontSize: 48, fontWeight: FontWeight.w800, letterSpacing: -1.5, height: 1.1),
      displayMedium: TextStyle(inherit: true, fontSize: 36, fontWeight: FontWeight.w700),
      displaySmall:  TextStyle(inherit: true, fontSize: 28, fontWeight: FontWeight.w700),
      titleLarge:    TextStyle(inherit: true, fontSize: 24, fontWeight: FontWeight.w700),
      titleMedium:   TextStyle(inherit: true, fontSize: 20, fontWeight: FontWeight.w600),
      titleSmall:    TextStyle(inherit: true, fontSize: 16, fontWeight: FontWeight.w600),
      bodyLarge:     TextStyle(inherit: true, fontSize: 18, fontWeight: FontWeight.w500, height: 1.5),
      bodyMedium:    TextStyle(inherit: true, fontSize: 16, fontWeight: FontWeight.w400, height: 1.4),
      bodySmall:     TextStyle(inherit: true, fontSize: 14, fontWeight: FontWeight.w400),
      labelLarge:    TextStyle(inherit: true, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 0.5),
      labelMedium:   TextStyle(inherit: true, fontSize: 14, fontWeight: FontWeight.w600),
      labelSmall:    TextStyle(inherit: true, fontSize: 12, fontWeight: FontWeight.w500),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: cs,
      scaffoldBackgroundColor: SinyalistColors.oledBlack,
      canvasColor: SinyalistColors.oledBlack,
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: SinyalistColors.oledBlack,
        foregroundColor: SinyalistColors.oledTextPrimary,
        elevation: 0, scrolledUnderElevation: 0, centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: SinyalistColors.oledBlack,
        ),
      ),
      cardTheme: CardThemeData(
        color: SinyalistColors.oledSurface, elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: SinyalistColors.oledBorder, width: 0.5),
        ),
      ),
      // NO textStyle override — prevents inherit mismatch during lerp
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: SinyalistColors.emergencyRed,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 72),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: SinyalistColors.emergencyRed,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: SinyalistColors.oledSurface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SinyalistColors.oledBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SinyalistColors.signalBlue, width: 2),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: SinyalistColors.oledBlack,
        selectedItemColor: SinyalistColors.emergencyRed,
        unselectedItemColor: SinyalistColors.oledTextDisabled,
        elevation: 0,
      ),
      iconTheme: const IconThemeData(color: SinyalistColors.oledTextPrimary, size: 28),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
  }

  // =========================================================================
  // PROFESSIONAL WHITE — Daily Mode
  // =========================================================================
  static ThemeData professionalWhite() {
    const cs = ColorScheme(
      brightness: Brightness.light,
      primary: SinyalistColors.professionalBlue,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFD2E3FC),
      onPrimaryContainer: Color(0xFF0D47A1),
      secondary: SinyalistColors.professionalGreen,
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFCEEAD6),
      onSecondaryContainer: Color(0xFF0D652D),
      tertiary: SinyalistColors.professionalAmber,
      onTertiary: Colors.black,
      error: SinyalistColors.professionalRed,
      onError: Colors.white,
      surface: SinyalistColors.whiteSurface,
      onSurface: SinyalistColors.whiteTextPrimary,
      surfaceContainerHighest: SinyalistColors.whiteSurfaceHigh,
      onSurfaceVariant: SinyalistColors.whiteTextSecondary,
      outline: SinyalistColors.whiteBorder,
      outlineVariant: Color(0xFFD1D1D6),
      shadow: Colors.black12,
    );

    // ALL 12 keys matching OLED 1:1, ALL inherit:true
    const textTheme = TextTheme(
      displayLarge:  TextStyle(inherit: true, fontSize: 40, fontWeight: FontWeight.w700),
      displayMedium: TextStyle(inherit: true, fontSize: 32, fontWeight: FontWeight.w600),
      displaySmall:  TextStyle(inherit: true, fontSize: 26, fontWeight: FontWeight.w600),
      titleLarge:    TextStyle(inherit: true, fontSize: 22, fontWeight: FontWeight.w600),
      titleMedium:   TextStyle(inherit: true, fontSize: 18, fontWeight: FontWeight.w500),
      titleSmall:    TextStyle(inherit: true, fontSize: 15, fontWeight: FontWeight.w500),
      bodyLarge:     TextStyle(inherit: true, fontSize: 16, fontWeight: FontWeight.w400, height: 1.5),
      bodyMedium:    TextStyle(inherit: true, fontSize: 14, fontWeight: FontWeight.w400),
      bodySmall:     TextStyle(inherit: true, fontSize: 12, fontWeight: FontWeight.w400),
      labelLarge:    TextStyle(inherit: true, fontSize: 16, fontWeight: FontWeight.w600),
      labelMedium:   TextStyle(inherit: true, fontSize: 13, fontWeight: FontWeight.w500),
      labelSmall:    TextStyle(inherit: true, fontSize: 11, fontWeight: FontWeight.w500),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: cs,
      scaffoldBackgroundColor: SinyalistColors.whiteBackground,
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: SinyalistColors.whiteSurface,
        foregroundColor: SinyalistColors.whiteTextPrimary,
        elevation: 0, scrolledUnderElevation: 1, centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
        ),
      ),
      cardTheme: CardThemeData(
        color: SinyalistColors.whiteSurface, elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: SinyalistColors.whiteBorder),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: SinyalistColors.professionalBlue,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          elevation: 0,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: SinyalistColors.whiteSurface,
        selectedItemColor: SinyalistColors.professionalBlue,
        unselectedItemColor: SinyalistColors.whiteTextDisabled,
        elevation: 8,
      ),
      iconTheme: const IconThemeData(color: SinyalistColors.whiteTextSecondary, size: 24),
    );
  }
}

@immutable
class SinyalistSemanticColors extends ThemeExtension<SinyalistSemanticColors> {
  final Color trapped;
  final Color safe;
  final Color warning;
  final Color info;
  final Color mesh;

  const SinyalistSemanticColors({
    required this.trapped, required this.safe,
    required this.warning, required this.info, required this.mesh,
  });

  static const oled = SinyalistSemanticColors(
    trapped: SinyalistColors.emergencyRed, safe: SinyalistColors.safeGreen,
    warning: SinyalistColors.emergencyAmber, info: SinyalistColors.signalBlue,
    mesh: Color(0xFFBF5AF2),
  );

  static const professional = SinyalistSemanticColors(
    trapped: SinyalistColors.professionalRed, safe: SinyalistColors.professionalGreen,
    warning: SinyalistColors.professionalAmber, info: SinyalistColors.professionalBlue,
    mesh: Color(0xFF7B61FF),
  );

  @override
  ThemeExtension<SinyalistSemanticColors> copyWith({
    Color? trapped, Color? safe, Color? warning, Color? info, Color? mesh,
  }) => SinyalistSemanticColors(
    trapped: trapped ?? this.trapped, safe: safe ?? this.safe,
    warning: warning ?? this.warning, info: info ?? this.info,
    mesh: mesh ?? this.mesh,
  );

  @override
  ThemeExtension<SinyalistSemanticColors> lerp(
    covariant ThemeExtension<SinyalistSemanticColors>? other, double t,
  ) {
    if (other is! SinyalistSemanticColors) return this;
    return SinyalistSemanticColors(
      trapped: Color.lerp(trapped, other.trapped, t)!,
      safe: Color.lerp(safe, other.safe, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      mesh: Color.lerp(mesh, other.mesh, t)!,
    );
  }
}
