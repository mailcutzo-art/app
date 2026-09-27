import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'gallery_scaffold.dart';

class FoundationsPage extends StatelessWidget {
  const FoundationsPage({super.key});

  static const _animated = [
    ('Bell', AppIcons.notification, IconMotions.bell),
    ('Bookmark', AppIcons.bookmark, IconMotions.bookmark),
    ('Check', AppIcons.check, IconMotions.check),
    ('Search', AppIcons.search, IconMotions.search),
    ('Settings', AppIcons.settings, IconMotions.settings),
    ('Trophy', AppIcons.arena, IconMotions.trophy),
    ('Timer', AppIcons.timer, IconMotions.timer),
    ('Flame', AppIcons.fire, IconMotions.flame),
    ('Home', AppIcons.home, IconMotions.home),
    ('Gamepad', AppIcons.battle, IconMotions.gamepad),
    ('Coins', AppIcons.coins, IconMotions.coins),
    ('Crown', AppIcons.crown, IconMotions.crown),
  ];

  static const _icons = [
    AppIcons.home,
    AppIcons.learn,
    AppIcons.battle,
    AppIcons.arena,
    AppIcons.social,
    AppIcons.physics,
    AppIcons.chemistry,
    AppIcons.biology,
    AppIcons.maths,
    AppIcons.allChapters,
    AppIcons.notification,
    AppIcons.search,
    AppIcons.bookmark,
    AppIcons.settings,
    AppIcons.share,
    AppIcons.timer,
    AppIcons.fire,
    AppIcons.coins,
    AppIcons.flash,
    AppIcons.crown,
    AppIcons.medal,
    AppIcons.target,
    AppIcons.brain,
    AppIcons.idea,
    AppIcons.robot,
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pastels = [
      ('Sky', colors.sky),
      ('Mint', colors.mint),
      ('Lemon', colors.lemon),
      ('Lavender', colors.lavender),
      ('Peach', colors.peach),
      ('Rose', colors.rose),
    ];
    return GalleryScaffold(
      title: 'Foundations',
      children: [
        DemoBlock(
          title: 'Brand',
          child: Row(
            children: [
              Expanded(
                child: _Swatch(name: 'Lime', color: colors.accent, on: colors.onAccent),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _Swatch(name: 'Ink', color: colors.inverse, on: colors.onInverse),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _Swatch(name: 'Paper', color: colors.paper, on: colors.ink, bordered: true),
              ),
            ],
          ),
        ),
        DemoBlock(
          title: 'Pastels',
          child: GridView.count(
            padding: EdgeInsets.zero,
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: AppSpacing.sm,
            crossAxisSpacing: AppSpacing.sm,
            childAspectRatio: 1.3,
            children: [
              for (final (name, pair) in pastels)
                _Swatch(name: name, color: pair.container, on: pair.onContainer),
            ],
          ),
        ),
        DemoBlock(
          title: 'Type · Plus Jakarta Sans',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Display 40', style: text.display),
              Text('Headline 32', style: text.headlineLarge),
              Text('Headline 26', style: text.headlineMedium),
              Text('Title 20', style: text.titleLarge),
              Text('Title 17', style: text.titleMedium),
              Text('Body 16 — questions and content', style: text.bodyLarge),
              Text('Body 14 — secondary text', style: text.bodyMedium),
              Text('Label 16 · buttons', style: text.labelLarge),
              Text('Caption 12', style: text.caption),
              Text('OVERLINE 11', style: text.overline),
              const SizedBox(height: AppSpacing.sm),
              Text('1,523 · 0:09 · #1,204', style: text.numericLarge),
              const SizedBox(height: AppSpacing.sm),
              QuizText(
                'H_2SO_4 · x^2 + y^2 · 20 m s^{-1} · λ = h/p · θ = 30° · **bold** *italic*',
                style: text.bodyLarge,
              ),
            ],
          ),
        ),
        DemoBlock(
          title: 'Icons · Hugeicons stroke rounded',
          child: Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.lg,
            children: [for (final icon in _icons) HugeIcon(icon, size: 26, color: colors.ink)],
          ),
        ),
        DemoBlock(
          title: 'Animated icons · tap to play',
          child: GridView.count(
            padding: EdgeInsets.zero,
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            children: [
              for (final (label, icon, motion) in _animated)
                Column(
                  children: [
                    AppIconButton(
                      icon: icon,
                      motion: motion,
                      semanticLabel: label,
                      variant: AppIconButtonVariant.tonal,
                      onPressed: () {},
                    ),
                    const SizedBox(height: 4),
                    Text(label, style: text.caption),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.name, required this.color, required this.on, this.bordered = false});

  final String name;
  final Color color;
  final Color on;
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final hex = '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
    return Container(
      height: 76,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: bordered ? Border.all(color: context.colors.outline) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(name, style: context.text.labelMedium.copyWith(color: on)),
          Text(hex, style: context.text.caption.copyWith(color: on)),
        ],
      ),
    );
  }
}
