import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The five main tabs.
const appTabs = [
  NavItem(icon: AppIcons.home, label: 'Home', motion: IconMotions.home),
  NavItem(icon: AppIcons.learn, label: 'Learn', motion: IconMotions.book),
  NavItem(icon: AppIcons.battle, label: 'Battle', motion: IconMotions.gamepad),
  NavItem(icon: AppIcons.arena, label: 'Arena', motion: IconMotions.trophy),
  NavItem(icon: AppIcons.social, label: 'Social', motion: IconMotions.users),
];

/// Tab scaffold: content scrolls under the floating pill nav bar.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: shell,
      bottomNavigationBar: FloatingNavBar(
        items: appTabs,
        selectedIndex: shell.currentIndex,
        // Tapping the current tab again returns it to its first page.
        onSelected: (index) => shell.goBranch(index, initialLocation: index == shell.currentIndex),
      ),
    );
  }
}

/// Keeps every tab alive like an [IndexedStack] but fades between them.
/// Hidden tabs are offstage with tickers paused, so they cost nothing.
class FadeIndexedStack extends StatefulWidget {
  const FadeIndexedStack({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
    value: 1,
  );

  @override
  void didUpdateWidget(covariant FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      if (AppMotion.reduced(context)) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _controller, curve: AppMotion.emphasized);
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          Offstage(
            offstage: i != widget.index,
            child: TickerMode(
              enabled: i == widget.index,
              child: i == widget.index
                  ? FadeTransition(
                      opacity: curved,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.985, end: 1).animate(curved),
                        child: widget.children[i],
                      ),
                    )
                  : widget.children[i],
            ),
          ),
      ],
    );
  }
}

/// Standard tab page: soft gradient wash behind a scrolling list that ends
/// above the floating nav bar.
class TabPage extends StatelessWidget {
  const TabPage({super.key, required this.children, this.onRefresh});

  final List<Widget> children;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final list = ListView(
      padding: const EdgeInsets.only(bottom: 128),
      physics: const AlwaysScrollableScrollPhysics(),
      children: children,
    );
    return DecoratedBox(
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
        child: onRefresh == null
            ? list
            : RefreshIndicator(
                onRefresh: onRefresh!,
                color: colors.ink,
                backgroundColor: colors.surface,
                child: list,
              ),
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
