import 'dart:async';

import 'package:clock/clock.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../app/router.dart';
import '../../app/shell.dart';
import '../../core/auth/session.dart';
import '../../core/auth/user.dart';
import '../../core/network/connectivity.dart';
import '../../core/realtime/live_providers.dart';
import '../../core/realtime/live_text.dart';
import '../../core/realtime/search_state.dart';
import '../learn/widgets/learn_widgets.dart' show failureMessage, subjectTone;
import '../rooms/data/room_models.dart' show RoomKind;
import '../rooms/rooms_controller.dart' show roomViewProvider, roomsControllerProvider;
import 'battle_selection.dart';
import 'chapter_picker.dart';
import 'data/battle_models.dart';
import 'data/battle_repository.dart';

/// "3 players searching · usually 20 s".
String onlineLine(OnlineStat? stat) {
  if (stat == null) return 'Opponents are matched by rating';
  final who = stat.searching == 1 ? '1 player searching' : '${stat.searching} players searching';
  final wait = stat.p50WaitS;
  return wait == null ? who : '$who · usually $wait s';
}

/// "Physics this week: Riya leads · you're #12". Null when there's nothing to say.
String? leaderLine(String subjectName, SubjectLeaders? leaders) {
  if (leaders == null) return null;
  final position = leaders.myPosition;
  final name = leaders.leaderName;
  if (leaders.leaderIsMe) return '$subjectName this week: you lead!';
  final parts = [if (name != null) '$name leads', if (position != null) 'you\'re #$position'];
  return parts.isEmpty ? null : '$subjectName this week: ${parts.join(' · ')}';
}

/// Where "Go there" leads for something the user is already in.
String activeRoute(BattleActive active) {
  final route = active.route;
  if (route != null) {
    if (route.startsWith('/rooms/')) {
      return Routes.room(route.substring('/rooms/'.length));
    }
    return route;
  }
  final id = active.id;
  return switch (active.kind) {
    'match' when id != null => Routes.battleMatch(id),
    'queue' => Routes.battleSearch,
    'tournament' when id != null => '${Routes.arena}?t=${Uri.encodeQueryComponent(id)}',
    'tournament' => Routes.arena,
    'room' when id != null => Routes.room(id),
    _ => Routes.battle,
  };
}

/// What the user is in, for the line above "Go there".
String activeLine(BattleActive active) {
  final what = switch (active.kind) {
    'match' => 'You\'re in a match',
    'queue' => 'You\'re searching for a match',
    'room' => 'You\'re in a room',
    'tournament' => 'Your tournament starts soon',
    _ => 'You\'re in another game',
  };
  final title = active.title;
  return title == null ? what : '$what · $title';
}

/// The Battle tab: choose a subject, chapter and mode, then find an opponent or play the
/// Practice Bot.
class BattleScreen extends ConsumerWidget {
  const BattleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final goal = me.goal ?? Goal.neet;
    final online = ref.watch(isOnlineProvider);
    final query = GoRouterState.of(context).uri.queryParameters;

    // A section that failed loads again by itself when the connection is back.
    ref.listen(isOnlineProvider, (wasOnline, online) {
      if (online && wasOnline == false && ref.read(battleSetupProvider(goal)).hasError) {
        ref.invalidate(battleSetupProvider(goal));
      }
    });

    return TabPage(
      onRefresh: () async {
        ref.invalidate(battleSetupProvider(goal));
        try {
          await ref.read(battleSetupProvider(goal).future);
        } on Object {
          // The section shows its own error.
        }
      },
      children: [
        OfflineBanner(visible: !online, message: 'You\'re offline · battles need a connection'),
        LargeTitle(
          title: 'Battle',
          subtitle: 'Pick a chapter, find an opponent, play live.',
          trailing: Pressable(
            onPressed: () => context.push(Routes.profile),
            semanticLabel: 'Your profile',
            child: AppAvatar(data: me.avatar.toData(), ring: true),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Gutter(
          child: _QuickBattleSection(
            goal: goal,
            preset: (subject: query['subject'], chapter: query['chapter']),
          ),
        ),
        const SectionHeader(title: 'More ways to play'),
        const Gutter(child: _MoreWays()),
      ],
    );
  }
}

typedef _Preset = ({String? subject, String? chapter});

class _QuickBattleSection extends ConsumerWidget {
  const _QuickBattleSection({required this.goal, required this.preset});

  final Goal goal;
  final _Preset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setup = ref.watch(battleSetupProvider(goal));
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.medium),
      child: switch (setup) {
        AsyncValue(:final value?) when value.subjects.isEmpty => SurfaceCard(
          key: const ValueKey('empty'),
          child: EmptyState(
            icon: AppIcons.battle,
            title: 'No battles yet',
            message: 'Battles for ${goal.label} are on the way.',
          ),
        ),
        AsyncValue(:final value?) => _QuickBattleCard(
          key: const ValueKey('card'),
          goal: goal,
          setup: value,
          preset: preset,
        ),
        AsyncValue(:final error?) => ErrorState(
          key: const ValueKey('error'),
          compact: true,
          title: 'Couldn\'t load battles',
          message: failureMessage(error),
          retrying: setup.isLoading,
          onRetry: () => ref.invalidate(battleSetupProvider(goal)),
        ),
        _ => const _QuickBattleSkeleton(key: ValueKey('loading')),
      },
    );
  }
}

class _QuickBattleCard extends ConsumerStatefulWidget {
  const _QuickBattleCard({
    super.key,
    required this.goal,
    required this.setup,
    required this.preset,
  });

  final Goal goal;
  final BattleSetup setup;
  final _Preset preset;

  @override
  ConsumerState<_QuickBattleCard> createState() => _QuickBattleCardState();
}

class _QuickBattleCardState extends ConsumerState<_QuickBattleCard> {
  BattleMode? _joining;
  String? _error;
  _Preset? _applied;

  BattleSetup get _setup => widget.setup;

  @override
  void initState() {
    super.initState();
    _applyPreset();
  }

  @override
  void didUpdateWidget(covariant _QuickBattleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _applyPreset();
  }

  /// A coach tip can open the tab on a subject and chapter.
  void _applyPreset() {
    final preset = widget.preset;
    if (preset.subject == null || preset == _applied) return;
    _applied = preset;
    final subject = _setup.subject(preset.subject);
    if (subject == null) return;
    final current = resolveSelection(_setup, ref.read(battleSelectionProvider));
    final chapter = subject.chapter(preset.chapter);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(battleSelectionProvider.notifier)
          .pick(
            current.copyWith(
              subject: subject.slug,
              chapter: chapter != null && chapter.battleReady ? chapter.slug : null,
            ),
          );
    });
  }

  void _pick(BattleSelection selection) {
    setState(() => _error = null);
    ref.read(battleSelectionProvider.notifier).pick(selection);
  }

  Future<void> _chooseChapter(BattleSelection selection, BattleSubject subject) async {
    final choice = await showChapterPicker(context, subject: subject, selected: selection.chapter);
    if (choice == null || !mounted) return;
    _pick(selection.copyWith(chapter: choice.chapter));
  }

  Future<void> _play(BattleSelection selection, BattleSubject subject, BattleMode mode) async {
    final live = ref.read(liveControllerProvider);
    if (live == null) {
      showAppToast(context, 'Still connecting. Try again in a moment.', icon: AppIcons.info);
      return;
    }
    final chapter = subject.chapter(selection.chapter);
    final stat = _setup.online[subject.slug];
    setState(() {
      _joining = mode;
      _error = null;
    });
    try {
      await live.join(
        SearchRequest(
          mode: mode.wire,
          subject: subject.slug,
          chapter: chapter?.slug,
          subjectName: subject.name,
          chapterName: chapter?.name,
        ),
        online: stat?.searching,
        p50WaitS: stat?.p50WaitS,
      );
      // A Practice Bot game opens by itself; a search shows the search screen.
      if (mounted && mode != BattleMode.bot) unawaited(context.push(Routes.battleSearch));
    } on RealtimeError catch (error) {
      if (!mounted) return;
      if (error.code == RealtimeErrorCode.cooldown) {
        ref.invalidate(battleSetupProvider(widget.goal));
      }
      // BUSY shows "Go there" on the live layer.
      if (error.code != RealtimeErrorCode.busy) setState(() => _error = LiveText.joinError(error));
    } finally {
      if (mounted) setState(() => _joining = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final setup = _setup;
    final selection = resolveSelection(setup, ref.watch(battleSelectionProvider));
    final subject = setup.subject(selection.subject)!;
    final chapter = subject.chapter(selection.chapter);
    final online = ref.watch(isOnlineProvider);
    final searching = ref.watch(searchProvider.select((s) => s.isSearching));
    final canAffordCasual = setup.canAffordCasual;
    final leader = leaderLine(subject.name, setup.leaders[subject.slug]);
    final busy = _joining != null;

    return SurfaceCard(
      elevated: true,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4, top: 2),
                  child: Text('Quick battle', style: text.titleLarge),
                ),
              ),
              _RatingBadge(subject: subject),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final s in setup.subjects)
                AppChip(
                  label: s.name,
                  dotColor: colors.pastel(subjectTone(s.tone)).onContainer,
                  selected: s.slug == subject.slug,
                  onSelected: busy
                      ? null
                      : (_) => _pick(selection.copyWith(subject: s.slug, chapter: null)),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _ChapterField(
            name: chapter?.name ?? 'All chapters',
            onTap: busy ? null : () => _chooseChapter(selection, subject),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSegmentedControl<BattleMode>(
            segments: [
              const AppSegment(value: BattleMode.rated, label: 'Rated', icon: AppIcons.flash),
              AppSegment(
                value: BattleMode.casual,
                label: 'Casual',
                icon: AppIcons.coins,
                enabled: canAffordCasual,
              ),
            ],
            selected: selection.mode,
            onChanged: busy ? null : (mode) => _pick(selection.copyWith(mode: mode)),
          ),
          const SizedBox(height: AppSpacing.sm),
          _ModeNote(mode: selection.mode, setup: setup, subject: subject),
          const SizedBox(height: AppSpacing.lg),
          _InfoLine(icon: AppIcons.social, text: onlineLine(setup.online[subject.slug])),
          if (leader != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _InfoLine(icon: AppIcons.crown, text: leader),
          ],
          const SizedBox(height: AppSpacing.xl),
          if (setup.active case final active?) ...[
            Text(activeLine(active), style: text.labelMedium, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Go there',
              variant: AppButtonVariant.ink,
              trailingIcon: AppIcons.chevronRight,
              onPressed: () => context.go(activeRoute(active)),
            ),
            if (active.kind == 'room') ...[
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Leave room',
                variant: AppButtonVariant.ghost,
                leadingIcon: AppIcons.logout,
                onPressed: () async {
                  await ref.read(roomsControllerProvider)?.leave();
                  ref.invalidate(battleSetupProvider(widget.goal));
                },
              ),
            ],
          ] else if (searching)
            AppButton(
              label: 'Back to your search',
              trailingIcon: AppIcons.search,
              onPressed: () => context.push(Routes.battleSearch),
            )
          else if (setup.cooldownUntil case final until? when until.isAfter(clock.now()))
            _CooldownButton(
              until: until,
              onDone: () => ref.invalidate(battleSetupProvider(widget.goal)),
            )
          else
            AppButton(
              label: 'Find opponent',
              trailingIcon: AppIcons.search,
              loading: _joining == BattleMode.rated || _joining == BattleMode.casual,
              onPressed: online && !busy ? () => _play(selection, subject, selection.mode) : null,
            ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Practice vs Bot',
            variant: AppButtonVariant.secondary,
            leadingIcon: AppIcons.robot,
            loading: _joining == BattleMode.bot,
            onPressed: online && !busy && setup.active == null
                ? () => _play(selection, subject, BattleMode.bot)
                : null,
          ),
          if (!online) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'You\'re offline. Connect to play live.',
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
          if (_error case final error?) ...[
            const SizedBox(height: AppSpacing.md),
            _InlineError(message: error),
          ],
        ],
      ),
    );
  }
}

class _RatingBadge extends StatelessWidget {
  const _RatingBadge({required this.subject});

  final BattleSubject subject;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final rating = subject.rating;
    return Semantics(
      label: '${subject.name} rating ${rating.isNew ? 'not set yet' : rating.display}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(rating.display, style: text.numericMedium),
          Text(
            rating.isNew ? 'New · ${subject.name}' : '${subject.name} rating',
            style: text.caption,
          ),
        ],
      ),
    );
  }
}

class _ChapterField extends StatelessWidget {
  const _ChapterField({required this.name, required this.onTap});

  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    return Pressable(
      onPressed: onTap,
      semanticLabel: 'Chapter: $name. Change',
      pressedScale: 0.98,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 14),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadii.lg),
        ),
        child: Row(
          children: [
            HugeIcon(AppIcons.learn, size: 20, color: colors.inkMuted),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Chapter', style: text.caption),
                  Text(name, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            HugeIcon(AppIcons.chevronDown, size: 20, color: colors.ink),
          ],
        ),
      ),
    );
  }
}

class _ModeNote extends StatelessWidget {
  const _ModeNote({required this.mode, required this.setup, required this.subject});

  final BattleMode mode;
  final BattleSetup setup;
  final BattleSubject subject;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final coins = setup.coins;
    if (!setup.canAffordCasual) {
      return Row(
        children: [
          Expanded(
            child: Text(
              mode == BattleMode.rated
                  ? 'Free · changes your ${subject.name} rating'
                  : 'Casual costs ${setup.casualFee} coins',
              style: text.bodySmall,
            ),
          ),
          InfoChip(
            icon: AppIcons.coins,
            iconColor: colors.coin,
            label: 'Earn coins from missions',
            background: colors.warningContainer,
            foreground: colors.onWarningContainer,
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            mode == BattleMode.rated
                ? 'Free · changes your ${subject.name} rating'
                : '${setup.casualFee} coins to enter · winner takes ${setup.casualFee * 2}',
            style: text.bodySmall,
          ),
        ),
        if (coins != null) ...[
          const SizedBox(width: AppSpacing.sm),
          Semantics(
            label: 'You have ${formatCount(coins)} coins',
            excludeSemantics: true,
            child: CoinAmount(amount: coins, style: text.labelMedium, iconSize: 16),
          ),
        ],
      ],
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text});

  final HugeIconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        HugeIcon(icon, size: 18, color: colors.inkMuted),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(text, style: context.text.bodySmall)),
      ],
    );
  }
}

/// "Try again in 4:32", counting down, while queueing is blocked.
class _CooldownButton extends StatefulWidget {
  const _CooldownButton({required this.until, required this.onDone});

  final DateTime until;
  final VoidCallback onDone;

  @override
  State<_CooldownButton> createState() => _CooldownButtonState();
}

class _CooldownButtonState extends State<_CooldownButton> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    if (!widget.until.isAfter(clock.now())) {
      _ticker?.cancel();
      widget.onDone();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.until.difference(clock.now());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Too many cancelled matches',
          style: context.text.labelMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(label: 'Try again in ${LiveText.mmss(left)}', onPressed: null),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            HugeIcon(AppIcons.alert, size: 20, color: colors.onErrorContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: context.text.labelMedium.copyWith(color: colors.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Play with Friend, Group Battle, and joining a room by code.
class _MoreWays extends ConsumerWidget {
  const _MoreWays();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final room = ref.watch(roomViewProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (room != null && room.state.isKnown && !room.state.status.isGone) ...[
          ListRowCard(
            title: 'Back to your room',
            subtitle: '${room.kind.label} · code ${room.state.code ?? ''}',
            leading: const HugeIcon(AppIcons.userAdd, size: 22),
            trailing: const HugeIcon(AppIcons.chevronRight, size: 20),
            onTap: () => context.push(room.route),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Row(
          children: [
            Expanded(
              child: PastelTile(
                tone: PastelTone.lavender,
                icon: AppIcons.userAdd,
                title: 'Play a friend',
                subtitle: 'Private 1v1',
                onTap: () => context.push(Routes.roomSetup(RoomKind.friend.wire)),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: PastelTile(
                tone: PastelTone.peach,
                icon: AppIcons.social,
                title: 'Group battle',
                subtitle: '2–8 players',
                onTap: () => context.push(Routes.roomSetup(RoomKind.group.wire)),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton(
          label: 'Join with code',
          variant: AppButtonVariant.secondary,
          leadingIcon: AppIcons.grid,
          onPressed: () => context.push(Routes.joinRoom()),
        ),
      ],
    );
  }
}

class _QuickBattleSkeleton extends StatelessWidget {
  const _QuickBattleSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Shimmer(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SkeletonBox(height: 28, width: 160),
        SizedBox(height: AppSpacing.md),
        SkeletonBox(height: AppSizes.chip, radius: AppRadii.pill),
        SizedBox(height: AppSpacing.lg),
        SkeletonBox(height: 64, radius: AppRadii.lg),
        SizedBox(height: AppSpacing.lg),
        SkeletonBox(height: AppSizes.buttonMedium, radius: AppRadii.pill),
        SizedBox(height: AppSpacing.xl),
        SkeletonBox(height: AppSizes.buttonLarge, radius: AppRadii.pill),
        SizedBox(height: AppSpacing.sm),
        SkeletonBox(height: AppSizes.buttonLarge, radius: AppRadii.pill),
      ],
    ),
  );
}
