import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _items = [
  NavItem(icon: AppIcons.home, label: 'Home'),
  NavItem(icon: AppIcons.battle, label: 'Battle'),
];

Widget _bar(int selected, {required bool reduceMotion}) => MaterialApp(
  theme: AppTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: child!,
  ),
  home: Scaffold(
    bottomNavigationBar: FloatingNavBar(
      items: _items,
      selectedIndex: selected,
      onSelected: (_) {},
    ),
  ),
);

void main() {
  for (final reduced in [false, true]) {
    testWidgets('switching tabs shows the new label (reduce motion: $reduced)', (tester) async {
      await tester.pumpWidget(_bar(0, reduceMotion: reduced));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Battle'), findsNothing);

      await tester.pumpWidget(_bar(1, reduceMotion: reduced));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Battle'), findsOneWidget);
      expect(find.text('Home'), findsNothing);
    });
  }
}
