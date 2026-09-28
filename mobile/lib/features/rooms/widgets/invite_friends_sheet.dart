import 'dart:async';

import 'package:clock/clock.dart';
import 'package:design_system/design_system.dart' hide Presence;
import 'package:design_system/design_system.dart' as ds show Presence;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/app_failure.dart';
import '../../../core/realtime/live_text.dart';
import '../../learn/widgets/learn_widgets.dart' show failureMessage;
import '../../social/data/social_models.dart';
import '../../social/social_providers.dart';
import '../rooms_controller.dart';

/// Opens the friends list to invite from, with presence and each invite's state.
Future<void> showInviteFriendsSheet(BuildContext context, {required VoidCallback onShare}) =>
    showAppSheet<void>(context, builder: (_) => InviteFriendsSheet(onShare: onShare));

/// What an invite row says and whether it can be sent (again).
({String? chip, bool canInvite, bool canCancel}) inviteRowState(
  Friend friend,
  OutgoingInvite? invite, {
  required bool inRoom,
  required DateTime now,
}) {
  if (inRoom) return (chip: 'In the room', canInvite: false, canCancel: false);
  switch (invite?.state) {
    case InviteState.sending:
      return (chip: 'Sending…', canInvite: false, canCancel: false);
    case InviteState.pending when invite!.isOpenAt(now):
      final left = invite.expiresAt?.difference(now);
      return (
        chip: left == null ? 'Invited' : 'Invited · ${LiveText.mmss(left)}',
        canInvite: false,
        canCancel: true,
      );
    case InviteState.pending || InviteState.expired:
      return (chip: 'Invite expired', canInvite: true, canCancel: false);
    case InviteState.accepted:
      return (chip: 'Accepted', canInvite: false, canCancel: false);
    case InviteState.declined:
      return (chip: 'Declined', canInvite: true, canCancel: false);
    case InviteState.cancelled:
      return (chip: null, canInvite: true, canCancel: false);
    case InviteState.busy:
      return (chip: 'Busy', canInvite: true, canCancel: false);
    case InviteState.notAllowed:
      return (chip: 'Can\'t be invited', canInvite: false, canCancel: false);
    case null:
      break;
  }
  if (friend.presence.isBusy) return (chip: 'Busy', canInvite: false, canCancel: false);
  return (chip: null, canInvite: true, canCancel: false);
}

/// The user's friends, online first, each with **Invite** or where their invite stands
/// ("Invited · 1:45", "Busy", "Declined"). A user without friends is pointed to Share link.
class InviteFriendsSheet extends ConsumerStatefulWidget {
  const InviteFriendsSheet({super.key, required this.onShare});

  final VoidCallback onShare;

  @override
  ConsumerState<InviteFriendsSheet> createState() => _InviteFriendsSheetState();
}

class _InviteFriendsSheetState extends ConsumerState<InviteFriendsSheet> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Invites count down from 2 minutes.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // Presence may be stale: ask again quietly.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(friendsProvider.notifier).poll());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _invite(Friend friend) async {
    try {
      await ref.read(roomsControllerProvider)?.invite(friend.user.id);
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    }
  }

  Future<void> _cancel(Friend friend) async {
    try {
      await ref.read(roomsControllerProvider)?.cancelInvite(friend.user.id);
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    }
  }

  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(friendsProvider);
    final outgoing = ref.watch(outgoingInvitesProvider);
    final members = {
      for (final member in ref.watch(roomViewProvider)?.state.members ?? const []) member.uid,
    };
    final now = clock.now();
    return SheetScaffold(
      title: 'Invite friends',
      subtitle: 'An invite lasts 2 minutes',
      footer: AppButton(
        label: 'Share link instead',
        variant: AppButtonVariant.secondary,
        leadingIcon: AppIcons.share,
        onPressed: widget.onShare,
      ),
      child: switch (friends) {
        AsyncValue(:final value?) when value.friends.isEmpty => const Padding(
          padding: EdgeInsets.only(bottom: AppSpacing.lg),
          child: EmptyState(
            icon: AppIcons.userAdd,
            tone: PastelTone.lavender,
            title: 'No friends yet',
            message: 'Share the link and anyone can join with the code.',
          ),
        ),
        AsyncValue(:final value?) => ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.lg,
          ),
          children: [
            for (final friend in value.sorted)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: _FriendRow(
                  friend: friend,
                  state: inviteRowState(
                    friend,
                    outgoing[friend.user.id],
                    inRoom: members.contains(friend.user.id),
                    now: now,
                  ),
                  onInvite: () => _invite(friend),
                  onCancel: () => _cancel(friend),
                ),
              ),
          ],
        ),
        AsyncValue(:final error?) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          child: ErrorState(
            compact: true,
            title: 'Couldn\'t load your friends',
            message: failureMessage(error),
            retrying: friends.isLoading,
            onRetry: () => ref.invalidate(friendsProvider),
          ),
        ),
        _ => const Padding(
          padding: EdgeInsets.all(AppSpacing.gutter),
          child: Shimmer(
            child: Column(
              children: [
                SkeletonBox(height: 56, radius: AppRadii.lg),
                SizedBox(height: AppSpacing.sm),
                SkeletonBox(height: 56, radius: AppRadii.lg),
                SizedBox(height: AppSpacing.sm),
                SkeletonBox(height: 56, radius: AppRadii.lg),
              ],
            ),
          ),
        ),
      },
    );
  }
}

class _FriendRow extends StatelessWidget {
  const _FriendRow({
    required this.friend,
    required this.state,
    required this.onInvite,
    required this.onCancel,
  });

  final Friend friend;
  final ({String? chip, bool canInvite, bool canCancel}) state;
  final VoidCallback onInvite;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final user = friend.user;
    final presence = switch (friend.presence) {
      FriendPresence.online => ds.Presence.online,
      FriendPresence.inBattle || FriendPresence.inTournament => ds.Presence.playing,
      FriendPresence.offline => ds.Presence.offline,
    };
    final chip = state.chip;
    return Row(
      children: [
        AppAvatar(data: user.avatar.toData(), presence: presence),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user.displayName,
                style: text.titleMedium.copyWith(fontSize: 15),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(friend.presence.label, style: text.caption),
            ],
          ),
        ),
        if (chip != null) ...[
          const SizedBox(width: AppSpacing.sm),
          InfoChip(
            label: chip,
            background: chip == 'Busy' ? colors.warningContainer : colors.surfaceMuted,
            foreground: chip == 'Busy' ? colors.onWarningContainer : null,
          ),
        ],
        if (state.canCancel)
          AppIconButton(
            icon: AppIcons.close,
            size: AppSizes.iconButtonSmall,
            variant: AppIconButtonVariant.ghost,
            semanticLabel: 'Cancel the invite to ${user.displayName}',
            onPressed: onCancel,
          ),
        if (state.canInvite) ...[
          const SizedBox(width: AppSpacing.sm),
          AppButton(
            label: chip == null ? 'Invite' : 'Again',
            size: AppButtonSize.small,
            expand: false,
            onPressed: onInvite,
          ),
        ],
      ],
    );
  }
}
