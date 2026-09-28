import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderOrFamily;
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart';
import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import '../../core/network/connectivity.dart';
import '../learn/widgets/learn_widgets.dart' show failureMessage;
import '../profile/data/profile_models.dart' show StatsRange;
import '../profile/profile_providers.dart' show statsProvider;
import '../share/share_card.dart';
import '../share/share_sheet.dart';
import '../share/share_sources.dart';
import 'data/social_models.dart';
import 'social_providers.dart';
import 'widgets/presence_poller.dart';
import 'widgets/social_widgets.dart';

/// The Social tab: search by handle, friend requests, friends with presence,
/// rivals, recent opponents and friends' activity. Each section loads and
/// fails on its own.
class SocialScreen extends ConsumerStatefulWidget {
  const SocialScreen({super.key});

  @override
  ConsumerState<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends ConsumerState<SocialScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _findFriends() => _searchFocus.requestFocus();

  void _clearSearch() {
    _search.clear();
    _searchFocus.unfocus();
    ref.read(userSearchProvider.notifier).clear();
  }

  /// Friends' presence and new requests, every 30 s while the tab shows.
  Future<void> _poll() async {
    await Future.wait([
      ref.read(friendsProvider.notifier).poll(),
      ref.read(friendRequestsProvider.notifier).poll(),
    ]);
  }

  Future<void> _refresh() async {
    ref.read(relationshipOverridesProvider.notifier).clear();
    _invalidateSections();
    final results = await Future.wait([
      _settle(ref.read(friendRequestsProvider.future)),
      _settle(ref.read(friendsProvider.future)),
      _settle(ref.read(rivalsProvider.future)),
      _settle(ref.read(recentOpponentsProvider.future)),
      _settle(ref.read(activityProvider.future)),
    ]);
    if (!mounted) return;
    if (results.contains(false)) {
      showAppToast(context, 'Couldn\'t refresh everything. Try again in a moment.');
    }
  }

  /// Reloads every section, or only those showing an error.
  void _invalidateSections({bool failedOnly = false}) {
    void reload(ProviderOrFamily provider, bool failed) {
      if (!failedOnly || failed) ref.invalidate(provider);
    }

    reload(friendRequestsProvider, ref.read(friendRequestsProvider).hasError);
    reload(friendsProvider, ref.read(friendsProvider).hasError);
    reload(rivalsProvider, ref.read(rivalsProvider).hasError);
    reload(recentOpponentsProvider, ref.read(recentOpponentsProvider).hasError);
    reload(activityProvider, ref.read(activityProvider).hasError);
  }

  static Future<bool> _settle(Future<Object?> future) async {
    try {
      await future;
      return true;
    } on Object {
      return false; // Each section shows its own error.
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final online = ref.watch(isOnlineProvider);
    final search = ref.watch(userSearchProvider);

    // Sections that failed load again by themselves when the connection is back.
    ref.listen(isOnlineProvider, (wasOnline, online) {
      if (!online || wasOnline != false) return;
      _invalidateSections(failedOnly: true);
    });

    return PresencePoller(
      interval: const Duration(seconds: 30),
      onPoll: _poll,
      child: TabPage(
        onRefresh: _refresh,
        children: [
          OfflineBanner(visible: !online),
          LargeTitle(
            title: 'Social',
            subtitle: 'Friends, rivals and challenges.',
            trailing: Pressable(
              onPressed: () => context.push(Routes.profile),
              semanticLabel: 'Your profile',
              child: AppAvatar(data: me.avatar.toData(), ring: true),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Gutter(
            child: AppSearchField(
              controller: _search,
              focusNode: _searchFocus,
              hint: 'Find players by username',
              onChanged: ref.read(userSearchProvider.notifier).setQuery,
            ),
          ),
          if (search.active)
            _SearchResults(state: search, onClear: _clearSearch)
          else ...[
            _RequestsSection(onFindFriends: _findFriends),
            _FriendsSection(onFindFriends: _findFriends),
            const _RivalsSection(),
            const _OpponentsSection(),
            _ActivitySection(onFindFriends: _findFriends),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- search

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.state, required this.onClear});

  final UserSearchState state;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overrides = ref.watch(relationshipOverridesProvider);
    final Widget body = switch (state.status) {
      SearchStatus.tooShort => const CompactEmpty(
        icon: AppIcons.search,
        title: 'Keep typing',
        message: 'Type at least ${UserSearchController.minLength} letters of a username.',
      ),
      SearchStatus.loading when state.results.isEmpty => const PlayerRowsSkeleton(rows: 2),
      SearchStatus.failed => ErrorState(
        compact: true,
        title: 'Search didn\'t work',
        message: state.error?.message ?? 'Something went wrong. Please try again.',
        onRetry: ref.read(userSearchProvider.notifier).retry,
      ),
      _ => () {
        final results = [
          for (final result in state.results)
            if (effectiveRelationship(overrides, result.user.id, result.relationship) !=
                Relationship.blocked)
              result,
        ];
        if (results.isEmpty) {
          return CompactEmpty(
            icon: AppIcons.user,
            title: 'No players found',
            message: 'Nobody\'s username starts with “${state.query}”.',
            actionLabel: 'Clear',
            onAction: onClear,
          );
        }
        return RowList(
          children: [
            for (final result in results)
              PlayerRow(
                user: result.user,
                trailing: RelationshipButton(user: result.user, relationship: result.relationship),
              ),
          ],
        );
      }(),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SocialSectionHeader(title: 'Players'),
        Gutter(child: body),
      ],
    );
  }
}

// ---------------------------------------------------------------- requests

class _RequestsSection extends ConsumerWidget {
  const _RequestsSection({required this.onFindFriends});

  final VoidCallback onFindFriends;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(friendRequestsProvider);
    final incoming = requests.value?.incoming.length ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SocialSectionHeader(title: 'Requests', count: incoming),
        Gutter(
          child: switch (requests) {
            AsyncValue(:final value?) when value.isEmpty => CompactEmpty(
              icon: AppIcons.userAdd,
              tone: PastelTone.lavender,
              title: 'No requests',
              message: 'Requests you send and get show up here.',
              actionLabel: 'Find friends',
              onAction: onFindFriends,
            ),
            AsyncValue(:final value?) => RowList(
              children: [
                for (final request in value.incoming) _IncomingRequestRow(request: request),
                for (final request in value.outgoing) _OutgoingRequestRow(request: request),
              ],
            ),
            AsyncValue(:final error?) => ErrorState(
              compact: true,
              title: 'Couldn\'t load requests',
              message: failureMessage(error),
              retrying: requests.isLoading,
              onRetry: () => ref.invalidate(friendRequestsProvider),
            ),
            _ => const PlayerRowsSkeleton(rows: 1),
          },
        ),
      ],
    );
  }
}

class _IncomingRequestRow extends ConsumerWidget {
  const _IncomingRequestRow({required this.request});

  final FriendRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = request.user;
    final actions = ref.read(socialActionsProvider);
    return PlayerRow(
      user: user,
      subtitle: [
        'Wants to be friends',
        if (request.createdAt case final at?) timeAgo(at),
      ].join(' · '),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIconButton(
            icon: AppIcons.close,
            semanticLabel: 'Decline ${user.displayName}',
            size: 40,
            onPressed: () => runSocialAction(
              context,
              () => actions.decline(request),
              done: 'Request from ${user.displayName} declined',
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          AppIconButton(
            icon: AppIcons.check,
            semanticLabel: 'Accept ${user.displayName}',
            size: 40,
            variant: AppIconButtonVariant.ink,
            onPressed: () => runSocialAction(
              context,
              () => actions.accept(request),
              done: 'You and ${user.displayName} are now friends',
              icon: AppIcons.userAdd,
            ),
          ),
        ],
      ),
    );
  }
}

class _OutgoingRequestRow extends ConsumerWidget {
  const _OutgoingRequestRow({required this.request});

  final FriendRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = request.user;
    return PlayerRow(
      user: user,
      subtitle: 'Request sent · ${user.at}',
      trailing: AppButton(
        label: 'Cancel',
        variant: AppButtonVariant.secondary,
        size: AppButtonSize.small,
        expand: false,
        onPressed: () => runSocialAction(
          context,
          () => ref.read(socialActionsProvider).cancelRequest(user),
          done: 'Request to ${user.displayName} cancelled',
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- friends

class _FriendsSection extends ConsumerWidget {
  const _FriendsSection({required this.onFindFriends});

  final VoidCallback onFindFriends;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends = ref.watch(friendsProvider);
    final value = friends.value;
    final online = value?.onlineCount ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SocialSectionHeader(
          title: 'Friends',
          subtitle: value == null || value.friends.isEmpty
              ? null
              : online == 0
              ? '${value.friends.length}${value.hasMore ? '+' : ''} friends'
              : '$online online',
        ),
        Gutter(
          child: switch (friends) {
            AsyncValue(:final value?) when value.friends.isEmpty => SurfaceCard(
              child: EmptyState(
                icon: AppIcons.social,
                tone: PastelTone.lavender,
                title: 'No friends yet',
                message: 'Add friends by username or share your invite link.',
                actionLabel: 'Find friends',
                onAction: onFindFriends,
              ),
            ),
            AsyncValue(:final value?) => Column(
              children: [
                RowList(children: [for (final friend in value.sorted) _FriendRow(friend: friend)]),
                if (value.hasMore) ...[
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    label: 'Show more friends',
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.medium,
                    loading: value.loadingMore,
                    onPressed: () =>
                        runSocialAction(context, ref.read(friendsProvider.notifier).loadMore),
                  ),
                ],
              ],
            ),
            AsyncValue(:final error?) => ErrorState(
              compact: true,
              title: 'Couldn\'t load your friends',
              message: failureMessage(error),
              retrying: friends.isLoading,
              onRetry: () => ref.invalidate(friendsProvider),
            ),
            _ => const PlayerRowsSkeleton(),
          },
        ),
      ],
    );
  }
}

class _FriendRow extends ConsumerWidget {
  const _FriendRow({required this.friend});

  final Friend friend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = friend.user;
    return PlayerRow(
      user: user,
      presence: friend.presence,
      subtitle: [friend.presence.label, ?levelLabel(user)].join(' · '),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppButton(
            label: 'Challenge',
            leadingIcon: AppIcons.battle,
            variant: AppButtonVariant.tonal,
            tone: PastelTone.lime,
            size: AppButtonSize.small,
            expand: false,
            onPressed: () => context.go(Routes.battleWithFriend(user.id)),
          ),
          const SizedBox(width: AppSpacing.xs),
          AppIconButton(
            icon: AppIcons.more,
            semanticLabel: 'More for ${user.displayName}',
            size: 40,
            variant: AppIconButtonVariant.ghost,
            onPressed: () => showFriendActions(context, ref, user),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- rivals and opponents

class _RivalsSection extends ConsumerWidget {
  const _RivalsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rivals = ref.watch(rivalsProvider);
    final overrides = ref.watch(relationshipOverridesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SocialSectionHeader(title: 'Rivals', subtitle: 'Played 3+ times in 60 days'),
        Gutter(
          child: switch (rivals) {
            AsyncValue(:final value?) => () {
              final visible = _unblocked(value, overrides);
              if (visible.isEmpty) {
                return CompactEmpty(
                  icon: AppIcons.battle,
                  tone: PastelTone.peach,
                  title: 'No rivals yet',
                  message: 'Play more battles to find rivals.',
                  actionLabel: 'Play',
                  onAction: () => context.go(Routes.battle),
                );
              }
              return RowList(
                children: [
                  for (final rival in visible)
                    PlayerRow(
                      user: rival.user,
                      subtitle: '${rival.h2h.summary} · ${rival.h2h.short}',
                      trailing:
                          effectiveRelationship(overrides, rival.user.id, rival.relationship) ==
                              Relationship.friend
                          ? AppButton(
                              label: 'Challenge',
                              variant: AppButtonVariant.tonal,
                              tone: PastelTone.peach,
                              size: AppButtonSize.small,
                              expand: false,
                              onPressed: () => context.go(Routes.battleWithFriend(rival.user.id)),
                            )
                          : RelationshipButton(user: rival.user, relationship: rival.relationship),
                    ),
                ],
              );
            }(),
            AsyncValue(:final error?) => ErrorState(
              compact: true,
              title: 'Couldn\'t load rivals',
              message: failureMessage(error),
              retrying: rivals.isLoading,
              onRetry: () => ref.invalidate(rivalsProvider),
            ),
            _ => const PlayerRowsSkeleton(rows: 2),
          },
        ),
      ],
    );
  }
}

class _OpponentsSection extends ConsumerWidget {
  const _OpponentsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opponents = ref.watch(recentOpponentsProvider);
    final overrides = ref.watch(relationshipOverridesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SocialSectionHeader(
          title: 'Recent opponents',
          subtitle: 'A good game can turn into a friendship',
        ),
        Gutter(
          child: switch (opponents) {
            AsyncValue(:final value?) => () {
              final visible = _unblocked(value, overrides);
              if (visible.isEmpty) {
                return CompactEmpty(
                  icon: AppIcons.social,
                  tone: PastelTone.mint,
                  title: 'No opponents yet',
                  message: 'People you battle in the last 30 days show up here.',
                  actionLabel: 'Play',
                  onAction: () => context.go(Routes.battle),
                );
              }
              return RowList(
                children: [
                  for (final opponent in visible)
                    PlayerRow(
                      user: opponent.user,
                      subtitle: [
                        opponent.h2h.short,
                        if (opponent.lastPlayedAt case final at?) timeAgo(at),
                      ].join(' · '),
                      trailing: RelationshipButton(
                        user: opponent.user,
                        relationship: opponent.relationship,
                      ),
                    ),
                ],
              );
            }(),
            AsyncValue(:final error?) => ErrorState(
              compact: true,
              title: 'Couldn\'t load recent opponents',
              message: failureMessage(error),
              retrying: opponents.isLoading,
              onRetry: () => ref.invalidate(recentOpponentsProvider),
            ),
            _ => const PlayerRowsSkeleton(rows: 2),
          },
        ),
      ],
    );
  }
}

List<Opponent> _unblocked(List<Opponent> list, Map<String, Relationship> overrides) => [
  for (final item in list)
    if (effectiveRelationship(overrides, item.user.id, item.relationship) != Relationship.blocked)
      item,
];

// ---------------------------------------------------------------- activity

class _ActivitySection extends ConsumerWidget {
  const _ActivitySection({required this.onFindFriends});

  final VoidCallback onFindFriends;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(activityProvider);
    final overrides = ref.watch(relationshipOverridesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SocialSectionHeader(title: 'Activity', subtitle: 'Your friends this week'),
        const Gutter(child: PostBox()),
        const SizedBox(height: AppSpacing.md),
        Gutter(
          child: switch (activity) {
            AsyncValue(:final value?) => () {
              // Someone just removed or blocked drops out of the feed right away.
              final items = [
                for (final item in value.items)
                  if (overrides[item.user.id] case null || Relationship.friend) item,
              ];
              if (items.isEmpty) {
                return CompactEmpty(
                  icon: AppIcons.sparkles,
                  tone: PastelTone.lemon,
                  title: 'Quiet week',
                  message: 'Friends\' level-ups, streaks, podiums and shared wins show up here.',
                  actionLabel: 'Find friends',
                  onAction: onFindFriends,
                );
              }
              return Column(
                children: [
                  RowList(children: [for (final item in items) _ActivityRow(item: item)]),
                  if (value.hasMore) ...[
                    const SizedBox(height: AppSpacing.md),
                    AppButton(
                      label: 'Show more',
                      variant: AppButtonVariant.secondary,
                      size: AppButtonSize.medium,
                      loading: value.loadingMore,
                      onPressed: () =>
                          runSocialAction(context, ref.read(activityProvider.notifier).loadMore),
                    ),
                  ],
                ],
              );
            }(),
            AsyncValue(:final error?) => ErrorState(
              compact: true,
              title: 'Couldn\'t load activity',
              message: failureMessage(error),
              retrying: activity.isLoading,
              onRetry: () => ref.invalidate(activityProvider),
            ),
            _ => const PlayerRowsSkeleton(rows: 2),
          },
        ),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item});

  final ActivityItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final icon = switch (item.kind) {
      ActivityKind.achievement => AppIcons.award,
      ActivityKind.podium => AppIcons.medal,
      ActivityKind.levelUp => AppIcons.star,
      ActivityKind.streak => AppIcons.fire,
      ActivityKind.win || ActivityKind.sharedResult => AppIcons.arena,
      ActivityKind.sharedProgress => AppIcons.chart,
      ActivityKind.other => AppIcons.sparkles,
    };
    final row = PlayerRow(
      user: item.user,
      subtitle: '${item.text} · ${timeAgo(item.createdAt)}',
      trailing: HugeIcon(icon, size: 22, color: colors.inkMuted),
    );
    final share = item.share;
    if (share == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
          child: ShareCard.compact(data: share),
        ),
      ],
    );
  }
}

/// The top of the activity section: what can be posted. Messages and photos are turned off for
/// now (the field and its buttons show as disabled); progress can be shared from here, and a win
/// from any battle's result.
class PostBox extends ConsumerStatefulWidget {
  const PostBox({super.key});

  static const offMessage = 'Messages and photos are turned off for now';

  @override
  ConsumerState<PostBox> createState() => _PostBoxState();
}

class _PostBoxState extends ConsumerState<PostBox> {
  bool _loading = false;

  Future<void> _shareProgress() async {
    setState(() => _loading = true);
    final provider = statsProvider(StatsRange.days30);
    // Keeps the (auto-disposed) stats alive while they load.
    final keepAlive = ref.listenManual(provider, (_, _) {});
    try {
      final stats = await ref.read(provider.future);
      if (!mounted) return;
      final data = progressShareData(stats, ref.read(meProvider));
      setState(() => _loading = false);
      if (data == null) {
        showAppToast(context, 'Your progress isn\'t ready yet. Try again soon.');
        return;
      }
      await showShareSheet(context, data: data);
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() => _loading = false);
      showAppToast(context, failure.message, icon: AppIcons.alert);
    } finally {
      keepAlive.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final me = ref.watch(meProvider);
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppAvatar(data: me.avatar.toData(), size: 36),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                // A text field that can't be used: it looks and reads as disabled.
                child: Semantics(
                  textField: true,
                  enabled: false,
                  readOnly: true,
                  label: 'Message',
                  hint: PostBox.offMessage,
                  excludeSemantics: true,
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      borderRadius: AppRadii.pillAll,
                      border: Border.all(color: colors.outline),
                    ),
                    child: Row(
                      children: [
                        HugeIcon(AppIcons.lock, size: 16, color: colors.inkSubtle),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            PostBox.offMessage,
                            style: text.bodySmall.copyWith(color: colors.inkSubtle),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              const AppIconButton(
                icon: AppIcons.message,
                semanticLabel: 'Send a message (turned off)',
                size: 40,
                variant: AppIconButtonVariant.ghost,
                onPressed: null,
              ),
              const AppIconButton(
                icon: AppIcons.image,
                semanticLabel: 'Add a photo (turned off)',
                size: 40,
                variant: AppIconButtonVariant.ghost,
                onPressed: null,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppButton(
                label: 'Share progress',
                leadingIcon: AppIcons.share,
                variant: AppButtonVariant.tonal,
                tone: PastelTone.lavender,
                size: AppButtonSize.small,
                expand: false,
                loading: _loading,
                onPressed: _loading ? null : _shareProgress,
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HugeIcon(AppIcons.battle, size: 16, color: colors.inkMuted),
                  const SizedBox(width: AppSpacing.xs),
                  Text('Share a win from any battle result', style: text.caption),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
