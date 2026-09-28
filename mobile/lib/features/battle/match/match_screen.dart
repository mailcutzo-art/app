import 'dart:async';

import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart' hide AnswerOption;

import '../../../app/router.dart';
import '../../../core/auth/session.dart';
import '../../../core/auth/user.dart';
import '../../../core/realtime/live_match.dart';
import '../../../core/realtime/live_providers.dart';
import '../../../core/realtime/live_text.dart';
import '../../rooms/room_text.dart';
import '../../rooms/rooms_controller.dart' show roomViewProvider, roomsOf;
import '../data/battle_repository.dart';
import 'group_widgets.dart';
import 'match_widgets.dart';
import 'result_view.dart';
import 'screen_guard.dart';

/// "4 from Motion in a Straight Line · 3 from Laws of Motion".
String sourcesLine(List<SourceChapter> sources) =>
    sources.map((s) => '${s.count} from ${s.name ?? s.chapter}').join(' · ');

/// "You 3 – 1 Riya" (plus draws). Null before the first game against them.
String? recordLine(HeadToHead? record, String opponent) {
  if (record == null || record.wins + record.losses + record.draws == 0) return null;
  final draws = record.draws == 0 ? '' : ' · ${record.draws} drawn';
  return 'You ${record.wins} – ${record.losses} $opponent$draws';
}

/// A live match, full screen above the tabs (`/battle/match/:id`): the VS screen, the 3-2-1, the
/// questions and reveals, then the result. Everything shown comes from the server's state.
///
/// While it's up the screen stays on and, on Android, can't be captured.
class MatchScreen extends ConsumerStatefulWidget {
  const MatchScreen({super.key, required this.matchId});

  final String matchId;

  @override
  ConsumerState<MatchScreen> createState() => _MatchScreenState();
}

class _MatchScreenState extends ConsumerState<MatchScreen> {
  late final ScreenGuard _guard;
  bool _asking = false;
  Timer? _leaving;

  @override
  void initState() {
    super.initState();
    _guard = ref.read(screenGuardProvider);
    unawaited(_guard.protect());
  }

  @override
  void dispose() {
    _leaving?.cancel();
    unawaited(_guard.release());
    super.dispose();
  }

  LiveMatch? get _match => liveMatchOf(ref, widget.matchId);

  /// Done: back to the Battle tab (or to the room's lobby, for a room's game), and stop
  /// following this match.
  void _done() {
    final live = ref.read(liveControllerProvider);
    // Ratings and coins changed: the Battle tab reads them again.
    ref.invalidate(battleSetupProvider);
    context.go(_doneRoute());
    WidgetsBinding.instance.addPostFrameCallback((_) => live?.closeMatch(widget.matchId));
  }

  String _doneRoute() {
    final view = ref.read(matchViewProvider(widget.matchId));
    final room = ref.read(roomViewProvider);
    if (view == null || !view.isRoomGame || room == null) return Routes.battle;
    final ours = room.state.matchId == widget.matchId || view.roomId == room.roomId;
    return ours ? Routes.room(room.roomId) : Routes.battle;
  }

  Future<void> _requestLeave() async {
    final view = ref.read(matchViewProvider(widget.matchId));
    if (view == null || view.isOver || !view.hasLiveState) {
      _done();
      return;
    }
    if (_asking) return;
    _asking = true;
    final room = ref.read(roomViewProvider);
    // The host of a group can end the game for everyone, on the current scores.
    final canEnd =
        view.isGroup && room != null && room.isHost && room.state.matchId == view.matchId;
    final choice = await showAppSheet<String>(
      context,
      builder: (context) => SheetScaffold(
        title: 'Leave the battle?',
        subtitle: view.isGroup
            ? 'You score nothing for the questions you miss.'
            : 'You\'ll lose this game.',
        footer: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppButton(label: 'Keep playing', onPressed: () => Navigator.pop(context, 'stay')),
            if (canEnd) ...[
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'End the game for everyone',
                variant: AppButtonVariant.secondary,
                onPressed: () => Navigator.pop(context, 'end'),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Leave',
              variant: AppButtonVariant.danger,
              onPressed: () => Navigator.pop(context, 'leave'),
            ),
          ],
        ),
        child: const SizedBox.shrink(),
      ),
    );
    _asking = false;
    if (!mounted) return;
    if (choice == 'end') {
      try {
        await roomsOf(ref)?.end();
      } on RealtimeError catch (error) {
        if (mounted) showAppToast(context, 'Couldn\'t end the game: ${error.message}');
      }
      return;
    }
    if (choice != 'leave') return;
    final match = _match;
    if (match == null) {
      _done();
      return;
    }
    await match.forfeit();
    // The result follows as soon as the server confirms. If it can't (no connection), go anyway:
    // the server ends the game when the grace period runs out.
    _leaving?.cancel();
    _leaving = Timer(const Duration(seconds: 4), () {
      if (mounted && !(ref.read(matchViewProvider(widget.matchId))?.isOver ?? true)) _done();
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.matchId;
    final phase = ref.watch(matchViewProvider(id).select((v) => v?.phase));
    final loading = ref.watch(
      matchViewProvider(id)
          .select((v) => v == null ? null : (hasLive: v.hasLiveState, failed: v.loadFailed)),
    );
    final over = phase?.isOver ?? false;

    final Widget body;
    final String key;
    if (loading == null) {
      key = 'gone';
      body = _Unavailable(onBack: _done);
    } else if (phase == null || phase == MatchPhase.unknown) {
      key = loading.failed ? 'failed' : 'loading';
      body = loading.failed ? _LoadFailed(matchId: id, onBack: _done) : const _Rejoining();
    } else {
      switch (phase) {
        case MatchPhase.readyWait:
          key = 'vs';
          body = _VersusView(matchId: id, onLeave: _requestLeave);
        case MatchPhase.countdown:
          key = 'countdown';
          body = _CountdownView(matchId: id, onLeave: _requestLeave);
        case MatchPhase.qOpen || MatchPhase.qReveal:
          key = 'question';
          body = _QuestionView(matchId: id, onLeave: _requestLeave);
        case MatchPhase.finished || MatchPhase.aborted || MatchPhase.voided || MatchPhase.unknown:
          key = 'result';
          body = ResultView(matchId: id, onDone: _done);
      }
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (over) {
          _done();
        } else {
          unawaited(_requestLeave());
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            SafeArea(
              child: AnimatedSwitcher(
                duration: AppMotion.of(context, AppMotion.medium),
                switchInCurve: AppMotion.emphasized,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.98, end: 1).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(key: ValueKey(key), child: body),
              ),
            ),
            if (!over) const SafeArea(child: ReconnectingOverlay()),
          ],
        ),
      ),
    );
  }
}

class _TopRow extends StatelessWidget {
  const _TopRow({required this.onLeave, this.trailing});

  final VoidCallback onLeave;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, 0),
    child: Row(
      children: [
        AppIconButton(icon: AppIcons.close, semanticLabel: 'Leave the battle', onPressed: onLeave),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}

// ---------------------------------------------------------------------------------------------
// VS

class _VersusView extends ConsumerStatefulWidget {
  const _VersusView({required this.matchId, required this.onLeave});

  final String matchId;
  final VoidCallback onLeave;

  @override
  ConsumerState<_VersusView> createState() => _VersusViewState();
}

class _VersusViewState extends ConsumerState<_VersusView> {
  @override
  void initState() {
    super.initState();
    // Ready once the VS screen is actually on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) liveMatchOf(ref, widget.matchId)?.markVsVisible();
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(matchViewProvider(widget.matchId));
    if (view == null) return const SizedBox.shrink();
    final text = context.text;
    final colors = context.colors;
    final me = ref.watch(meProvider);
    final goal = me.goal ?? Goal.neet;
    final subject = view.intro?.request?.subject;
    final myRating = subject == null
        ? null
        : ref.watch(battleSetupProvider(goal)).value?.subject(subject)?.rating.display;
    final opponent = view.opponentCard;
    final record = view.isBot ? null : recordLine(view.opponentRecord, view.opponentName);
    final sources = sourcesLine(view.intro?.sources ?? const []);
    final total = view.state.total > 0 ? view.state.total : 7;
    final seconds = ((view.state.limitMs ?? 15000) / 1000).round();
    final mode = switch (view.mode) {
      'bot' => 'Practice game · not rated',
      'casual' => 'Casual · winner takes 10 coins',
      'friend' => 'Friend battle · unrated',
      'group' => 'Group battle · unrated',
      _ => 'Rated',
    };
    return Column(
      children: [
        _TopRow(onLeave: widget.onLeave),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            children: [
              const SizedBox(height: AppSpacing.xl),
              Center(
                child: OverlineBadge(
                  label: view.isBot
                      ? 'Practice Bot'
                      : (view.isRoomGame ? 'Get ready' : 'Match found'),
                  icon: view.isBot ? AppIcons.robot : AppIcons.battle,
                  solid: true,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              if (view.isGroup)
                GroupLineup(view: view)
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _PlayerCardView(
                        avatar: me.avatar.toData(),
                        name: 'You',
                        level: view.myCard?.level,
                        rating: myRating,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 28),
                      child: Container(
                        width: 48,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: colors.inverse, shape: BoxShape.circle),
                        child: Text('VS', style: text.labelLarge.copyWith(color: colors.onInverse)),
                      ),
                    ),
                    Expanded(
                      child: _PlayerCardView(
                        avatar: avatarOf(opponent),
                        name: view.opponentName,
                        level: view.isBot ? null : opponent?.level,
                        rating: view.isBot ? null : view.opponentRating?.display,
                        caption: view.isBot ? 'Practice Bot' : null,
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: AppSpacing.xl),
              if (record != null)
                Text(record, style: text.titleMedium, textAlign: TextAlign.center),
              if (sources.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(sources, style: text.bodyMedium, textAlign: TextAlign.center),
              ],
              const SizedBox(height: AppSpacing.lg),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  InfoChip(icon: AppIcons.flash, label: mode, background: colors.surfaceMuted),
                  InfoChip(
                    icon: AppIcons.timer,
                    label: '$total questions · $seconds s each',
                    background: colors.surfaceMuted,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xxl),
              Semantics(
                liveRegion: true,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: colors.inkMuted),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      view.readySent
                          ? (view.isGroup
                                ? 'Waiting for everyone…'
                                : 'Waiting for ${view.opponentName}…')
                          : 'Getting ready…',
                      style: text.labelMedium.copyWith(color: colors.inkMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlayerCardView extends StatelessWidget {
  const _PlayerCardView({
    required this.avatar,
    required this.name,
    required this.level,
    required this.rating,
    this.caption,
  });

  final AvatarData avatar;
  final String name;
  final int? level;
  final String? rating;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final details = [?caption, if (level != null) 'Level $level'].join(' · ');
    return Column(
      children: [
        AppAvatar(data: avatar, size: 88, ring: true),
        const SizedBox(height: AppSpacing.md),
        Text(name, style: text.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (details.isNotEmpty) Text(details, style: text.caption),
        if (rating != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(rating!, style: text.numericMedium),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// 3-2-1

class _CountdownView extends ConsumerWidget {
  const _CountdownView({required this.matchId, required this.onLeave});

  final String matchId;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final endsAt = ref.watch(matchViewProvider(matchId).select((v) => v?.state.endsAt));
    final name = ref.watch(matchViewProvider(matchId).select((v) => v?.opponentName));
    final group = ref.watch(matchViewProvider(matchId).select((v) => v?.isGroup ?? false));
    final text = context.text;
    return Column(
      children: [
        _TopRow(onLeave: onLeave),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Get ready', style: text.titleLarge),
                const SizedBox(height: AppSpacing.lg),
                if (endsAt != null) CountdownDigits(endsAt: endsAt),
                const SizedBox(height: AppSpacing.lg),
                if (group)
                  Text('Group battle', style: text.bodyMedium)
                else if (name != null)
                  Text('You vs $name', style: text.bodyMedium),
              ],
            ),
          ),
        ),
        _Emotes(matchId: matchId),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Questions

class _QuestionView extends ConsumerWidget {
  const _QuestionView({required this.matchId, required this.onLeave});

  final String matchId;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(matchViewProvider(matchId));
    if (view == null) return const SizedBox.shrink();
    final me = ref.watch(meProvider);
    final state = view.state;
    final question = state.question;
    final opponent = view.opponent;
    final opponentUid = view.opponentCard?.uid;
    final open = state.phase == MatchPhase.qOpen;
    final ring = question != null && open && view.questionVisible
        ? QuestionRing(
            key: ValueKey(question.q),
            deadlineAt: question.deadlineAt,
            limitMs: question.limitMs,
          )
        : const SizedBox.square(dimension: AppSizes.iconButton);
    final reconnecting = !view.isGroup && opponent?.presence == Presence.reconnecting;
    final answered = state.answered;
    return Column(
      children: [
        _TopRow(onLeave: onLeave, trailing: ring),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.lg,
            AppSpacing.gutter,
            0,
          ),
          child: EmoteLayer(
            matchId: matchId,
            me: view.me,
            child: view.isGroup
                ? GroupHeader(view: view)
                : VersusHeader(
                    me: VersusPlayer(
                      name: 'You',
                      avatar: me.avatar.toData(),
                      score: view.myTotals.points,
                      answered: open && answered.contains(view.me),
                    ),
                    opponent: VersusPlayer(
                      name: view.opponentName,
                      avatar: avatarOf(view.opponentCard),
                      score: view.opponentTotals.points,
                      answered: open && opponentUid != null && answered.contains(opponentUid),
                    ),
                    questionNumber: state.q,
                    total: state.total,
                  ),
          ),
        ),
        AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.medium),
          transitionBuilder: (child, animation) => SizeTransition(
            sizeFactor: animation,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: view.isSpectator
              ? const Padding(
                  key: ValueKey('spectator'),
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    AppSpacing.md,
                    AppSpacing.gutter,
                    0,
                  ),
                  child: SpectatorBanner(),
                )
              : reconnecting
              ? Padding(
                  key: const ValueKey('reconnecting'),
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    AppSpacing.md,
                    AppSpacing.gutter,
                    0,
                  ),
                  child: OpponentReconnecting(
                    name: view.opponentName,
                    graceUntil: opponent?.graceUntil,
                  ),
                )
              : const SizedBox(key: ValueKey('connected'), width: double.infinity),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.medium),
            switchInCurve: AppMotion.emphasized,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(
                  begin: AppMotion.reduced(context) ? Offset.zero : const Offset(0.05, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: question == null || !view.questionVisible
                ? _GetReady(key: ValueKey('ready-${state.q}'), number: state.q, total: state.total)
                : _QuestionBody(key: ValueKey('q-${question.q}'), view: view),
          ),
        ),
        _Emotes(matchId: matchId),
      ],
    );
  }
}

/// Shown until the question goes live: nothing of it is on screen before `shown_at`.
class _GetReady extends StatelessWidget {
  const _GetReady({super.key, required this.number, required this.total});

  final int number;
  final int total;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        OverlineBadge(label: 'Question ${number < 1 ? 1 : number} / $total', solid: true),
        const SizedBox(height: AppSpacing.md),
        Text('Get ready…', style: context.text.titleLarge),
      ],
    ),
  );
}

class _QuestionBody extends ConsumerWidget {
  const _QuestionBody({super.key, required this.view});

  final MatchView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = view.state;
    final question = state.question!;
    final reveal = state.currentReveal;
    final me = view.me;
    final opponentUid = view.opponentCard?.uid;
    final myAnswer = state.myAnswer;
    final myPick =
        reveal?.players[me]?.opt ?? (myAnswer?.status == AnswerStatus.late ? null : myAnswer?.opt);
    final timesUp =
        myAnswer?.status == AnswerStatus.late || (view.closedQ == question.q && myAnswer == null);
    final locked =
        reveal != null || myAnswer != null || timesUp || view.leaving || view.isSpectator;

    AnswerOptionState stateOf(String optionId) {
      if (reveal != null) {
        if (optionId == reveal.correctOption) return AnswerOptionState.correct;
        if (optionId == myPick) return AnswerOptionState.wrong;
        return AnswerOptionState.dimmed;
      }
      if (optionId == myPick) return AnswerOptionState.selected;
      return locked ? AnswerOptionState.dimmed : AnswerOptionState.idle;
    }

    final opponentPick = opponentUid == null || view.isGroup
        ? null
        : reveal?.players[opponentUid]?.opt;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.lg,
        AppSpacing.gutter,
        AppSpacing.lg,
      ),
      children: [
        QuestionCard(
          number: question.q,
          total: question.total,
          text: question.stem,
          tag: question.chapter,
        ),
        const SizedBox(height: AppSpacing.lg),
        for (final (i, option) in question.options.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpacing.md),
          AnswerOption(
            index: i,
            text: option.text,
            state: stateOf(option.id),
            opponent: opponentPick == option.id ? avatarOf(view.opponentCard) : null,
            onTap: locked ? null : () => liveMatchOf(ref, view.matchId)?.answer(option.id),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        _StatusLine(view: view, timesUp: timesUp),
      ],
    );
  }
}

/// Under the options: "Riya answered", "Locked in", "Time's up", or after the reveal the points
/// and who was faster.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.view, required this.timesUp});

  final MatchView view;
  final bool timesUp;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final state = view.state;
    final reveal = state.currentReveal;
    final opponentUid = view.opponentCard?.uid;
    final name = view.opponentName;
    final Widget child;
    if (reveal != null && view.isGroup) {
      final mine = reveal.players[view.me];
      final pts = mine?.pts ?? 0;
      final place = state.placeOf(view.me);
      final change = state.standings.where((s) => s.uid == view.me).firstOrNull?.change ?? 0;
      child = Column(
        key: ValueKey('reveal-${reveal.q}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!view.isSpectator) ...[
            Center(
              child: InfoChip(
                icon: pts > 0 ? AppIcons.checkCircle : AppIcons.close,
                label: LiveText.points(pts),
                background: pts > 0 ? colors.successContainer : colors.surfaceMuted,
                foreground: pts > 0 ? colors.onSuccessContainer : colors.ink,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'You\'re ${RoomText.ordinal(place)}'
              '${change > 0 ? ' · up $change' : (change < 0 ? ' · down ${-change}' : '')}',
              style: text.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
          if (state.standings.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            MiniLeaderboard(view: view),
          ],
          const SizedBox(height: AppSpacing.xs),
          Text(
            state.q >= state.total ? 'That was the last one' : 'Next question coming up',
            style: text.caption,
            textAlign: TextAlign.center,
          ),
        ],
      );
    } else if (reveal != null) {
      final mine = reveal.players[view.me];
      final pts = mine?.pts ?? 0;
      final speed = LiveText.speedLine(
        reveal,
        me: view.me,
        opponentUid: opponentUid,
        opponent: name,
        bot: view.isBot,
      );
      child = Column(
        key: ValueKey('reveal-${reveal.q}'),
        children: [
          InfoChip(
            icon: pts > 0 ? AppIcons.checkCircle : AppIcons.close,
            label: LiveText.points(pts),
            background: pts > 0 ? colors.successContainer : colors.surfaceMuted,
            foreground: pts > 0 ? colors.onSuccessContainer : colors.ink,
          ),
          if (speed != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(speed, style: text.titleMedium, textAlign: TextAlign.center),
          ],
          const SizedBox(height: AppSpacing.xs),
          Text(
            state.q >= state.total ? 'That was the last one' : 'Next question coming up',
            style: text.caption,
            textAlign: TextAlign.center,
          ),
        ],
      );
    } else if (timesUp) {
      child = InfoChip(
        key: const ValueKey('late'),
        icon: AppIcons.timer,
        label: 'Time\'s up',
        background: colors.warningContainer,
        foreground: colors.onWarningContainer,
      );
    } else if (view.isGroup) {
      final count = state.answered.length;
      final label = view.isSpectator
          ? '$count of ${state.players.length} answered'
          : (state.myAnswer != null
                ? 'Locked in · $count of ${state.players.length} answered'
                : (count == 0 ? null : '$count of ${state.players.length} answered'));
      child = label == null
          ? const SizedBox(key: ValueKey('none'), height: 32)
          : InfoChip(
              key: ValueKey(label),
              icon: AppIcons.check,
              label: label,
              background: colors.surfaceMuted,
            );
    } else {
      final iAnswered = state.myAnswer != null;
      final theyAnswered = opponentUid != null && state.answered.contains(opponentUid);
      final label = switch ((iAnswered, theyAnswered)) {
        (true, true) => 'Both answered',
        (true, false) => 'Locked in · waiting for $name',
        (false, true) => '$name answered',
        (false, false) => null,
      };
      child = label == null
          ? const SizedBox(key: ValueKey('none'), height: 32)
          : InfoChip(
              key: ValueKey(label),
              icon: theyAnswered && !iAnswered ? AppIcons.flash : AppIcons.check,
              label: label,
              background: colors.surfaceMuted,
            );
    }
    return Semantics(
      liveRegion: true,
      child: Center(
        child: AnimatedSwitcher(duration: AppMotion.of(context, AppMotion.fast), child: child),
      ),
    );
  }
}

class _Emotes extends ConsumerWidget {
  const _Emotes({required this.matchId});

  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leaving = ref.watch(matchViewProvider(matchId).select((v) => v?.leaving ?? true));
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.md),
      child: EmoteBar(
        emotes: battleEmotes,
        onSend: leaving ? null : (emote) => liveMatchOf(ref, matchId)?.emote(emote),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Loading and dead ends

/// A match opened without live state yet (after a restart, from a link).
class _Rejoining extends StatelessWidget {
  const _Rejoining();

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
        SizedBox(height: AppSpacing.lg),
        Text('Opening your game…'),
      ],
    ),
  );
}

class _LoadFailed extends ConsumerWidget {
  const _LoadFailed({required this.matchId, required this.onBack});

  final String matchId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ErrorState(
            title: 'Couldn\'t open this game',
            onRetry: () => liveMatchOf(ref, matchId)?.resume(),
          ),
          AppButton(label: 'Back to Battle', variant: AppButtonVariant.ghost, onPressed: onBack),
        ],
      ),
    ),
  );
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Center(
    child: EmptyState(
      icon: AppIcons.offline,
      title: 'Not connected',
      message: 'Live games need you signed in and online.',
      actionLabel: 'Back to Battle',
      onAction: onBack,
    ),
  );
}
