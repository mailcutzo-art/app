/// Room codes: 6 characters of Crockford base32 (`0-9` and `A-Z` without `I`, `L`, `O`, `U`),
/// for example `K7M2QX` (docs/plan.md, Play with Friend).
abstract final class RoomCode {
  static const length = 6;

  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// What someone typed or pasted, as a code: upper case, without spaces or dashes, with the
  /// look-alikes Crockford allows (`I`/`L` → `1`, `O` → `0`). A link (`…/j/K7M2QX`) gives its
  /// code. Returns `null` unless exactly [length] valid characters remain.
  static String? normalize(String input) {
    var text = input.trim();
    final link = RegExp(r'/j/([A-Za-z0-9-]+)').firstMatch(text);
    if (link != null) text = link.group(1)!;
    final buffer = StringBuffer();
    for (final rune in text.toUpperCase().runes) {
      final char = String.fromCharCode(rune);
      if (char == ' ' || char == '-') continue;
      final mapped = switch (char) {
        'I' || 'L' => '1',
        'O' => '0',
        _ => char,
      };
      if (!_alphabet.contains(mapped)) return null;
      buffer.write(mapped);
    }
    final code = buffer.toString();
    return code.length == length ? code : null;
  }

  /// `K7M 2QX`, easier to read aloud.
  static String spaced(String code) =>
      code.length == length ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
}
