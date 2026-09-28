import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/share/share_models.dart';
import 'package:quiz_app/features/social/data/social_models.dart';

import '../../support/share_samples.dart';

Map<String, Object?> _card(String id, String name) => {
  'id': id,
  'handle': name.toLowerCase(),
  'display_name': name,
  'avatar': {'tone': 'mint', 'symbol': 'dna'},
  'level': 9,
};

void main() {
  group('shared result payload', () {
    final payload = {
      'match_id': 'm-9',
      'mode': 'quick_rated',
      'result': 'win',
      'subject': 'Physics',
      'chapter': 'Kinematics',
      'score': 840,
      'opponent_score': 610,
      'opponent': _card('u-riya', 'Riya'),
      'opponent_name': 'Riya',
      'questions': ['correct', 'wrong', 'skipped', 'correct', 'mystery'],
      'rating_change': 14,
      'coins': 50,
      'xp': 30,
    };

    test('reads every field', () {
      final data = MatchShareData.fromPayload(payload, player: samplePlayer);

      expect(data.matchId, 'm-9');
      expect(data.outcome, ShareOutcome.win);
      expect((data.subject, data.chapter), ('Physics', 'Kinematics'));
      expect((data.score, data.opponentScore), (840, 610));
      expect(data.opponentName, 'Riya');
      expect(data.opponentAvatar, isNotNull);
      expect(data.answers, [
        ShareAnswer.correct,
        ShareAnswer.wrong,
        ShareAnswer.skipped,
        ShareAnswer.correct,
        ShareAnswer.skipped,
      ]);
      expect(data.correct, 2);
      expect((data.ratingChange, data.coins, data.xp), (14, 50, 30));
      expect(data.target, const MatchShareTarget('m-9'));
      expect(data.target.toJson(), {'kind': 'match_result', 'match_id': 'm-9'});
    });

    test('a bot or hidden opponent and an unsettled match', () {
      final data = MatchShareData.fromPayload({
        ...payload,
        'result': 'draw',
        'chapter': null,
        'opponent': null,
        'opponent_name': 'Another player',
        'rating_change': null,
        'coins': null,
        'xp': null,
      }, player: samplePlayer);

      expect(data.outcome, ShareOutcome.draw);
      expect(data.chapter, isNull);
      expect(data.opponentName, 'Another player');
      expect(data.opponentAvatar, isNull);
      expect((data.ratingChange, data.coins, data.xp), (null, null, null));
    });

    test('an unknown result or a missing score is unreadable', () {
      expect(
        () => MatchShareData.fromPayload({...payload, 'result': 'aborted'}, player: samplePlayer),
        throwsFormatException,
      );
      expect(
        () => MatchShareData.fromPayload({...payload}..remove('score'), player: samplePlayer),
        throwsFormatException,
      );
    });
  });

  group('shared progress payload', () {
    test('reads every field; accuracy is a whole percent', () {
      final data = ProgressShareData.fromPayload(const {
        'level': 12,
        'xp': 3480,
        'xp_into_level': 180,
        'xp_for_level': 700,
        'streak': {'current': 7, 'best': 15},
        'answered': 1240,
        'correct': 893,
        'accuracy': 72,
        'ratings': [
          {'scope': 'neet:physics', 'rating': 1524},
          {'scope': 'bad'},
        ],
      }, player: samplePlayer);

      expect(data.level, 12);
      expect((data.xpIntoLevel, data.xpForLevel), (180, 700));
      expect(data.levelProgress, closeTo(180 / 700, 1e-9));
      expect((data.currentStreak, data.bestStreak), (7, 15));
      expect(data.answered, 1240);
      expect(data.accuracyLabel, '72%');
      expect(data.ratings.single.label, 'Physics');
      expect(data.ratings.single.rating, '1524');
      expect(data.target.toJson(), {'kind': 'progress'});
    });

    test('before the first answer accuracy is unknown', () {
      final data = ProgressShareData.fromPayload(const {
        'level': 1,
        'accuracy': null,
      }, player: samplePlayer);

      expect(data.accuracyLabel, '—');
      expect(data.ratings, isEmpty);
      expect(data.levelProgress, 1, reason: 'no span to the next level: the top level');
    });

    test('a level is required', () {
      expect(
        () => ProgressShareData.fromPayload(const {'answered': 3}, player: samplePlayer),
        throwsFormatException,
      );
    });
  });

  group('captions', () {
    test('say what happened, with a link only when one is configured', () {
      expect(sampleWin.caption, 'I won a Physics battle on Quiz Arena! 🏆');
      expect(sampleProgress.caption, 'Level 12 on Quiz Arena with a 7-day streak! 📈');
      expect(sampleWin.captionWithLink(''), sampleWin.caption);
      expect(
        sampleWin.captionWithLink('https://quizarena.app/'),
        'I won a Physics battle on Quiz Arena! 🏆 https://quizarena.app',
      );
    });

    test('describe the card for screen readers', () {
      expect(sampleWin.semanticLabel, contains('Victory! Physics battle'));
      expect(sampleWin.semanticLabel, contains('Asha 840, Riya 610'));
      expect(sampleWin.semanticLabel, contains('Rating +14'));
      expect(sampleProgress.semanticLabel, contains('level 12'));
    });
  });

  group('activity items', () {
    Map<String, Object?> item(String kind, Object? payload) => {
      'id': 'a-1',
      'user': _card('u-meera', 'Meera'),
      'kind': kind,
      'payload': payload,
      'created_at': '2026-09-28T10:00:00Z',
    };

    test('shared results and progress carry their cards, by the sharer', () {
      final result = ActivityItem.fromJson(
        item('shared_result', {
          'match_id': 'm-1',
          'mode': 'bot',
          'result': 'win',
          'subject': 'Biology',
          'chapter': null,
          'score': 700,
          'opponent_score': 400,
          'opponent': null,
          'opponent_name': 'Practice Bot',
          'questions': ['correct'],
          'rating_change': null,
          'coins': null,
          'xp': 15,
        }),
      );
      final progress = ActivityItem.fromJson(
        item('shared_progress', {
          'level': 9,
          'streak': {'current': 3, 'best': 4},
        }),
      );

      expect(result.kind, ActivityKind.sharedResult);
      expect(result.text, 'shared a win');
      final match = result.share! as MatchShareData;
      expect(match.player.displayName, 'Meera');
      expect(match.player.at, '@meera');
      expect(match.opponentName, 'Practice Bot');
      expect(progress.kind, ActivityKind.sharedProgress);
      expect(progress.text, 'shared their progress');
      expect((progress.share! as ProgressShareData).level, 9);
    });

    test('other kinds read their payload and have no card', () {
      final podium = ActivityItem.fromJson(
        item('podium', {'tournament_id': 't', 'name': 'Sunday Cup', 'rank': 2}),
      );
      expect(podium.text, 'finished #2 in Sunday Cup');
      expect(podium.share, isNull);
    });

    test('a share the app can\'t read is left out of the feed', () {
      final page = CursorPage.fromJson({
        'items': [
          item('shared_result', {'result': 'win'}),
          item('level_up', {'level': 5}),
        ],
        'next_cursor': null,
      }, ActivityItem.fromJson);

      expect(page.items.single.kind, ActivityKind.levelUp);
    });
  });
}
