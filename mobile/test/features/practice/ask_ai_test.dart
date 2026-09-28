import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/features/practice/ask_ai.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';
import 'package:url_launcher/url_launcher.dart';

const _question = PracticeQuestion(
  ref: 'q_1',
  position: 1,
  stem: 'The unit of **force** is *equivalent* to kg m s^{-2}. Which is it?',
  options: [
    PracticeOption(id: 2, text: 'Joule'),
    PracticeOption(id: 0, text: 'Newton'),
    PracticeOption(id: 1, text: 'Watt'),
    PracticeOption(id: 3, text: 'Pascal'),
  ],
  answer: 0,
  explanation: '',
  chapter: NamedRef(slug: 'laws-of-motion', name: 'Laws of Motion'),
  topic: NamedRef(slug: 'newtons-laws', name: "Newton's laws"),
);

/// Records every open; answers true for the first opens whose index is in [handled].
class _Opener {
  _Opener(this.handled);

  final Set<int> handled;
  final opened = <(Uri, LaunchMode)>[];

  Future<bool> call(Uri uri, LaunchMode mode) async {
    opened.add((uri, mode));
    return handled.contains(opened.length - 1);
  }
}

void main() {
  group('buildAskAiPrompt', () {
    test('has the question, lettered options in screen order, the answer and the ask', () {
      final prompt = buildAskAiPrompt(_question, goal: Goal.neet);

      expect(prompt, contains('preparing for NEET'));
      expect(prompt, contains("Topic: Laws of Motion · Newton's laws"));
      expect(prompt, contains('Question: The unit of force is equivalent to kg m s^{-2}.'));
      expect(prompt, contains('A) Joule\nB) Newton\nC) Watt\nD) Pascal'));
      expect(prompt, contains('Correct answer: B) Newton'));
      expect(prompt, contains('why this answer is correct'));
      expect(prompt, isNot(contains('**')));
    });

    test('without a goal it says NEET/JEE', () {
      expect(buildAskAiPrompt(_question), contains('preparing for NEET/JEE'));
    });

    test('a very long stem is trimmed, keeping the options and the answer', () {
      final long = PracticeQuestion(
        ref: 'q_2',
        position: 1,
        stem: 'x' * 5000,
        options: _question.options,
        answer: 0,
        explanation: '',
      );
      final prompt = buildAskAiPrompt(long);
      expect(prompt.length, lessThanOrEqualTo(1800));
      expect(prompt, contains('x…'));
      expect(prompt, contains('Correct answer: B) Newton'));
    });
  });

  group('openAskAi', () {
    late List<String> copied;
    setUp(() => copied = []);
    Future<void> copy(String text) async => copied.add(text);

    test('opens the ChatGPT app with the prompt when it is installed', () async {
      final open = _Opener({0});
      final target = await openAskAi('hello tutor', open: open.call, copy: copy);

      expect(target, AskAiTarget.chatGptApp);
      final (uri, mode) = open.opened.single;
      expect(uri.host, 'chatgpt.com');
      expect(uri.queryParameters['q'], 'hello tutor');
      expect(mode, LaunchMode.externalNonBrowserApplication);
      expect(copied, ['hello tutor']);
      expect(askAiMessage(target), isNull);
    });

    test('falls back to the Gemini app, with the prompt on the clipboard', () async {
      final open = _Opener({1});
      final target = await openAskAi('hello tutor', open: open.call, copy: copy);

      expect(target, AskAiTarget.geminiApp);
      expect(open.opened[1].$1.host, 'gemini.google.com');
      expect(open.opened[1].$2, LaunchMode.externalNonBrowserApplication);
      expect(copied, ['hello tutor']);
      expect(askAiMessage(target), contains('Paste it into Gemini'));
    });

    test('with neither app, ChatGPT opens in the browser', () async {
      final open = _Opener({2});
      final target = await openAskAi('hello tutor', open: open.call, copy: copy);

      expect(target, AskAiTarget.chatGptWeb);
      expect(open.opened[2].$1.queryParameters['q'], 'hello tutor');
      expect(open.opened[2].$2, LaunchMode.externalApplication);
    });

    test('when nothing opens, it says the question is copied', () async {
      final target = await openAskAi('hello tutor', open: _Opener({}).call, copy: copy);

      expect(target, AskAiTarget.none);
      expect(askAiMessage(target), contains('copied'));
    });
  });
}
