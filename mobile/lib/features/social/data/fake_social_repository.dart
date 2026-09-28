import 'package:clock/clock.dart';
import 'package:dio/dio.dart';

import '../../../core/auth/user.dart';
import '../../../core/network/app_failure.dart';
import '../../battle/data/battle_models.dart' show RatingInfo;
import '../../share/share_models.dart';
import 'social_models.dart';
import 'social_repository.dart';

/// Calls of [FakeSocialRepository] that tests can make fail.
enum FakeSocialOp {
  friends,
  search,
  sendRequest,
  requests,
  accept,
  decline,
  cancel,
  removeFriend,
  rivals,
  opponents,
  activity,
  share,
  block,
  unblock,
  blocks,
  report,
  profile,
}

/// Who may send a player friend requests (their privacy setting).
enum FakeRequestPolicy { everyone, playedWith, nobody }

/// One player in the fake world.
class FakePlayer {
  FakePlayer({
    required this.card,
    this.minor = false,
    this.policy = FakeRequestPolicy.everyone,
    this.presence = FriendPresence.offline,
    this.h2h,
    this.lastPlayedAt,
    this.ratings = const [],
    this.form = const [],
  });

  final UserCard card;
  final bool minor;
  final FakeRequestPolicy policy;
  FriendPresence presence;

  /// The record against the signed-in user; null if they never played.
  HeadToHead? h2h;
  DateTime? lastPlayedAt;
  final List<ScopedRating> ratings;
  final List<FormResult> form;

  String get id => card.id;
}

/// In-memory stand-in for the social API. Used by tests and by the debug
/// "Demo data" switch.
///
/// It follows the contract where the app can notice: search needs 3
/// characters and matches handle prefixes, blocking hides both players from
/// each other (search, profile, friends and requests) and ends a friendship,
/// requests to minors need a game played together (`NOT_ALLOWED` with
/// `details.reason`), at most 20 requests go out a day (`LIMIT_REACHED`), two
/// requests that meet become a friendship, and a minor who isn't a friend
/// shows only their card on their profile. Shares follow the server's rules:
/// a battle in [matchResults] is posted once (`ALREADY_SHARED`), any other is
/// `NOT_FOUND`, and progress ([progress]) goes out 3 times a day
/// (`LIMIT_REACHED`); the user's own shares show in their activity.
class FakeSocialRepository implements SocialRepository {
  FakeSocialRepository({
    List<FakePlayer> players = const [],
    Iterable<String> friends = const [],
    Iterable<String> incoming = const [],
    Iterable<String> outgoing = const [],
    Iterable<String> blocked = const [],
    Iterable<String> blockedBy = const [],
    List<ActivityItem> activity = const [],
    this.me = defaultMe,
    Map<String, MatchShareData> matchResults = const {},
    ProgressShareData? progress,
    this.latency = Duration.zero,
    this.pageSize = 20,
  }) : _activity = [...activity],
       matchResults = {...matchResults},
       progress = progress ?? _sampleProgress(me) {
    for (final player in players) {
      _players[player.id] = player;
    }
    _friends.addAll(friends);
    for (final id in incoming) {
      _incoming[_nextRequestId()] = id;
    }
    for (final id in outgoing) {
      _outgoing[_nextRequestId()] = id;
    }
    _blocked.addAll(blocked);
    _blockedBy.addAll(blockedBy);
  }

  /// A small world: friends in every presence, requests both ways, rivals,
  /// recent opponents, a minor who only accepts people they've played, and
  /// a week of activity.
  factory FakeSocialRepository.seeded({Duration latency = Duration.zero}) {
    final now = clock.now();
    FakePlayer player(
      String id,
      String handle,
      String name,
      String tone,
      String symbol,
      int level, {
      bool minor = false,
      FakeRequestPolicy policy = FakeRequestPolicy.everyone,
      FriendPresence presence = FriendPresence.offline,
      HeadToHead? h2h,
      int? playedDaysAgo,
      int physics = 1500,
    }) => FakePlayer(
      card: UserCard(
        id: id,
        handle: handle,
        displayName: name,
        avatar: Avatar(tone: tone, symbol: symbol),
        level: level,
      ),
      minor: minor,
      policy: policy,
      presence: presence,
      h2h: h2h,
      lastPlayedAt: playedDaysAgo == null ? null : now.subtract(Duration(days: playedDaysAgo)),
      ratings: [
        ScopedRating(
          scope: 'physics',
          rating: RatingInfo(display: '$physics', value: physics),
          position: 3000 - physics,
        ),
        ScopedRating(
          scope: 'chemistry',
          rating: RatingInfo(display: '${physics - 40}?', value: physics - 40, provisional: true),
        ),
      ],
      form: const [
        FormResult.win,
        FormResult.loss,
        FormResult.win,
        FormResult.win,
        FormResult.draw,
      ],
    );

    final players = [
      player(
        'u-rahul',
        'rahul_07',
        'Rahul',
        'sky',
        'atom',
        7,
        presence: FriendPresence.online,
        h2h: const HeadToHead(wins: 3, losses: 1),
        playedDaysAgo: 1,
        physics: 1523,
      ),
      player(
        'u-meera',
        'meera_bio',
        'Meera',
        'mint',
        'dna',
        9,
        presence: FriendPresence.inBattle,
        h2h: const HeadToHead(wins: 1, losses: 2),
        playedDaysAgo: 4,
        physics: 1611,
      ),
      player('u-kabir', 'kabir_k', 'Kabir', 'peach', 'flask', 5),
      player(
        'u-ishaan',
        'ishaan',
        'Ishaan',
        'lemon',
        'pi',
        11,
        presence: FriendPresence.inTournament,
        physics: 1702,
      ),
      player(
        'u-zoya',
        'zoya_z',
        'Zoya',
        'rose',
        'star',
        6,
        h2h: const HeadToHead(wins: 2, losses: 2, draws: 1),
        playedDaysAgo: 2,
      ),
      player('u-dev', 'dev_neet', 'Dev', 'lavender', 'brain', 4),
      player(
        'u-ananya',
        'ananya',
        'Ananya',
        'lime',
        'crown',
        8,
        h2h: const HeadToHead(wins: 4, losses: 3),
        playedDaysAgo: 3,
        physics: 1580,
      ),
      player(
        'u-riya',
        'riya_s',
        'Riya',
        'sky',
        'leaf',
        3,
        minor: true,
        policy: FakeRequestPolicy.playedWith,
      ),
      player(
        'u-arjun',
        'arjun_22',
        'Arjun',
        'mint',
        'rocket',
        5,
        minor: true,
        policy: FakeRequestPolicy.playedWith,
        h2h: const HeadToHead(wins: 1),
        playedDaysAgo: 6,
      ),
      player('u-sam', 'sam_x', 'Sam', 'peach', 'fire', 2),
    ];
    final rahul = players[0].card;
    final meera = players[1].card;
    final ishaan = players[3].card;
    SharePlayer sharer(UserCard card) =>
        SharePlayer(displayName: card.displayName, handle: card.handle, avatar: card.avatar);
    return FakeSocialRepository(
      players: players,
      friends: ['u-rahul', 'u-meera', 'u-kabir', 'u-ishaan'],
      incoming: ['u-zoya', 'u-dev'],
      outgoing: ['u-ananya'],
      blocked: ['u-sam'],
      activity: [
        ActivityItem(
          id: 'a0',
          user: meera,
          kind: ActivityKind.sharedResult,
          text: 'shared a win',
          createdAt: now.subtract(const Duration(minutes: 40)),
          share: MatchShareData(
            player: sharer(meera),
            matchId: 'm-demo-meera',
            outcome: ShareOutcome.win,
            subject: 'Biology',
            chapter: 'Human Physiology',
            score: 910,
            opponentScore: 640,
            opponentName: 'Kabir',
            opponentAvatar: const Avatar(tone: 'peach', symbol: 'flask').toData(),
            answers: const [
              ShareAnswer.correct,
              ShareAnswer.correct,
              ShareAnswer.wrong,
              ShareAnswer.correct,
              ShareAnswer.correct,
              ShareAnswer.skipped,
              ShareAnswer.correct,
            ],
            ratingChange: 16,
            coins: 40,
            xp: 30,
          ),
        ),
        ActivityItem(
          id: 'a1',
          user: meera,
          kind: ActivityKind.levelUp,
          text: 'reached level 9',
          createdAt: now.subtract(const Duration(hours: 2)),
        ),
        ActivityItem(
          id: 'a2',
          user: ishaan,
          kind: ActivityKind.podium,
          text: 'finished #2 in Physics Sunday Cup',
          createdAt: now.subtract(const Duration(days: 1, hours: 3)),
        ),
        ActivityItem(
          id: 'a3',
          user: rahul,
          kind: ActivityKind.streak,
          text: 'is on a 12-day streak',
          createdAt: now.subtract(const Duration(days: 2)),
        ),
        ActivityItem(
          id: 'a3b',
          user: rahul,
          kind: ActivityKind.sharedProgress,
          text: 'shared their progress',
          createdAt: now.subtract(const Duration(days: 2, hours: 1)),
          share: ProgressShareData(
            player: sharer(rahul),
            level: 7,
            xpIntoLevel: 180,
            xpForLevel: 450,
            ratings: const [ShareRating(label: 'Physics', rating: '1523')],
            accuracy: 0.74,
            answered: 1240,
            currentStreak: 12,
            bestStreak: 15,
          ),
        ),
        ActivityItem(
          id: 'a4',
          user: rahul,
          kind: ActivityKind.achievement,
          text: 'earned “Sharp Shooter”',
          createdAt: now.subtract(const Duration(days: 4)),
        ),
      ],
      latency: latency,
    );
  }

  /// The signed-in user, who owns the shares they post.
  static const defaultMe = UserCard(id: 'u-me', handle: 'you', displayName: 'You', level: 6);

  final UserCard me;

  /// Ended battles the user may post, by match id.
  final Map<String, MatchShareData> matchResults;

  /// What a progress share posts.
  ProgressShareData progress;

  /// Every share posted, in order (retries with a used key included once).
  final List<ShareTarget> posted = [];

  static const dailyProgressShares = 3;

  static ProgressShareData _sampleProgress(UserCard me) => ProgressShareData(
    player: SharePlayer(displayName: me.displayName, handle: me.handle, avatar: me.avatar),
    level: me.level ?? 1,
    xpIntoLevel: 120,
    xpForLevel: 400,
    accuracy: 0.68,
    answered: 540,
    currentStreak: 4,
    bestStreak: 9,
  );

  /// Delay before every response, to see loading states.
  Duration latency;

  /// Friends per page.
  final int pageSize;

  /// Calls that fail until removed from the map.
  final Map<FakeSocialOp, AppFailure> failures = {};

  /// Every search query, in order.
  final List<String> searchQueries = [];

  /// Every report sent.
  final List<({String userId, ReportReason reason, String? matchId, String? note})> reports = [];

  /// How many times each call was made.
  final Map<FakeSocialOp, int> calls = {};

  /// Requests sent today, for the daily limit.
  int sentToday = 0;

  static const dailyLimit = 20;
  static const pendingLimit = 100;

  final _players = <String, FakePlayer>{};
  final _friends = <String>{};
  final _incoming = <String, String>{};
  final _outgoing = <String, String>{};
  final _blocked = <String>{};
  final _blockedBy = <String>{};
  final List<ActivityItem> _activity;
  final _shareKeys = <String, ActivityItem>{};
  var _requestCounter = 0;

  Set<String> get friendIds => Set.unmodifiable(_friends);
  Set<String> get blockedIds => Set.unmodifiable(_blocked);
  Map<String, String> get outgoingRequests => Map.unmodifiable(_outgoing);
  Map<String, String> get incomingRequests => Map.unmodifiable(_incoming);

  FakePlayer player(String id) => _players[id]!;

  void setPresence(String userId, FriendPresence presence) => _players[userId]!.presence = presence;

  /// Someone new asks to be friends.
  String receiveRequest(String userId) {
    final id = _nextRequestId();
    _incoming[id] = userId;
    return id;
  }

  // ---------------------------------------------------------------- friends

  @override
  Future<CursorPage<Friend>> friends({String? cursor}) async {
    await _call(FakeSocialOp.friends);
    final all = [
      for (final id in _friends)
        if (_visible(id)) Friend(user: _players[id]!.card, presence: _players[id]!.presence),
    ];
    final start = int.tryParse(cursor ?? '') ?? 0;
    final end = (start + pageSize).clamp(0, all.length);
    return CursorPage(
      all.sublist(start.clamp(0, all.length), end),
      nextCursor: end < all.length ? '$end' : null,
    );
  }

  @override
  Future<void> removeFriend(String userId) async {
    await _call(FakeSocialOp.removeFriend);
    _friends.remove(userId);
  }

  // ---------------------------------------------------------------- search

  @override
  Future<List<SearchResult>> search(String query, {CancelToken? cancelToken}) async {
    searchQueries.add(query);
    await _call(FakeSocialOp.search);
    if (cancelToken?.isCancelled ?? false) throw const CancelledFailure();
    final q = query.trim().toLowerCase();
    if (q.length < 3) {
      throw const ValidationFailure('Type at least 3 characters.', code: 'VALIDATION_ERROR');
    }
    return [
      for (final player in _players.values)
        if (_visible(player.id) && player.card.handle.startsWith(q))
          SearchResult(user: player.card, relationship: _relationship(player.id)),
    ];
  }

  // ---------------------------------------------------------------- requests

  @override
  Future<SentRequest> sendRequest(String userId) async {
    await _call(FakeSocialOp.sendRequest);
    final player = _players[userId];
    if (player == null || !_visible(userId)) {
      throw const NotFoundFailure('That player isn\'t available.', code: 'NOT_FOUND');
    }
    if (_friends.contains(userId)) {
      throw const ConflictFailure('You\'re already friends.', code: 'ALREADY_FRIENDS');
    }
    final existing = _outgoing.entries.where((e) => e.value == userId).firstOrNull;
    if (existing != null) return SentRequest(requestId: existing.key);
    // Two requests that meet become a friendship.
    final theirs = _incoming.entries.where((e) => e.value == userId).firstOrNull;
    if (theirs != null) {
      _incoming.remove(theirs.key);
      _friends.add(userId);
      return SentRequest(requestId: theirs.key, becameFriends: true);
    }
    switch (player.policy) {
      case FakeRequestPolicy.nobody:
        throw const ForbiddenFailure(
          'They aren\'t accepting friend requests.',
          code: 'NOT_ALLOWED',
          details: {'reason': 'nobody'},
        );
      case FakeRequestPolicy.playedWith when player.h2h == null:
        throw const ForbiddenFailure(
          'They only accept requests from people they\'ve played.',
          code: 'NOT_ALLOWED',
          details: {'reason': 'played_with'},
        );
      default:
        break;
    }
    if (sentToday >= dailyLimit || _outgoing.length >= pendingLimit) {
      throw const ConflictFailure('Friend request limit reached.', code: 'LIMIT_REACHED');
    }
    sentToday++;
    final id = _nextRequestId();
    _outgoing[id] = userId;
    return SentRequest(requestId: id);
  }

  @override
  Future<FriendRequests> requests() async {
    await _call(FakeSocialOp.requests);
    FriendRequest request(MapEntry<String, String> e) =>
        FriendRequest(id: e.key, user: _players[e.value]!.card);
    return FriendRequests(
      incoming: [
        for (final e in _incoming.entries)
          if (_visible(e.value)) request(e),
      ],
      outgoing: [
        for (final e in _outgoing.entries)
          if (_visible(e.value)) request(e),
      ],
    );
  }

  @override
  Future<void> acceptRequest(String requestId) async {
    await _call(FakeSocialOp.accept);
    final userId = _incoming.remove(requestId) ?? (throw _noRequest);
    _friends.add(userId);
  }

  @override
  Future<void> declineRequest(String requestId) async {
    await _call(FakeSocialOp.decline);
    _incoming.remove(requestId) ?? (throw _noRequest);
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    await _call(FakeSocialOp.cancel);
    _outgoing.remove(requestId) ?? (throw _noRequest);
  }

  static const _noRequest = NotFoundFailure(
    'That request isn\'t pending any more.',
    code: 'NOT_FOUND',
  );

  // ---------------------------------------------------------------- opponents

  @override
  Future<List<Opponent>> rivals() async {
    await _call(FakeSocialOp.rivals);
    final since = clock.now().subtract(const Duration(days: 60));
    return [
      for (final p in _played(since))
        if (p.h2h!.played >= 3) _opponent(p),
    ];
  }

  @override
  Future<List<Opponent>> opponents({int days = 30}) async {
    await _call(FakeSocialOp.opponents);
    return [for (final p in _played(clock.now().subtract(Duration(days: days)))) _opponent(p)];
  }

  Iterable<FakePlayer> _played(DateTime since) {
    final played = [
      for (final p in _players.values)
        if (p.h2h != null && _visible(p.id) && !p.lastPlayedAt!.isBefore(since)) p,
    ]..sort((a, b) => b.lastPlayedAt!.compareTo(a.lastPlayedAt!));
    return played;
  }

  Opponent _opponent(FakePlayer p) => Opponent(
    user: p.card,
    h2h: p.h2h!,
    relationship: _relationship(p.id),
    lastPlayedAt: p.lastPlayedAt,
  );

  // ---------------------------------------------------------------- activity

  @override
  Future<CursorPage<ActivityItem>> activity({String? cursor}) async {
    await _call(FakeSocialOp.activity);
    final since = clock.now().subtract(const Duration(days: 7));
    final all = [
      for (final item in _activity)
        if ((_friends.contains(item.user.id) && _visible(item.user.id) ||
                item.user.id == me.id && item.share != null) &&
            item.createdAt.isAfter(since))
          item,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final start = int.tryParse(cursor ?? '') ?? 0;
    final end = (start + pageSize).clamp(0, all.length);
    return CursorPage(
      all.sublist(start.clamp(0, all.length), end),
      nextCursor: end < all.length ? '$end' : null,
    );
  }

  @override
  Future<ActivityItem> share(ShareTarget target, {required String idempotencyKey}) async {
    await _call(FakeSocialOp.share);
    if (_shareKeys[idempotencyKey] case final replay?) return replay;
    final player = SharePlayer(displayName: me.displayName, handle: me.handle, avatar: me.avatar);
    final now = clock.now();
    final ShareCardData data;
    switch (target) {
      case MatchShareTarget(:final matchId):
        final result = matchResults[matchId];
        if (result == null) {
          throw const NotFoundFailure(
            'That battle was not found, or it hasn\'t ended yet.',
            code: 'NOT_FOUND',
          );
        }
        final shared = _activity.where(
          (item) =>
              item.share is MatchShareData && (item.share! as MatchShareData).matchId == matchId,
        );
        if (shared.firstOrNull case final item?) {
          throw ConflictFailure(
            'You\'ve already posted this battle.',
            code: 'ALREADY_SHARED',
            details: {'activity_id': item.id},
          );
        }
        data = MatchShareData(
          player: player,
          matchId: matchId,
          outcome: result.outcome,
          subject: result.subject,
          chapter: result.chapter,
          score: result.score,
          opponentScore: result.opponentScore,
          opponentName: result.opponentName,
          opponentAvatar: result.opponentAvatar,
          answers: result.answers,
          ratingChange: result.ratingChange,
          coins: result.coins,
          xp: result.xp,
        );
      case ProgressShareTarget():
        final today = DateTime(now.year, now.month, now.day);
        final todays = _activity.where(
          (item) =>
              item.user.id == me.id &&
              item.kind == ActivityKind.sharedProgress &&
              !item.createdAt.isBefore(today),
        );
        if (todays.length >= dailyProgressShares) {
          throw const ConflictFailure(
            'You\'ve posted your progress 3 times today. Try again tomorrow.',
            code: 'LIMIT_REACHED',
            details: {'limit': 'daily', 'max': dailyProgressShares},
          );
        }
        data = ProgressShareData(
          player: player,
          level: progress.level,
          xpIntoLevel: progress.xpIntoLevel,
          xpForLevel: progress.xpForLevel,
          ratings: progress.ratings,
          accuracy: progress.accuracy,
          answered: progress.answered,
          currentStreak: progress.currentStreak,
          bestStreak: progress.bestStreak,
        );
    }
    final item = ActivityItem(
      id: 'share-${_shareKeys.length + 1}',
      user: me,
      kind: data is MatchShareData ? ActivityKind.sharedResult : ActivityKind.sharedProgress,
      text: data is MatchShareData ? 'shared a battle' : 'shared their progress',
      createdAt: now,
      share: data,
    );
    _activity.add(item);
    _shareKeys[idempotencyKey] = item;
    posted.add(target);
    return item;
  }

  // ---------------------------------------------------------------- blocks

  @override
  Future<void> block(String userId) async {
    await _call(FakeSocialOp.block);
    if (!_players.containsKey(userId)) {
      throw const NotFoundFailure('That player isn\'t available.', code: 'NOT_FOUND');
    }
    _blocked.add(userId);
    _friends.remove(userId);
    _incoming.removeWhere((_, id) => id == userId);
    _outgoing.removeWhere((_, id) => id == userId);
  }

  @override
  Future<void> unblock(String userId) async {
    await _call(FakeSocialOp.unblock);
    _blocked.remove(userId);
  }

  @override
  Future<List<UserCard>> blocks() async {
    await _call(FakeSocialOp.blocks);
    return [for (final id in _blocked) _players[id]!.card];
  }

  @override
  Future<void> report({
    required String userId,
    required ReportReason reason,
    String? matchId,
    String? note,
  }) async {
    await _call(FakeSocialOp.report);
    reports.add((userId: userId, reason: reason, matchId: matchId, note: note));
  }

  // ---------------------------------------------------------------- profile

  @override
  Future<PublicProfile> profile(String handle) async {
    await _call(FakeSocialOp.profile);
    final player = _players.values.where((p) => p.card.handle == handle).firstOrNull;
    if (player == null || !_visible(player.id) || _blocked.contains(player.id)) {
      throw const NotFoundFailure('That player isn\'t available.', code: 'NOT_FOUND');
    }
    final friend = _friends.contains(player.id);
    // What non-friends see of a minor: only the name, avatar and level.
    final private = player.minor && !friend;
    return PublicProfile(
      user: player.card,
      ratings: private ? null : player.ratings,
      form: private ? null : player.form,
      h2h: private ? null : (player.h2h ?? const HeadToHead()),
      relationship: _relationship(player.id),
      canChallenge: friend,
    );
  }

  // ---------------------------------------------------------------- helpers

  /// Hidden when they blocked the user; the user's own blocks show in the
  /// blocks list but nowhere else.
  bool _visible(String id) => !_blockedBy.contains(id) && !_blocked.contains(id);

  Relationship _relationship(String id) {
    if (_blocked.contains(id)) return Relationship.blocked;
    if (_friends.contains(id)) return Relationship.friend;
    if (_outgoing.containsValue(id)) return Relationship.requested;
    return Relationship.none;
  }

  String _nextRequestId() => 'fr-${++_requestCounter}';

  Future<void> _call(FakeSocialOp op) async {
    calls[op] = (calls[op] ?? 0) + 1;
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failures[op] case final failure?) throw failure;
  }
}
