/// Typed, validating readers over decoded JSON. Internal to the package.
library;

/// A decoded JSON object with typed accessors.
///
/// Required accessors throw a [FormatException] naming [context] and the key when the value is
/// missing, `null` or of the wrong type. Optional accessors return `null` for a missing or `null`
/// value, but still throw when the value has the wrong type. Unknown keys are ignored.
final class JsonObject {
  const JsonObject(this.map, this.context);

  /// Wraps [value], which must be a JSON object.
  factory JsonObject.from(Object? value, String context) {
    if (value is Map<String, Object?>) return JsonObject(value, context);
    throw FormatException('$context: expected a JSON object, got ${_describe(value)}');
  }

  final Map<String, Object?> map;

  /// Names the message being read, for error messages (for example `q.show`).
  final String context;

  bool has(String key) => map[key] != null;

  String string(String key) => _required(key, optString(key));

  String? optString(String key) {
    final value = map[key];
    if (value == null || value is String) return value as String?;
    throw _wrongType(key, 'a string', value);
  }

  int integer(String key) => _required(key, optInt(key));

  int? optInt(String key) {
    final value = map[key];
    if (value == null) return null;
    final parsed = asInt(value);
    if (parsed == null) throw _wrongType(key, 'an integer', value);
    return parsed;
  }

  /// Any JSON number (tournament points can be fractional).
  num? optNum(String key) {
    final value = map[key];
    if (value == null || value is num) return value as num?;
    throw _wrongType(key, 'a number', value);
  }

  /// A server time in Unix ms. An ISO 8601 string (the REST convention) is accepted too.
  int? optTimestamp(String key) {
    final value = map[key];
    if (value == null) return null;
    final ms = asInt(value);
    if (ms != null) return ms;
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.millisecondsSinceEpoch;
    }
    throw _wrongType(key, 'a timestamp', value);
  }

  bool boolean(String key) => _required(key, optBool(key));

  bool? optBool(String key) {
    final value = map[key];
    if (value == null || value is bool) return value as bool?;
    throw _wrongType(key, 'a boolean', value);
  }

  JsonObject object(String key) => _required(key, optObject(key));

  JsonObject? optObject(String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is Map<String, Object?>) return JsonObject(value, '$context.$key');
    throw _wrongType(key, 'an object', value);
  }

  List<Object?> list(String key) => _required(key, optList(key));

  List<Object?>? optList(String key) {
    final value = map[key];
    if (value == null || value is List<Object?>) return value as List<Object?>?;
    throw _wrongType(key, 'a list', value);
  }

  /// A list of JSON objects, each parsed with [parse].
  List<T> objects<T>(String key, T Function(JsonObject item) parse) =>
      _required(key, optObjects(key, parse));

  List<T>? optObjects<T>(String key, T Function(JsonObject item) parse) {
    final items = optList(key);
    if (items == null) return null;
    return List.unmodifiable([
      for (final (index, item) in items.indexed)
        parse(JsonObject.from(item, '$context.$key[$index]')),
    ]);
  }

  /// A list of strings.
  List<String> strings(String key) => _required(key, optStrings(key));

  List<String>? optStrings(String key) {
    final items = optList(key);
    if (items == null) return null;
    return List.unmodifiable([
      for (final item in items)
        if (item is String) item else throw _wrongType(key, 'a list of strings', items),
    ]);
  }

  /// An object whose values are all objects, parsed with [parse] and keyed like the source.
  Map<String, T> objectMap<T>(String key, T Function(JsonObject item) parse) =>
      _required(key, optObjectMap(key, parse));

  Map<String, T>? optObjectMap<T>(String key, T Function(JsonObject item) parse) {
    final source = optObject(key);
    if (source == null) return null;
    return Map.unmodifiable({
      for (final MapEntry(key: name, :value) in source.map.entries)
        name: parse(JsonObject.from(value, '${source.context}.$name')),
    });
  }

  T _required<T>(String key, T? value) {
    if (value == null) throw FormatException('$context: missing required field "$key"');
    return value;
  }

  FormatException _wrongType(String key, String expected, Object? value) =>
      FormatException('$context: "$key" must be $expected, got ${_describe(value)}');
}

/// Reads a JSON number as an integer. Accepts doubles with an integral value (`41.0`).
int? asInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) return value.toInt();
  return null;
}

String _describe(Object? value) => switch (value) {
  null => 'null',
  String() => 'a string',
  bool() => 'a boolean',
  num() => 'a number',
  List<Object?>() => 'a list',
  Map<Object?, Object?>() => 'an object',
  _ => 'an unsupported value',
};
