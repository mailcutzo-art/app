import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/features/share/share_models.dart';
import 'package:quiz_app/features/share/share_providers.dart';

const samplePlayer = SharePlayer(
  displayName: 'Asha',
  handle: 'asha_k',
  avatar: Avatar(tone: 'sky', symbol: 'atom'),
);

const sampleWin = MatchShareData(
  player: samplePlayer,
  matchId: 'm-1',
  outcome: ShareOutcome.win,
  subject: 'Physics',
  chapter: 'Kinematics',
  score: 840,
  opponentScore: 610,
  opponentName: 'Riya',
  answers: [
    ShareAnswer.correct,
    ShareAnswer.correct,
    ShareAnswer.wrong,
    ShareAnswer.correct,
    ShareAnswer.skipped,
    ShareAnswer.correct,
    ShareAnswer.correct,
  ],
  ratingChange: 14,
  coins: 50,
  xp: 30,
);

const sampleProgress = ProgressShareData(
  player: samplePlayer,
  level: 12,
  xpIntoLevel: 180,
  xpForLevel: 700,
  ratings: [
    ShareRating(label: 'Physics', rating: '1524'),
    ShareRating(label: 'Chemistry', rating: '1480?'),
  ],
  accuracy: 0.72,
  answered: 1240,
  currentStreak: 7,
  bestStreak: 15,
);

/// Stands in for the image capture and the system share sheet, and remembers what they got.
class ShareRecorder {
  final captured = <ShareCardData>[];
  final shared = <({Uint8List image, String text})>[];

  /// Thrown by the capture when set.
  Error? captureError;

  static final image = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);

  List<Override> get overrides => [
    captureShareCardProvider.overrideWithValue((context, data) async {
      if (captureError case final error?) throw error;
      captured.add(data);
      return image;
    }),
    shareToAppsProvider.overrideWithValue(({required image, required text, origin}) async {
      shared.add((image: image, text: text));
    }),
  ];
}
