import 'package:flutter/material.dart';

/// Renders question text with lightweight markup for science content:
///
/// * `x^2`, `x^{n+1}` superscript · `H_2O`, `a_{max}` subscript
/// * scripts nest: `d_{x^2−y^2}`, `e^{-x^2}`; `σ^{*}` is a literal star
/// * `**bold**` · `*italic*`
/// * line breaks in the source are kept (statement and match questions)
///
/// Digit-only scripts use the font's real superscript/subscript glyphs;
/// anything else falls back to smaller, shifted text.
class QuizText extends StatelessWidget {
  const QuizText(this.source, {super.key, this.style, this.textAlign, this.maxLines});

  final String source;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(children: parseQuizMarkup(source, base)),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

final _fontScript = RegExp(r'^[0-9]+$');

/// Parses [source] into spans styled from [base]. Exposed for testing.
List<InlineSpan> parseQuizMarkup(String source, TextStyle base) {
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();
  var bold = false;
  var italic = false;

  TextStyle current() => base.copyWith(
    fontWeight: bold ? FontWeight.w800 : null,
    fontStyle: italic ? FontStyle.italic : null,
  );

  void flush() {
    if (buffer.isEmpty) return;
    spans.add(TextSpan(text: buffer.toString(), style: current()));
    buffer.clear();
  }

  var i = 0;
  while (i < source.length) {
    final ch = source[i];
    if (ch == '*') {
      final isBold = i + 1 < source.length && source[i + 1] == '*';
      flush();
      if (isBold) {
        bold = !bold;
        i += 2;
      } else {
        italic = !italic;
        i += 1;
      }
      continue;
    }
    if ((ch == '^' || ch == '_') && i + 1 < source.length) {
      String? script;
      var next = i + 1;
      if (source[next] == '{') {
        final close = _matchingBrace(source, next);
        if (close > next) {
          script = source.substring(next + 1, close);
          next = close + 1;
        }
      } else if (source[next].trim().isNotEmpty) {
        script = source[next];
        next += 1;
      }
      if (script != null && script.isNotEmpty) {
        flush();
        spans.add(_script(script.replaceAll('-', '−'), current(), superscript: ch == '^'));
        i = next;
        continue;
      }
    }
    buffer.write(ch);
    i += 1;
  }
  flush();
  return spans;
}

/// Index of the `}` that closes the `{` at [open], or -1 when unbalanced.
int _matchingBrace(String source, int open) {
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return i;
  }
  return -1;
}

// Markup that can appear inside a braced script. `*` counts only in pairs, so a
// lone `σ^{*}` stays a literal star.
final _nestedMarkup = RegExp(r'[\^_]|\*[^*]+\*');

InlineSpan _script(String text, TextStyle style, {required bool superscript}) {
  if (_fontScript.hasMatch(text)) {
    return TextSpan(
      text: text,
      style: style.copyWith(
        fontFeatures: [
          ...?style.fontFeatures,
          superscript ? const FontFeature.superscripts() : const FontFeature.subscripts(),
        ],
      ),
    );
  }
  final size = (style.fontSize ?? 16) * 0.68;
  final small = style.copyWith(fontSize: size, height: 1);
  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: Transform.translate(
      offset: Offset(0, superscript ? -size * 0.55 : size * 0.3),
      child: _nestedMarkup.hasMatch(text)
          ? Text.rich(TextSpan(children: parseQuizMarkup(text, small)))
          : Text(text, style: small),
    ),
  );
}
