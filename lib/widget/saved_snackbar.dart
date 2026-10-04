import 'package:backend/widget/app_snackbar.dart';
import 'package:flutter/material.dart';

/// A small "saved" confirmation — used by autosaving settings screens (App,
/// Indstillinger) instead of a manual "Gem" button. Same look as every other
/// snackbar (see [showAppSnackbar]), but accented with the bureau's own
/// theme color and dismissed quicker since autosaves fire often.
void showSavedSnackbar(
  BuildContext context,
  Color themeColor, {
  String message = 'Gemt',
}) {
  showAppSnackbar(
    context,
    message,
    accentColor: themeColor,
    duration: const Duration(seconds: 2),
  );
}
