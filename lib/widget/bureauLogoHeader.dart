import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The bureau's own logo (from `config/AgencyLogos/{agencyCode}.png` in
/// Storage), rendered as a solid white silhouette so it reads cleanly on a
/// colored header. The resolved URL is cached per agencyCode so navigating
/// between pages doesn't re-fetch it, and while it's loading (only ever
/// happens once per agency) this shows blank rather than flashing the
/// bureau name and then swapping it out for the logo.
class BureauLogoHeader extends StatelessWidget {
  final String agencyCode;
  final String fallbackText;
  final double height;
  final double width;

  const BureauLogoHeader({
    super.key,
    required this.agencyCode,
    required this.fallbackText,
    this.height = 30,
    this.width = 200,
  });

  static final Map<String, Future<String?>> _urlCache = {};

  Future<String?> _loadUrl() {
    return _urlCache.putIfAbsent(agencyCode, () async {
      try {
        return await FirebaseStorage.instance
            .ref('config/AgencyLogos/$agencyCode.png')
            .getDownloadURL();
      } catch (_) {
        return null;
      }
    });
  }

  Widget _buildFallback() {
    return Text(
      fallbackText,
      style: GoogleFonts.kanit(
        fontWeight: FontWeight.bold,
        color: Colors.white,
        fontSize: 20,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _loadUrl(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // Give the logo a moment to load instead of flashing the bureau
          // name first.
          return SizedBox(height: height);
        }
        final url = snapshot.data;
        if (url == null) {
          return _buildFallback();
        }
        return Container(
       //   colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
          child: Image.network(
            url,
            height: height,
            width: width,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => _buildFallback(),
          ),
        );
      },
    );
  }
}
