import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/app_motion.dart';

enum HapticKind { none, selection, light, medium }

/// The player's touch feedback preferences, read by every [Pressable] below it: haptic ticks and
/// the platform's click sound. Without one, haptics are on and clicks off.
class TouchFeedback extends InheritedWidget {
  const TouchFeedback({
    super.key,
    required this.haptics,
    required this.sounds,
    required super.child,
  });

  final bool haptics;
  final bool sounds;

  /// The nearest preferences, without depending on them (read on tap, not in build).
  static TouchFeedback? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TouchFeedback>();

  @override
  bool updateShouldNotify(TouchFeedback oldWidget) =>
      haptics != oldWidget.haptics || sounds != oldWidget.sounds;
}

/// Tap target with the design system's press feedback: a quick scale-down,
/// an optional haptic tick, button semantics and keyboard activation.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    required this.onPressed,
    this.onLongPress,
    this.pressedScale = AppMotion.pressedScale,
    this.haptic = HapticKind.selection,
    this.semanticLabel,
    this.isButton = true,
    this.selected,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final HapticKind haptic;
  final String? semanticLabel;
  final bool isButton;
  final bool? selected;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null || widget.onLongPress != null;

  void _setPressed(bool value) {
    if (_pressed != value && mounted) setState(() => _pressed = value);
  }

  void _handleTap() {
    final feedback = TouchFeedback.maybeOf(context);
    if (feedback?.sounds ?? false) SystemSound.play(SystemSoundType.click);
    final haptic = (feedback?.haptics ?? true) ? widget.haptic : HapticKind.none;
    switch (haptic) {
      case HapticKind.none:
        break;
      case HapticKind.selection:
        HapticFeedback.selectionClick();
      case HapticKind.light:
        HapticFeedback.lightImpact();
      case HapticKind.medium:
        HapticFeedback.mediumImpact();
    }
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final scale = _pressed && !reduced ? widget.pressedScale : 1.0;
    return Semantics(
      button: widget.isButton,
      enabled: _enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (widget.onPressed != null) _handleTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => _setPressed(true) : null,
          onTapUp: _enabled ? (_) => _setPressed(false) : null,
          onTapCancel: _enabled ? () => _setPressed(false) : null,
          onTap: widget.onPressed == null ? null : _handleTap,
          onLongPress: widget.onLongPress,
          child: AnimatedScale(
            scale: scale,
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
