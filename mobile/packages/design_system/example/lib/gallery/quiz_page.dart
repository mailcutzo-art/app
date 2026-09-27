import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../mock_data.dart';
import 'gallery_scaffold.dart';

class QuizPage extends StatefulWidget {
  const QuizPage({super.key});

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  int? _picked;

  AnswerOptionState _stateFor(int i) {
    if (_picked == null) return AnswerOptionState.idle;
    if (i == 1) return AnswerOptionState.correct;
    if (i == _picked) return AnswerOptionState.wrong;
    return AnswerOptionState.dimmed;
  }

  @override
  Widget build(BuildContext context) {
    const answers = ['sp', 'sp^2', 'sp^3', 'dsp^2'];
    return GalleryScaffold(
      title: 'Quiz',
      children: [
        const DemoBlock(
          title: 'Versus header',
          child: VersusHeader(
            me: VersusPlayer(name: 'You', avatar: Mock.me, score: 412, answered: true),
            opponent: VersusPlayer(name: 'Riya', avatar: Mock.riya, score: 390),
            questionNumber: 4,
            total: 7,
          ),
        ),
        const DemoBlock(
          title: 'Countdown',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              CountdownRing(progress: 0.9, label: '14'),
              CountdownRing(progress: 0.45, label: '7'),
              CountdownRing(progress: 0.15, label: '2'),
            ],
          ),
        ),
        const DemoBlock(
          title: 'Question card',
          child: QuestionCard(
            number: 2,
            total: 7,
            tag: 'Chemical Bonding',
            tone: PastelTone.lavender,
            text: 'What is the hybridisation of carbon in C_2H_4 (ethene)?',
          ),
        ),
        DemoBlock(
          title: 'Answers · tap one to reveal',
          child: Column(
            children: [
              for (var i = 0; i < answers.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.md),
                AnswerOption(
                  index: i,
                  text: answers[i],
                  state: _stateFor(i),
                  opponent: _picked != null && i == 1 ? Mock.riya : null,
                  onTap: _picked == null ? () => setState(() => _picked = i) : null,
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: 'Reset',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.small,
                onPressed: () => setState(() => _picked = null),
              ),
            ],
          ),
        ),
        const DemoBlock(
          title: 'Answer states',
          child: Spaced(
            children: [
              AnswerOption(index: 0, text: 'Idle'),
              AnswerOption(
                index: 1,
                text: 'Selected — waiting for reveal',
                state: AnswerOptionState.selected,
              ),
              AnswerOption(
                index: 2,
                text: 'Correct',
                state: AnswerOptionState.correct,
                opponent: Mock.kabir,
              ),
              AnswerOption(index: 3, text: 'Wrong', state: AnswerOptionState.wrong),
            ],
          ),
        ),
        const DemoBlock(
          title: 'Matchmaking pulse',
          child: Center(
            child: SearchingPulse(size: 200, child: AppAvatar(data: Mock.me, size: 72, ring: true)),
          ),
        ),
      ],
    );
  }
}
