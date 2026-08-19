import 'package:flutter/material.dart';

/// Customizable colors for the liveness UI elements in the TrueFace SDK.
class TrueFaceColors {
  const TrueFaceColors({
    this.primaryColor = const Color(0xFF4F46E5),
    this.backgroundColor = const Color(0xFFF8FAFC),
    this.cardBackgroundColor = Colors.white,
    this.textColor = const Color(0xFF0F172A),
    this.subtitleColor = const Color(0xFF64748B),
    this.promptBackgroundColor = Colors.white,
    this.promptTextColor = const Color(0xFF0F172A),
    this.promptBorderColor = const Color(0xFFE2E8F0),
    this.ovalBorderColor = const Color(0xFF4F46E5),
    this.overlayScrimColor = const Color(0x80F8FAFC),
  });

  /// Main action buttons & primary brand accents (default: Indigo `#4F46E5`).
  final Color primaryColor;

  /// Main view background & instruction card item fills (default: `#F8FAFC`).
  final Color backgroundColor;

  /// Instructions & outcome sheet background (default: `#FFFFFF`).
  final Color cardBackgroundColor;

  /// Primary headers & title text color (default: Slate-900 `#0F172A`).
  final Color textColor;

  /// Subtitle & secondary body text color (default: Slate-500 `#64748B`).
  final Color subtitleColor;

  /// Challenge prompt pill card background (default: `#FFFFFF`).
  final Color promptBackgroundColor;

  /// Challenge prompt pill card text color (default: Slate-900 `#0F172A`).
  final Color promptTextColor;

  /// Challenge prompt pill card border color (default: Slate-200 `#E2E8F0`).
  final Color promptBorderColor;

  /// Oval target border line color (default: Indigo `#4F46E5`).
  final Color ovalBorderColor;

  /// Camera overlay translucent scrim color (default: `#F8FAFC` @ 50% opacity).
  final Color overlayScrimColor;

  Map<String, int> toMap() {
    return {
      'primaryColor': primaryColor.toARGB32(),
      'backgroundColor': backgroundColor.toARGB32(),
      'cardBackgroundColor': cardBackgroundColor.toARGB32(),
      'textColor': textColor.toARGB32(),
      'subtitleColor': subtitleColor.toARGB32(),
      'promptBackgroundColor': promptBackgroundColor.toARGB32(),
      'promptTextColor': promptTextColor.toARGB32(),
      'promptBorderColor': promptBorderColor.toARGB32(),
      'ovalBorderColor': ovalBorderColor.toARGB32(),
      'overlayScrimColor': overlayScrimColor.toARGB32(),
    };
  }
}
