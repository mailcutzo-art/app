import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden in `bootstrap()`.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw StateError('SharedPreferences not provided'),
);
