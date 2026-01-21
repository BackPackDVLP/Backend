import 'package:flutter/material.dart';

class AppColors {
  // Base Palette
  static const Color beige = Color(0xFFFAFAFA); // Off-white
  static const Color brown = Color(0xFF455A64); // Professional Blue Grey
  static const Color darkGreen = Color(0xFF263238); // Dark Slate
  
  // Main Theme
  static Color primary = brown;
  
  static Color fromHex(String hexString) {
    final buffer = StringBuffer();
    if (hexString.length == 6 || hexString.length == 7) buffer.write('ff');
    buffer.write(hexString.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  }


  static const Color secondary = beige;
  
  // Backgrounds & Gradients
  static const Color scaffoldGradientStart = Color(0xFFFAF9F6);
  static const Color homeGradientStart = Color(0xFFFAF9F6);
  static const Color scaffoldGradientEnd = Color(0xFFFAF9F6);
  
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