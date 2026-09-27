import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../mock_data.dart';

/// A live question just after the reveal: my wrong pick, the correct answer,
/// and where the opponent answered.
class QuestionMockScreen extends StatelessWidget {
  const QuestionMockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.md,
            AppSpacing.gutter,
            AppSpacing.xxl,
          ),
          children: [
            Row(
              children: [
                AppIconButton(
                  icon: AppIcons.close,
                  semanticLabel: 'Leave match',
                  onPressed: () => Navigator.maybePop(context),
                ),
                const Spacer(),
                const CountdownRing(progress: 0.2, label: '3', size: 56),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            const VersusHeader(
              me: VersusPlayer(name: 'You', avatar: Mock.me, score: 412, answered: true),
              opponent: VersusPlayer(name: 'Riya', avatar: Mock.riya, score: 538, answered: true),
              questionNumber: 4,
              total: 7,
            ),
            const SizedBox(height: AppSpacing.lg),
            const QuestionCard(
              number: 4,
              total: 7,
              tag: 'Kinematics',
              text: 'A car accelerates uniformly from rest to 20 m s^{-1} in 5 s. What is its acceleration?',
            ),
            const SizedBox(height: AppSpacing.lg),
            const AnswerOption(index: 0, text: '2 m s^{-2}', state: AnswerOptionState.dimmed),
            const SizedBox(height: AppSpacing.md),
            const AnswerOption(
              index: 1,
              text: '4 m s^{-2}',
              state: AnswerOptionState.correct,
              opponent: Mock.riya,
            ),
            const SizedBox(height: AppSpacing.md),
            const AnswerOption(index: 2, text: '5 m s^{-2}', state: AnswerOptionState.wrong),
            const SizedBox(height: AppSpacing.md),
            const AnswerOption(index: 3, text: '100 m s^{-2}', state: AnswerOptionState.dimmed),
            const SizedBox(height: AppSpacing.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final emote in const ['GG', 'Nice!', 'Wow', 'Oops']) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: AppChip(label: emote, selected: false, onSelected: (_) {}),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Center(
              child: Text(
                'Next question in 3 s',
                style: context.text.caption.copyWith(color: colors.inkMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
