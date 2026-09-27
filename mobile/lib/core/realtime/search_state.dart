import 'package:flutter/foundation.dart';
import 'package:realtime_client/realtime_client.dart';

/// What the user asked to play: the `mm.join` payload plus names for the screen.
@immutable
class SearchRequest {
  const SearchRequest({
    required this.mode,
    required this.subject,
    this.chapter,
    this.subjectName,
    this.chapterName,
  });

  /// `rated`, `casual` or `bot`.
  final String mode;
  final String subject;

  /// `null` means all chapters.
  final String? chapter;
  final String? subjectName;
  final String? chapterName;

  bool get isBot => mode == 'bot';

  bool get isCasual => mode == 'casual';

  /// "Physics", from the name the tab knew or the slug.
  String get subjectLabel => subjectName ?? _titleCase(subject);

  /// "Motion in a Straight Line", or null for all chapters.
  String? get chapterLabel => chapter == null ? null : (chapterName ?? _titleCase(chapter!));

  Map<String, Object?> toJoin(String idem) => {
    'mode': mode,
    'subject': subject,
    'chapter': chapter,
    'idem': idem,
  };

  SearchRequest withMode(String mode) => SearchRequest(
    mode: mode,
    subject: subject,
    chapter: chapter,
    subjectName: subjectName,
    chapterName: chapterName,
  );

  @override
  bool operator ==(Object other) =>
      other is SearchRequest &&
      other.mode == mode &&
      other.subject == subject &&
      other.chapter == chapter &&
      other.subjectName == subjectName &&
      other.chapterName == chapterName;

  @override
  int get hashCode => Object.hash(mode, subject, chapter, subjectName, chapterName);
}

String _titleCase(String slug) => slug
    .split('-')
    .where((part) => part.isNotEmpty)
    .map((part) => part[0].toUpperCase() + part.substring(1))
    .join(' ');

/// Why a search stopped without a match (`mm.cancelled.reason`), plus `away` when the app only
/// learned on reconnecting that the search was gone.
@immutable
class SearchEnd {
  const SearchEnd({required this.reason, this.refunded = 0});

  /// `user`, `timeout`, `background`, `disconnected`, `cooldown` or `away`.
  final String reason;

  /// Coins that came back.
  final int refunded;

  bool get byUser => reason == 'user';

  @override
  bool operator ==(Object other) =>
      other is SearchEnd && other.reason == reason && other.refunded == refunded;

  @override
  int get hashCode => Object.hash(reason, refunded);
}

enum SearchPhase {
  /// Not searching.
  idle,

  /// `mm.join` is on its way.
  joining,

  /// In the queue.
  queued,

  /// `mm.timeout`: the options (keep, bot, invite, cancel) are on offer.
  offered,

  /// `mm.found`: the match is being opened.
  matched,
}

/// The user's matchmaking state, built from `mm.*` events by [reduceSearch].
@immutable
class SearchState {
  const SearchState({
    this.phase = SearchPhase.idle,
    this.request,
    this.ticketId,
    this.joinedAt,
    this.waitedS = 0,
    this.widened = false,
    this.online,
    this.p50WaitS,
    this.options = const [],
    this.offers = 0,
    this.matchId,
    this.lastEnd,
    this.requeued = false,
  });

  final SearchPhase phase;
  final SearchRequest? request;
  final String? ticketId;

  /// Server ms when the search started (`mm.queued.joined_at`), when known.
  final int? joinedAt;
  final int waitedS;

  /// The search now takes players from other chapters of the subject.
  final bool widened;

  /// Players searching in this subject right now.
  final int? online;
  final int? p50WaitS;

  /// What `mm.timeout` offered.
  final List<String> options;

  /// Counts `mm.timeout`s, so a screen shows each offer once.
  final int offers;

  /// The match `mm.found` made.
  final String? matchId;

  /// Why the last search stopped without a match.
  final SearchEnd? lastEnd;

  /// The found match fell through and the search is back at the front of the queue.
  final bool requeued;

  bool get isSearching => phase == SearchPhase.queued || phase == SearchPhase.offered;

  SearchState copyWith({
    SearchPhase? phase,
    Object? ticketId = _keep,
    Object? joinedAt = _keep,
    int? waitedS,
    bool? widened,
    Object? online = _keep,
    Object? p50WaitS = _keep,
    List<String>? options,
    int? offers,
    Object? matchId = _keep,
    Object? lastEnd = _keep,
    bool? requeued,
  }) => SearchState(
    phase: phase ?? this.phase,
    request: request,
    ticketId: identical(ticketId, _keep) ? this.ticketId : ticketId as String?,
    joinedAt: identical(joinedAt, _keep) ? this.joinedAt : joinedAt as int?,
    waitedS: waitedS ?? this.waitedS,
    widened: widened ?? this.widened,
    online: identical(online, _keep) ? this.online : online as int?,
    p50WaitS: identical(p50WaitS, _keep) ? this.p50WaitS : p50WaitS as int?,
    options: options ?? this.options,
    offers: offers ?? this.offers,
    matchId: identical(matchId, _keep) ? this.matchId : matchId as String?,
    lastEnd: identical(lastEnd, _keep) ? this.lastEnd : lastEnd as SearchEnd?,
    requeued: requeued ?? this.requeued,
  );

  /// `mm.join` was sent for [request].
  static SearchState joining(SearchRequest request, {int? online, int? p50WaitS}) =>
      SearchState(phase: SearchPhase.joining, request: request, online: online, p50WaitS: p50WaitS);

  /// `mm.join` failed: back to idle, keeping the request for "Try again".
  SearchState joinFailed() => SearchState(request: request, lastEnd: lastEnd);

  /// The user chose "Keep searching".
  SearchState keepSearching() =>
      phase == SearchPhase.offered ? copyWith(phase: SearchPhase.queued, options: const []) : this;

  /// On reconnecting, the server listed no queue: the search stopped while the app was away.
  SearchState stoppedWhileAway() => SearchState(
    request: request,
    lastEnd: const SearchEnd(reason: 'away'),
  );

  /// On reconnecting (or from a `BUSY` answer), the server says the user is queued.
  SearchState adoptQueue({String? ticketId}) => isSearching
      ? this
      : SearchState(phase: SearchPhase.queued, request: request, ticketId: ticketId);

  @override
  bool operator ==(Object other) =>
      other is SearchState &&
      other.phase == phase &&
      other.request == request &&
      other.ticketId == ticketId &&
      other.joinedAt == joinedAt &&
      other.waitedS == waitedS &&
      other.widened == widened &&
      other.online == online &&
      other.p50WaitS == p50WaitS &&
      listEquals(other.options, options) &&
      other.offers == offers &&
      other.matchId == matchId &&
      other.lastEnd == lastEnd &&
      other.requeued == requeued;

  @override
  int get hashCode => Object.hash(
    phase,
    request,
    ticketId,
    joinedAt,
    waitedS,
    widened,
    online,
    p50WaitS,
    Object.hashAll(options),
    offers,
    matchId,
    lastEnd,
    requeued,
  );

  @override
  String toString() => 'SearchState(${phase.name}, waited $waitedS s, widened: $widened)';
}

const Object _keep = Object();

/// Applies one matchmaking event to [state]. Pure. [nowServerMs] (synced server time) fills in
/// the start of a search when the server only says how long it has waited.
SearchState reduceSearch(SearchState state, ServerEvent event, {required int nowServerMs}) {
  switch (event) {
    case MmQueuedEvent():
      final request = state.request;
      return SearchState(
        phase: SearchPhase.queued,
        request: SearchRequest(
          mode: event.mode,
          subject: event.subject,
          chapter: event.chapter,
          subjectName: request?.subject == event.subject ? request?.subjectName : null,
          chapterName: request?.chapter == event.chapter ? request?.chapterName : null,
        ),
        ticketId: event.ticketId,
        joinedAt: event.joinedAt ?? nowServerMs,
        online: state.online,
        p50WaitS: state.p50WaitS,
      );
    case MmStatusEvent() when state.isSearching:
      return state.copyWith(
        waitedS: event.waitedS,
        widened: state.widened || event.widened,
        online: event.online ?? state.online,
        p50WaitS: event.p50WaitS ?? state.p50WaitS,
        joinedAt: state.joinedAt ?? nowServerMs - event.waitedS * 1000,
      );
    case MmTimeoutEvent() when state.isSearching:
      return state.copyWith(
        phase: SearchPhase.offered,
        options: event.options,
        waitedS: event.waitedS,
        offers: state.offers + 1,
        joinedAt: state.joinedAt ?? nowServerMs - event.waitedS * 1000,
      );
    case MmCancelledEvent():
      return SearchState(
        request: state.request,
        lastEnd: SearchEnd(reason: event.reason, refunded: event.refunded),
      );
    case MmRequeuedEvent():
      return SearchState(
        phase: SearchPhase.queued,
        request: state.request,
        ticketId: state.ticketId,
        joinedAt: nowServerMs - event.waitedS * 1000,
        waitedS: event.waitedS,
        widened: state.widened,
        online: state.online,
        p50WaitS: state.p50WaitS,
        requeued: true,
      );
    case MmFoundEvent():
      return SearchState(
        phase: SearchPhase.matched,
        request: state.request,
        matchId: event.matchId,
        online: state.online,
        p50WaitS: state.p50WaitS,
      );
    default:
      return state;
  }
}
