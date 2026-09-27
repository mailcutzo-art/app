import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../icons/huge_icon.dart';
import '../theme/app_theme.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';

/// Formats an integer with thousands separators (Indian grouping optional).
String formatCount(int value, {bool indian = false}) {
  final negative = value < 0;
  final digits = value.abs().toString();
  final buffer = StringBuffer();
  if (indian && digits.length > 3) {
    final head = digits.substring(0, digits.length - 3);
    final tail = digits.substring(digits.length - 3);
    for (var i = 0; i < head.length; i++) {
      if (i > 0 && (head.length - i).isEven) buffer.write(',');
      buffer.write(head[i]);
    }
    buffer
      ..write(',')
      ..write(tail);
  } else {
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
  }
  return negative ? '-$buffer' : buffer.toString();
}

/// Animated integer that counts to its new value (tabular figures, so the
/// width stays stable while it runs).
class NumberTicker extends StatelessWidget {
  const NumberTicker({
    super.key,
    required this.value,
    this.style,
    this.prefix = '',
    this.suffix = '',
    this.duration = const Duration(milliseconds: 700),
  });

  final int value;
  final TextStyle? style;
  final String prefix;
  final String suffix;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.toDouble()),
      duration: AppMotion.of(context, duration),
      curve: AppMotion.emphasized,
      builder: (context, v, _) => Text(
        '$prefix${formatCount(v.round())}$suffix',
        style: style,
        semanticsLabel: '$prefix${formatCount(value)}$suffix',
      ),
    );
  }
}

/// "+12" / "−8" rating change pill.
class RatingDelta extends StatelessWidget {
  const RatingDelta({super.key, required this.delta});

  final int delta;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final positive = delta >= 0;
    final bg = positive ? colors.successContainer : colors.errorContainer;
    final fg = positive ? colors.onSuccessContainer : colors.onErrorContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: AppRadii.pillAll),
      child: Text(
        positive ? '+$delta' : '−${delta.abs()}',
        style: context.text.numericMedium.copyWith(color: fg, fontSize: 13),
      ),
    );
  }
}

/// Coin amount with the coin icon.
class CoinAmount extends StatelessWidget {
  const CoinAmount({super.key, required this.amount, this.style, this.iconSize = 18});

  final int amount;
  final TextStyle? style;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HugeIcon(AppIcons.coins, size: iconSize, color: context.colors.coin),
        const SizedBox(width: 4),
        Text(formatCount(amount), style: style ?? context.text.numericMedium),
      ],
    );
  }
}
