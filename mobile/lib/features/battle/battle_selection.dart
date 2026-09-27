import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/session.dart';
import '../../core/storage/prefs.dart';
import 'data/battle_models.dart';

/// The Battle tab's choice: what the user picked in this session, and the copy saved on the
/// device from the last one.
class SelectionMemory {
  const SelectionMemory({this.picked, this.saved});

  /// Picked on the tab since the app started. Wins over everything.
  final BattleSelection? picked;

  /// Saved on the device last time; used when the server doesn't remember one.
  final BattleSelection? saved;
}

/// Remembers the subject, chapter and mode per user, on the device.
final battleSelectionProvider = NotifierProvider<BattleSelectionController, SelectionMemory>(
  BattleSelectionController.new,
);

class BattleSelectionController extends Notifier<SelectionMemory> {
  static String key(String userId) => 'battle.last.$userId';

  SharedPreferences? get _prefs {
    try {
      return ref.read(sharedPrefsProvider);
    } on Object {
      return null;
    }
  }

  @override
  SelectionMemory build() {
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return const SelectionMemory();
    final raw = _prefs?.getString(key(userId));
    if (raw == null) return const SelectionMemory();
    try {
      return SelectionMemory(saved: BattleSelection.tryParse(jsonDecode(raw)));
    } on FormatException {
      return const SelectionMemory();
    }
  }

  void pick(BattleSelection selection) {
    state = SelectionMemory(picked: selection, saved: selection);
    final userId = ref.read(currentUserIdProvider);
    if (userId != null) {
      unawaited(_prefs?.setString(key(userId), jsonEncode(selection.toJson())));
    }
  }
}

/// The selection to show: this session's pick, else the server's `last`, else the device's copy,
/// else the first subject with all chapters, rated. Whatever is chosen must still exist: an
/// unknown subject falls back, a chapter that isn't battle-ready becomes "All chapters", and
/// Casual without the coins becomes Rated.
BattleSelection resolveSelection(BattleSetup setup, SelectionMemory memory) {
  final candidates = [memory.picked, setup.last, memory.saved];
  final chosen = candidates.firstWhere(
    (c) => c != null && setup.subject(c.subject) != null,
    orElse: () => null,
  );
  final subject =
      setup.subject(chosen?.subject) ??
      setup.subjects.where((s) => s.anyReady).firstOrNull ??
      setup.subjects.firstOrNull;
  if (subject == null) return const BattleSelection(subject: '');
  final chapter = subject.chapter(chosen?.chapter);
  final mode = chosen?.mode == BattleMode.casual && setup.canAffordCasual
      ? BattleMode.casual
      : BattleMode.rated;
  return BattleSelection(
    subject: subject.slug,
    chapter: chapter != null && chapter.battleReady ? chapter.slug : null,
    mode: mode,
  );
}
