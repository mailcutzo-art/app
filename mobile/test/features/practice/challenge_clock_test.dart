import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/practice/challenge_clock.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';

PracticeSession _session({int? timeLimitMs = 600000, DateTime? createdAt}) => PracticeSession(
  sessionId: 's-1',
  title: 'Physics · Self Challenge',
  mode: PracticeMode.challenge,
  feedback: FeedbackTiming.atEnd,
  createdAt: createdAt ?? DateTime.utc(2026, 9, 28, 10),
  timeLimitMs: timeLimitMs,
  questions: const [
    PracticeQuestion(
      ref: 'q1',
      position: 1,
      stem: 'Stem',
      options: [
        PracticeOption(id: 0, text: 'A'),
        PracticeOption(id: 1, text: 'B'),
      ],
      answer: 0,
      explanation: '',
    ),
  ],
);

void main() {
  final start = DateTime.utc(2026, 9, 28, 10);

  test('counts down from created_at + time limit, the server\'s deadline', () {
    final clock = ChallengeClock.of(_session())!;
    expect(clock.deadline, DateTime.utc(2026, 9, 28, 10, 10));
    expect(clock.remaining(start), const Duration(minutes: 10));
    expect(
      clock.remaining(start.add(const Duration(minutes: 3, seconds: 20))),
      const Duration(minutes: 6, seconds: 40),
    );
    expect(clock.fraction(start.add(const Duration(minutes: 5))), 0.5);
  });

  test('time spent away counts: reopening late shows what is really left', () {
    final clock = ChallengeClock.of(_session())!;
    final later = start.add(const Duration(minutes: 9, seconds: 30));
    expect(clock.remaining(later), const Duration(seconds: 30));
    expect(clock.isLow(later), isTrue);
    expect(clock.isOver(later), isFalse);
  });

  test('never negative once over, and never more than the limit', () {
    final clock = ChallengeClock.of(_session())!;
    expect(clock.remaining(start.add(const Duration(hours: 2))), Duration.zero);
    expect(clock.isOver(start.add(const Duration(minutes: 10))), isTrue);
    // A phone clock behind the server's doesn't add time.
    expect(
      clock.remaining(start.subtract(const Duration(minutes: 2))),
      const Duration(minutes: 10),
    );
    expect(clock.isLow(start), isFalse);
  });

  test('only sessions with a total time limit have one', () {
    expect(ChallengeClock.of(_session(timeLimitMs: null)), isNull);
    expect(ChallengeClock.of(_session(timeLimitMs: 0)), isNull);
    final noStart = PracticeSession(
      sessionId: 's',
      title: '',
      timeLimitMs: 300000,
      questions: _session().questions,
    );
    expect(ChallengeClock.of(noStart), isNull);
  });

  test('the countdown reads m:ss, rounding seconds up', () {
    expect(formatCountdown(const Duration(minutes: 10)), '10:00');
    expect(formatCountdown(const Duration(minutes: 9, seconds: 41)), '9:41');
    expect(formatCountdown(const Duration(milliseconds: 59001)), '1:00');
    expect(formatCountdown(const Duration(milliseconds: 400)), '0:01');
    expect(formatCountdown(Duration.zero), '0:00');
    expect(formatCountdown(const Duration(hours: 1)), '1:00:00');
    expect(formatCountdown(const Duration(minutes: 62, seconds: 5)), '1:02:05');
  });

  test('screen readers hear minutes and seconds', () {
    expect(
      countdownSemantics(const Duration(minutes: 9, seconds: 41)),
      '9 minutes 41 seconds left',
    );
    expect(countdownSemantics(const Duration(minutes: 1)), '1 minute left');
    expect(countdownSemantics(const Duration(seconds: 1)), '1 second left');
  });
}
