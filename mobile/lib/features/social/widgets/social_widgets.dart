import 'dart:async';

import 'package:clock/clock.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/network/app_failure.dart';
import '../data/social_models.dart';
import '../social_providers.dart';

/// The design system's presence dot for a friend's presence.
Presence presenceDot(FriendPresence presence) => switch (presence) {
  FriendPresence.online => Presence.online,
  FriendPresence.inBattle || FriendPresence.inTournament => Presence.playing,
  FriendPresence.offline => Presence.offline,
};

/// "just now", "5m ago", "3h ago", "2d ago".
String timeAgo(DateTime at, {DateTime? now}) {
  final elapsed = (now ?? clock.now()).difference(at);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
  return '${elapsed.inDays}d ago';
}

/// "Level 7", or null without a level.
String? levelLabel(UserCard user) => user.level == null ? null : 'Level ${user.level}';

/// Why a friend request didn't go through, in words for people.
String friendRequestError(AppFailure failure, UserCard user) {
  final details = failure is ForbiddenFailure ? failure.details : const <String, Object?>{};
  return switch (failure.code) {
    'NOT_ALLOWED' => switch (details['reason']) {
      'played_with' => '${user.displayName} only accepts requests from people they\'ve played.',
      'nobody' => '${user.displayName} isn\'t accepting friend requests.',
      'blocked' => 'You can\'t send ${user.displayName} a request.',
      'friends_limit' || 'their_limit' => '${user.displayName} can\'t take more friends right now.',
      _ => '${user.displayName}\'s privacy settings don\'t allow requests from you.',
    },
    'LIMIT_REACHED' =>
      'You\'ve sent a lot of requests. You can send 20 a day and have 100 waiting.',
    'ALREADY_FRIENDS' => 'You\'re already friends with ${user.displayName}.',
    _ => failure.message,
  };
}

/// Runs a social [action] and shows [done] as a toast, or the failure's
/// message (through [failed] when given). Returns whether it worked.
Future<bool> runSocialAction(
  BuildContext context,
  Future<Object?> Function() action, {
  String? done,
  String Function(AppFailure failure)? failed,
  HugeIconData? icon,
}) async {
  try {
    await action();
  } on AppFailure catch (failure) {
    if (context.mounted) {
      showAppToast(context, failed?.call(failure) ?? failure.message, icon: AppIcons.alert);
    }
    return false;
  }
  if (done != null && context.mounted) showAppToast(context, done, icon: icon ?? AppIcons.check);
  return true;
}

/// A player's preset avatar, with a presence dot for friends.
class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar({super.key, required this.user, this.presence, this.size = AppSizes.avatar});

  final UserCard user;
  final FriendPresence? presence;
  final double size;

  @override
  Widget build(BuildContext context) => AppAvatar(
    data: user.avatar.toData(),
    size: size,
    presence: presence == null ? null : presenceDot(presence!),
  );
}

/// One player in a list: avatar, name, a detail line and a trailing action.
/// Tapping the row opens their profile.
class PlayerRow extends StatelessWidget {
  const PlayerRow({
    super.key,
    required this.user,
    this.subtitle,
    this.presence,
    this.trailing,
    this.onTap,
    this.openProfile = true,
  });

  final UserCard user;
  final String? subtitle;
  final FriendPresence? presence;
  final Widget? trailing;

  /// Defaults to opening the profile when [openProfile] is true.
  final VoidCallback? onTap;
  final bool openProfile;

  @override
  Widget build(BuildContext context) => ListRowCard(
    title: user.displayName,
    subtitle: subtitle ?? [user.at, ?levelLabel(user)].join(' · '),
    leading: PlayerAvatar(user: user, presence: presence),
    trailing: trailing,
    onTap: onTap ?? (openProfile ? () => context.push(Routes.userProfile(user.handle)) : null),
  );
}

/// A section title with an optional count badge (e.g. new requests).
class SocialSectionHeader extends StatelessWidget {
  const SocialSectionHeader({super.key, required this.title, this.subtitle, this.count});

  final String title;
  final String? subtitle;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final badge = count;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.xxl,
        AppSpacing.gutter,
        AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(title, style: text.titleLarge)),
                    if (badge != null && badge > 0) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Semantics(
                        label: '$badge new',
                        excludeSemantics: true,
                        child: OverlineBadge(label: '$badge', tone: PastelTone.rose, solid: true),
                      ),
                    ],
                  ],
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: text.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A card-sized empty state for a section, with a call to action.
class CompactEmpty extends StatelessWidget {
  const CompactEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.tone = PastelTone.sky,
    this.actionLabel,
    this.onAction,
  });

  final HugeIconData icon;
  final String title;
  final String message;
  final PastelTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pair = colors.pastel(tone);
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: HugeIcon(icon, size: 22, color: pair.onContainer),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium),
                Text(message, style: text.bodySmall),
              ],
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(width: AppSpacing.sm),
            AppButton(
              label: actionLabel!,
              onPressed: onAction,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              expand: false,
            ),
          ],
        ],
      ),
    );
  }
}

/// Loading placeholder shaped like a list of player rows.
class PlayerRowsSkeleton extends StatelessWidget {
  const PlayerRowsSkeleton({super.key, this.rows = 3});

  final int rows;

  @override
  Widget build(BuildContext context) => Shimmer(
    child: Column(
      children: [
        for (var i = 0; i < rows; i++)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: SkeletonBox(height: 72, radius: AppRadii.xl),
          ),
      ],
    ),
  );
}

/// Vertical list of rows with the standard gap.
class RowList extends StatelessWidget {
  const RowList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final (i, child) in children.indexed) ...[
        if (i > 0) const SizedBox(height: AppSpacing.sm),
        child,
      ],
    ],
  );
}

/// "Add friend", "Requested" or "Friends" for a player in a list. Only "Add
/// friend" does something; a request is cancelled from the profile.
class RelationshipButton extends ConsumerStatefulWidget {
  const RelationshipButton({super.key, required this.user, required this.relationship});

  final UserCard user;

  /// What the server said; local changes are applied on top.
  final Relationship relationship;

  @override
  ConsumerState<RelationshipButton> createState() => _RelationshipButtonState();
}

class _RelationshipButtonState extends ConsumerState<RelationshipButton> {
  bool _busy = false;

  Future<void> _add() async {
    setState(() => _busy = true);
    final user = widget.user;
    SentRequest? sent;
    await runSocialAction(
      context,
      () async => sent = await ref.read(socialActionsProvider).addFriend(user),
      failed: (failure) => friendRequestError(failure, user),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (sent case final sent?) {
      showAppToast(
        context,
        sent.becameFriends
            ? 'You and ${user.displayName} are now friends'
            : 'Friend request sent to ${user.displayName}',
        icon: AppIcons.userAdd,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final overrides = ref.watch(relationshipOverridesProvider);
    final relationship = effectiveRelationship(overrides, widget.user.id, widget.relationship);
    return switch (relationship) {
      Relationship.none => AppButton(
        label: 'Add friend',
        leadingIcon: AppIcons.userAdd,
        variant: AppButtonVariant.tonal,
        tone: PastelTone.lime,
        size: AppButtonSize.small,
        expand: false,
        loading: _busy,
        onPressed: _add,
      ),
      Relationship.requested => const AppButton(
        label: 'Requested',
        variant: AppButtonVariant.secondary,
        size: AppButtonSize.small,
        expand: false,
        onPressed: null,
      ),
      Relationship.friend => const InfoChip(label: 'Friends', icon: AppIcons.checkCircle),
      Relationship.blocked => const InfoChip(label: 'Blocked', icon: AppIcons.lock),
    };
  }
}

/// The last results as small W / L / D circles, oldest first.
class FormStrip extends StatelessWidget {
  const FormStrip({super.key, required this.form});

  final List<FormResult> form;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      label: 'Recent form: ${form.map((r) => r.label).join(', ')}',
      excludeSemantics: true,
      child: Wrap(
        spacing: AppSpacing.sm,
        children: [
          for (final result in form)
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: switch (result) {
                  FormResult.win => colors.successContainer,
                  FormResult.loss => colors.errorContainer,
                  FormResult.draw => colors.surfaceSunken,
                },
              ),
              child: Text(
                result.letter,
                style: context.text.labelMedium.copyWith(
                  color: switch (result) {
                    FormResult.win => colors.onSuccessContainer,
                    FormResult.loss => colors.onErrorContainer,
                    FormResult.draw => colors.inkMuted,
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- sheets

/// Asks before blocking. True when confirmed.
Future<bool> confirmBlock(BuildContext context, UserCard user) async {
  final confirmed = await showAppSheet<bool>(
    context,
    builder: (context) => SheetScaffold(
      title: 'Block ${user.displayName}?',
      subtitle:
          'You won\'t see each other in search, lists or games. Pending requests and invites '
          'are cancelled, and you won\'t be matched together. You can unblock them in '
          'Settings → Privacy.',
      footer: const _ConfirmButtons(label: 'Block', danger: true),
      child: const SizedBox.shrink(),
    ),
  );
  return confirmed ?? false;
}

/// Asks before removing a friend. True when confirmed.
Future<bool> confirmRemoveFriend(BuildContext context, UserCard user) async {
  final confirmed = await showAppSheet<bool>(
    context,
    builder: (context) => SheetScaffold(
      title: 'Remove ${user.displayName}?',
      subtitle: 'They won\'t be told. You can send a new request any time.',
      footer: const _ConfirmButtons(label: 'Remove friend', danger: true),
      child: const SizedBox.shrink(),
    ),
  );
  return confirmed ?? false;
}

class _ConfirmButtons extends StatelessWidget {
  const _ConfirmButtons({required this.label, this.danger = false});

  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      AppButton(
        label: label,
        variant: danger ? AppButtonVariant.danger : AppButtonVariant.primary,
        onPressed: () => Navigator.pop(context, true),
      ),
      const SizedBox(height: AppSpacing.sm),
      AppButton(
        label: 'Cancel',
        variant: AppButtonVariant.ghost,
        onPressed: () => Navigator.pop(context, false),
      ),
    ],
  );
}

/// Blocks [user] after asking, with a toast either way. True when blocked.
Future<bool> blockWithConfirm(BuildContext context, WidgetRef ref, UserCard user) async {
  if (!await confirmBlock(context, user)) return false;
  if (!context.mounted) return false;
  return runSocialAction(
    context,
    () => ref.read(socialActionsProvider).block(user),
    done: '${user.displayName} is blocked',
    icon: AppIcons.lock,
  );
}

/// Removes [user] as a friend after asking. True when removed.
Future<bool> removeFriendWithConfirm(BuildContext context, WidgetRef ref, UserCard user) async {
  if (!await confirmRemoveFriend(context, user)) return false;
  if (!context.mounted) return false;
  return runSocialAction(
    context,
    () => ref.read(socialActionsProvider).removeFriend(user),
    done: '${user.displayName} was removed from your friends',
  );
}

/// The report form: a reason, an optional note, and "also block". The sheet
/// sends it and says thanks; it stays open if sending fails.
Future<void> showReportSheet(BuildContext context, UserCard user, {String? matchId}) async {
  final sent = await showAppSheet<bool>(
    context,
    builder: (context) => _ReportSheet(user: user, matchId: matchId),
  );
  if (sent == true && context.mounted) {
    showAppToast(context, 'Thanks. Our team will review your report.', icon: AppIcons.shield);
  }
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.user, this.matchId});

  final UserCard user;
  final String? matchId;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  final _note = TextEditingController();
  ReportReason? _reason;
  bool _alsoBlock = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final actions = ref.read(socialActionsProvider);
    try {
      await actions.report(widget.user, reason: reason, note: _note.text, matchId: widget.matchId);
      if (_alsoBlock) await actions.block(widget.user);
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = failure.message;
        });
      }
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    return SheetScaffold(
      title: 'Report ${user.displayName}',
      subtitle: 'Reports are private. ${user.displayName} won\'t know who sent it.',
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            Text(
              _error!,
              style: context.text.bodySmall.copyWith(color: context.colors.error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          AppButton(
            label: 'Send report',
            variant: AppButtonVariant.danger,
            loading: _sending,
            onPressed: _reason == null ? null : _send,
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final reason in ReportReason.values)
              SelectableRow(
                title: reason.label,
                subtitle: reason.hint,
                selected: _reason == reason,
                onTap: _sending ? null : () => setState(() => _reason = reason),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.md,
                AppSpacing.gutter,
                AppSpacing.sm,
              ),
              child: AppTextField(
                label: 'Anything else? (optional)',
                controller: _note,
                hint: 'What happened',
                maxLength: 500,
                textInputAction: TextInputAction.done,
              ),
            ),
            ToggleRow(
              title: 'Also block ${user.displayName}',
              subtitle: 'You won\'t see each other again',
              value: _alsoBlock,
              onChanged: _sending ? null : (value) => setState(() => _alsoBlock = value),
            ),
          ],
        ),
      ),
    );
  }
}

/// What can be done with a friend: open their profile, challenge, remove,
/// block or report.
Future<void> showFriendActions(BuildContext context, WidgetRef ref, UserCard user) async {
  final choice = await showAppSheet<_FriendAction>(
    context,
    builder: (context) => SheetScaffold(
      title: user.displayName,
      subtitle: [user.at, ?levelLabel(user)].join(' · '),
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in _FriendAction.values)
              SelectableRow(
                title: action.label,
                icon: action.icon,
                selected: false,
                onTap: () => Navigator.pop(context, action),
              ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case _FriendAction.profile:
      unawaited(context.push(Routes.userProfile(user.handle)));
    case _FriendAction.challenge:
      context.go(Routes.battleWithFriend(user.id));
    case _FriendAction.remove:
      await removeFriendWithConfirm(context, ref, user);
    case _FriendAction.block:
      await blockWithConfirm(context, ref, user);
    case _FriendAction.report:
      await showReportSheet(context, user);
  }
}

enum _FriendAction {
  profile('View profile', AppIcons.user),
  challenge('Challenge', AppIcons.battle),
  remove('Remove friend', AppIcons.delete),
  block('Block', AppIcons.lock),
  report('Report', AppIcons.alert);

  const _FriendAction(this.label, this.icon);

  final String label;
  final HugeIconData icon;
}
