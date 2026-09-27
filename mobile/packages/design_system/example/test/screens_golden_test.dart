import 'package:design_system/design_system.dart';
import 'package:design_system_catalog/gallery/cards_page.dart';
import 'package:design_system_catalog/gallery/competition_page.dart';
import 'package:design_system_catalog/gallery/controls_page.dart';
import 'package:design_system_catalog/gallery/feedback_page.dart';
import 'package:design_system_catalog/gallery/foundations_page.dart';
import 'package:design_system_catalog/gallery/quiz_page.dart';
import 'package:design_system_catalog/screens/arena_screen.dart';
import 'package:design_system_catalog/screens/battle_screen.dart';
import 'package:design_system_catalog/screens/home_screen.dart';
import 'package:design_system_catalog/screens/learn_screen.dart';
import 'package:design_system_catalog/screens/matchmaking_screen.dart';
import 'package:design_system_catalog/screens/question_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _phone = Size(390, 844);

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page, {
  required Brightness brightness,
  Size size = _phone,
}) async {
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      // Static frames: stop looping animations so goldens are deterministic.
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final screens = <String, (Widget, double)>{
    'home': (const HomeMockScreen(), 2250),
    'learn': (const LearnMockScreen(), 1900),
    'battle': (const BattleMockScreen(), 1650),
    'arena': (const ArenaMockScreen(), 1650),
    'matchmaking': (const MatchmakingMockScreen(), _phone.height),
    'question': (const QuestionMockScreen(), 1000),
  };

  final galleries = <String, (Widget, double)>{
    'foundations': (const FoundationsPage(), 1900),
    'controls': (const ControlsPage(), 1750),
    'cards': (const CardsPage(), 1500),
    'quiz': (const QuizPage(), 1850),
    'competition': (const CompetitionPage(), 1550),
    'feedback': (const FeedbackPage(), 1500),
  };

  for (final brightness in Brightness.values) {
    final theme = brightness.name;
    group('$theme theme', () {
      for (final MapEntry(key: name, value: (page, _)) in screens.entries) {
        testWidgets('screen $name (phone viewport)', (tester) async {
          await _pumpPage(tester, page, brightness: brightness);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/$theme/screen_$name.png'),
          );
        });
      }

      for (final MapEntry(key: name, value: (page, height)) in screens.entries) {
        if (height <= _phone.height) continue;
        testWidgets('screen $name (full length)', (tester) async {
          await _pumpPage(tester, page, brightness: brightness, size: Size(_phone.width, height));
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/$theme/full_$name.png'),
          );
        });
      }

      for (final MapEntry(key: name, value: (page, height)) in galleries.entries) {
        testWidgets('gallery $name', (tester) async {
          await _pumpPage(tester, page, brightness: brightness, size: Size(_phone.width, height));
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/$theme/gallery_$name.png'),
          );
        });
      }
    });
  }
}
