/// Reads one decoded JSON object for hand-written model parsing.
///
/// Unknown keys are ignored. A required key that is missing, or any key with
/// the wrong type, throws a [FormatException] naming the payload and the key,
/// e.g. `practice question: "stem" must be a string`.
final class JsonReader {
  JsonReader(Object? json, this.what)
    : _map = switch (json) {
        final Map<Object?, Object?> map => map,
        _ => throw FormatException('$what: expected a JSON object'),
      };

  /// What is being parsed, for error messages.
  final String what;
  final Map<Object?, Object?> _map;

  /// The raw value, for fields with their own lenient parsing.
  Object? operator [](String key) => _map[key];

  bool has(String key) => _map[key] != null;

  String string(String key) => switch (_map[key]) {
    final String value => value,
    _ => throw _invalid(key, 'a string'),
  };

  String? optString(String key) => switch (_map[key]) {
    null => null,
    final String value => value,
    _ => throw _invalid(key, 'a string or null'),
  };

  int integer(String key) => _int(key, _map[key]) ?? (throw _invalid(key, 'an integer'));

  int? optInt(String key) => _int(key, _map[key]);

  bool boolean(String key) => switch (_map[key]) {
    final bool value => value,
    _ => throw _invalid(key, 'a boolean'),
  };

  /// A boolean that defaults to [fallback] when absent.
  bool flag(String key, {bool fallback = false}) => switch (_map[key]) {
    null => fallback,
    final bool value => value,
    _ => throw _invalid(key, 'a boolean'),
  };

  DateTime dateTime(String key) => switch (_map[key]) {
    final String value when DateTime.tryParse(value) != null => DateTime.parse(value),
    _ => throw _invalid(key, 'an ISO 8601 time'),
  };

  /// A required list whose items are parsed by [item].
  List<T> list<T>(String key, T Function(Object? json) item) => switch (_map[key]) {
    final List<Object?> values => List.unmodifiable(values.map(item)),
    _ => throw _invalid(key, 'a list'),
  };

  /// A list that defaults to empty when absent.
  List<T> optList<T>(String key, T Function(Object? json) item) =>
      _map[key] == null ? List<T>.unmodifiable(const []) : list(key, item);

  /// A nested object parsed by [parse].
  T object<T>(String key, T Function(Object? json) parse) =>
      _map[key] == null ? throw _invalid(key, 'an object') : parse(_map[key]);

  /// A nested object that may be absent or null.
  T? optObject<T>(String key, T Function(Object? json) parse) =>
      _map[key] == null ? null : parse(_map[key]);

  /// String values of a flat object. Numbers and booleans are converted, so
  /// `{"count": 10}` and `{"count": "10"}` read the same.
  Map<String, String> stringMap(String key) => switch (_map[key]) {
    null => const {},
    final Map<Object?, Object?> map => Map.unmodifiable({
      for (final MapEntry(:key, :value) in map.entries)
        if (key is String && (value is String || value is num || value is bool)) key: '$value',
    }),
    _ => throw _invalid(key, 'an object'),
  };

  int? _int(String key, Object? value) => switch (value) {
    null => null,
    final int v => v,
    final double v when v == v.truncateToDouble() && v.isFinite => v.toInt(),
    _ => throw _invalid(key, 'an integer'),
  };

  FormatException _invalid(String key, String expected) =>
      FormatException('$what: "$key" must be $expected');
}
