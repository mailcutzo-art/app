import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/features/auth/sign_in_screen.dart';
import 'package:quiz_app/features/auth/welcome/arena_hero.dart';

import '../../support/fakes.dart';

/// A release-like build: Google configured, no developer shortcuts.
const prodEnv = AppEnv(
  flavor: Flavor.prod,
  apiBaseUrl: 'http://api.test',
  googleServerClientId: 'web-client-id',
);

/// Counts Google sign-ins instead of opening the account picker.
class RecordingSessionController extends FakeSessionController {
  RecordingSessionController([super.initial = const SignedOut()]);

  int googleSignIns = 0;

  @override
  Future<void> signInWithGoogle() async => googleSignIns++;
}

typedef Phone = ({String name, Size size, EdgeInsets padding});

const phones = <Phone>[
  (name: 'small 320×568', size: Size(320, 568), padding: EdgeInsets.only(top: 24)),
  (name: 'normal 390×844', size: Size(390, 844), padding: EdgeInsets.only(top: 47, bottom: 34)),
  (name: 'large 430×932', size: Size(430, 932), padding: EdgeInsets.only(top: 59, bottom: 34)),
  (name: 'tall 360×800', size: Size(360, 800), padding: EdgeInsets.only(top: 32, bottom: 24)),
];

void usePhone(WidgetTester tester, Phone phone, {double textScale = 1}) {
  const ratio = 3.0;
  tester.view
    ..physicalSize = phone.size * ratio
    ..devicePixelRatio = ratio
    ..padding = FakeViewPadding(
      top: phone.padding.top * ratio,
      bottom: phone.padding.bottom * ratio,
    )
    ..viewPadding = FakeViewPadding(
      top: phone.padding.top * ratio,
      bottom: phone.padding.bottom * ratio,
    );
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<RecordingSessionController> pumpWelcome(
  WidgetTester tester, {
  AppEnv env = prodEnv,
  Session session = const SignedOut(),
  bool tickers = true,
}) async {
  final controller = RecordingSessionController(session);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appEnvProvider.overrideWithValue(env),
        sessionProvider.overrideWith(() => controller),
      ],
      child: TickerMode(
        enabled: tickers,
        child: MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          home: const SignInScreen(),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

Finder get google => find.widgetWithText(AppButton, 'Continue with Google');

/// The Google button is laid out entirely inside the screen, without scrolling.
void expectGoogleOnScreen(WidgetTester tester, Phone phone) {
  final rect = tester.getRect(google);
  expect(rect.top, greaterThanOrEqualTo(phone.padding.top));
  expect(rect.bottom, lessThanOrEqualTo(phone.size.height - phone.padding.bottom));
}

void main() {
  group('fits', () {
    for (final phone in phones) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('${phone.name} at text ×$scale', (tester) async {
          usePhone(tester, phone, textScale: scale);
          await pumpWelcome(tester);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Learn. Battle. Level\u00A0Up.'), findsOneWidget);
          expect(find.text('Master NEET & JEE one challenge at a time.'), findsOneWidget);
          for (final chip in ['1v1', 'Tournaments', 'Practice']) {
            expect(find.text(chip), findsOneWidget);
          }
          expectGoogleOnScreen(tester, phone);
          expect(
            tester
                .renderObject<RenderParagraph>(find.text('Continue with Google'))
                .didExceedMaxLines,
            isFalse,
            reason: 'the label is never cut off',
          );
          // The arena keeps its proportions and a useful size.
          final hero = tester.getSize(
            find.descendant(of: find.byType(ArenaHero), matching: find.byType(Stack)).first,
          );
          expect(hero.height / hero.width, closeTo(ArenaHero.aspectRatio, 0.01));
          expect(hero.height, greaterThanOrEqualTo(QuizArenaWelcomePage.minHeroHeight));
        });
      }
    }

    testWidgets('small phone at text ×2.0 scrolls to a usable button', (tester) async {
      final phone = phones.first;
      usePhone(tester, phone, textScale: 2);
      final session = await pumpWelcome(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(google);
      await tester.pumpAndSettle();
      expectGoogleOnScreen(tester, phone);
      await tester.tap(google);
      await tester.pump();
      expect(session.googleSignIns, 1);
    });

    testWidgets('dev builds still fit with the developer shortcuts', (tester) async {
      usePhone(tester, phones[1]);
      await pumpWelcome(tester, env: testEnv);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Developer login'), findsOneWidget);
      expect(find.text('Debug settings'), findsOneWidget);
      expectGoogleOnScreen(tester, phones[1]);
    });
  });

  testWidgets('Continue with Google goes through the session sign-in', (tester) async {
    usePhone(tester, phones[1]);
    final session = await pumpWelcome(tester);
    await tester.pumpAndSettle();
    await tester.tap(google);
    await tester.pump();
    expect(session.googleSignIns, 1);
    expect(find.text('Developer login'), findsNothing, reason: 'not in release builds');
  });

  testWidgets('Google stays disabled until the build is configured for it', (tester) async {
    usePhone(tester, phones[1]);
    await pumpWelcome(tester, env: testEnv);
    await tester.pumpAndSettle();
    expect(tester.widget<AppButton>(google).onPressed, isNull);
  });

  testWidgets('says why the session ended', (tester) async {
    usePhone(tester, phones.first);
    await pumpWelcome(tester, session: SignedOut(message: signedOutMessage('session_limit')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(signedOutMessage('session_limit')), findsOneWidget);
  });

  testWidgets('always shows the dark welcome, whatever the system theme', (tester) async {
    usePhone(tester, phones[1]);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpWelcome(tester);
    final context = tester.element(find.byType(ArenaHero));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(context.colors.paper, AppColors.dark.paper);
    await tester.pumpAndSettle();
  });

  testWidgets('the artwork stays out of the accessibility tree', (tester) async {
    final semantics = tester.ensureSemantics();
    usePhone(tester, phones[1]);
    await pumpWelcome(tester);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('?'), findsNothing);
    expect(find.bySemanticsLabel('Quiz Arena'), findsOneWidget);
    expect(find.bySemanticsLabel('Continue with Google'), findsOneWidget);
    semantics.dispose();
  });

  group('motion', () {
    testWidgets('plays the entrance, idles for a while, then rests', (tester) async {
      usePhone(tester, phones[1]);
      await pumpWelcome(tester);
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await tester.pump(ArenaHero.entranceDuration);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.binding.transientCallbackCount, greaterThan(0), reason: 'idle motion');

      await tester.pump(ArenaHero.idlePeriod * ArenaHero.idleCycles);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0, reason: 'no perpetual ticking');
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('reduced motion shows the resting scene without ticking', (tester) async {
      usePhone(tester, phones[1]);
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
        disableAnimations: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pumpWelcome(tester);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      // Everything is already in place.
      final fades = tester.widgetList<FadeTransition>(
        find.descendant(of: find.byType(ArenaHero), matching: find.byType(FadeTransition)),
      );
      expect(fades, isNotEmpty);
      expect(fades.every((fade) => fade.opacity.value == 1), isTrue);
    });

    testWidgets('does no animation work while TickerMode is off', (tester) async {
      usePhone(tester, phones[1]);
      await pumpWelcome(tester, tickers: false);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);

      // Visible again: picks up where it was.
      await pumpWelcome(tester);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpAndSettle();
    });

    testWidgets('disposes its controllers with the screen', (tester) async {
      usePhone(tester, phones[1]);
      await pumpWelcome(tester);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
    });
  });
}
