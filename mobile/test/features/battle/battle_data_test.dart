import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/battle/battle_selection.dart';
import 'package:quiz_app/features/battle/chapter_picker.dart';
import 'package:quiz_app/features/battle/data/battle_models.dart';
import 'package:quiz_app/features/battle/data/battle_repository.dart';
import 'package:quiz_app/features/battle/data/fake_battle_repository.dart';
import 'package:quiz_app/features/battle/data/match_models.dart';
import 'package:quiz_app/features/learn/data/learn_models.dart' show ChapterLabel;
import 'package:realtime_client/realtime_client.dart';

import '../../support/fakes.dart';

/// The `GET /v1/battle/setup` sample from docs/api-play.md.
Map<String, Object?> setupJson() => {
  'subjects': [
    {
      'slug': 'physics',
      'name': 'Physics',
      'tone': 'sky',
      'rating': {'display': '—', 'value': null, 'provisional': true},
      'chapters': [
        {
          'slug': 'kinematics',
          'name': 'Motion in a Straight Line',
          'battle_ready': true,
          'question_count': 8,
          'label': 'needs_work',
        },
      ],
    },
  ],
  'coins': 245,
  'casual_fee': 5,
  'cooldown_until': null,
  'active': null,
  'last': {'subject': 'physics', 'chapter': null, 'mode': 'rated'},
  'online': {
    'physics': {'searching': 3, 'p50_wait_s': 20},
  },
  'first_search': true,
  'leaders': {
    'physics': {
      'leader': {
        'position': 1,
        'user': {'id': 'riya-id', 'display_name': 'Riya'},
        'value': 212,
      },
      'me': {'position': 12},
    },
  },
};

/// The `GET /v1/matches/{id}` shape from docs/api-play.md, settled.
Map<String, Object?> matchJson({bool settled = true}) => {
  'id': 'm1',
  'kind': 'quick_rated',
  'subject': 'physics',
  'chapters': ['Motion in a Straight Line'],
  'played_at': '2026-09-27T16:00:00Z',
  'result': 'win',
  'reason': 'normal',
  'score': {'me': 612, 'best_other': 480},
  'opponents': [
    {
      'id': 'riya',
      'handle': 'riya_s',
      'display_name': 'Riya',
      'avatar': {'tone': 'rose', 'symbol': 'dna'},
      'level': 6,
    },
  ],
  'rating_delta': 16,
  'coins_delta': 10,
  'status': settled ? 'settled' : 'settling',
  'totals': {
    'u1': {'points': 612, 'correct': 5},
    'riya': {'points': 480, 'correct': 4},
  },
  'settlement': settled
      ? {
          'match_id': 'm1',
          'rating': {'scope': 'physics', 'before': '1502?', 'after': '1518?', 'delta': 16},
          'rank': {'board': 'rating:physics', 'before': 47, 'after': 42},
          'coins': {'delta': 10, 'balance': 255, 'capped': false},
          'xp': {'delta': 30, 'level': 4, 'into_level': 150, 'for_next': 250},
        }
      : null,
};

Map<String, Object?> reviewJson() => {
  'questions': [
    {
      'q': 2,
      'ref': 'phy-kin-003',
      'stem': 'What does the slope of a position–time graph give?',
      'options': [
        {'id': 'aa', 'text': 'Velocity'},
        {'id': 'bb', 'text': 'Acceleration'},
      ],
      'correct': 'aa',
      'explanation': 'The slope is the rate of change of position.',
      'chapter': 'Motion in a Straight Line',
      'topic': 'Speed and velocity',
      'players': {
        'u1': {'opt': 'aa', 'correct': true, 'pts': 138, 'time_ms': 2400, 'speed': 'fast'},
        'riya': {'opt': 'bb', 'correct': false, 'pts': 0, 'time_ms': 6100, 'speed': 'slow'},
      },
      'bookmarked': true,
    },
    {
      'q': 1,
      'ref': 'phy-kin-001',
      'stem': 'Q1',
      'options': [
        {'id': 'x', 'text': 'Zero'},
      ],
      'correct': 'x',
    },
  ],
};

void main() {
  group('BattleSetup', () {
    test('reads the documented sample', () {
      final setup = BattleSetup.fromJson(setupJson(), myId: 'u1');
      final physics = setup.subject('physics')!;
      expect(physics.name, 'Physics');
      expect(physics.rating.display, '—');
      expect(physics.rating.isNew, isTrue);
      final chapter = physics.chapter('kinematics')!;
      expect(chapter.battleReady, isTrue);
      expect(chapter.questionCount, 8);
      expect(chapter.label, ChapterLabel.needsWork);
      expect(setup.coins, 245);
      expect(setup.casualFee, 5);
      expect(setup.canAffordCasual, isTrue);
      expect(setup.last, const BattleSelection(subject: 'physics'));
      expect(setup.online['physics']!.searching, 3);
      expect(setup.online['physics']!.p50WaitS, 20);
      expect(setup.firstSearch, isTrue);
      expect(setup.leaders['physics']!.leaderName, 'Riya');
      expect(setup.leaders['physics']!.myPosition, 12);
      expect(setup.leaders['physics']!.leaderIsMe, isFalse);
    });

    test('is lenient: defaults for missing fields, unreadable items skipped', () {
      final setup = BattleSetup.fromJson(const {
        'subjects': [
          {
            'slug': 'chemistry',
            'name': 'Chemistry',
            'rating': {'display': '1523?', 'value': 1523, 'provisional': true},
            'chapters': [
              {'slug': 'mole', 'name': 'Mole concept', 'battle_ready': true},
              {'name': 'no slug'},
              'junk',
            ],
          },
          {'name': 'no slug'},
        ],
        'coins': '3',
        'cooldown_until': '2026-09-27T16:04:32Z',
        'active': {
          'kind': 'match',
          'id': 'm7',
          'title': 'Quick battle',
          'action': {'route': '/x'},
        },
        'last': {'subject': 'chemistry', 'mode': 'bot'},
        'online': {
          'chemistry': {'searching': 'many'},
        },
      });
      expect(setup.subjects.map((s) => s.slug), ['chemistry']);
      expect(setup.subjects.single.chapters.map((c) => c.slug), ['mole']);
      expect(setup.subjects.single.rating.display, '1523?');
      expect(setup.coins, 3);
      expect(setup.canAffordCasual, isFalse);
      expect(setup.cooldownUntil, DateTime.utc(2026, 9, 27, 16, 4, 32));
      expect(setup.active?.kind, 'match');
      expect(setup.active?.route, '/x');
      expect(setup.last?.mode, BattleMode.rated, reason: 'the bot is never the remembered mode');
      expect(setup.online, isEmpty);
      expect(setup.casualFee, 5);
      expect(setup.firstSearch, isFalse);
    });

    test('a payload without subjects is not a setup', () {
      expect(() => BattleSetup.fromJson(const {'coins': 3}), throwsFormatException);
    });

    test('recognises the signed-in user as the leader', () {
      final setup = BattleSetup.fromJson(setupJson(), myId: 'riya-id');
      expect(setup.leaders['physics']!.leaderIsMe, isTrue);
    });
  });

  group('MatchSummary and MatchReview', () {
    test('read the result, the totals and the settlement', () {
      final summary = MatchSummary.fromJson(matchJson());
      expect(summary.status, MatchStatus.settled);
      expect(summary.isOver, isTrue);
      expect(summary.opponents.single.displayName, 'Riya');
      expect(summary.settlement?.rating?.delta, 16);
      expect(summary.settlement?.rank, isA<RankMoved>());
      final outcome = summary.outcome(me: 'u1')!;
      expect(outcome.result, MatchResult.win);
      expect(outcome.reason, MatchEndReason.normal);
      expect(outcome.totals['u1']!.points, 612);
    });

    test('a match still settling has no settlement yet', () {
      final summary = MatchSummary.fromJson(matchJson(settled: false));
      expect(summary.status, MatchStatus.settling);
      expect(summary.settlement, isNull);
      expect(summary.isOver, isTrue);
    });

    test('aborted and voided map to their end reasons; totals fall back to the score', () {
      final json = matchJson()
        ..['result'] = 'aborted'
        ..['reason'] = null
        ..['status'] = 'aborted'
        ..['totals'] = null;
      final outcome = MatchSummary.fromJson(json).outcome(me: 'u1')!;
      expect(outcome.reason, MatchEndReason.aborted);
      expect(outcome.totals['u1']!.points, 612);
      expect(outcome.totals['riya']!.points, 480);
    });

    test('a live match has no outcome yet', () {
      final json = matchJson()..['status'] = 'live';
      expect(MatchSummary.fromJson(json).outcome(me: 'u1'), isNull);
    });

    test('the review is read in question order', () {
      final review = MatchReview.fromJson(reviewJson());
      expect(review.questions.map((q) => q.q), [1, 2]);
      final second = review.questions.last;
      expect(second.correct, 'aa');
      expect(second.bookmarked, isTrue);
      expect(second.players['u1']!.speed, Speed.fast);
      expect(second.players['riya']!.opt, 'bb');
      expect(review.questions.first.explanation, isEmpty);
    });

    test('an unreadable settlement is ignored, not fatal', () {
      expect(parseSettlement({'rating': 'nope'}), isNull);
      expect(parseSettlement(null), isNull);
    });
  });

  group('repositories', () {
    (ApiClient, FakeAdapter) api(Object? Function(RequestOptions options) respond) {
      final adapter = FakeAdapter((options) async {
        final body = respond(options);
        return body is ResponseBody ? body : jsonBody(body);
      });
      return (
        ApiClient(Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter),
        adapter,
      );
    }

    test('battle setup is GET /v1/battle/setup?goal=', () async {
      final (client, adapter) = api((_) => setupJson());
      final setup = await ApiBattleRepository(client, myId: 'u1').setup(Goal.jee);
      expect(setup.subjects, hasLength(1));
      final request = adapter.requests.single;
      expect(request.path, '/v1/battle/setup');
      expect(request.queryParameters, {'goal': 'jee'});
    });

    test('an unreadable setup is a generic failure', () async {
      final (client, _) = api((_) => {'nope': true});
      await expectLater(
        ApiBattleRepository(client).setup(Goal.neet),
        throwsA(isA<UnexpectedFailure>()),
      );
    });

    test('match results and reviews come from /v1/matches/{id}', () async {
      final (client, adapter) = api(
        (options) => options.path.endsWith('/review') ? reviewJson() : matchJson(),
      );
      final repository = ApiMatchRepository(client);
      expect((await repository.match('m 1')).id, 'm1');
      expect((await repository.review('m 1')).questions, hasLength(2));
      expect(adapter.requests.map((r) => r.path), [
        '/v1/matches/m%201',
        '/v1/matches/m%201/review',
      ]);
    });

    test('a missing match is a not-found failure', () async {
      final (client, _) = api(
        (_) => jsonBody({
          'error': {'code': 'NOT_FOUND', 'message': 'No such match.'},
        }, status: 404),
      );
      await expectLater(ApiMatchRepository(client).match('x'), throwsA(isA<NotFoundFailure>()));
    });

    test('the fake serves the sample setup and can fail', () async {
      final fake = FakeBattleRepository();
      expect((await fake.setup(Goal.neet)).subject('biology'), isNotNull);
      expect((await fake.setup(Goal.jee)).subject('maths'), isNotNull);
      fake.failure = const NetworkFailure();
      await expectLater(fake.setup(Goal.neet), throwsA(isA<NetworkFailure>()));
      expect(fake.calls, [Goal.neet, Goal.jee, Goal.neet]);
    });
  });

  group('resolveSelection', () {
    final setup = sampleBattleSetup(
      Goal.neet,
      last: const BattleSelection(subject: 'biology', chapter: 'cell', mode: BattleMode.casual),
    );

    test('this session\'s pick wins, then the server\'s last, then the device\'s copy', () {
      const picked = BattleSelection(subject: 'chemistry', chapter: 'mole-concept');
      const saved = BattleSelection(subject: 'physics', chapter: 'kinematics');
      expect(resolveSelection(setup, const SelectionMemory(picked: picked, saved: saved)), picked);
      expect(
        resolveSelection(setup, const SelectionMemory(saved: saved)),
        const BattleSelection(subject: 'biology', chapter: 'cell', mode: BattleMode.casual),
      );
      final noLast = sampleBattleSetup(Goal.neet);
      expect(resolveSelection(noLast, const SelectionMemory(saved: saved)), saved);
    });

    test('defaults to the first subject, all chapters, rated', () {
      expect(
        resolveSelection(sampleBattleSetup(Goal.neet), const SelectionMemory()),
        const BattleSelection(subject: 'physics'),
      );
    });

    test('an unknown subject falls back; a chapter that isn\'t ready means all chapters', () {
      final jee = sampleBattleSetup(Goal.jee);
      expect(
        resolveSelection(
          jee,
          const SelectionMemory(
            picked: BattleSelection(subject: 'biology', chapter: 'cell'),
          ),
        ).subject,
        'physics',
      );
      expect(
        resolveSelection(
          jee,
          const SelectionMemory(
            picked: BattleSelection(subject: 'physics', chapter: 'work-energy-power'),
          ),
        ).chapter,
        isNull,
      );
    });

    test('Casual without the coins becomes Rated', () {
      final poor = sampleBattleSetup(Goal.neet, coins: 3);
      expect(
        resolveSelection(
          poor,
          const SelectionMemory(
            picked: BattleSelection(subject: 'physics', mode: BattleMode.casual),
          ),
        ).mode,
        BattleMode.rated,
      );
    });
  });

  test('chapter subtitles carry the count and the Strong/Needs work word', () {
    const ready = BattleChapter(
      slug: 'k',
      name: 'K',
      battleReady: true,
      questionCount: 48,
      label: ChapterLabel.needsWork,
    );
    expect(chapterSubtitle(ready), '48 questions · Needs work');
    expect(
      chapterSubtitle(const BattleChapter(slug: 'w', name: 'W', questionCount: 4)),
      'Coming soon',
    );
  });
}
