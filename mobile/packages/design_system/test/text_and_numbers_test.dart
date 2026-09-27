import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _plain(List<InlineSpan> spans) => spans.map((s) {
  if (s is TextSpan) return s.text ?? '';
  if (s is WidgetSpan) {
    final text = (s.child as Transform).child! as Text;
    return '[${text.data}]';
  }
  return '?';
}).join();

void main() {
  const base = TextStyle(fontSize: 20);

  group('parseQuizMarkup', () {
    test('plain text stays one span', () {
      final spans = parseQuizMarkup('Newton second law', base);
      expect(spans, hasLength(1));
      expect(_plain(spans), 'Newton second law');
    });

    test('digit subscripts use font features', () {
      final spans = parseQuizMarkup('H_2SO_4', base);
      expect(_plain(spans), 'H2SO4');
      final two = spans[1] as TextSpan;
      expect(two.style!.fontFeatures, contains(const FontFeature.subscripts()));
    });

    test('grouped and non-digit scripts fall back to shifted text', () {
      final spans = parseQuizMarkup('e^{-kt} and a_{max}', base);
      expect(_plain(spans), 'e[−kt] and a[max]');
    });

    test('bold and italic toggle', () {
      final spans = parseQuizMarkup('a **b** *c*', base).cast<TextSpan>();
      expect(spans.map((s) => s.text), ['a ', 'b', ' ', 'c']);
      expect(spans[1].style!.fontWeight, FontWeight.w800);
      expect(spans[3].style!.fontStyle, FontStyle.italic);
    });

    test('a trailing caret or underscore is kept literally', () {
      expect(_plain(parseQuizMarkup('x_ and y^', base)), 'x_ and y^');
    });
  });

  group('formatCount', () {
    test('international grouping', () {
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(1204), '1,204');
      expect(formatCount(1234567), '1,234,567');
      expect(formatCount(-2500), '-2,500');
    });

    test('Indian grouping', () {
      expect(formatCount(1234567, indian: true), '12,34,567');
      expect(formatCount(100000, indian: true), '1,00,000');
      expect(formatCount(999, indian: true), '999');
    });
  });

  testWidgets('AnswerOption reports its letter and selection to accessibility', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: AnswerOption(
            index: 2,
            text: 'sp^3',
            state: AnswerOptionState.selected,
            onTap: () {},
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel(RegExp('Option C')), findsOneWidget);
  });

  testWidgets('AppButton ignores taps while loading', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: AppButton(label: 'Join', loading: true, onPressed: () => taps++),
        ),
      ),
    );
    await tester.tap(find.byType(AppButton));
    expect(taps, 0);
  });

  testWidgets('CoinAmount shows a balance, or a change with its sign', (tester) async {
    Future<void> pump(CoinAmount amount) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: amount),
      ),
    );
    await pump(const CoinAmount(amount: 1250));
    expect(find.text('1,250'), findsOneWidget);
    await pump(const CoinAmount(amount: 10, signed: true));
    expect(find.text('+10'), findsOneWidget);
    await pump(const CoinAmount(amount: -5, signed: true));
    expect(find.text('−5'), findsOneWidget);
    await pump(const CoinAmount(amount: -5));
    expect(find.text('-5'), findsOneWidget);
    await pump(const CoinAmount(amount: 0, signed: true));
    expect(find.text('0'), findsOneWidget);
  });
}
