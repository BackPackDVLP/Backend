import 'package:flutter/material.dart';

class AppColors {
  // Base Palette
  static const Color beige = Color(0xFFFAFAFA); // Off-white
  static const Color brown = Color(0xFF455A64); // Professional Blue Grey
  static const Color darkGreen = Color(0xFF263238); // Dark Slate
  static const Color brandBeige = Color(0xFFE6D8C6); // BackPack brand beige

  // Main Theme
  static Color primary = brandBeige;
  // Readable foreground for content placed on top of `primary` fills
  // (buttons, FABs, toolbars). `primary` is replaced at runtime with each
  // agency's own brand color, which can be light or dark, so this must be
  // computed from it rather than fixed to one value.
  static Color get onPrimary =>
      primary.computeLuminance() < 0.5 ? Colors.white : Colors.black;

  static Color fromHex(String hexString) {
    final buffer = StringBuffer();
    if (hexString.length == 6 || hexString.length == 7) buffer.write('ff');
    buffer.write(hexString.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  }


  static const Color secondary = beige;
  
  // Backgrounds & Gradients
  static const Color scaffoldGradientStart = Color(0xFFF6EFE2);
  static const Color homeGradientStart = Color(0xFFF6EFE2);
  static const Color scaffoldGradientEnd = Color(0xFFF6EFE2);
  
  // Cards & Panels
  static const Color cardBackground = Color(0xFFF5F5F5);
  static const Color panelBackground = Color.fromARGB(255, 232, 232, 232);
  static const Color chipBackground = Color(0xFFECEFF1);
  
  // Navigation
  static Color navActive = const Color(0xFF37474F);

  
  // Dialogs
  static const Color dialogAltBackground = Color(0xFFF5F5F5);
  static const Color uploadDialogBackground = Color(0xFFF5F5F5);
  static const Color uploadDialogButton = Color(0xFFCFD8DC);
  static const Color iconPickerDialog = Color(0xFFF5F5F5);
}