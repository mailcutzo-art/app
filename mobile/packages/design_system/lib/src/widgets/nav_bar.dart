import 'package:flutter/material.dart';

import '../icons/huge_icon.dart';
import '../icons/icon_motion.dart';
import '../icons/icon_shapes.dart';
import '../theme/app_theme.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';
import '../tokens/app_shadows.dart';
import 'pressable.dart';

@immutable
class NavItem {
  const NavItem({required this.icon, required this.label, this.motion, this.showDot = false});

  final HugeIconData icon;
  final String label;
  final IconMotion? motion;
  final bool showDot;
}

/// Floating pill navigation bar. The selected item expands into an ink pill
/// with its label, and its icon plays its motion.
class FloatingNavBar extends StatelessWidget {
  const FloatingNavBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<NavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        bottomInset > 0 ? bottomInset : AppSpacing.lg,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Container(
            height: AppSizes.navBar,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: AppRadii.pillAll,
              border: Border.all(color: colors.outline),
              boxShadow: AppShadows.floating(colors),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < items.length; i++)
                  _NavButton(
                    item: items[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelected(i),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.item, required this.selected, required this.onTap});

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final duration = AppMotion.of(context, AppMotion.medium);
    final fg = selected ? colors.onInverse : colors.inkMuted;
    final icon = item.motion == null
        ? HugeIcon(item.icon, size: 22, color: fg)
        : AnimatedHugeIcon(item.icon, motion: item.motion!, trigger: selected, size: 22, color: fg);

    return Pressable(
      onPressed: onTap,
      selected: selected,
      semanticLabel: item.label,
      pressedScale: 0.92,
      child: AnimatedContainer(
        duration: duration,
        curve: AppMotion.emphasized,
        height: AppSizes.navItem,
        padding: EdgeInsets.symmetric(horizontal: selected ? 16 : 15),
        decoration: BoxDecoration(
          color: selected ? colors.inverse : Colors.transparent,
          borderRadius: AppRadii.pillAll,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                icon,
                if (item.showDot)
                  Positioned(
                    top: -1,
                    right: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: colors.error,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.surface, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
            AnimatedSize(
              duration: duration,
              curve: AppMotion.emphasized,
              child: selected
                  ? Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        item.label,
                        style: context.text.labelMedium.copyWith(color: colors.onInverse),
                        maxLines: 1,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
