import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/share/share_card.dart';
import 'package:quiz_app/features/share/share_models.dart';
import 'package:quiz_app/features/share/share_sheet.dart';
import 'package:quiz_app/features/social/data/fake_social_repository.dart';
import 'package:quiz_app/features/social/data/social_repository.dart';

import '../../support/fakes.dart';
import '../../support/share_samples.dart';

void main() {
  late FakeSocialRepository social;
  late ShareRecorder recorder;

  setUp(() {
    social = FakeSocialRepository(matchResults: {sampleWin.matchId: sampleWin});
    recorder = ShareRecorder();
  });

  Future<void> open(WidgetTester tester, ShareCardData data, {AppEnv env = testEnv}) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvProvider.overrideWithValue(env),
          socialRepositoryProvider.overrideWithValue(social),
          ...recorder.overrides,
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: AppButton(
                  label: 'Open',
                  expand: false,
                  onPressed: () => showShareSheet(context, data: data),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows a preview of the card and both ways to share', (tester) async {
    await open(tester, sampleWin);

    expect(find.text('Share this battle'), findsOneWidget);
    expect(find.byType(SharePreview), findsOneWidget);
    expect(find.byType(ShareCard), findsOneWidget);
    expect(find.text('Victory!'), findsOneWidget);
    expect(find.text('Quiz Arena'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Victory! Physics battle')), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Post to friends'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Share to other apps'), findsOneWidget);
  });

  testWidgets('Post to friends posts the battle, closes and says so', (tester) async {
    await open(tester, sampleWin);
    await tester.tap(find.text('Post to friends'));
    await tester.pumpAndSettle();

    expect(social.posted, [const MatchShareTarget('m-1')]);
    expect(find.text('Share this battle'), findsNothing);
    expect(find.text('Posted to your friends'), findsOneWidget);
    final feed = await social.activity();
    expect(feed.items.single.user.id, FakeSocialRepository.defaultMe.id);
    expect(recorder.shared, isEmpty);
  });

  testWidgets('progress posted too often: the limit is explained in the sheet', (tester) async {
    for (var i = 0; i < FakeSocialRepository.dailyProgressShares; i++) {
      await social.share(const ProgressShareTarget(), idempotencyKey: 'k$i');
    }
    await open(tester, sampleProgress);
    expect(find.text('Share your progress'), findsOneWidget);

    await tester.tap(find.text('Post to friends'));
    await tester.pumpAndSettle();

    expect(
      find.text('You\'ve posted your progress 3 times today. Try again tomorrow.'),
      findsOneWidget,
    );
    expect(find.text('Share your progress'), findsOneWidget, reason: 'the sheet stays open');
    expect(find.text('Posted to your friends'), findsNothing);
  });

  testWidgets('a battle posted before, and a failed post that can be retried', (tester) async {
    await social.share(const MatchShareTarget('m-1'), idempotencyKey: 'first');
    await open(tester, sampleWin);
    await tester.tap(find.text('Post to friends'));
    await tester.pumpAndSettle();
    expect(find.text('You\'ve already posted this battle to your friends.'), findsOneWidget);

    social.failures[FakeSocialOp.share] = const NetworkFailure();
    await tester.tap(find.text('Post to friends'));
    await tester.pumpAndSettle();
    expect(find.text(const NetworkFailure().message), findsOneWidget);
    expect(social.posted, hasLength(1));
  });

  testWidgets('Share to other apps captures the card and hands it over with a caption', (
    tester,
  ) async {
    await open(tester, sampleWin);
    await tester.tap(find.text('Share to other apps'));
    await tester.pumpAndSettle();

    expect(recorder.captured, [sampleWin]);
    expect(recorder.shared.single.image, ShareRecorder.image);
    expect(recorder.shared.single.text, 'I won a Physics battle on Quiz Arena! 🏆');
    expect(find.text('Share this battle'), findsNothing);
    expect(social.posted, isEmpty, reason: 'nothing is posted in the app');
  });

  testWidgets('the caption links to the app only when the build has a link', (tester) async {
    const env = AppEnv(
      flavor: Flavor.dev,
      apiBaseUrl: 'http://api.test',
      googleServerClientId: '',
      shareBaseUrl: 'https://quizarena.app',
    );
    await open(tester, sampleProgress, env: env);
    await tester.tap(find.text('Share to other apps'));
    await tester.pumpAndSettle();

    expect(
      recorder.shared.single.text,
      'Level 12 on Quiz Arena with a 7-day streak! 📈 https://quizarena.app',
    );
  });

  testWidgets('a capture that fails says so and can be tried again', (tester) async {
    recorder.captureError = StateError('no frame');
    await open(tester, sampleWin);
    await tester.tap(find.text('Share to other apps'));
    await tester.pumpAndSettle();

    expect(find.text('Couldn\'t share the image. Please try again.'), findsOneWidget);
    expect(recorder.shared, isEmpty);

    recorder.captureError = null;
    await tester.tap(find.text('Share to other apps'));
    await tester.pumpAndSettle();
    expect(recorder.shared, hasLength(1));
  });
}
