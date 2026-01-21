import 'package:flutter/material.dart';

/// A widget that displays a hardcoded agency logo.
///
/// The `agencyCode` parameter is kept for compatibility with existing code,
/// but it is not used.
class AgencyLogo extends StatelessWidget {
  final String agencyCode;

  const AgencyLogo({super.key, required this.agencyCode});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/BackPack.png',
      fit: BoxFit.contain,
    );
  }
}
