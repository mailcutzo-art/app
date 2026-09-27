import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../../app/shell.dart';

/// Placeholder body for tabs whose features land in later phases.
class ComingSoonTab extends StatelessWidget {
  const ComingSoonTab({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tone,
    required this.message,
  });

  final String title;
  final String subtitle;
  final HugeIconData icon;
  final PastelTone tone;
  final String message;

  @override
  Widget build(BuildContext context) {
    return TabPage(
      children: [
        LargeTitle(title: title, subtitle: subtitle),
        const SizedBox(height: AppSpacing.xxl),
        Gutter(
          child: SurfaceCard(
            child: EmptyState(icon: icon, tone: tone, title: 'Coming soon', message: message),
          ),
        ),
      ],
    );
  }
}
