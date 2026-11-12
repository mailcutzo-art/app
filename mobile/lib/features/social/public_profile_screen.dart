import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import '../learn/widgets/learn_widgets.dart' show failureMessage;
import 'data/social_models.dart';
import 'social_providers.dart';
import 'widgets/social_widgets.dart';

/// Another player's profile (`/u/:handle`, also the shared link): card,
/// level, ratings, recent form, the record between you, and what you can do
/// (add, cancel, accept, challenge, remove, block, report).
///
/// For a minor who isn't a friend the server sends only the card, and only
/// the card is shown.
class PublicProfileScreen extends ConsumerWidget {
  const PublicProfileScreen({super.key, required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(publicProfileProvider(handle));
    final loaded = profile.value;
    final me = ref.watch(meProvider);
    final isMe = loaded != null && loaded.user.id == me.id;
    return Scaffold(
      appBar: AppTopBar(
        title: '@$handle',
        onBack: () => context.canPop() ? context.pop() : context.go(Routes.social),
        actions: [
          if (loaded != null && !isMe)
            AppIconButton(
              icon: AppIcons.more,
              semanticLabel: 'More',
              onPressed: () => _showMore(context, ref, loaded),
            ),
        ],
      ),
      body: switch (profile) {
        AsyncValue(:final value?) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(publicProfileProvider(handle));
            try {
              await ref.read(publicProfileProvider(handle).future);
            } on Object {
              // The screen shows the error.
            }
          },
          child: _ProfileBody(profile: value, isMe: isMe),
        ),
        AsyncValue(error: NotFoundFailure()) => Center(
          child: EmptyState(
            icon: AppIcons.user,
            tone: PastelTone.lavender,
            title: 'Player not found',
            message: 'There\'s no player @$handle, or their profile isn\'t available.',
            actionLabel: 'Back to Social',
            onAction: () => context.go(Routes.social),
          ),
        ),
        AsyncValue(:final error?) => Center(
          child: ErrorState(
            title: 'Couldn\'t load this profile',
            message: failureMessage(error),
            retrying: profile.isLoading,
            onRetry: () => ref.invalidate(publicProfileProvider(handle)),
          ),
        ),
        _ => const _ProfileSkeleton(),
      },
    );
  }

  Future<void> _showMore(BuildContext context, WidgetRef ref, PublicProfile profile) async {
    final user = profile.user;
    final blocked =
        effectiveRelationship(
          ref.read(relationshipOverridesProvider),
          user.id,
          profile.relationship,
        ) ==
        Relationship.blocked;
    final choice = await showAppSheet<String>(
      context,
      builder: (context) => SheetScaffold(
        title: user.displayName,
        child: Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableRow(
                title: blocked ? 'Unblock' : 'Block',
                icon: AppIcons.lock,
                selected: false,
                onTap: () => Navigator.pop(context, 'block'),
              ),
              SelectableRow(
                title: 'Report',
                icon: AppIcons.alert,
                selected: false,
                onTap: () => Navigator.pop(context, 'report'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'block' when blocked:
        await runSocialAction(
          context,
          () => ref.read(socialActionsProvider).unblock(user),
          done: '${user.displayName} is unblocked',
        );
      case 'block':
        await blockWithConfirm(context, ref, user);
      case 'report':
        await showReportSheet(context, user);
    }
  }
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({required this.profile, required this.isMe});

  final PublicProfile profile;
  final bool isMe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = profile.user;
    final text = context.text;
    final relationship = effectiveRelationship(
      ref.watch(relationshipOverridesProvider),
      user.id,
      profile.relationship,
    );
    final blocked = relationship == Relationship.blocked;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.sm,
        AppSpacing.gutter,
        AppSpacing.huge,
      ),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Center(child: PlayerAvatar(user: user, size: 104)),
        const SizedBox(height: AppSpacing.lg),
        Center(
          child: Text(user.displayName, style: text.headlineMedium, textAlign: TextAlign.center),
        ),
        Center(child: Text(user.at, style: text.bodyMedium)),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            alignment: WrapAlignment.center,
            children: [
              if (user.level case final level?)
                OverlineBadge(label: 'Level $level', tone: PastelTone.mint, icon: AppIcons.star),
              if (relationship == Relationship.friend)
                const OverlineBadge(label: 'Friends', tone: PastelTone.lime),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        if (isMe)
          AppButton(
            label: 'Open your profile',
            variant: AppButtonVariant.secondary,
            onPressed: () => context.push(Routes.profile),
          )
        else if (blocked)
          _BlockedNotice(user: user)
        else ...[
          _Actions(profile: profile, relationship: relationship),
          if (profile.isLimited)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xl),
              child: CompactEmpty(
                icon: AppIcons.shield,
                title: 'Some details are private',
                message: '${user.displayName} shares ratings and recent form with friends only.',
              ),
            )
          else
            _Stats(profile: profile),
        ],
      ],
    );
  }
}

class _BlockedNotice extends ConsumerWidget {
  const _BlockedNotice({required this.user});

  final UserCard user;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CompactEmpty(
    icon: AppIcons.lock,
    tone: PastelTone.rose,
    title: 'You blocked ${user.displayName}',
    message: 'You won\'t see each other or be matched together.',
    actionLabel: 'Unblock',
    onAction: () => runSocialAction(
      context,
      () => ref.read(socialActionsProvider).unblock(user),
      done: '${user.displayName} is unblocked',
    ),
  );
}

/// The buttons for where the user stands with this player.
class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.profile, required this.relationship});

  final PublicProfile profile;
  final Relationship relationship;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  String? _busy;

  UserCard get _user => widget.profile.user;

  Future<void> _run(
    String key,
    Future<Object?> Function() action, {
    String? done,
    String Function(AppFailure failure)? failed,
  }) async {
    if (_busy != null) return;
    setState(() => _busy = key);
    await runSocialAction(context, action, done: done, failed: failed);
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    final actions = ref.read(socialActionsProvider);
    final incoming = ref.watch(friendRequestsProvider).value?.incomingFrom(user.id);
    final canChallenge = widget.profile.canChallenge && widget.relationship != Relationship.blocked;

    final buttons = <Widget>[
      if (canChallenge)
        AppButton(
          label: 'Challenge',
          leadingIcon: AppIcons.battle,
          onPressed: () => context.go(Routes.battleWithFriend(user.id)),
        ),
      ...switch (widget.relationship) {
        Relationship.none when incoming != null => [
          AppButton(
            label: 'Accept request',
            leadingIcon: AppIcons.check,
            variant: canChallenge ? AppButtonVariant.ink : AppButtonVariant.primary,
            loading: _busy == 'accept',
            onPressed: () => _run(
              'accept',
              () => actions.accept(incoming),
              done: 'You and ${user.displayName} are now friends',
            ),
          ),
          AppButton(
            label: 'Decline',
            variant: AppButtonVariant.secondary,
            loading: _busy == 'decline',
            onPressed: () => _run(
              'decline',
              () => actions.decline(incoming),
              done: 'Request from ${user.displayName} declined',
            ),
          ),
        ],
        Relationship.none => [
          AppButton(
            label: 'Add friend',
            leadingIcon: AppIcons.userAdd,
            variant: canChallenge ? AppButtonVariant.secondary : AppButtonVariant.primary,
            loading: _busy == 'add',
            onPressed: () => _run('add', () async {
              final sent = await actions.addFriend(user);
              if (!mounted) return null;
              showAppToast(
                this.context,
                sent.becameFriends
                    ? 'You and ${user.displayName} are now friends'
                    : 'Friend request sent to ${user.displayName}',
                icon: AppIcons.userAdd,
              );
              return sent;
            }, failed: (failure) => friendRequestError(failure, user)),
          ),
        ],
        Relationship.requested => [
          AppButton(
            label: 'Cancel request',
            variant: AppButtonVariant.secondary,
            loading: _busy == 'cancel',
            onPressed: () => _run(
              'cancel',
              () => actions.cancelRequest(user),
              done: 'Request to ${user.displayName} cancelled',
            ),
          ),
        ],
        Relationship.friend => [
          AppButton(
            label: 'Remove friend',
            variant: AppButtonVariant.secondary,
            loading: _busy == 'remove',
            onPressed: () async {
              // Busy only once confirmed, not while the question is open.
              if (!await confirmRemoveFriend(context, user) || !mounted) return;
              await _run(
                'remove',
                () => actions.removeFriend(user),
                done: '${user.displayName} was removed from your friends',
              );
            },
          ),
        ],
        Relationship.blocked => const <Widget>[],
      },
    ];
    return Column(
      children: [
        for (final (i, button) in buttons.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          button,
        ],
      ],
    );
  }
}

/// Ratings, form and the record between the two players, each shown only
/// when the server sent it.
class _Stats extends StatelessWidget {
  const _Stats({required this.profile});

  final PublicProfile profile;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final colors = context.colors;
    const header = EdgeInsets.fromLTRB(0, AppSpacing.xxl, 0, AppSpacing.md);
    final ratings = profile.ratings;
    final form = profile.form;
    final h2h = profile.h2h;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (h2h != null) ...[
          SectionHeader(
            title: 'Your record',
            subtitle: 'Head-to-head with ${profile.user.displayName}',
            padding: header,
          ),
          SurfaceCard(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(h2h.summary, style: text.titleMedium),
                      Text(
                        h2h.played == 1 ? '1 game played' : '${h2h.played} games played',
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
                _Count(label: 'Won', value: h2h.wins, color: colors.success),
                _Count(label: 'Lost', value: h2h.losses, color: colors.error),
                _Count(label: 'Drawn', value: h2h.draws, color: colors.inkMuted),
              ],
            ),
          ),
        ],
        if (form != null) ...[
          const SectionHeader(title: 'Recent form', padding: header),
          if (form.isEmpty)
            Text('No rated games yet.', style: text.bodyMedium)
          else
            Align(
              alignment: Alignment.centerLeft,
              child: FormStrip(form: form),
            ),
        ],
        if (ratings != null) ...[
          SectionHeader(
            title: 'Ratings',
            subtitle: 'Competitive skill score (starts at 1500)',
            actionLabel: 'Explain',
            onAction: () => _showRatingHelp(context),
            padding: header,
          ),
          if (ratings.isEmpty)
            Text('No rated games yet.', style: text.bodyMedium)
          else
            RowList(
              children: [
                for (final rating in ratings)
                  ListRowCard(
                    title: rating.label,
                    subtitle: rating.position == null
                        ? (rating.rating.provisional ? 'Provisional score' : 'Unranked')
                        : 'Rank #${rating.position}',
                    trailing: Text(rating.rating.display, style: text.numericMedium),
                    onTap: () => _showRatingHelp(context),
                  ),
              ],
            ),
        ],
      ],
    );
  }
}

void _showRatingHelp(BuildContext context) {
  showAppSheet<void>(
    context,
    builder: (context) => SheetScaffold(
      title: 'About Ratings',
      subtitle: 'Competitive skill score in Quiz Arena',
      footer: AppButton(
        label: 'Got it',
        onPressed: () => Navigator.pop(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '• Ratings represent competitive skill score (starting at 1,500 points), not the total number of games played.\n'
            '• A question mark "?" indicates a provisional rating while completing placement matches.\n'
            '• Ratings adjust up or down after each rated battle based on opponent strength and match outcome.\n'
            '• After completing 10 rated games, the provisional status is removed and global ranking is unlocked.',
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    ),
  );
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: AppSpacing.lg),
    child: Column(
      children: [
        Text('$value', style: context.text.numericMedium.copyWith(color: color)),
        Text(label, style: context.text.caption),
      ],
    ),
  );
}

class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(AppSpacing.gutter),
    child: Shimmer(
      child: Column(
        children: [
          SkeletonBox(height: 104, circle: true),
          SizedBox(height: AppSpacing.lg),
          SkeletonBox(width: 160, height: 28),
          SizedBox(height: AppSpacing.sm),
          SkeletonBox(width: 100, height: 18),
          SizedBox(height: AppSpacing.xl),
          SkeletonBox(height: 56, radius: AppRadii.pill),
          SizedBox(height: AppSpacing.xxl),
          SkeletonBox(height: 88, radius: AppRadii.xl),
          SizedBox(height: AppSpacing.md),
          SkeletonBox(height: 72, radius: AppRadii.xl),
        ],
      ),
    ),
  );
}
