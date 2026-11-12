import 'package:design_system/design_system.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/user.dart';
import 'data/practice_models.dart';

/// Where "Ask AI" ended up, so the screen can tell the student what to do next.
enum AskAiTarget {
  /// The ChatGPT app, with the prompt filled in.
  chatGptApp,

  /// The Gemini app (ChatGPT isn't installed). Gemini links can't carry a prompt, so it is on the
  /// clipboard to paste.
  geminiApp,

  /// Neither app is installed: ChatGPT in the browser, with the prompt filled in.
  chatGptWeb,

  /// Nothing could be opened; the prompt is on the clipboard.
  none,
}

/// Opens [uri] in [mode]; false when nothing on the device can handle it. Replaced in tests.
typedef UrlOpener = Future<bool> Function(Uri uri, LaunchMode mode);

final askAiUrlOpenerProvider = Provider<UrlOpener>(
  (ref) => (uri, mode) async {
    try {
      return await launchUrl(uri, mode: mode);
    } on PlatformException {
      return false;
    }
  },
);

/// Copies text to the clipboard. Replaced in tests.
final askAiClipboardProvider = Provider<Future<void> Function(String)>(
  (ref) =>
      (text) => Clipboard.setData(ClipboardData(text: text)),
);

/// Browsers and chat apps cut long links short; prompts stay well under this.
const _maxPromptLength = 2000;

/// The tutor prompt for [question]: the question, its options, the correct one, what the
/// student did ([outcome], with their [picked] option when they got it wrong) and a request for
/// an explanation in a fixed structure, pitched at a [goal] aspirant. Students don't need to
/// know how to write a good prompt.
String buildAskAiPrompt(
  PracticeQuestion question, {
  Goal? goal,
  AnswerOutcome? outcome,
  int? picked,
}) {
  String letter(int index) => String.fromCharCode(65 + index);
  final correct = question.options.indexWhere((o) => o.id == question.answer);
  final mine = picked == null ? -1 : question.options.indexWhere((o) => o.id == picked);
  final wrongPick = outcome == AnswerOutcome.wrong && mine >= 0 && mine != correct;
  final exam = goal == null ? 'NEET/JEE' : goal.label;
  final where = [question.chapter?.name, question.topic?.name].whereType<String>().join(' · ');
  final options = [
    for (var i = 0; i < question.options.length; i++)
      '${letter(i)}) ${_plain(question.options[i].text)}',
  ];
  final situation = switch (outcome) {
    AnswerOutcome.correct => 'I got this question right, but I want to be sure I understand it.',
    AnswerOutcome.wrong => 'I got this question wrong. Please help me understand it.',
    AnswerOutcome.timeout => 'I ran out of time on this question. Please help me solve it faster.',
    _ => 'I skipped this question. Please help me understand it.',
  };
  final steps = [
    'Correct answer: one line on why it is right.',
    'Solution: short numbered steps (show the formula and the working for a numerical).',
    'Why each other option is wrong: one line each.',
    if (wrongPick) 'My mistake: why someone picks ${letter(mine)} and how to avoid it.',
    'Key concept: the rule or formula to remember, in one or two lines.',
    'Exam tip: a quick way to solve questions like this faster.',
  ];
  String compose(String stem) => [
    'I am preparing for $exam. $situation',
    if (where.isNotEmpty) 'Topic: $where',
    '',
    'Question: $stem',
    '',
    'Options:',
    ...options,
    '',
    'Correct answer: ${letter(correct)}) ${_plain(question.options[correct].text)}',
    if (wrongPick) 'My answer: ${letter(mine)}) ${_plain(question.options[mine].text)}',
    '',
    'Explain it with these headings:',
    for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}',
    'Keep it short, in simple language.',
  ].join('\n');

  final stem = _plain(question.stem);
  final full = compose(stem);
  if (full.length <= _maxPromptLength) return full;
  // Only the stem is long enough to matter; trim it and keep everything else.
  final room = (stem.length - (full.length - _maxPromptLength) - 1).clamp(0, stem.length);
  return compose('${stem.substring(0, room)}…');
}

/// Question markup without its bold/italic markers. Scripts (`x^2`, `H_2O`) stay: chat models
/// read them fine.
String _plain(String source) =>
    source.replaceAll('**', '').replaceAll(RegExp(r'(?<![\^_{])\*(?!})'), '').trim();

/// Opens an AI chat with [prompt]: the ChatGPT app with the prompt filled in, else the Gemini
/// app, else ChatGPT in the browser. The prompt also goes on the clipboard ([copy]), so it can be
/// pasted wherever the student lands.
Future<AskAiTarget> openAskAi(
  String prompt, {
  required UrlOpener open,
  required Future<void> Function(String) copy,
}) async {
  await copy(prompt);
  final chatGpt = Uri.https('chatgpt.com', '/', {'q': prompt});
  // A verified app link: with an app-only mode it opens only when the app is installed.
  if (await open(chatGpt, LaunchMode.externalNonBrowserApplication)) {
    return AskAiTarget.chatGptApp;
  }
  if (await open(
    Uri.https('gemini.google.com', '/app'),
    LaunchMode.externalNonBrowserApplication,
  )) {
    return AskAiTarget.geminiApp;
  }
  if (await open(chatGpt, LaunchMode.externalApplication)) return AskAiTarget.chatGptWeb;
  return AskAiTarget.none;
}

/// [openAskAi] about [question], with the app's opener and clipboard.
Future<AskAiTarget> askAiAbout(
  WidgetRef ref,
  PracticeQuestion question, {
  Goal? goal,
  AnswerOutcome? outcome,
  int? picked,
}) => openAskAi(
  buildAskAiPrompt(question, goal: goal, outcome: outcome, picked: picked),
  open: ref.read(askAiUrlOpenerProvider),
  copy: ref.read(askAiClipboardProvider),
);

/// What to tell the student after [askAiAbout].
String? askAiMessage(AskAiTarget target) => switch (target) {
  AskAiTarget.chatGptApp || AskAiTarget.chatGptWeb => null,
  AskAiTarget.geminiApp => 'Question copied. Paste it into Gemini and send.',
  AskAiTarget.none => 'Couldn\'t open ChatGPT or Gemini. The question is copied to paste anywhere.',
};

/// The round ChatGPT button beside Next.
class AskAiButton extends StatelessWidget {
  const AskAiButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: AppIcons.chatGpt,
    semanticLabel: 'Ask ChatGPT to explain this question',
    variant: AppIconButtonVariant.tonal,
    onPressed: onPressed,
  );
}
