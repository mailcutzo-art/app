import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart';
import '../../core/auth/session.dart';
import '../../core/network/connectivity.dart';
import '../../core/utils/time_text.dart';
import '../inbox/inbox_bell.dart';
import '../leaderboards/leaderboards.dart';
import '../learn/widgets/learn_widgets.dart';
import '../missions/missions.dart';
import 'data/home_models.dart';
import 'home_providers.dart';

/// Home: the headline stats, ways to play, what to continue, today's
/// missions, a coach tip, the weekly leaders and the next tournament, all
/// from `GET /v1/home`. Each section loads and fails on its own.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// The answer whose welcome bonus was already celebrated.
  HomeFeed? _welcomed;

  @override
  void initState() {
    super.initState();
    ref.listenManual(homeProvider, (_, next) {
      final feed = next.value;
      if (feed == null || feed.welcomeCoins == null || identical(feed, _welcomed)) return;
      _welcomed = feed;
      final coins = feed.welcomeCoins!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(showWelcomeSheet(context, coins: coins));
      });
    }, fireImmediately: true);
  }

  Future<void> _refresh() async {
    ref.invalidate(homeProvider);
    await Future.wait([
      ref.read(sessionProvider.notifier).refreshUser(),
      ref
          .read(homeProvider.future)
          .then<void>(
            (_) {},
            onError: (Object _) {
              // Each section shows its own error.
            },
          ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final offline = switch (ref.watch(sessionProvider).value) {
      SignedIn(:final offline) => offline,
      _ => false,
    };
    final home = ref.watch(homeProvider);
    final firstName = me.displayName.split(' ').first;

    // Home loads again by itself when the connection is back.
    ref.listen(isOnlineProvider, (wasOnline, online) {
      if (online && wasOnline == false && ref.read(homeProvider).hasError) {
        ref.invalidate(homeProvider);
      }
    });

    final banner = home.value?.maintenanceBanner;
    return TabPage(
      onRefresh: _refresh,
      children: [
        OfflineBanner(visible: offline),
        GreetingHeader(
          avatar: AppAvatar(data: me.avatar.toData(), ring: true, semanticLabel: 'Your avatar'),
          greeting: 'Hi, $firstName!',
          subtitle: [
            if (me.goal != null) me.goal!.label,
            if (me.handle != null) '@${me.handle}',
          ].join(' · '),
          onAvatarTap: () => context.push(Routes.profile),
          actions: [
            AppIconButton(
              icon: AppIcons.arena,
              semanticLabel: 'Leaderboards',
              motion: IconMotions.trophy,
              onPressed: () => context.push(Routes.leaderboards),
            ),
            const InboxBell(),
          ],
        ),
        if (banner != null) ...[
          const SizedBox(height: AppSpacing.lg),
          Gutter(child: _MaintenanceBanner(message: banner)),
        ],
        const SizedBox(height: AppSpacing.xl),
        Gutter(child: _Hero(home: home)),
        _Optional(
          home: home,
          pick: (f) => f.live,
          builder: (live) => Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.lg,
              AppSpacing.gutter,
              0,
            ),
            child: _LiveCard(live: live),
          ),
        ),
        const SectionHeader(title: 'Play'),
        const Gutter(child: _BattleTiles()),
        _Section(
          home: home,
          pick: (f) => f.continuePractice,
          errorTitle: 'Couldn\'t load your practice',
          skeleton: const CardSkeleton(height: 120),
          builder: (practice) => practice == null
              ? null
              : ContinuePracticeCard(
                  practice: practice,
                  onResume: () => context.push(Routes.practiceSession(practice.sessionId)),
                ),
        ),
        const SectionHeader(title: 'Today\'s missions'),
        _Section(
          home: home,
          pick: (f) => f.missions,
          errorTitle: 'Couldn\'t load today\'s missions',
          skeleton: const CardSkeleton(height: 260),
          padded: false,
          builder: (missions) => missions.items.isEmpty
              ? const SurfaceCard(
                  child: EmptyState(
                    icon: AppIcons.target,
                    tone: PastelTone.lemon,
                    title: 'No missions today',
                    message: 'New missions arrive at midnight.',
                  ),
                )
              : MissionsCard(missions: missions),
        ),
        _Section(
          home: home,
          pick: (f) => f.tip,
          errorTitle: 'Couldn\'t load your coach tip',
          skeleton: const CardSkeleton(height: 120),
          header: 'Coach tip',
          builder: (tip) => tip == null ? null : CoachTipCard(tip: tip),
        ),
        _Section(
          home: home,
          pick: (f) => f.leaders,
          errorTitle: 'Couldn\'t load the leaders',
          skeleton: const CardSkeleton(height: 220),
          header: 'Leaders this week',
          headerAction: ('See all', () => context.push(Routes.board('weekly_xp'))),
          builder: (leaders) => _LeadersCard(leaders: leaders, myId: me.id),
        ),
        _Section(
          home: home,
          pick: (f) => f.tournament,
          errorTitle: 'Couldn\'t load tournaments',
          skeleton: const CardSkeleton(height: 120),
          header: 'Next tournament',
          builder: (tournament) =>
              tournament == null ? null : _TournamentCard(tournament: tournament),
        ),
      ],
    );
  }
}

void _retry(WidgetRef ref) => ref.invalidate(homeProvider);

/// One Home section: a skeleton while Home loads, its content, or an error
/// with a retry when the server couldn't build it. A builder returning null
/// hides the section (and its header), e.g. nothing to continue.
class _Section<T> extends ConsumerWidget {
  const _Section({
    super.key,
    required this.home,
    required this.pick,
    required this.errorTitle,
    required this.skeleton,
    required this.builder,
    this.header,
    this.headerAction,
    this.padded = true,
  });

  final AsyncValue<HomeFeed> home;
  final HomeSection<T> Function(HomeFeed feed) pick;
  final String errorTitle;
  final Widget skeleton;
  final Widget? Function(T data) builder;
  final String? header;
  final (String, VoidCallback)? headerAction;

  /// Adds space above when there's no header.
  final bool padded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Widget? body = switch (home) {
      AsyncValue(:final value?) => switch (pick(value)) {
        SectionOk(:final value) => builder(value),
        SectionFailed() => ErrorState(
          compact: true,
          title: errorTitle,
          message: 'Something went wrong on our side. Try again.',
          retrying: home.isLoading,
          onRetry: () => _retry(ref),
        ),
      },
      // The hero shows why Home failed as a whole.
      AsyncValue(hasError: true) => null,
      _ => skeleton,
    };
    if (body == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null)
          SectionHeader(title: header!, actionLabel: headerAction?.$1, onAction: headerAction?.$2)
        else if (padded)
          const SizedBox(height: AppSpacing.lg),
        Gutter(child: body),
      ],
    );
  }
}

/// A section that is simply absent while loading or when it fails (the live
/// banner layer covers the same things).
class _Optional<T> extends StatelessWidget {
  const _Optional({required this.home, required this.pick, required this.builder});

  final AsyncValue<HomeFeed> home;
  final HomeSection<T?> Function(HomeFeed feed) pick;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) {
    final data = home.value == null ? null : pick(home.value!).data;
    return data == null ? const SizedBox.shrink() : builder(data);
  }
}

class _Hero extends ConsumerWidget {
  const _Hero({required this.home});

  final AsyncValue<HomeFeed> home;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (home) {
      AsyncValue(:final value?) => switch (value.hero) {
        SectionOk(value: final hero) => _HeroCard(hero: hero, streak: value.missions.data?.streak),
        SectionFailed() => ErrorState(
          compact: true,
          title: 'Couldn\'t load your stats',
          message: 'Something went wrong on our side. Try again.',
          retrying: home.isLoading,
          onRetry: () => _retry(ref),
        ),
      },
      AsyncValue(:final error?) => ErrorState(
        compact: true,
        title: 'Couldn\'t load Home',
        message: failureMessage(error),
        retrying: home.isLoading,
        onRetry: () => _retry(ref),
      ),
      _ => const CardSkeleton(height: 280),
    };
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.hero, required this.streak});

  final HomeHero hero;
  final StreakSummary? streak;

  @override
  Widget build(BuildContext context) {
    final rank = hero.rank;
    final games = rank.gamesToRank;
    final level = hero.level;
    final caption = switch ((rank.position, games)) {
      (null, final games?) when games > 0 =>
        'Play $games more rated ${games == 1 ? 'game' : 'games'} to get ranked',
      (final position?, _) => 'Ranked #${formatCount(position)} overall',
      _ when hero.rating.provisional => 'Your rating settles as you play rated games',
      _ => null,
    };
    return HeroStatCard(
      label: 'Rating',
      trailing: AppIconButton(
        icon: AppIcons.info,
        size: 32,
        variant: AppIconButtonVariant.ghost,
        semanticLabel: 'About rating',
        onPressed: () => _showRatingInfo(context),
      ),
      value: Text(hero.rating.display),
      caption: caption,
      stats: [
        HeroStat(
          label: 'Global rank',
          value: rank.position == null ? '—' : '#${formatCount(rank.position!)}',
          onTap: () => unawaited(context.push(Routes.board(rank.board))),
        ),
        HeroStat(
          label: 'Coins',
          value: formatCount(hero.coins),
          icon: AppIcons.coins,
          onTap: () => unawaited(context.push(Routes.wallet)),
        ),
        if (streak != null)
          HeroStat(
            label: 'Streak',
            value: '${streak!.days} ${streak!.days == 1 ? 'day' : 'days'}',
            icon: AppIcons.fire,
            onTap: () => unawaited(context.push(Routes.streak)),
          )
        else if (level != null)
          HeroStat(label: 'Level', value: '${level.level}', icon: AppIcons.star),
      ],
      actions: [
        HeroAction(label: 'Play', icon: AppIcons.battle, onTap: () => context.go(Routes.battle)),
        HeroAction(label: 'Practice', icon: AppIcons.learn, onTap: () => context.go(Routes.learn)),
        HeroAction(label: 'Arena', icon: AppIcons.arena, onTap: () => context.go(Routes.arena)),
      ],
    );
  }
}

void _showRatingInfo(BuildContext context) {
  showAppSheet<void>(
    context,
    builder: (context) => SheetScaffold(
      title: 'About Rating',
      subtitle: 'Your competitive skill score in Quiz Arena',
      footer: AppButton(
        label: 'Got it',
        onPressed: () => Navigator.pop(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '• All players start at 1,500 rating points.\n'
            '• Winning rated games increases your rating; losing decreases it.\n'
            '• The "?" mark indicates a provisional rating while you are in placement matches.\n'
            '• Play 10 rated games to settle your rating and unlock your global rank.',
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    ),
  );
}

/// Play 1v1, with a friend, or in a group: all set up on the Battle tab.
class _BattleTiles extends StatelessWidget {
  const _BattleTiles();

  @override
  Widget build(BuildContext context) {
    void battle() => context.go(Routes.battle);
    return Column(
      children: [
        PastelTile(
          tone: PastelTone.sky,
          icon: AppIcons.battle,
          title: 'Play 1v1',
          subtitle: 'Find an opponent now',
          onTap: battle,
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: PastelTile(
                tone: PastelTone.lavender,
                icon: AppIcons.userAdd,
                title: 'Play with Friend',
                subtitle: 'Private 1v1',
                onTap: () => context.push(Routes.roomSetup('friend')),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: PastelTile(
                tone: PastelTone.peach,
                icon: AppIcons.social,
                title: 'Group Battle',
                subtitle: '2–8 players',
                onTap: () => context.push(Routes.roomSetup('group')),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _LiveCard extends StatelessWidget {
  const _LiveCard({required this.live});

  final HomeLive live;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final what = switch ((live.kind, live.state)) {
      ('tournament', 'check_in') => 'Check in for your tournament',
      ('tournament', _) => 'Your tournament is live',
      ('match', _) => 'You\'re in a match',
      ('queue' || 'search', _) => 'You\'re searching for a match',
      ('room', _) => 'You\'re in a room',
      _ => 'Something needs you',
    };
    final action = live.action;
    return SurfaceCard(
      color: colors.mint.container,
      bordered: false,
      padding: const EdgeInsets.all(AppSpacing.lg),
      onTap: action == null ? null : () => openAction(context, action),
      semanticLabel: what,
      child: Row(
        children: [
          HugeIcon(AppIcons.flash, size: 24, color: colors.mint.onContainer),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(what, style: text.titleMedium),
                if (live.title != null) Text(live.title!, style: text.bodySmall),
              ],
            ),
          ),
          if (action != null) HugeIcon(AppIcons.chevronRight, size: 20, color: colors.inkMuted),
        ],
      ),
    );
  }
}

class _LeadersCard extends StatelessWidget {
  const _LeadersCard({required this.leaders, required this.myId});

  final HomeLeaders leaders;
  final String myId;

  @override
  Widget build(BuildContext context) {
    final me = leaders.me;
    final meInTop = me != null && leaders.top.any((row) => row.user.id == me.user.id);
    void open() => unawaited(context.push(Routes.board(leaders.board)));
    if (leaders.top.isEmpty) {
      return const SurfaceCard(
        child: EmptyState(
          icon: AppIcons.crown,
          tone: PastelTone.lemon,
          title: 'No leaders yet this week',
          message: 'Earn XP in practice and battles to top the board.',
        ),
      );
    }
    return Column(
      children: [
        for (final (index, row) in leaders.top.indexed) ...[
          if (index > 0) const SizedBox(height: AppSpacing.sm),
          BoardRowTile(
            row: row,
            mine: isMine(row, myId) || row.user.id == me?.user.id,
            onTap: open,
          ),
        ],
        if (me != null && !meInTop) ...[
          if (leaders.top.isNotEmpty) const SizedBox(height: AppSpacing.sm),
          BoardRowTile(row: me, mine: true, onTap: open),
        ],
      ],
    );
  }
}

class _TournamentCard extends StatelessWidget {
  const _TournamentCard({required this.tournament});

  final HomeTournament tournament;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final t = tournament;
    final details = [
      if (t.startsAt case final starts?) '${shortDate(starts)} · ${clockTime(starts)}',
      if (t.entryFee case final fee?) fee == 0 ? 'Free entry' : '$fee coins entry',
      if (t.prizePool case final pool? when pool > 0) '$pool coins prize pool',
      if ((t.players, t.capacity) case (final players?, final capacity?))
        '$players/$capacity players',
    ];
    void open() => unawaited(context.push(Routes.tournament(t.id)));
    return SurfaceCard(
      onTap: open,
      semanticLabel: t.title,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: colors.lemon.container, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: HugeIcon(AppIcons.award, size: 24, color: colors.lemon.onContainer),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.title, style: text.titleMedium),
                if (details.isNotEmpty) Text(details.join(' · '), style: text.bodySmall),
              ],
            ),
          ),
          HugeIcon(AppIcons.chevronRight, size: 20, color: colors.inkMuted),
        ],
      ),
    );
  }
}

class _MaintenanceBanner extends StatelessWidget {
  const _MaintenanceBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SurfaceCard(
      color: colors.lemon.container,
      bordered: false,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          HugeIcon(AppIcons.info, size: 20, color: colors.lemon.onContainer),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(message, style: context.text.bodySmall)),
        ],
      ),
    );
  }
}

/// Celebrates the welcome bonus, once, on the first Home after onboarding.
Future<void> showWelcomeSheet(BuildContext context, {required int coins}) => showAppSheet<void>(
  context,
  builder: (sheetContext) {
    final colors = sheetContext.colors;
    final text = sheetContext.text;
    return SheetScaffold(
      title: 'Welcome to Quiz Arena!',
      subtitle: 'Here are some coins to get you started.',
      footer: AppButton(label: 'Let\'s play', onPressed: () => Navigator.of(sheetContext).pop()),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            HugeIcon(AppIcons.coins, size: 40, color: colors.lemon.onContainer),
            const SizedBox(width: AppSpacing.md),
            Text('+${formatCount(coins)} coins', style: text.headlineMedium),
          ],
        ),
      ),
    );
  },
);
