import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../app/router.dart';
import '../../core/auth/session.dart';
import '../../core/auth/user.dart';
import '../../core/network/app_failure.dart';
import '../../core/network/connectivity.dart';
import '../../core/utils/ids.dart';
import '../battle/data/battle_models.dart';
import '../battle/data/battle_repository.dart';
import '../learn/widgets/learn_widgets.dart' show failureMessage;
import '../social/social_providers.dart';
import 'data/room_models.dart';
import 'room_text.dart';
import 'rooms_controller.dart';
import 'widgets/room_widgets.dart';

/// Setting up a Play with Friend duel or a Group Battle (`/battle/room/new?kind=`): subject,
/// chapters, questions and time (and the group options), then **Create**, which makes the room
/// (`POST /v1/rooms`), joins it and opens the lobby. A friend picked beforehand (Social →
/// Challenge) is invited as soon as the room exists.
class RoomSetupScreen extends ConsumerStatefulWidget {
  const RoomSetupScreen({super.key, required this.kind, this.friendId, this.subject, this.chapter});

  final RoomKind kind;

  /// A friend to invite once the room exists.
  final String? friendId;
  final String? subject;
  final String? chapter;

  @override
  ConsumerState<RoomSetupScreen> createState() => _RoomSetupScreenState();
}

class _RoomSetupScreenState extends ConsumerState<RoomSetupScreen> {
  /// One key per screen, so a retried Create returns the same room.
  final String _key = randomHexId();
  RoomSettings? _settings;
  bool _creating = false;
  String? _error;

  RoomSettings _resolve(BattleSetup setup) {
    final current = _settings;
    if (current != null) return current;
    final subject =
        setup.subject(widget.subject) ?? setup.subject(setup.last?.subject) ?? setup.subjects.first;
    final chapter = subject.chapter(widget.chapter);
    return defaultRoomSettings(
      widget.kind,
      subject: subject.slug,
      chapter: chapter != null && chapter.battleReady ? chapter.slug : null,
    );
  }

  Future<void> _create(RoomSettings settings) async {
    final rooms = ref.read(roomsControllerProvider);
    if (rooms == null) {
      showAppToast(context, 'Still connecting. Try again in a moment.', icon: AppIcons.info);
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final view = await rooms.create(widget.kind, settings, idempotencyKey: _key);
      if (!mounted) return;
      context.go(Routes.room(view.roomId, invite: widget.friendId));
    } on RealtimeError catch (error) {
      // BUSY shows "Go there" on the live layer.
      if (mounted && error.code != RealtimeErrorCode.busy) {
        setState(() => _error = RoomText.error(error));
      }
    } on AppFailure catch (failure) {
      if (!mounted) return;
      if (failure is ConflictFailure && failure.code == 'BUSY') {
        setState(() => _error = 'You\'re already in a room or a game. Finish it first.');
      } else {
        setState(() => _error = failure.message);
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final goal = ref.watch(meProvider.select((me) => me.goal)) ?? Goal.neet;
    final setup = ref.watch(battleSetupProvider(goal));
    final online = ref.watch(isOnlineProvider);
    final friend = widget.friendId == null
        ? null
        : ref
              .watch(friendsProvider)
              .value
              ?.friends
              .where((f) => f.user.id == widget.friendId)
              .firstOrNull;
    final group = widget.kind == RoomKind.group;

    return Scaffold(
      appBar: AppTopBar(title: group ? 'Group battle' : 'Play with a friend'),
      body: switch (setup) {
        AsyncValue(:final value?) when value.subjects.isEmpty => Center(
          child: EmptyState(
            icon: AppIcons.battle,
            title: 'No battles yet',
            message: 'Battles for ${goal.label} are on the way.',
          ),
        ),
        AsyncValue(:final value?) => _form(value, friend?.user.displayName, online: online),
        AsyncValue(:final error?) => Center(
          child: ErrorState(
            title: 'Couldn\'t load subjects',
            message: failureMessage(error),
            retrying: setup.isLoading,
            onRetry: () => ref.invalidate(battleSetupProvider(goal)),
          ),
        ),
        _ => const _SetupSkeleton(),
      },
    );
  }

  Widget _form(BattleSetup setup, String? friendName, {required bool online}) {
    final text = context.text;
    final colors = context.colors;
    final settings = _resolve(setup);
    final group = widget.kind == RoomKind.group;
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
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  InfoChip(
                    icon: group ? AppIcons.social : AppIcons.userAdd,
                    label: group ? '2–8 players' : 'Private 1v1',
                    background: colors.surfaceMuted,
                  ),
                  InfoChip(
                    icon: AppIcons.shield,
                    label: 'Unrated · free',
                    background: colors.surfaceMuted,
                  ),
                  InfoChip(
                    icon: AppIcons.star,
                    label: group ? 'XP: 20 win · 10 taking part' : 'Half XP',
                    background: colors.surfaceMuted,
                  ),
                ],
              ),
              if (friendName != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  'You\'ll invite $friendName as soon as the room is ready.',
                  style: text.bodyMedium,
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              RoomSettingsForm(
                kind: widget.kind,
                setup: setup,
                settings: settings,
                onChanged: _creating ? null : (next) => setState(() => _settings = next),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.sm,
              AppSpacing.gutter,
              AppSpacing.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error case final error?) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      style: text.labelMedium.copyWith(color: colors.onErrorContainer),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (!online) ...[
                  Text(
                    'You\'re offline. Connect to create a room.',
                    style: text.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                AppButton(
                  label: 'Create room',
                  trailingIcon: AppIcons.chevronRight,
                  loading: _creating,
                  onPressed: online && !_creating ? () => _create(settings) : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SetupSkeleton extends StatelessWidget {
  const _SetupSkeleton();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(AppSpacing.gutter),
    child: Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkeletonBox(height: AppSizes.chip, radius: AppRadii.pill),
          SizedBox(height: AppSpacing.xl),
          SkeletonBox(height: AppSizes.chip, radius: AppRadii.pill),
          SizedBox(height: AppSpacing.lg),
          SkeletonBox(height: 64, radius: AppRadii.lg),
          SizedBox(height: AppSpacing.lg),
          SkeletonBox(height: AppSizes.buttonMedium, radius: AppRadii.pill),
          SizedBox(height: AppSpacing.lg),
          SkeletonBox(height: AppSizes.buttonMedium, radius: AppRadii.pill),
        ],
      ),
    ),
  );
}
