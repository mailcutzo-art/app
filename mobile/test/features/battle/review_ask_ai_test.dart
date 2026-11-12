import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/battle/data/match_models.dart';
import 'package:quiz_app/features/battle/match/review_screen.dart';
import 'package:quiz_app/features/practice/ask_ai.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';
import 'package:realtime_client/realtime_client.dart';

const _question = ReviewQuestion(
  q: 3,
  ref: 'q_3',
  stem: 'Which is a vector?',
  options: [
    ReviewOption(id: 'aa111', text: 'Speed'),
    ReviewOption(id: 'bb222', text: 'Velocity'),
    ReviewOption(id: 'cc333', text: 'Mass'),
    ReviewOption(id: 'dd444', text: 'Time'),
  ],
  correct: 'bb222',
  chapter: 'Motion in a Straight Line',
);

void main() {
  test('a wrong pick becomes a prompt with the student\'s answer', () {
    final input = askAiInput(_question, const PlayerReveal(opt: 'cc333', correct: false, pts: 0));
    expect(input.outcome, AnswerOutcome.wrong);
    final prompt = buildAskAiPrompt(input.question, outcome: input.outcome, picked: input.picked);
    expect(prompt, contains('Correct answer: B) Velocity'));
    expect(prompt, contains('My answer: C) Mass'));
    expect(prompt, contains('Topic: Motion in a Straight Line'));
  });

  test('no answer reads as out of time; a right one as correct', () {
    expect(askAiInput(_question, null).outcome, AnswerOutcome.timeout);
    expect(
      askAiInput(_question, const PlayerReveal(opt: null, correct: false, pts: 0)).outcome,
      AnswerOutcome.timeout,
    );
    expect(
      askAiInput(_question, const PlayerReveal(opt: 'bb222', correct: true, pts: 140)).outcome,
      AnswerOutcome.correct,
    );
  });
}
