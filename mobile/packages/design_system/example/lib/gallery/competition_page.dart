import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../mock_data.dart';
import 'gallery_scaffold.dart';

class CompetitionPage extends StatefulWidget {
  const CompetitionPage({super.key});

  @override
  State<CompetitionPage> createState() => _CompetitionPageState();
}

class _CompetitionPageState extends State<CompetitionPage> {
  int _coins = 250;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return GalleryScaffold(
      title: 'Competition',
      children: [
        DemoBlock(
          title: 'Tournament card',
          child: TournamentCard(
            title: 'Chemistry Open',
            description: 'Four Swiss rounds. Registration closes 5 minutes before start.',
            statusLabel: 'Registration open',
            subjectLabel: 'Chemistry',
            tone: PastelTone.lavender,
            rounds: 4,
            entryFee: 15,
            prizePool: 500,
            joined: 38,
            capacity: 100,
            ctaLabel: 'Join',
            onCta: () {},
          ),
        ),
        const DemoBlock(
          title: 'Podium',
          child: Podium(
            entries: [
              PodiumEntry(name: 'Riya', score: '5.5 pts', avatar: Mock.riya),
              PodiumEntry(name: 'Kabir', score: '5 pts', avatar: Mock.kabir),
              PodiumEntry(name: 'Zara', score: '4.5 pts', avatar: Mock.zara),
            ],
          ),
        ),
        const DemoBlock(
          title: 'Standings',
          child: Spaced(
            gap: AppSpacing.sm,
            children: [
              LeaderboardRow(
                rank: 1,
                name: 'Riya',
                subtitle: 'Buchholz 18.5',
                score: '5.5',
                avatar: Mock.riya,
              ),
              LeaderboardRow(
                rank: 2,
                name: 'Kabir',
                subtitle: 'Buchholz 17',
                score: '5',
                avatar: Mock.kabir,
              ),
              LeaderboardRow(
                rank: 3,
                name: 'Zara',
                subtitle: 'Buchholz 16.5',
                score: '4.5',
                avatar: Mock.zara,
              ),
              LeaderboardRow(
                rank: 14,
                name: 'Aarav',
                subtitle: 'Buchholz 12',
                score: '3',
                avatar: Mock.me,
                highlight: true,
              ),
            ],
          ),
        ),
        DemoBlock(
          title: 'Numbers · tap to add coins',
          child: Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _coins += 25),
                child: CoinAmount(amount: _coins, style: text.numericLarge, iconSize: 26),
              ),
              const Spacer(),
              const RatingDelta(delta: 18),
              const SizedBox(width: AppSpacing.sm),
              const RatingDelta(delta: -9),
            ],
          ),
        ),
        const DemoBlock(
          title: 'Progress',
          child: Spaced(
            children: [
              AppProgressBar(value: 0.64),
              SegmentedProgress(total: 3, completed: 2),
              SegmentedProgress(total: 7, completed: 4, height: 4),
            ],
          ),
        ),
        DemoBlock(
          title: 'Dot matrix chart · drag to explore',
          child: SurfaceCard(
            child: DotMatrixChart(
              values: Mock.weeklyActivity,
              initialIndex: 9,
              tooltipBuilder: (i, v) => 'Day ${i + 1} · ${v.round()} Qs',
            ),
          ),
        ),
      ],
    );
  }
}
