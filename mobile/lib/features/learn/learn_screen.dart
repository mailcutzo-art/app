import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../common/coming_soon_tab.dart';

class LearnScreen extends StatelessWidget {
  const LearnScreen({super.key});

  @override
  Widget build(BuildContext context) => const ComingSoonTab(
    title: 'Learn',
    subtitle: 'Practice by subject and chapter.',
    icon: AppIcons.learn,
    tone: PastelTone.mint,
    message: 'Chapter practice, self challenge, bookmarks and word games arrive next.',
  );
}
