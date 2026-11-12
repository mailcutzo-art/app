import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/settings_providers.dart';

/// The app's sound effects: soft, low and short (made by `tool/generate_sounds.py`).
enum Sfx {
  /// A right answer.
  correct,

  /// A wrong answer.
  wrong,

  /// A question ran out of time.
  timeout,

  /// A countdown second (3, 2, 1) before a game.
  tick,

  /// The game starts.
  go,

  /// An opponent was found.
  found,

  /// A battle won, lost or drawn.
  win,
  lose,
  draw,

  /// A practice set finished.
  complete,

  /// Coins, XP or a level-up landed.
  reward;

  String get asset => 'sounds/$name.wav';
}

/// Plays [Sfx] when the user has Sounds on (Settings → Sound and haptics). Never throws: a
/// sound that can't play is simply skipped.
abstract class SoundEffects {
  void play(Sfx sfx);
}

/// Plays through `audioplayers`, one low-latency player per sound, mixed with whatever else is
/// playing (music keeps going) and silent when the phone is on silent.
class AudioSoundEffects implements SoundEffects {
  AudioSoundEffects(this._enabled);

  final bool Function() _enabled;
  final _players = <Sfx, AudioPlayer>{};
  bool _configured = false;

  /// Effects sit under everything else.
  static const volume = 0.6;

  @override
  void play(Sfx sfx) {
    if (!_enabled()) return;
    unawaited(_play(sfx));
  }

  Future<void> _play(Sfx sfx) async {
    try {
      if (!_configured) {
        _configured = true;
        await AudioPlayer.global.setAudioContext(
          AudioContextConfig(
            focus: AudioContextConfigFocus.mixWithOthers,
            respectSilence: true,
          ).build(),
        );
      }
      final player = _players[sfx] ??= await _player();
      await player.stop();
      await player.play(AssetSource(sfx.asset), volume: volume, mode: PlayerMode.lowLatency);
    } on Object catch (error) {
      // No audio output, a missing plugin (tests) or a busy device: carry on silently.
      debugPrint('Sound ${sfx.name} skipped: $error');
    }
  }

  Future<AudioPlayer> _player() async {
    final player = AudioPlayer();
    await player.setReleaseMode(ReleaseMode.stop);
    return player;
  }

  Future<void> dispose() async {
    for (final player in _players.values) {
      await player.dispose();
    }
    _players.clear();
  }
}

/// The app's sound effects. Tests replace it to see what would play.
final soundEffectsProvider = Provider<SoundEffects>((ref) {
  final sounds = AudioSoundEffects(() => ref.read(touchPrefsProvider).sounds);
  ref.onDispose(() => unawaited(sounds.dispose()));
  return sounds;
});

/// Plays [sfx] (when sounds are on).
void playSfx(WidgetRef ref, Sfx sfx) => ref.read(soundEffectsProvider).play(sfx);
