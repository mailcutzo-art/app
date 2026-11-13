import 'package:flutter/material.dart';

const appName = 'PrepCue';
const appLogoAsset = 'assets/branding/prepcue-logo.png';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 48, this.semanticLabel = appName});

  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.asset(
        appLogoAsset,
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        semanticLabel: semanticLabel,
        excludeFromSemantics: semanticLabel == null,
      ),
    );
  }
}
