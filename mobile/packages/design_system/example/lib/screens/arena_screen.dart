import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'tab_scaffold.dart';

class ArenaMockScreen extends StatefulWidget {
  const ArenaMockScreen({super.key});

  @override
  State<ArenaMockScreen> createState() => _ArenaMockScreenState();
}

class _ArenaMockScreenState extends State<ArenaMockScreen> {
  String _status = 'All';
  String _subject = 'All subjects';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget chips(List<(String, Color?)> options, String selected, ValueChanged<String> onSelect) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Row(
          children: [
            for (final (label, dot) in options) ...[
              AppChip(
                label: label,
                dotColor: dot,
                selected: selected == label,
                onSelected: (_) => onSelect(label),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
          ],
        ),
      );
    }

    return TabScaffold(
      selectedTab: 3,
      children: [
        LargeTitle(
          title: 'Tournaments',
          subtitle: 'Swiss format · live standings · coin prizes',
          trailing: AppIconButton(
            icon: AppIcons.filter,
            semanticLabel: 'Filters',
            onPressed: () {},
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        chips(
          const [
            ('All', null),
            ('Open', null),
            ('Live', null),
            ('Upcoming', null),
            ('Finished', null),
          ],
          _status,
          (v) => setState(() => _status = v),
        ),
        const SizedBox(height: AppSpacing.sm),
        chips(
          [
            ('All subjects', null),
            ('Physics', colors.sky.onContainer),
            ('Chemistry', colors.lavender.onContainer),
            ('Biology', colors.mint.onContainer),
            ('Maths', colors.peach.onContainer),
          ],
          _subject,
          (v) => setState(() => _subject = v),
        ),
        const SizedBox(height: AppSpacing.lg),
        Gutter(
          child: Column(
            children: [
              TournamentCard(
                title: 'Biology Night Arena',
                description: 'Four quick rounds on Biology. Standings update live.',
                live: true,
                statusLabel: 'Round 2 of 4',
                subjectLabel: 'Biology',
                tone: PastelTone.mint,
                rounds: 4,
                entryFee: 25,
                prizePool: 1000,
                joined: 31,
                capacity: 200,
                ctaLabel: 'Watch',
                primaryCta: false,
                onCta: () {},
              ),
              const SizedBox(height: AppSpacing.md),
              TournamentCard(
                title: 'All-India Arena Finals',
                description: 'Six Swiss rounds across every subject.',
                statusLabel: 'Registration open',
                subjectLabel: 'All subjects',
                rounds: 6,
                entryFee: 50,
                prizePool: 2500,
                joined: 142,
                capacity: 256,
                ctaLabel: 'Join',
                onCta: () {},
              ),
              const SizedBox(height: AppSpacing.md),
              TournamentCard(
                title: 'Physics Blitz',
                description: 'Three fast rounds for Physics practice.',
                statusLabel: 'Starts in 20 min',
                subjectLabel: 'Physics',
                tone: PastelTone.sky,
                rounds: 3,
                entryFee: 10,
                prizePool: 400,
                joined: 22,
                capacity: 64,
                ctaLabel: 'Join',
                onCta: () {},
              ),
              const SizedBox(height: AppSpacing.md),
              TournamentCard(
                title: 'JEE Weekend Cup',
                description: 'Free entry. Physics, Chemistry and Maths.',
                statusLabel: 'Sat, 7:00 PM',
                subjectLabel: 'JEE',
                tone: PastelTone.peach,
                rounds: 5,
                prizePool: 750,
                joined: 31,
                capacity: 128,
                ctaLabel: 'Join',
                onCta: () {},
              ),
            ],
          ),
        ),
      ],
    );
  }
}
