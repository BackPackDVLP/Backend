import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shared design tokens for spacing, corner radius, shadow, and text style —
/// named constants for the values the app already agreed on independently
/// in every screen (see the survey behind this file: BorderRadius.circular
/// values cluster overwhelmingly on 12/20/10, and one BoxShadow literal
/// covers the large majority of cards), so adopting these is a rename, not
/// a redesign. Kanit stays the only font — AppTextStyles just gives it a
/// disciplined size/weight scale instead of the ~23 ad-hoc sizes previously
/// scattered across the app.
class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

class AppRadii {
  static const double sm = 10;
  static const double md = 12;
  static const double lg = 20;

  static const BorderRadius smRadius = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdRadius = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgRadius = BorderRadius.all(Radius.circular(lg));
}

class AppShadows {
  // The de facto standard already used on the large majority of cards
  // across the app — named here rather than reinvented per screen.
  static List<BoxShadow> get card => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ];

  // For genuinely more prominent/floating elements (hero sections, the App
  // screen's phone mockup) — codifies the heavier one-offs already used
  // for those rather than forcing everything onto the same flat shadow.
  static List<BoxShadow> get elevated => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.15),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
      ];
}

class AppTextStyles {
  // A second full-page-title survey (multi-line-aware, unlike the first
  // pass) found 18pt actually splits into two real conventions —
  // FontWeight.bold/w700 (14 call sites) edges out w600 (8) as the more
  // common one. Both are kept as named tokens rather than picking a
  // winner and silently changing the other's rendered weight.
  // Color is nullable (not just optional) because plenty of existing call
  // sites pass a MaterialColor index expression like `Colors.grey[500]`,
  // which is itself typed `Color?` — matching GoogleFonts.kanit's own
  // nullable `color` param instead of forcing every caller to `!` it.
  static TextStyle headingBold({Color? color}) => GoogleFonts.kanit(
      fontSize: 18, fontWeight: FontWeight.bold, color: color ?? Colors.black87);

  static TextStyle heading({Color? color}) => GoogleFonts.kanit(
      fontSize: 18, fontWeight: FontWeight.w600, color: color ?? Colors.black87);

  static TextStyle label({Color? color}) => GoogleFonts.kanit(
      fontSize: 14, fontWeight: FontWeight.w600, color: color ?? Colors.black87);

  static TextStyle body({Color? color}) =>
      GoogleFonts.kanit(fontSize: 13, color: color ?? Colors.black87);

  static TextStyle caption({Color? color}) =>
      GoogleFonts.kanit(fontSize: 11.5, color: color ?? Colors.grey[600]);
}
