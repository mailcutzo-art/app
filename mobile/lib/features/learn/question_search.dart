import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/app_failure.dart';
import 'data/learn_repository.dart';
import 'data/question_models.dart';

/// What the search screen shows.
@immutable
class QuestionSearchState {
  const QuestionSearchState({
    this.query = '',
    this.subject,
    this.results,
    this.loading = false,
    this.error,
  });

  /// Trimmed, with runs of spaces collapsed.
  final String query;

  /// Subject slug filter; null searches every subject.
  final String? subject;

  /// Results of the latest finished search. While a new one runs, the last
  /// results stay on screen under a progress bar.
  final List<QuestionSummary>? results;
  final bool loading;
  final AppFailure? error;

  /// Too short to search: the screen explains instead.
  bool get idle => query.length < QuestionSearch.minLength;

  QuestionSearchState copyWith({
    List<QuestionSummary>? results,
    bool? loading,
    AppFailure? error,
    bool clearError = false,
  }) => QuestionSearchState(
    query: query,
    subject: subject,
    results: results ?? this.results,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Question search (`GET /v1/search`): waits for a pause in typing, needs 2+
/// characters, and cancels the request in flight when the query changes, so
/// a slow answer to an old query never replaces a newer one.
final questionSearchProvider = NotifierProvider.autoDispose<QuestionSearch, QuestionSearchState>(
  QuestionSearch.new,
);

class QuestionSearch extends Notifier<QuestionSearchState> {
  static const minLength = 2;
  static const debounce = Duration(milliseconds: 300);

  Timer? _timer;
  CancelToken? _inFlight;

  @override
  QuestionSearchState build() {
    ref.onDispose(_stop);
    return const QuestionSearchState();
  }

  /// The text in the search field changed.
  void setQuery(String text) {
    final query = text.trim().split(RegExp(r'\s+')).join(' ');
    if (query == state.query) return;
    _restart(QuestionSearchState(query: query, subject: state.subject, results: state.results));
  }

  /// A subject chip was picked (null: all subjects). Searches at once.
  void setSubject(String? subject) {
    if (subject == state.subject) return;
    _restart(
      QuestionSearchState(query: state.query, subject: subject),
      delay: Duration.zero,
    );
  }

  void retry() {
    if (!state.idle) _restart(state, delay: Duration.zero);
  }

  void _restart(QuestionSearchState next, {Duration delay = debounce}) {
    _stop();
    if (next.idle) {
      state = QuestionSearchState(query: next.query, subject: next.subject);
      return;
    }
    state = next.copyWith(loading: true, clearError: true);
    _timer = delay == Duration.zero ? null : Timer(delay, _run);
    if (delay == Duration.zero) unawaited(_run());
  }

  Future<void> _run() async {
    _timer = null;
    _inFlight?.cancel();
    final token = _inFlight = CancelToken();
    final (query, subject) = (state.query, state.subject);
    try {
      final results = await ref
          .read(learnRepositoryProvider)
          .search(query, subject: subject, cancelToken: token);
      if (!identical(token, _inFlight)) return;
      state = state.copyWith(results: results, loading: false, clearError: true);
    } on CancelledFailure {
      // A newer query replaced this one.
    } on AppFailure catch (failure) {
      if (!identical(token, _inFlight)) return;
      state = state.copyWith(loading: false, error: failure);
    } finally {
      if (identical(token, _inFlight)) _inFlight = null;
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _inFlight?.cancel();
    _inFlight = null;
  }
}
