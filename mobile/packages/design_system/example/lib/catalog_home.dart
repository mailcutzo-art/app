import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'gallery/cards_page.dart';
import 'gallery/competition_page.dart';
import 'gallery/controls_page.dart';
import 'gallery/feedback_page.dart';
import 'gallery/foundations_page.dart';
import 'gallery/quiz_page.dart';
import 'main.dart';
import 'screens/arena_screen.dart';
import 'screens/battle_screen.dart';
import 'screens/home_screen.dart';
import 'screens/learn_screen.dart';
import 'screens/matchmaking_screen.dart';
import 'screens/question_screen.dart';

class CatalogHome extends StatelessWidget {
  const CatalogHome({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = ThemeModeScope.of(context);
    final dark = scope.mode == ThemeMode.dark;

    void open(Widget page) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

    final sections = [
      (
        PastelTone.lavender,
        AppIcons.sparkles,
        'Foundations',
        'Color, type, icons',
        const FoundationsPage(),
      ),
      (PastelTone.sky, AppIcons.grid, 'Controls', 'Buttons, chips, inputs', const ControlsPage()),
      (PastelTone.mint, AppIcons.checklist, 'Cards', 'Tiles, rows, avatars', const CardsPage()),
      (PastelTone.lemon, AppIcons.quiz, 'Quiz', 'Questions, answers, timer', const QuizPage()),
      (
        PastelTone.peach,
        AppIcons.arena,
        'Competition',
        'Tournaments, ranks',
        const CompetitionPage(),
      ),
      (PastelTone.rose, AppIcons.alert, 'Feedback', 'Empty, error, loading', const FeedbackPage()),
    ];

    final screens = [
      (AppIcons.home, 'Home', const HomeMockScreen()),
      (AppIcons.learn, 'Learn', const LearnMockScreen()),
      (AppIcons.battle, 'Battle', const BattleMockScreen()),
      (AppIcons.search, 'Matchmaking', const MatchmakingMockScreen()),
      (AppIcons.quiz, 'Live question', const QuestionMockScreen()),
      (AppIcons.arena, 'Arena', const ArenaMockScreen()),
    ];

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.huge),
          children: [
            LargeTitle(
              title: 'Design system',
              subtitle: 'Pastel · minimal · rounded',
              trailing: AppIconButton(
                icon: dark ? AppIcons.sun : AppIcons.moon,
                semanticLabel: dark ? 'Light theme' : 'Dark theme',
                motion: IconMotions.sparkle,
                onPressed: scope.toggle,
              ),
            ),
            const SectionHeader(title: 'Components'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: GridView.count(
                padding: EdgeInsets.zero,
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: AppSpacing.md,
                crossAxisSpacing: AppSpacing.md,
                childAspectRatio: 1.05,
                children: [
                  for (final (tone, icon, title, subtitle, page) in sections)
                    PastelTile(
                      tone: tone,
                      icon: icon,
                      title: title,
                      subtitle: subtitle,
                      onTap: () => open(page),
                    ),
                ],
              ),
            ),
            const SectionHeader(
              title: 'Mock screens',
              subtitle: 'Built only from these components',
            ),
            for (final (icon, title, page) in screens)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  0,
                  AppSpacing.gutter,
                  AppSpacing.sm,
                ),
                child: ListRowCard(
                  title: title,
                  leading: Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.colors.surfaceMuted,
                      shape: BoxShape.circle,
                    ),
                    child: HugeIcon(icon, size: 22, color: context.colors.ink),
                  ),
                  trailing: HugeIcon(
                    AppIcons.chevronRight,
                    size: 20,
                    color: context.colors.inkMuted,
                  ),
                  onTap: () => open(page),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
