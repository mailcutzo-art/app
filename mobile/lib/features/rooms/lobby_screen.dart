import 'dart:async';

import 'package:clock/clock.dart';
import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../app/router.dart';
import '../../core/auth/session.dart';
import '../../core/auth/user.dart';
import '../../core/network/app_failure.dart';
import '../../core/realtime/live_providers.dart';
import '../../core/realtime/live_text.dart';
import '../battle/data/battle_repository.dart';
import '../social/social_providers.dart';
import 'data/room_models.dart';
import 'room_share.dart';
import 'room_text.dart';
import 'rooms_controller.dart';
import 'widgets/invite_friends_sheet.dart';
import 'widgets/room_widgets.dart';

/// A room's lobby (`/battle/room/:roomId`): the code to share, the players with their badges,
/// invites, the host's controls, and Ready / Start. The room lives on the server, so leaving the
/// screen (or the app, to share the link) keeps it; a pill on every screen leads back.
///
/// [invite] is a friend to invite on arrival (Social → Challenge); [pick] opens the invite list
/// (the search screen's "Invite a friend").
class LobbyScreen extends ConsumerStatefulWidget {
  const LobbyScreen({super.key, required this.roomId, this.invite, this.pick = false});

  final String roomId;
  final String? invite;
  final bool pick;

  @override
  ConsumerState<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends ConsumerState<LobbyScreen> {
  bool _joining = false;
  String? _joinError;
  bool _arrived = false;
  String? _busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureJoined());
  }

  /// Opened from a link, a notification or after a restart: join (or rejoin) the room.
  Future<void> _ensureJoined() async {
    if (!mounted) return;
    final rooms = ref.read(roomsControllerProvider);
    final view = ref.read(roomViewProvider);
    if (rooms == null || (view != null && view.roomId == widget.roomId)) return;
    setState(() {
      _joining = true;
      _joinError = null;
    });
    try {
      await rooms.joinRoom(widget.roomId);
    } on RealtimeError catch (error) {
      if (mounted) setState(() => _joinError = RoomText.joinError(error));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  /// Once the lobby is known: invite the friend picked beforehand, or open the invite list.
  void _onArrival(RoomView view) {
    if (_arrived || !view.state.isKnown) return;
    _arrived = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final friend = widget.invite;
      if (friend != null && view.state.member(friend) == null) {
        try {
          await ref.read(roomsControllerProvider)?.invite(friend);
        } on AppFailure catch (failure) {
          if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
        }
      }
      if (widget.pick && mounted) unawaited(_openInvites(view));
    });
  }

  Future<void> _share(RoomView view) async {
    try {
      await ref.read(roomShareProvider)(view.shareText(), subject: 'Join my Quiz Arena room');
    } on Object catch (error) {
      debugPrint('Share failed: $error');
      if (mounted) showAppToast(context, 'Couldn\'t open sharing. Copy the code instead.');
    }
  }

  Future<void> _copy(RoomView view) async {
    await ref.read(roomClipboardProvider)(view.state.code ?? '');
    if (mounted) showAppToast(context, 'Code copied', icon: AppIcons.checkCircle);
  }

  Future<void> _openInvites(RoomView view) =>
      showInviteFriendsSheet(context, onShare: () => _share(view));

  /// Runs a lobby action, showing what went wrong.
  Future<void> _act(String what, Future<void> Function(RoomsController rooms) action) async {
    final rooms = ref.read(roomsControllerProvider);
    if (rooms == null || _busy != null) return;
    setState(() => _busy = what);
    try {
      await action(rooms);
    } on RealtimeError catch (error) {
      if (mounted) showAppToast(context, RoomText.error(error), icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _back() {
    // The room goes on; the pill brings the user back.
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.battle);
    }
  }

  Future<void> _leave(RoomView view) async {
    final host = view.isHost;
    final others = view.others.isNotEmpty;
    final confirmed = await showAppSheet<bool>(
      context,
      builder: (context) => SheetScaffold(
        title: 'Leave the room?',
        subtitle: host && others
            ? 'The next player who joined becomes the host.'
            : 'You can join again with the code while it\'s open.',
        footer: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppButton(label: 'Stay', onPressed: () => Navigator.pop(context, false)),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Leave',
              variant: AppButtonVariant.danger,
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
        child: const SizedBox.shrink(),
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;
    await ref.read(roomsControllerProvider)?.leave();
    if (mounted) context.go(Routes.battle);
  }

  Future<void> _end() async {
    final confirmed = await showAppSheet<bool>(
      context,
      builder: (context) => SheetScaffold(
        title: 'Close the room for everyone?',
        subtitle: 'Everyone goes back to the Battle tab.',
        footer: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppButton(label: 'Keep it open', onPressed: () => Navigator.pop(context, false)),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Close room',
              variant: AppButtonVariant.danger,
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
        child: const SizedBox.shrink(),
      ),
    );
    if (confirmed ?? false) await _act('end', (rooms) => rooms.end());
  }

  Future<void> _hostMenu(RoomView view) async {
    final choice = await showAppSheet<String>(
      context,
      builder: (context) => SheetScaffold(
        title: 'Room settings',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (view.state.status == RoomStatus.lobby)
              SelectableRow(
                title: 'Change game settings',
                subtitle: settingsLines(view.state.settings, view.kind).take(4).join(' · '),
                icon: AppIcons.edit,
                selected: false,
                onTap: () => Navigator.pop(context, 'settings'),
              ),
            SelectableRow(
              title: view.state.locked ? 'Unlock the room' : 'Lock the room',
              subtitle: view.state.locked
                  ? 'New players can join with the code again'
                  : 'Nobody new can join',
              icon: AppIcons.lock,
              selected: false,
              onTap: () => Navigator.pop(context, 'lock'),
            ),
            SelectableRow(
              title: 'Close the room',
              subtitle: 'Ends it for everyone',
              icon: AppIcons.close,
              selected: false,
              onTap: () => Navigator.pop(context, 'end'),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'settings':
        await _editSettings(view);
      case 'lock':
        await _act('lock', (rooms) => rooms.lock(locked: !view.state.locked));
      case 'end':
        await _end();
    }
  }

  Future<void> _editSettings(RoomView view) async {
    final goal = ref.read(meProvider).goal ?? Goal.neet;
    final RoomSettings? next = await showAppSheet<RoomSettings>(
      context,
      builder: (_) => _SettingsSheet(goal: goal, kind: view.kind, initial: view.state.settings),
    );
    if (next == null || next == view.state.settings || !mounted) return;
    await _act('settings', (rooms) => rooms.updateSettings(next));
  }

  Future<void> _manage(RoomView view, RoomMember member) async {
    final name = member.card.displayName ?? member.card.handle ?? 'this player';
    final choice = await showAppSheet<String>(
      context,
      builder: (context) => SheetScaffold(
        title: name,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableRow(
              title: 'Make host',
              subtitle: '$name runs the room from now on',
              icon: AppIcons.crown,
              selected: false,
              onTap: () => Navigator.pop(context, 'host'),
            ),
            SelectableRow(
              title: 'Remove from room',
              subtitle: 'They can\'t join this room again',
              icon: AppIcons.delete,
              selected: false,
              onTap: () => Navigator.pop(context, 'kick'),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'host':
        await _act('transfer', (rooms) => rooms.transfer(member.uid));
      case 'kick':
        await _act('kick', (rooms) => rooms.kick(member.uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rooms = ref.watch(roomsControllerProvider);
    final view = ref.watch(roomViewProvider);
    final mine = view != null && view.roomId == widget.roomId ? view : null;
    if (mine != null) _onArrival(mine);

    final Widget body;
    if (rooms == null) {
      body = Center(
        child: EmptyState(
          icon: AppIcons.offline,
          title: 'Not connected',
          message: 'Rooms need you signed in and online.',
          actionLabel: 'Back to Battle',
          onAction: () => context.go(Routes.battle),
        ),
      );
    } else if (mine == null || !mine.state.isKnown) {
      body = _joinError != null && !_joining
          ? Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.gutter),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ErrorState(
                      title: 'Couldn\'t open the room',
                      message: _joinError!,
                      onRetry: _ensureJoined,
                    ),
                    AppButton(
                      label: 'Back to Battle',
                      variant: AppButtonVariant.ghost,
                      onPressed: () => context.go(Routes.battle),
                    ),
                  ],
                ),
              ),
            )
          : const _LobbySkeleton();
    } else {
      body = _Lobby(
        view: mine,
        busy: _busy,
        onShare: () => _share(mine),
        onCopy: () => _copy(mine),
        onInvite: () => _openInvites(mine),
        onReady: () => _act('ready', (rooms) => rooms.setReady(ready: !mine.isReady)),
        onStart: () => _act('start', (rooms) => rooms.start()),
        onRematch: (accept) => _act('rematch', (rooms) => rooms.rematch(accept: accept)),
        onManage: (member) => _manage(mine, member),
        onEditSettings: () => _editSettings(mine),
      );
    }

    final title = mine == null ? 'Room' : mine.kind.label;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppTopBar(
          title: title,
          onBack: _back,
          actions: [
            if (mine != null && mine.state.isKnown && mine.isHost)
              AppIconButton(
                icon: AppIcons.settings,
                semanticLabel: 'Room settings',
                onPressed: () => _hostMenu(mine),
              ),
            if (mine != null && mine.state.isKnown) ...[
              const SizedBox(width: AppSpacing.sm),
              AppIconButton(
                icon: AppIcons.logout,
                semanticLabel: 'Leave the room',
                onPressed: () => _leave(mine),
              ),
            ],
          ],
        ),
        body: body,
      ),
    );
  }
}

class _Lobby extends ConsumerWidget {
  const _Lobby({
    required this.view,
    required this.busy,
    required this.onShare,
    required this.onCopy,
    required this.onInvite,
    required this.onReady,
    required this.onStart,
    required this.onRematch,
    required this.onManage,
    required this.onEditSettings,
  });

  final RoomView view;
  final String? busy;
  final VoidCallback onShare;
  final VoidCallback onCopy;
  final VoidCallback onInvite;
  final VoidCallback onReady;
  final VoidCallback onStart;
  final ValueChanged<bool> onRematch;
  final ValueChanged<RoomMember> onManage;
  final VoidCallback onEditSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = context.text;
    final colors = context.colors;
    final state = view.state;
    final goal = ref.watch(meProvider.select((me) => me.goal)) ?? Goal.neet;
    final setup = ref.watch(battleSetupProvider(goal)).value;
    final hasFriends = ref.watch(friendsProvider).value?.friends.isNotEmpty ?? false;
    final outgoing = ref.watch(outgoingInvitesProvider);
    final waiting = [
      for (final member in state.waitingFor)
        if (member.uid != view.me) member,
    ];
    final lobby = state.status == RoomStatus.lobby;
    final friendRoom = view.kind == RoomKind.friend;
    final capacity = state.capacity ?? (friendRoom ? 2 : 8);
    final open = state.members.length < capacity;
    final invitesOut = outgoing.values.where((i) => i.isOpenAt(clock.now())).length;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.sm,
              AppSpacing.gutter,
              AppSpacing.xl,
            ),
            children: [
              if (state.code case final code?)
                RoomCodeCard(code: code, onCopy: onCopy, onShare: onShare),
              if (state.locked) ...[
                const SizedBox(height: AppSpacing.md),
                _Notice(
                  icon: AppIcons.lock,
                  text: view.isHost
                      ? 'The room is locked. Nobody new can join.'
                      : 'The host locked the room.',
                ),
              ],
              for (final member in waiting.take(1)) ...[
                const SizedBox(height: AppSpacing.md),
                _Notice(
                  icon: AppIcons.hourglass,
                  text: 'Waiting for ${nameOf(member.card) ?? 'a player'} to come back',
                ),
              ],
              if (state.status == RoomStatus.playing) ...[
                const SizedBox(height: AppSpacing.md),
                _GameOn(view: view),
              ],
              if (state.status == RoomStatus.finished) ...[
                const SizedBox(height: AppSpacing.md),
                _RematchCard(view: view, busy: busy == 'rematch', onRematch: onRematch),
              ],
              const SizedBox(height: AppSpacing.lg),
              _SettingsCard(
                view: view,
                lines: settingsLines(state.settings, view.kind, setup: setup),
                onEdit: view.isHost && lobby ? onEditSettings : null,
              ),
              SectionHeader(
                title: 'Players ${state.members.length}/$capacity',
                padding: const EdgeInsets.fromLTRB(0, AppSpacing.xl, 0, AppSpacing.md),
              ),
              for (final member in state.members) ...[
                MemberTile(
                  member: member,
                  isMe: member.uid == view.me,
                  isHost: member.uid == state.host,
                  onManage: view.isHost && member.uid != view.me ? () => onManage(member) : null,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              if (friendRoom && state.members.length < 2) const WaitingSeat(),
              if (open && lobby) ...[
                const SizedBox(height: AppSpacing.md),
                if (invitesOut > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(
                      invitesOut == 1 ? '1 invite on its way' : '$invitesOut invites on their way',
                      style: text.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                // A new user with no friends shares the link instead.
                AppButton(
                  label: hasFriends ? 'Invite friends' : 'Share link',
                  variant: AppButtonVariant.secondary,
                  leadingIcon: hasFriends ? AppIcons.userAdd : AppIcons.share,
                  onPressed: hasFriends ? onInvite : onShare,
                ),
              ],
            ],
          ),
        ),
        if (lobby)
          _LobbyFooter(view: view, busy: busy, onReady: onReady, onStart: onStart, colors: colors),
      ],
    );
  }
}

class _LobbyFooter extends StatelessWidget {
  const _LobbyFooter({
    required this.view,
    required this.busy,
    required this.onReady,
    required this.onStart,
    required this.colors,
  });

  final RoomView view;
  final String? busy;
  final VoidCallback onReady;
  final VoidCallback onStart;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final state = view.state;
    final hint = view.isHost
        ? (state.canStart
              ? (state.allReady ? 'Everyone is ready' : 'You can start once players are here')
              : 'Start needs at least 2 players connected')
        : (view.isReady
              ? 'Waiting for ${view.hostName} to start'
              : 'Get ready so ${view.hostName} can start');
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.md,
          AppSpacing.gutter,
          AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.outline)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(hint, style: text.bodySmall, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: view.isReady ? 'Ready ✓' : 'I\'m ready',
                    variant: view.isReady ? AppButtonVariant.tonal : AppButtonVariant.secondary,
                    tone: PastelTone.mint,
                    loading: busy == 'ready',
                    onPressed: busy == null ? onReady : null,
                  ),
                ),
                if (view.isHost) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AppButton(
                      label: 'Start',
                      trailingIcon: AppIcons.battle,
                      loading: busy == 'start',
                      onPressed: state.canStart && busy == null ? onStart : null,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final HugeIconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.lemon.container,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            HugeIcon(icon, size: 18, color: colors.lemon.onContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                text,
                style: context.text.labelMedium.copyWith(color: colors.lemon.onContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.view, required this.lines, required this.onEdit});

  final RoomView view;
  final List<String> lines;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Game settings', style: context.text.titleMedium)),
              if (onEdit != null)
                AppButton(
                  label: 'Change',
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.ghost,
                  expand: false,
                  onPressed: onEdit,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final line in lines) InfoChip(label: line, background: colors.surfaceMuted),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            view.kind == RoomKind.friend
                ? 'Unrated and free · half XP'
                : 'Unrated and free · 20 XP for a win, 10 for taking part',
            style: context.text.caption,
          ),
        ],
      ),
    );
  }
}

/// A game is on (the user came back to the lobby, or joined late): back into it.
class _GameOn extends StatelessWidget {
  const _GameOn({required this.view});

  final RoomView view;

  @override
  Widget build(BuildContext context) {
    final matchId = view.state.matchId;
    return SurfaceCard(
      color: context.colors.sky.container,
      bordered: false,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('The game is on', style: context.text.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Open the game',
            size: AppButtonSize.medium,
            trailingIcon: AppIcons.chevronRight,
            onPressed: matchId == null ? null : () => context.go(Routes.battleMatch(matchId)),
          ),
        ],
      ),
    );
  }
}

/// After a game: offer, accept or turn down playing again with the same settings.
class _RematchCard extends StatefulWidget {
  const _RematchCard({required this.view, required this.busy, required this.onRematch});

  final RoomView view;
  final bool busy;
  final ValueChanged<bool> onRematch;

  @override
  State<_RematchCard> createState() => _RematchCardState();
}

class _RematchCardState extends State<_RematchCard> {
  Timer? _ticker;

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

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    return RoomRematchPanel(view: view, busy: widget.busy, onRematch: widget.onRematch);
  }
}

/// "Play again" after a room's game: who offered, who's in, and the buttons. Shared by the lobby
/// and the result screen.
class RoomRematchPanel extends ConsumerWidget {
  const RoomRematchPanel({
    super.key,
    required this.view,
    required this.busy,
    required this.onRematch,
  });

  final RoomView view;
  final bool busy;
  final ValueChanged<bool> onRematch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = context.text;
    final rematch = view.state.rematch;
    final friend = view.kind == RoomKind.friend;
    final accepted = rematch?.accepted ?? const <String>[];
    final iAccepted = accepted.contains(view.me);
    final offeredBy = rematch == null ? null : view.state.member(rematch.offeredBy);
    final until = rematch?.until;
    final left = until == null
        ? null
        : Duration(
            milliseconds:
                (until -
                        (ref.read(liveControllerProvider)?.connection.serverClock.nowServerMs() ??
                            until))
                    .clamp(0, 1 << 31),
          );
    final String line;
    if (rematch == null) {
      line = friend ? 'Rematch? You both have 30 s to say yes.' : 'Play again with the same room?';
    } else if (iAccepted) {
      line = friend
          ? 'Waiting for ${nameOf(view.others.firstOrNull?.card) ?? 'your friend'}…'
          : '${accepted.length} of ${view.state.members.length} are in';
    } else {
      line = '${nameOf(offeredBy?.card) ?? 'Someone'} wants to play again';
    }
    return SurfaceCard(
      color: context.colors.lavender.container,
      bordered: false,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(line, style: text.titleMedium),
          if (left != null && left > Duration.zero)
            Text('${LiveText.mmss(left)} left', style: text.caption),
          const SizedBox(height: AppSpacing.md),
          if (iAccepted)
            AppButton(
              label: friend ? 'Rematch offered' : 'You\'re in',
              size: AppButtonSize.medium,
              variant: AppButtonVariant.tonal,
              tone: PastelTone.lavender,
              loading: true,
              onPressed: null,
            )
          else
            Row(
              children: [
                if (rematch != null) ...[
                  Expanded(
                    child: AppButton(
                      label: 'No thanks',
                      size: AppButtonSize.medium,
                      variant: AppButtonVariant.secondary,
                      onPressed: busy ? null : () => onRematch(false),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(
                  child: AppButton(
                    label: friend ? 'Rematch' : 'Play again',
                    size: AppButtonSize.medium,
                    leadingIcon: AppIcons.refresh,
                    loading: busy,
                    onPressed: busy ? null : () => onRematch(true),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Changing the settings from the lobby (host only).
class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet({required this.goal, required this.kind, required this.initial});

  final Goal goal;
  final RoomKind kind;
  final RoomSettings initial;

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet> {
  late RoomSettings _settings = widget.initial;

  @override
  Widget build(BuildContext context) {
    final setup = ref.watch(battleSetupProvider(widget.goal)).value;
    return SheetScaffold(
      title: 'Game settings',
      footer: AppButton(
        label: 'Save',
        onPressed: setup == null ? null : () => Navigator.pop(context, _settings),
      ),
      child: setup == null
          ? const Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                0,
                AppSpacing.gutter,
                AppSpacing.lg,
              ),
              child: RoomSettingsForm(
                kind: widget.kind,
                setup: setup,
                settings: _settings,
                onChanged: (next) => setState(() => _settings = next),
              ),
            ),
    );
  }
}

class _LobbySkeleton extends StatelessWidget {
  const _LobbySkeleton();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(AppSpacing.gutter),
    child: Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkeletonBox(height: 180, radius: AppRadii.xxl),
          SizedBox(height: AppSpacing.lg),
          SkeletonBox(height: 110, radius: AppRadii.lg),
          SizedBox(height: AppSpacing.xl),
          SkeletonBox(height: 64, radius: AppRadii.lg),
          SizedBox(height: AppSpacing.sm),
          SkeletonBox(height: 64, radius: AppRadii.lg),
        ],
      ),
    ),
  );
}
