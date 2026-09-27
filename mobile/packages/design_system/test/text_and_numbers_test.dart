import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _plain(List<InlineSpan> spans) => spans.map((s) {
  if (s is TextSpan) return s.text ?? '';
  if (s is WidgetSpan) {
    final text = (s.child as Transform).child! as Text;
    final nested = text.textSpan as TextSpan?;
    return '[${text.data ?? _plain(nested!.children!)}]';
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

    test('scripts nest inside braced scripts', () {
      expect(_plain(parseQuizMarkup('d_{x^2−y^2} and d_{z^2}', base)), 'd[x2−y2] and d[z2]');
      expect(_plain(parseQuizMarkup('e^{-x^2}', base)), 'e[−x2]');
    });

    test('a lone star inside a script is literal, not italics', () {
      final spans = parseQuizMarkup('σ^{*}2s is antibonding', base);
      expect(_plain(spans), 'σ[*]2s is antibonding');
      expect((spans.last as TextSpan).style!.fontStyle, isNull);
    });

    test('line breaks are kept for statement questions', () {
      const stem = 'Assertion (A): x\nReason (R): y';
      expect(_plain(parseQuizMarkup(stem, base)), stem);
    });
  });

  group('question widgets', () {
    Widget wrap(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    testWidgets('QuestionCard shows a figure description until artwork exists', (tester) async {
      await tester.pumpWidget(
        wrap(
          const QuestionCard(
            number: 1,
            total: 7,
            text: 'Statement I: a\nStatement II: b',
            figure: QuestionFigure(description: 'A block on a 30° incline'),
          ),
        ),
      );
      expect(find.text('FIGURE'), findsOneWidget);
      expect(find.textContaining('30° incline', findRichText: true), findsOneWidget);
    });

    testWidgets('QuestionFigure prefers the image and labels it', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        wrap(
          const QuestionFigure(
            description: 'Ray diagram of a convex lens',
            image: SizedBox(width: 100, height: 60),
          ),
        ),
      );
      expect(find.text('FIGURE'), findsNothing);
      expect(find.bySemanticsLabel('Ray diagram of a convex lens'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('ExplanationCard shows the formula when given', (tester) async {
      await tester.pumpWidget(
        wrap(
          const ExplanationCard(
            text: 'Using s = ut + ½at^2 with u = 0.',
            formula: 's = ut + ½at^2',
            correct: true,
          ),
        ),
      );
      expect(find.text('EXPLANATION'), findsOneWidget);
      expect(find.textContaining('with u = 0', findRichText: true), findsOneWidget);
      expect(find.textContaining('s = ut + ½at', findRichText: true), findsNWidgets(2));
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
