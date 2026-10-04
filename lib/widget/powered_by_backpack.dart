import 'package:backend/config/design.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Discreet "Powered by BackPack" credit for the white-label control panel.
/// Lives at the foot of the sidebar so it's always present without
/// competing with the bureau's own logo up top, and links to the BackPack
/// website. The asset is an all-white logo (made for the dark login
/// backdrop), so it's tinted here to sit on the white sidebar.
class PoweredByBackpack extends StatelessWidget {
  const PoweredByBackpack({super.key, this.color});

  /// Tint for both the label and the logo — defaults to a muted grey.
  final Color? color;

  static final Uri _website = Uri.parse('https://backpack-app.dk');

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Colors.grey[600]!;
    return Semantics(
      link: true,
      label: 'Powered by BackPack',
      child: ExcludeSemantics(
        child: Tooltip(
          message: 'backpack-app.dk',
          child: InkWell(
            onTap: () =>
                launchUrl(_website, mode: LaunchMode.externalApplication),
            borderRadius: AppRadii.smRadius,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Powered by',
                    style: AppTextStyles.body(color: tint)
                        .copyWith(letterSpacing: 0.3),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Image.asset(
                    'assets/images/BackPack.png',
                    height: 22,
                    // The source is ~5800px wide; decode it at badge size
                    // instead.
                    cacheHeight: 88,
                    color: tint,
                    colorBlendMode: BlendMode.srcIn,
                    filterQuality: FilterQuality.medium,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
