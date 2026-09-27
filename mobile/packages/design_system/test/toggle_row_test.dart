import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('tapping the text or the switch flips the value', (tester) async {
    var value = false;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => ToggleRow(
            title: 'Timed',
            subtitle: '30 s per question',
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );

    await tester.tap(find.text('30 s per question'));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(value, isFalse);
  });

  testWidgets('is one toggle for accessibility, with its label and state', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(ToggleRow(title: 'Timed', value: true, onChanged: (_) {})));

    final node = tester.getSemantics(find.bySemanticsLabel('Timed'));
    expect(
      node,
      isSemantics(label: 'Timed', hasToggledState: true, isToggled: true, hasTapAction: true),
    );
    semantics.dispose();
  });

  testWidgets('a disabled row ignores taps and is at least a touch target tall', (tester) async {
    await tester.pumpWidget(_host(const ToggleRow(title: 'Timed', value: false, onChanged: null)));

    await tester.tap(find.text('Timed'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(tester.getSize(find.byType(ToggleRow)).height, greaterThanOrEqualTo(AppSizes.minTouch));
  });

  test('switches use the ink pill when on, in both themes', () {
    for (final (theme, colors) in [
      (AppTheme.light(), AppColors.light),
      (AppTheme.dark(), AppColors.dark),
    ]) {
      final track = theme.switchTheme.trackColor!;
      expect(track.resolve({WidgetState.selected}), colors.inverse);
      expect(track.resolve({}), colors.surfaceSunken);
      expect(theme.switchTheme.thumbColor!.resolve({WidgetState.selected}), colors.onInverse);
    }
  });
}
