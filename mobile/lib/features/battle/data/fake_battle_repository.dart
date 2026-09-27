import '../../../core/auth/user.dart';
import '../../../core/network/app_failure.dart';
import '../../learn/data/learn_models.dart' show ChapterLabel;
import 'battle_models.dart';
import 'battle_repository.dart';

/// In-memory stand-in for `GET /v1/battle/setup`, used by tests and the demo.
class FakeBattleRepository implements BattleRepository {
  FakeBattleRepository({BattleSetup Function(Goal goal)? setup, this.latency = Duration.zero})
    : _setup = setup ?? sampleBattleSetup;

  final BattleSetup Function(Goal goal) _setup;

  /// Delay before every response, to see loading states.
  Duration latency;

  /// When set, [setup] throws it until cleared.
  AppFailure? failure;

  /// Goals passed to [setup], in order.
  final List<Goal> calls = [];

  @override
  Future<BattleSetup> setup(Goal goal) async {
    calls.add(goal);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failure case final failure?) throw failure;
    return _setup(goal);
  }
}

const _kinematics = BattleChapter(
  slug: 'kinematics',
  name: 'Motion in a Straight Line',
  battleReady: true,
  questionCount: 48,
  label: ChapterLabel.needsWork,
);

const _lawsOfMotion = BattleChapter(
  slug: 'laws-of-motion',
  name: 'Laws of Motion',
  battleReady: true,
  questionCount: 36,
  label: ChapterLabel.strong,
);

const _workEnergy = BattleChapter(
  slug: 'work-energy-power',
  name: 'Work, Energy and Power',
  questionCount: 4,
);

/// The Physics, Chemistry and Biology (NEET) or Maths (JEE) setup the demo starts from.
BattleSetup sampleBattleSetup(
  Goal goal, {
  RatingInfo physicsRating = const RatingInfo(display: '1502?', value: 1502, provisional: true),
  int coins = 245,
  bool firstSearch = true,
  BattleSelection? last,
  DateTime? cooldownUntil,
  BattleActive? active,
}) => BattleSetup(
  subjects: [
    BattleSubject(
      slug: 'physics',
      name: 'Physics',
      tone: 'sky',
      rating: physicsRating,
      chapters: const [_kinematics, _lawsOfMotion, _workEnergy],
    ),
    const BattleSubject(
      slug: 'chemistry',
      name: 'Chemistry',
      tone: 'mint',
      chapters: [
        BattleChapter(
          slug: 'mole-concept',
          name: 'Some Basic Concepts of Chemistry',
          battleReady: true,
          questionCount: 30,
        ),
        BattleChapter(slug: 'atomic-structure', name: 'Structure of Atom', questionCount: 3),
      ],
    ),
    if (goal == Goal.neet)
      const BattleSubject(
        slug: 'biology',
        name: 'Biology',
        tone: 'peach',
        chapters: [
          BattleChapter(
            slug: 'cell',
            name: 'Cell: The Unit of Life',
            battleReady: true,
            questionCount: 40,
          ),
        ],
      )
    else
      const BattleSubject(
        slug: 'maths',
        name: 'Maths',
        tone: 'lavender',
        chapters: [
          BattleChapter(
            slug: 'quadratic-equations',
            name: 'Quadratic Equations',
            battleReady: true,
            questionCount: 32,
          ),
        ],
      ),
  ],
  coins: coins,
  cooldownUntil: cooldownUntil,
  active: active,
  last: last,
  online: const {
    'physics': OnlineStat(searching: 3, p50WaitS: 20),
    'chemistry': OnlineStat(searching: 2, p50WaitS: 25),
    'biology': OnlineStat(searching: 4, p50WaitS: 15),
    'maths': OnlineStat(searching: 1, p50WaitS: 40),
  },
  firstSearch: firstSearch,
  leaders: const {
    'physics': SubjectLeaders(leaderName: 'Riya', myPosition: 12),
    'chemistry': SubjectLeaders(leaderName: 'Kabir'),
  },
);
