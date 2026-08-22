import 'package:backend/blocs/groupinformation/groupinformation_bloc.dart';
import 'package:backend/screens/groupIDscreen/groupIDscreen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Signs the current user out and returns to a fresh GroupIDScreen, which
/// itself redirects to /login once it sees `currentUser == null` — the
/// single place that logic already lives, rather than duplicating it here.
///
/// Clearing the cached agency/group prefs and resetting the bloc are
/// best-effort: they make the *next* login snappier (no stale group
/// flashing before the new agency loads) but aren't required for logout
/// itself to succeed. Previously, three near-identical `_handleLogout`
/// copies (GroupIDScreen, GroupSelectionScreen, BureauSettingsScreen) ran
/// these steps with no error handling at all — if any one of them threw
/// (a SharedPreferences hiccup, a slow/flaky signOut() call), the function
/// aborted before ever reaching the navigation call, silently stranding
/// the user on the screen they clicked "Log ud" from. That read exactly
/// like "logout doesn't work" until a hard reload forced the app back
/// through main.dart's _AuthGate, which re-evaluates auth state from
/// scratch and finally shows the login screen — i.e. the reported bug.
/// Wrapping each step so a failure can't block the ones after it (and
/// consolidating three copies into one) removes that failure mode.
Future<void> performLogout(BuildContext context) async {
  try {
    context.read<GroupInformationBloc>().add(LogoutEvent());
  } catch (_) {
    // Best-effort — a stale bloc state is a minor cosmetic issue, not a
    // reason to strand the user on the current screen.
  }

  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('groupId');
    await prefs.remove('lastEnteredAgencyCode');
  } catch (_) {
    // Best-effort — see above.
  }

  try {
    await FirebaseAuth.instance.signOut();
  } catch (_) {
    // Even if sign-out itself failed, still try to get the user back to a
    // screen that reflects reality (GroupIDScreen re-checks currentUser)
    // rather than leaving them on the one they just tried to leave.
  }

  if (!context.mounted) return;
  Navigator.pushAndRemoveUntil(
    context,
    MaterialPageRoute(builder: (context) => const GroupIDScreen()),
    (route) => false,
  );
}
