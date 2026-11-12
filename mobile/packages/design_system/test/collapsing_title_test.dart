import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester, {
  VoidCallback? onBack,
  Widget? trailing,
  bool reduced = false,
}) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(size: const Size(390, 844), disableAnimations: reduced),
        child: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverCollapsingTitle(
                title: 'Leaderboards',
                subtitle: 'Who is leading where',
                onBack: onBack,
                trailing: trailing,
              ),
              SliverList(
                delegate: SliverChildListDelegate([
                  for (var i = 0; i < 40; i++) SizedBox(height: 60, child: Text('Row $i')),
                ]),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

double _titleSize(WidgetTester tester) =>
    tester.widget<Text>(find.text('Leaderboards')).style!.fontSize!;

double _subtitleOpacity(WidgetTester tester) {
  final subtitle = find.text('Who is leading where');
  if (subtitle.evaluate().isEmpty) return 0;
  return tester
      .widget<Opacity>(find.ancestor(of: subtitle, matching: find.byType(Opacity)).first)
      .opacity;
}

void main() {
  testWidgets('at rest: a big title and its description', (tester) async {
    await _pump(tester);
    expect(_titleSize(tester), 32, reason: 'headlineLarge');
    expect(_subtitleOpacity(tester), 1);
    expect(find.bySemanticsLabel('Back'), findsNothing, reason: 'nothing to go back to');
  });

  testWidgets('scrolling shrinks the title and fades the description', (tester) async {
    await _pump(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -10));
    await tester.pump();
    final partway = _titleSize(tester);
    expect(partway, lessThan(32));
    expect(partway, greaterThan(20));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(_titleSize(tester), 20, reason: 'titleLarge once collapsed');
    expect(_subtitleOpacity(tester), 0);
    // Still pinned at the top while the rows scroll under it.
    expect(tester.getTopLeft(find.text('Leaderboards')).dy, lessThan(40));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(_titleSize(tester), 32, reason: 'scrolling back opens it again');
  });

  testWidgets('a pushed screen gets the back button, and collapses beside it', (tester) async {
    var backs = 0;
    await _pump(tester, onBack: () => backs++);
    await tester.tap(find.bySemanticsLabel('Back'));
    expect(backs, 1);

    final open = tester.getTopLeft(find.text('Leaderboards'));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final shut = tester.getTopLeft(find.text('Leaderboards'));
    expect(shut.dx, greaterThan(open.dx), reason: 'moves up beside the back button');
    expect(shut.dy, lessThan(open.dy));
    expect(_titleSize(tester), 17, reason: 'titleMedium in the top row');
  });

  testWidgets('a trailing badge scales down as the header collapses', (tester) async {
    await _pump(tester, trailing: const SizedBox(key: ValueKey('badge'), width: 56, height: 56));
    double scale() => tester
        .widget<Transform>(
          find
              .ancestor(of: find.byKey(const ValueKey('badge')), matching: find.byType(Transform))
              .first,
        )
        .transform
        .storage[0]; // the x scale (Transform.scale leaves z at 1)
    expect(scale(), closeTo(1, 0.001));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(scale(), closeTo(0.72, 0.001));
  });

  testWidgets('it follows the scroll with reduced motion too', (tester) async {
    await _pump(tester, reduced: true);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(_titleSize(tester), 20);
  });

  testWidgets('paints the page backdrop it is given, never its own colour', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const key = ValueKey('wash');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: PageBackdrop(
            backdrop: const ColoredBox(key: key, color: Color(0xFF123456)),
            child: CustomScrollView(
              slivers: [
                const SliverCollapsingTitle(title: 'Leaderboards'),
                SliverList(
                  delegate: SliverChildListDelegate([
                    for (var i = 0; i < 40; i++) const SizedBox(height: 60),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(key), findsOneWidget);
  });

  testWidgets('mid-collapse, the title never runs into the back button', (tester) async {
    await _pump(tester, onBack: () {});
    final back = tester.getRect(find.bySemanticsLabel('Back'));
    for (var step = 0; step < 12; step++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4));
      await tester.pump();
      final title = tester.getRect(find.text('Leaderboards'));
      expect(title.overlaps(back), isFalse, reason: 'step $step: $title vs $back');
    }
  });

  testWidgets('let go part-way and it settles open or shut', (tester) async {
    await _pump(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -6));
    await tester.pumpAndSettle();
    expect(_titleSize(tester), 32, reason: 'a little scroll settles back open');

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -25));
    await tester.pumpAndSettle();
    expect(_titleSize(tester), 20, reason: 'most of the way settles shut');
  });

  testWidgets('a wide action never runs into the collapsed title', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const chip = ValueKey('chip');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverCollapsingTitle(
                title: 'A very long screen title that needs room',
                onBack: () {},
                actions: const [SizedBox(key: chip, width: 140, height: 40)],
              ),
              SliverList(
                delegate: SliverChildListDelegate([
                  for (var i = 0; i < 40; i++) const SizedBox(height: 60),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('A very long screen title that needs room'));
    expect(title.right, lessThanOrEqualTo(tester.getRect(find.byKey(chip)).left));
  });
}
