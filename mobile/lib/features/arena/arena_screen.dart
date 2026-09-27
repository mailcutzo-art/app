import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../common/coming_soon_tab.dart';

class ArenaScreen extends StatelessWidget {
  const ArenaScreen({super.key});

  @override
  Widget build(BuildContext context) => const ComingSoonTab(
    title: 'Tournaments',
    subtitle: 'Swiss format · live standings · coin prizes',
    icon: AppIcons.arena,
    tone: PastelTone.lemon,
    message: 'Scheduled Swiss tournaments with live standings are on the way.',
  );
}
