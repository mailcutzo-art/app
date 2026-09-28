import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../app/live/live_hub.dart';
import '../../app/router.dart';
import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import '../../core/realtime/live_providers.dart';
import '../../core/realtime/live_text.dart';
import '../../core/realtime/realtime_providers.dart';
import '../../core/realtime/search_state.dart';
import '../../core/utils/ids.dart';
import '../rooms/data/room_models.dart' show RoomKind;
import '../rooms/room_text.dart';
import '../rooms/rooms_controller.dart';
import '../rooms/widgets/room_widgets.dart' show defaultRoomSettings;
import 'battle_screen.dart' show onlineLine;
import 'data/battle_models.dart';

/// "Looking for a Physics player in Kinematics…", then "Widened to all of Physics".
String searchStatusLine(SearchState state) {
  final request = state.request;
  if (request == null) return 'Looking for an opponent…';
  final subject = request.subjectLabel;
  if (state.widened) return 'Widened to all of $subject';
  final chapter = request.chapterLabel;
  return chapter == null
      ? 'Looking for a $subject player…'
      : 'Looking for a $subject player in $chapter…';
}

/// The matchmaking screen (`/battle/search`). Leaving it keeps the search going, with the
/// "Searching" pill on every screen; Cancel stops it.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  int _handledOffers = 0;
  bool _sheetOpen = false;
  bool _cancelling = false;
  bool _restarting = false;

  /// A Practice Bot game was asked for: the search ends first (`mm.cancelled`), then the game
  /// opens by itself. Until then this screen says the game is starting.
  bool _botStarting = false;
  Timer? _botTimeout;

  /// "Invite a friend" was chosen: a friend duel is being set up.
  bool _inviting = false;

  @override
  void initState() {
    super.initState();
    // An offer that came while the user was elsewhere is shown on arrival.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _follow(ref.read(searchProvider));
    });
  }

  @override
  void dispose() {
    _botTimeout?.cancel();
    super.dispose();
  }

  void _startingBot(bool starting) {
    _botTimeout?.cancel();
    setState(() => _botStarting = starting);
    if (!starting) return;
    // The game opens by itself; if it doesn't, say so instead of waiting forever.
    _botTimeout = Timer(const Duration(seconds: 10), () {
      if (!mounted || !_botStarting) return;
      setState(() => _botStarting = false);
      showAppToast(context, 'Couldn\'t start the Practice Bot. Please try again.');
    });
  }

  void _follow(SearchState state) {
    if (state.phase == SearchPhase.offered && state.offers != _handledOffers && !_sheetOpen) {
      unawaited(_offerOptions(state));
    } else if (state.phase != SearchPhase.offered && _sheetOpen) {
      // The server moved on (a match, or it gave up): the options no longer apply.
      Navigator.of(context, rootNavigator: true).popUntil((r) => r is! ModalBottomSheetRoute);
    }
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.battle);
    }
  }

  Future<void> _offerOptions(SearchState state) async {
    _handledOffers = state.offers;
    _sheetOpen = true;
    final choice = await showAppSheet<String>(context, builder: (_) => _OptionsSheet(state: state));
    _sheetOpen = false;
    if (!mounted || ref.read(searchProvider).phase != SearchPhase.offered) return;
    await _respond(choice ?? 'keep');
  }

  Future<void> _respond(String choice) async {
    final live = ref.read(liveControllerProvider);
    if (live == null) return;
    if (choice == 'bot') _startingBot(true);
    final request = ref.read(searchProvider).request;
    try {
      await live.respond(choice);
      if (mounted && choice == 'cancel') _leave();
      if (mounted && choice == 'invite') await _inviteFriend(request);
    } on RealtimeError {
      if (!mounted) return;
      if (choice == 'bot') _startingBot(false);
      showAppToast(context, 'That didn\'t go through. Please try again.');
    }
  }

  /// "Invite a friend": the search has ended; a friend duel on the same subject and chapter
  /// opens with the friends list up.
  Future<void> _inviteFriend(SearchRequest? request) async {
    final rooms = ref.read(roomsControllerProvider);
    if (rooms == null) return;
    setState(() => _inviting = true);
    try {
      final view = await rooms.create(
        RoomKind.friend,
        defaultRoomSettings(RoomKind.friend, subject: request?.subject, chapter: request?.chapter),
        idempotencyKey: randomHexId(),
      );
      if (mounted) context.go(Routes.room(view.roomId, pick: true));
    } on RealtimeError catch (error) {
      if (mounted && error.code != RealtimeErrorCode.busy) {
        showAppToast(context, RoomText.error(error), icon: AppIcons.alert);
      }
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _inviting = false);
    }
  }

  Future<void> _cancel() async {
    final live = ref.read(liveControllerProvider);
    if (live == null) {
      _leave();
      return;
    }
    setState(() => _cancelling = true);
    try {
      await live.cancelSearch();
      if (mounted && ref.read(searchProvider).phase != SearchPhase.matched) _leave();
    } on RealtimeError {
      if (mounted) showAppToast(context, 'Couldn\'t cancel. Please try again.');
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  Future<void> _searchAgain(SearchRequest request) async {
    final live = ref.read(liveControllerProvider);
    if (live == null) return;
    if (request.isBot) _startingBot(true);
    setState(() => _restarting = true);
    try {
      await live.join(request);
    } on RealtimeError catch (error) {
      if (!mounted) return;
      if (request.isBot) _startingBot(false);
      if (error.code != RealtimeErrorCode.busy) {
        showAppToast(context, LiveText.joinError(error), icon: AppIcons.alert);
      }
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    ref.listen(searchProvider, (_, next) => _follow(next));
    final searching = !_botStarting && (state.isSearching || state.phase == SearchPhase.joining);

    final Widget body;
    if (_botStarting) {
      body = const _Found(key: ValueKey('bot'), bot: true);
    } else if (_inviting) {
      body = const _OpeningRoom(key: ValueKey('room'));
    } else if (searching) {
      body = _Searching(key: const ValueKey('searching'), state: state);
    } else if (state.phase == SearchPhase.matched) {
      body = const _Found(key: ValueKey('found'));
    } else {
      body = _Stopped(
        key: ValueKey('stopped-${state.lastEnd?.reason}'),
        state: state,
        busy: _restarting,
        onSearchAgain: _searchAgain,
        onBack: _leave,
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppTopBar(
              onBack: _leave,
              actions: [
                if (searching)
                  Text(
                    'Keep browsing',
                    style: context.text.labelMedium.copyWith(color: context.colors.inkMuted),
                  ),
              ],
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: AppMotion.of(context, AppMotion.medium),
                child: body,
              ),
            ),
            if (searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.sm,
                  AppSpacing.gutter,
                  AppSpacing.lg,
                ),
                child: AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.secondary,
                  loading: _cancelling,
                  onPressed: state.phase == SearchPhase.joining ? null : _cancel,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Searching extends ConsumerWidget {
  const _Searching({super.key, required this.state});

  final SearchState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.text;
    final me = ref.watch(meProvider);
    final request = state.request;
    final online = state.online;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: AppSpacing.xl),
        Center(
          child: SearchingPulse(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: AppShadows.floating(colors),
              ),
              child: AppAvatar(data: me.avatar.toData(), size: 96, ring: true),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Text(
          switch (state) {
            SearchState(phase: SearchPhase.joining) => 'Starting your search…',
            SearchState(requeued: true) => 'Searching again…',
            _ => 'Finding an opponent…',
          },
          style: text.headlineMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xs),
        Center(child: _Elapsed(joinedAt: state.joinedAt)),
        const SizedBox(height: AppSpacing.lg),
        if (request != null)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              OverlineBadge(
                label: switch (request.mode) {
                  'casual' => 'Casual',
                  'bot' => 'Practice',
                  _ => 'Rated',
                },
                solid: true,
                icon: request.isCasual ? AppIcons.coins : AppIcons.flash,
              ),
              OverlineBadge(label: request.subjectLabel, tone: PastelTone.sky),
              OverlineBadge(label: request.chapterLabel ?? 'All chapters', tone: PastelTone.sky),
            ],
          ),
        const SizedBox(height: AppSpacing.lg),
        Semantics(
          liveRegion: true,
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.medium),
            child: Text(
              searchStatusLine(state),
              key: ValueKey(state.widened),
              style: text.bodyLarge.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        if (online != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            onlineLine(OnlineStat(searching: online, p50WaitS: state.p50WaitS)),
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
        if (state.requeued) ...[
          const SizedBox(height: AppSpacing.lg),
          Center(
            child: InfoChip(
              icon: AppIcons.info,
              label: 'Your opponent didn\'t join. You\'re first in line.',
              background: colors.lemon.container,
              foreground: colors.lemon.onContainer,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        Text(
          'You can leave this screen. We\'ll keep looking and call you back.',
          style: text.caption,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// "0:32" since the search started, ticking once a second without rebuilding the screen.
class _Elapsed extends ConsumerStatefulWidget {
  const _Elapsed({required this.joinedAt});

  final int? joinedAt;

  @override
  ConsumerState<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends ConsumerState<_Elapsed> {
  Timer? _ticker;
  DateTime? _since;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  DateTime _now() => ref.read(liveClockProvider)();

  DateTime _start() {
    final joinedAt = widget.joinedAt;
    final clock = ref.read(realtimeConnectionProvider)?.serverClock;
    if (joinedAt == null || clock == null) return _since ??= _now();
    final waited = (clock.nowServerMs() - joinedAt).clamp(0, 1 << 31);
    return _since = _now().subtract(Duration(milliseconds: waited));
  }

  @override
  void didUpdateWidget(covariant _Elapsed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.joinedAt != widget.joinedAt) _since = null;
  }

  @override
  Widget build(BuildContext context) {
    final since = _since ?? _start();
    final label = LiveText.mmss(_now().difference(since));
    return Text(
      label,
      style: context.text.numericLarge.copyWith(color: context.colors.inkMuted),
      semanticsLabel: 'Searching for $label',
    );
  }
}

/// A match was found (or a Practice Bot game asked for): the game opens in a moment.
class _Found extends StatelessWidget {
  const _Found({super.key, this.bot = false});

  final bool bot;

  @override
  Widget build(BuildContext context) => Center(
    child: EmptyState(
      icon: bot ? AppIcons.robot : AppIcons.battle,
      tone: bot ? PastelTone.lavender : PastelTone.sky,
      title: bot ? 'Starting a Practice Bot game…' : 'Match found!',
      message: bot ? 'Unrated, no coins · just practice' : 'Getting the game ready…',
    ),
  );
}

/// The search is over without a match: why, and what next.
class _Stopped extends StatelessWidget {
  const _Stopped({
    super.key,
    required this.state,
    required this.busy,
    required this.onSearchAgain,
    required this.onBack,
  });

  final SearchState state;
  final bool busy;
  final ValueChanged<SearchRequest> onSearchAgain;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final end = state.lastEnd;
    final request = state.request;
    final explained = end != null && !end.byUser;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyState(
              icon: explained ? AppIcons.info : AppIcons.search,
              tone: explained ? PastelTone.lemon : PastelTone.sky,
              title: explained ? LiveText.cancelledTitle(end.reason) : 'You\'re not searching',
              message: explained
                  ? LiveText.cancelledMessage(end.reason, end.refunded)
                  : 'Start a quick battle from the Battle tab.',
            ),
            if (request != null && !request.isBot) ...[
              AppButton(
                label: 'Search again',
                trailingIcon: AppIcons.search,
                loading: busy,
                onPressed: busy ? null : () => onSearchAgain(request),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Play the Practice Bot',
                variant: AppButtonVariant.secondary,
                leadingIcon: AppIcons.robot,
                onPressed: busy ? null : () => onSearchAgain(request.withMode('bot')),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            AppButton(label: 'Back to Battle', variant: AppButtonVariant.ghost, onPressed: onBack),
          ],
        ),
      ),
    );
  }
}

/// Setting up a friend duel after "Invite a friend".
class _OpeningRoom extends StatelessWidget {
  const _OpeningRoom({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(height: AppSpacing.lg),
          Text('Setting up a room for you and a friend…', style: context.text.titleMedium),
        ],
      ),
    ),
  );
}

/// The `mm.timeout` choices: keep searching, the Practice Bot, a friend or cancel.
class _OptionsSheet extends StatelessWidget {
  const _OptionsSheet({required this.state});

  final SearchState state;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final options = state.options.isEmpty
        ? const ['keep', 'bot', 'invite', 'cancel']
        : state.options;
    final casual = state.request?.isCasual ?? false;
    return SheetScaffold(
      title: 'No one found yet',
      subtitle:
          'You\'ve waited ${LiveText.mmss(Duration(seconds: state.waitedS))}. '
          'What would you like to do?',
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (options.contains('keep'))
            AppButton(
              label: 'Keep searching',
              trailingIcon: AppIcons.search,
              onPressed: () => Navigator.pop(context, 'keep'),
            ),
          if (options.contains('bot')) ...[
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Play a Practice Bot',
              variant: AppButtonVariant.secondary,
              leadingIcon: AppIcons.robot,
              onPressed: () => Navigator.pop(context, 'bot'),
            ),
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                casual
                    ? 'Unrated, no coins · your 5 coins come back'
                    : 'Unrated, no coins · starts right away',
                style: text.caption,
              ),
            ),
          ],
          if (options.contains('invite')) ...[
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Invite a friend',
              variant: AppButtonVariant.secondary,
              leadingIcon: AppIcons.userAdd,
              onPressed: () => Navigator.pop(context, 'invite'),
            ),
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                casual
                    ? 'A private 1v1, unrated and free · your 5 coins come back'
                    : 'A private 1v1, unrated and free',
                style: text.caption,
              ),
            ),
          ],
          if (options.contains('cancel')) ...[
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Cancel search',
              variant: AppButtonVariant.ghost,
              onPressed: () => Navigator.pop(context, 'cancel'),
            ),
          ],
        ],
      ),
      child: const SizedBox.shrink(),
    );
  }
}
