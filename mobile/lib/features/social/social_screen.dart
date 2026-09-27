import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../common/coming_soon_tab.dart';

class SocialScreen extends StatelessWidget {
  const SocialScreen({super.key});

  @override
  Widget build(BuildContext context) => const ComingSoonTab(
    title: 'Social',
    subtitle: 'Friends, rivals and challenges.',
    icon: AppIcons.social,
    tone: PastelTone.lavender,
    message: 'Add friends, see your rivals and challenge them to a battle.',
  );
}
