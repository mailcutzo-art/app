import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../common/coming_soon_tab.dart';

class BattleScreen extends StatelessWidget {
  const BattleScreen({super.key});

  @override
  Widget build(BuildContext context) => const ComingSoonTab(
    title: 'Battle',
    subtitle: 'Pick a chapter, find an opponent, play live.',
    icon: AppIcons.battle,
    tone: PastelTone.sky,
    message: 'Live 1v1 battles, friend challenges and group battles are being built.',
  );
}
