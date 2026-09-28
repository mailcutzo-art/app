import 'package:design_system/design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/question_models.dart';
import 'package:quiz_app/features/learn/widgets/question_widgets.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';

import '../../support/fakes.dart';

/// Serves bookmarks three at a time, so paging shows with the small sample.
class _SmallPages extends FakeLearnRepository {
  _SmallPages() : super(subjects: sampleSubjects, passages: samplePassages);

  /// Pages after the first fail while set.
  bool failMore = false;

  @override
  Future<BookmarkPage> listBookmarks({String? subject, String? cursor, int limit = 20}) {
    if (failMore && cursor != null) throw const NetworkFailure();
    return super.listBookmarks(subject: subject, cursor: cursor, limit: 3);
  }
}

Finder _iconButton(String label) =>
    find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == label);

void main() {
  late _SmallPages learn;

  setUp(() => learn = _SmallPages());

  Future<void> bookmark(List<String> refs) async {
    for (final ref in refs) {
      await learn.setBookmark(ref, bookmarked: true);
    }
    learn.bookmarkCalls.clear();
  }

  Future<void> open(WidgetTester tester) async {
    usePhoneViewport(tester, height: 1400);
    await pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.learn);
    await tester.tap(find.text('Bookmarks'));
    await tester.pumpAndSettle();
  }

  testWidgets('nothing saved yet explains how to save', (tester) async {
    await open(tester);
    expect(find.text('No bookmarks yet'), findsOneWidget);
    expect(find.text('Practise these'), findsNothing);
  });

  testWidgets('lists the newest first and loads more pages on scroll', (tester) async {
    await bookmark(['phy-kin-001', 'phy-kin-003', 'bio-cell-001', 'bio-cell-002', 'phy-lom-002']);
    await open(tester);

    final rows = tester.widgetList<QuestionRow>(find.byType(QuestionRow));
    expect(rows.map((r) => r.question.ref), [
      'phy-lom-002',
      'bio-cell-002',
      'bio-cell-001',
      'phy-kin-003',
      'phy-kin-001',
    ], reason: 'the footer asked for page two as soon as it showed');
    expect(learn.bookmarkListCalls.map((c) => c.$2), [null, '3']);
    expect(find.text('Physics · Laws of Motion'), findsOneWidget);
  });

  testWidgets('a first page that fails offers a retry', (tester) async {
    await bookmark(['phy-kin-001', 'bio-cell-001']);
    learn.failures[FakeLearnOp.bookmarksList] = const NetworkFailure();
    await open(tester);
    expect(find.text('Couldn\'t load your bookmarks'), findsOneWidget);

    learn.failures.clear();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionRow), findsNWidgets(2));
  });

  testWidgets('a later page that fails keeps the list and retries in the footer', (tester) async {
    await bookmark(['phy-kin-001', 'phy-kin-003', 'bio-cell-001', 'bio-cell-002']);
    learn.failMore = true;
    await open(tester);

    expect(find.byType(QuestionRow), findsNWidgets(3));
    expect(find.text('Couldn\'t load more'), findsOneWidget);

    learn.failMore = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionRow), findsNWidgets(4));
    expect(find.text('Couldn\'t load more'), findsNothing);
  });

  testWidgets('the subject filter asks the server for that subject', (tester) async {
    await bookmark(['phy-kin-001', 'bio-cell-001']);
    await open(tester);
    expect(find.byType(QuestionRow), findsNWidgets(2));

    await tester.tap(find.widgetWithText(AppChip, 'Biology'));
    await tester.pumpAndSettle();

    expect(learn.bookmarkListCalls.last, ('biology', null));
    expect(find.byType(QuestionRow), findsOneWidget);
    expect(find.text('Biology · Cell: The Unit of Life'), findsOneWidget);
  });

  testWidgets('removing is immediate, and put back if it fails', (tester) async {
    await bookmark(['phy-kin-001', 'bio-cell-001']);
    await open(tester);

    await tester.tap(_iconButton('Remove bookmark').first);
    await tester.pumpAndSettle();
    expect(find.byType(QuestionRow), findsOneWidget);
    expect(find.text('Removed from bookmarks'), findsOneWidget);
    expect(learn.bookmarkCalls.single, ('bio-cell-001', false));

    learn.failures[FakeLearnOp.bookmark] = const ServerFailure();
    await tester.tap(_iconButton('Remove bookmark'));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionRow), findsOneWidget, reason: 'put back');
    expect(find.text('Couldn\'t save the bookmark. Please try again.'), findsOneWidget);
  });

  testWidgets('unbookmarking a question on its screen takes it off the list', (tester) async {
    await bookmark(['phy-kin-001', 'bio-cell-001']);
    await open(tester);

    await tester.tap(find.textContaining('powerhouse', findRichText: true));
    await tester.pumpAndSettle();
    await tester.tap(_iconButton('Remove bookmark'));
    await tester.pumpAndSettle();
    await tester.tap(_iconButton('Back'));
    await tester.pumpAndSettle();

    expect(find.byType(QuestionRow), findsOneWidget);
    expect(find.textContaining('powerhouse', findRichText: true), findsNothing);
  });

  testWidgets('Practise these starts a bookmarks session for the filter', (tester) async {
    await bookmark(['phy-kin-001', 'bio-cell-001']);
    await open(tester);
    await tester.tap(find.widgetWithText(AppChip, 'Biology'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Practise these'));
    await tester.pumpAndSettle();

    expect(
      learn.createCalls.single.$1,
      const SessionSettings(mode: PracticeMode.bookmarks, subject: 'biology', count: 20),
    );
    expect(find.text('QUESTION 1 / 1'), findsOneWidget);
  });
}
