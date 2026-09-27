import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  theme: AppTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: child!,
  ),
  home: Scaffold(body: Center(child: child)),
);

const _emotes = [
  EmoteOption(id: 'gg', label: 'GG'),
  EmoteOption(id: 'nice', label: 'Nice!'),
  EmoteOption(id: 'wow', label: 'Wow'),
  EmoteOption(id: 'oops', label: 'Oops'),
];

void main() {
  group('EmoteBar', () {
    testWidgets('sends the tapped reaction, then rests for the cooldown', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(_host(EmoteBar(emotes: _emotes, onSend: sent.add)));

      await tester.tap(find.text('GG'));
      await tester.pump();
      expect(sent, ['gg']);

      await tester.tap(find.text('Wow'), warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));
      expect(sent, ['gg'], reason: 'at most one reaction every 3 s');

      await tester.pump(const Duration(seconds: 2, milliseconds: 100));
      await tester.tap(find.text('Wow'));
      await tester.pump();
      expect(sent, ['gg', 'wow']);
      await tester.pumpAndSettle();
    });

    testWidgets('the cooldown also holds with reduced motion', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(
        _host(EmoteBar(emotes: _emotes, onSend: sent.add), reduceMotion: true),
      );
      await tester.tap(find.text('Nice!'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Oops'), warnIfMissed: false);
      expect(sent, ['nice']);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oops'));
      expect(sent, ['nice', 'oops']);
    });

    testWidgets('without a callback it is disabled', (tester) async {
      await tester.pumpWidget(_host(const EmoteBar(emotes: _emotes, onSend: null)));
      final buttons = tester.widgetList<Pressable>(find.byType(Pressable));
      expect(buttons, hasLength(4));
      expect(buttons.every((button) => button.onPressed == null), isTrue);
    });
  });

  testWidgets('EmoteBubble pops in and reads its text to screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(const EmoteBubble(label: 'Nice!')));
    await tester.pumpAndSettle();
    expect(find.text('Nice!'), findsOneWidget);
    expect(find.bySemanticsLabel('Nice!'), findsOneWidget);
    semantics.dispose();
  });

  group('ResultDots', () {
    testWidgets('draws one dot per question and describes each', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const ResultDots(
            dots: [
              ResultDot(outcome: DotOutcome.right, speed: DotSpeed.fast),
              ResultDot(outcome: DotOutcome.wrong, speed: DotSpeed.slow),
              ResultDot(outcome: DotOutcome.missed),
              ResultDot(outcome: DotOutcome.unknown),
            ],
          ),
        ),
      );
      expect(find.bySemanticsLabel('Question 1: right, faster'), findsOneWidget);
      expect(find.bySemanticsLabel('Question 2: wrong, slower'), findsOneWidget);
      expect(find.bySemanticsLabel('Question 3: no answer'), findsOneWidget);
      expect(find.bySemanticsLabel('Question 4: not known'), findsOneWidget);
      semantics.dispose();
    });

    test('an even pace adds nothing to the description', () {
      expect(
        ResultDots.describe(5, const ResultDot(outcome: DotOutcome.right, speed: DotSpeed.even)),
        'Question 5: right',
      );
    });

    testWidgets('lays out in dark mode too', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: ResultDots(
              dots: [
                for (var i = 0; i < 7; i++)
                  const ResultDot(outcome: DotOutcome.right, speed: DotSpeed.fast),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('AppSegmentedControl', () {
    testWidgets('a disabled segment cannot be picked', (tester) async {
      var selected = 'rated';
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 320,
              child: AppSegmentedControl<String>(
                segments: const [
                  AppSegment(value: 'rated', label: 'Rated'),
                  AppSegment(value: 'casual', label: 'Casual', enabled: false),
                ],
                selected: selected,
                onChanged: (value) => setState(() => selected = value),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Casual'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(selected, 'rated');
    });
  });
}
