import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

/// Page chrome for component galleries.
class GalleryScaffold extends StatelessWidget {
  const GalleryScaffold({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppTopBar(title: title),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          AppSpacing.huge,
        ),
        children: children,
      ),
    );
  }
}

/// Labeled demo block.
class DemoBlock extends StatelessWidget {
  const DemoBlock({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: context.text.overline),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }
}

/// Wraps children with consistent spacing.
class Spaced extends StatelessWidget {
  const Spaced({
    super.key,
    required this.children,
    this.gap = AppSpacing.md,
    this.horizontal = false,
  });

  final List<Widget> children;
  final double gap;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) horizontal ? SizedBox(width: gap) : SizedBox(height: gap),
        children[i],
      ],
    ];
    return horizontal
        ? Wrap(spacing: gap, runSpacing: gap, children: children)
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items);
  }
}
