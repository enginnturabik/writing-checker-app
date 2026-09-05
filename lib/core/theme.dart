import 'package:flutter/material.dart';

/// Colour per error category. Used for underlines, chips and the stats bars.
const kCategoryColors = <String, Color>{
  'grammar': Color(0xFFD1495B),
  'spelling': Color(0xFFE07A22),
  'punctuation': Color(0xFFB07C1E),
  'vocabulary': Color(0xFF3D7DCA),
  'style': Color(0xFF7A5BC2),
  'register': Color(0xFF0F8F86),
  'coherence': Color(0xFF4B7F52),
  'other': Color(0xFF6B7280),
};

Color categoryColor(String key) => kCategoryColors[key] ?? kCategoryColors['other']!;

Color severityColor(String severity) => switch (severity) {
      'critical' => const Color(0xFFD1495B),
      'moderate' => const Color(0xFFE07A22),
      _ => const Color(0xFF6B7280),
    };

/// Score colour ramp: red -> amber -> green.
Color scoreColor(int score) {
  if (score >= 85) return const Color(0xFF2E7D52);
  if (score >= 70) return const Color(0xFF6C9A3A);
  if (score >= 55) return const Color(0xFFC98A17);
  if (score >= 40) return const Color(0xFFE07A22);
  return const Color(0xFFD1495B);
}

const _seed = Color(0xFF2F6FB0);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(color: scheme.outlineVariant),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
  );
}
