import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

/// The app's five tabs, shared by the mock tab screens.
const appNavItems = [
  NavItem(icon: AppIcons.home, label: 'Home', motion: IconMotions.home),
  NavItem(icon: AppIcons.learn, label: 'Learn', motion: IconMotions.book),
  NavItem(icon: AppIcons.battle, label: 'Battle', motion: IconMotions.gamepad),
  NavItem(icon: AppIcons.arena, label: 'Arena', motion: IconMotions.trophy),
  NavItem(icon: AppIcons.social, label: 'Social', motion: IconMotions.users, showDot: true),
];

/// Tab page chrome: soft gradient wash at the top, scrolling content that
/// passes under the floating nav bar.
class TabScaffold extends StatelessWidget {
  const TabScaffold({super.key, required this.selectedTab, required this.children});

  final int selectedTab;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      extendBody: true,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.paperGradientStart, colors.paperGradientEnd, colors.paper],
            stops: const [0, 0.22, 0.42],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: ListView(padding: const EdgeInsets.only(bottom: 120), children: children),
        ),
      ),
      bottomNavigationBar: FloatingNavBar(
        items: appNavItems,
        selectedIndex: selectedTab,
        onSelected: (_) {},
      ),
    );
  }
}

/// Horizontal gutter padding.
class Gutter extends StatelessWidget {
  const Gutter({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
    child: child,
  );
}
