import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A small, floating "saved" confirmation — used by autosaving settings
/// screens (App, Indstillinger) instead of a manual "Gem" button. Replaces
/// the default SnackBar look with a compact rounded pill, a themed check
/// icon, and no jarring full-width bar.
void showSavedSnackbar(
  BuildContext context,
  Color themeColor, {
  String message = 'Gemt',
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.black87,
      duration: const Duration(seconds: 2),
      elevation: 6,
      width: 220,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(color: themeColor, shape: BoxShape.circle),
            child: const Icon(Icons.check_rounded, size: 15, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Text(
            message,
            style: GoogleFonts.kanit(
                color: Colors.white, fontWeight: FontWeight.w500, fontSize: 13),
          ),
        ],
      ),
    ),
  );
}
