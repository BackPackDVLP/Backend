import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// What a snackbar is reporting — drives its icon, accent color and how long
/// it stays up (errors linger so there's time to actually read them).
enum SnackType { success, error, warning, info }

extension on SnackType {
  IconData get icon => switch (this) {
        SnackType.success => Icons.check_rounded,
        SnackType.error => Icons.error_outline_rounded,
        SnackType.warning => Icons.warning_amber_rounded,
        SnackType.info => Icons.info_outline_rounded,
      };

  Color get color => switch (this) {
        SnackType.success => const Color(0xFF2E9E6A),
        SnackType.error => const Color(0xFFE5484D),
        SnackType.warning => const Color(0xFFE59A1A),
        SnackType.info => const Color(0xFF4A7BD0),
      };

  Duration get duration => switch (this) {
        SnackType.error => const Duration(seconds: 5),
        SnackType.warning => const Duration(seconds: 4),
        _ => const Duration(seconds: 3),
      };
}

/// The one snackbar look for the whole admin panel: a compact floating card
/// with a colored status badge, readable Kanit text and a close button —
/// replacing the default full-width grey Material bar. Any snackbar already
/// on screen is dismissed first, so rapid actions don't queue up a backlog
/// of stale messages.
void showAppSnackbar(
  BuildContext context,
  String message, {
  SnackType type = SnackType.success,
  Duration? duration,
  Color? accentColor,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final accent = accentColor ?? type.color;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.darkGreen,
      duration: duration ?? type.duration,
      elevation: 8,
      width: _snackWidth(context),
      shape: RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
      content: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            child: Icon(type.icon,
                size: 17,
                color: accent.computeLuminance() < 0.5
                    ? Colors.white
                    : Colors.black87),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.kanit(
                color: Colors.white,
                fontWeight: FontWeight.w500,
                fontSize: 13.5,
                height: 1.3,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: () {
                messenger.hideCurrentSnackBar();
                onAction();
              },
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                textStyle:
                    GoogleFonts.kanit(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              child: Text(actionLabel.toUpperCase()),
            ),
          IconButton(
            tooltip: 'Luk',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: Colors.white60,
            icon: const Icon(Icons.close_rounded),
            onPressed: messenger.hideCurrentSnackBar,
          ),
        ],
      ),
    ),
  );
}

void showErrorSnackbar(BuildContext context, String message) =>
    showAppSnackbar(context, message, type: SnackType.error);

void showWarningSnackbar(BuildContext context, String message) =>
    showAppSnackbar(context, message, type: SnackType.warning);

void showInfoSnackbar(BuildContext context, String message,
        {Duration? duration}) =>
    showAppSnackbar(context, message, type: SnackType.info, duration: duration);

/// Turns a caught exception into something fit to show an admin — strips
/// Dart's `Exception: ` prefix and Firebase's `[plugin/code] ` prefix rather
/// than dumping the raw toString() into the UI.
String describeError(Object error) {
  var text = error.toString();
  if (text.startsWith('Exception: ')) text = text.substring(11);
  text = text.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '');
  return text.trim().isEmpty ? 'Ukendt fejl' : text.trim();
}

// Fits the text on desktop without stretching across a wide admin window,
// while still leaving side margins on narrow screens.
double _snackWidth(BuildContext context) {
  final screen = MediaQuery.sizeOf(context).width;
  return (screen - 2 * AppSpacing.lg).clamp(0, 440).toDouble();
}
