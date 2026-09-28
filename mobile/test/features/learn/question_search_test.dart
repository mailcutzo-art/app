import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/question_models.dart';
import 'package:quiz_app/features/learn/question_search.dart';
import 'package:quiz_app/features/learn/widgets/question_widgets.dart';

import '../../support/fakes.dart';

/// Keeps the cancel token of every search, to check that stale ones are
/// cancelled.
class _RecordingLearn extends FakeLearnRepository {
  _RecordingLearn() : super(subjects: sampleSubjects, passages: samplePassages);

  final tokens = <CancelToken?>[];

  @override
  Future<List<QuestionSummary>> search(
    String query, {
    String? subject,
    int limit = 20,
    CancelToken? cancelToken,
  }) {
    tokens.add(cancelToken);
    return super.search(query, subject: subject, limit: limit, cancelToken: cancelToken);
  }
}

Finder get _field => find.byType(TextField);

void main() {
  late _RecordingLearn learn;

  setUp(() => learn = _RecordingLearn());

  Future<ProviderContainer> open(WidgetTester tester) async {
    usePhoneViewport(tester);
    return pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.learnSearch);
  }

  testWidgets('explains itself until 2 characters are typed', (tester) async {
    await open(tester);
    expect(find.text('Find any question'), findsOneWidget);

    await tester.enterText(_field, 'k');
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Find any question'), findsOneWidget);
    expect(learn.searchCalls, isEmpty, reason: 'one character is never sent');
  });

  testWidgets('waits for a pause in typing, then shows skeletons and results', (tester) async {
    learn.latency = const Duration(milliseconds: 200);
    final container = await open(tester);

    await tester.enterText(_field, 'ki');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(_field, 'kin');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(_field, 'kine');
    await tester.pump(const Duration(milliseconds: 299));
    expect(learn.searchCalls, isEmpty, reason: 'still typing');

    await tester.pump(const Duration(milliseconds: 1));
    expect(learn.searchCalls.single, ('kine', null));
    expect(find.byType(QuestionRowsSkeleton), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byType(QuestionRowsSkeleton), findsNothing);
    expect(find.byType(QuestionRow), findsWidgets);
    expect(find.text('Physics · Motion in a Straight Line'), findsWidgets);
    expect(
      container.read(questionSearchProvider).results,
      hasLength(7),
      reason: 'every Kinematics question, passage ones too',
    );
  });

  testWidgets('a new query cancels the request in flight; only its results show', (tester) async {
    learn.latency = const Duration(milliseconds: 500);
    await open(tester);

    await tester.enterText(_field, 'cell');
    await tester.pump(const Duration(milliseconds: 300));
    expect(learn.searchCalls.single.$1, 'cell');

    await tester.enterText(_field, 'friction');
    expect(learn.tokens.single!.isCancelled, isTrue);
    await tester.pumpAndSettle();

    expect(learn.searchCalls.map((c) => c.$1), ['cell', 'friction']);
    expect(find.byType(QuestionRow), findsOneWidget);
    expect(find.textContaining('heavy box', findRichText: true), findsOneWidget);
  });

  testWidgets('subject chips narrow the search at once', (tester) async {
    await open(tester);
    await tester.enterText(_field, 'which');
    await tester.pumpAndSettle();
    expect(find.byType(QuestionRow), findsWidgets);

    await tester.tap(find.widgetWithText(AppChip, 'Physics'));
    await tester.pumpAndSettle();

    expect(learn.searchCalls.last, ('which', 'physics'));
    expect(find.text('No questions found'), findsOneWidget);
  });

  testWidgets('errors offer a retry; too many searches says so', (tester) async {
    learn.failures[FakeLearnOp.search] = const RateLimitedFailure();
    await open(tester);
    await tester.enterText(_field, 'kine');
    await tester.pumpAndSettle();

    expect(find.text('Couldn\'t search'), findsOneWidget);
    expect(find.textContaining('a lot of searches'), findsOneWidget);

    learn.failures.clear();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionRow), findsWidgets);
    expect(find.text('Couldn\'t search'), findsNothing);
  });

  testWidgets('leaving the screen cancels a search in flight', (tester) async {
    learn.latency = const Duration(milliseconds: 500);
    usePhoneViewport(tester);
    final container = await pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: Routes.learn,
    );
    unawaited(container.read(routerProvider).push(Routes.learnSearch));
    await tester.pumpAndSettle();
    await tester.enterText(_field, 'kine');
    await tester.pump(const Duration(milliseconds: 350));

    container.read(routerProvider).pop();
    await tester.pumpAndSettle();

    expect(learn.tokens.single!.isCancelled, isTrue);
    expect(container.exists(questionSearchProvider), isFalse);
    await tester.pump(const Duration(seconds: 1)); // the fake's latency
  });

  testWidgets('a result opens the question with its answer and explanation', (tester) async {
    await open(tester);
    await tester.enterText(_field, 'powerhouse');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(QuestionRow));
    await tester.pumpAndSettle();

    expect(find.text('Question'), findsOneWidget);
    expect(find.textContaining('powerhouse of the cell', findRichText: true), findsOneWidget);
    expect(find.text('Show answer'), findsOneWidget);
  });
}
