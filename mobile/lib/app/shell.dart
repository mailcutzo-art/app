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
        // Learn returns to its subject list whenever the tab is revisited. Other tabs keep
        // their place when switching between tabs; tapping the current tab resets it.
        onSelected: (index) {
          FocusManager.instance.primaryFocus?.unfocus();
          shell.goBranch(index, initialLocation: index == shell.currentIndex || index == 1);
        },
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

/// Standard tab page: soft gradient wash behind scrolling content that ends above the floating
/// nav bar.
///
/// The top is one of:
/// * [title]: a [SliverCollapsingTitle] that shrinks as the page scrolls (most tabs);
/// * [header]: a header that stays put while the content scrolls under it (Home);
/// * neither: [children] start at the top.
class TabPage extends StatelessWidget {
  const TabPage({super.key, required this.children, this.onRefresh, this.title, this.header})
    : assert(title == null || header == null, 'A page has a collapsing title or a fixed header');

  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final SliverCollapsingTitle? title;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = this.title;
    final header = this.header;
    final wash = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [colors.paperGradientStart, colors.paperGradientEnd, colors.paper],
          stops: const [0, 0.22, 0.42],
        ),
      ),
    );
    Widget scroll = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        ?title,
        SliverPadding(
          // Room for the floating tab bar (and the gap under it), so the last item scrolls clear.
          padding: EdgeInsets.only(
            bottom:
                AppSizes.navBar + AppSpacing.sm + AppSpacing.bottomAction(context) + AppSpacing.xxl,
          ),
          sliver: SliverList(delegate: SliverChildListDelegate(children)),
        ),
      ],
    );
    if (onRefresh case final refresh?) {
      scroll = RefreshIndicator(
        onRefresh: refresh,
        color: colors.ink,
        backgroundColor: colors.surface,
        child: scroll,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // The header shows the very slice of the wash behind it, so it's never a separate band.
        final top = MediaQuery.paddingOf(context).top;
        final backdrop = _WashSlice(height: constraints.maxHeight, top: top, child: wash);
        return Stack(
          fit: StackFit.expand,
          children: [
            wash,
            SafeArea(
              bottom: false,
              child: PageBackdrop(
                backdrop: backdrop,
                child: header == null
                    ? scroll
                    : Column(
                        children: [
                          ClipRect(
                            child: Stack(
                              children: [
                                Positioned.fill(child: backdrop),
                                Padding(
                                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                                  child: header,
                                ),
                              ],
                            ),
                          ),
                          Expanded(child: scroll),
                        ],
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The part of a page-sized [child] that sits behind a header [top] below the page's top edge.
class _WashSlice extends StatelessWidget {
  const _WashSlice({required this.height, required this.top, required this.child});

  final double height;
  final double top;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: OverflowBox(
      alignment: Alignment.topCenter,
      minHeight: height,
      maxHeight: height,
      child: Transform.translate(offset: Offset(0, -top), child: child),
    ),
  );
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
