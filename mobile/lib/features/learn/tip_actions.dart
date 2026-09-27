import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/app_failure.dart';
import '../../core/utils/ids.dart';
import '../practice/data/practice_models.dart';
import '../practice/start_practice.dart';
import 'data/learn_models.dart';

/// Where a coach tip's button leads.
sealed class TipDestination {
  const TipDestination();
}

/// Start a practice set with these settings.
final class TipPractice extends TipDestination {
  const TipPractice(this.settings);

  final SessionSettings settings;

  @override
  bool operator ==(Object other) => other is TipPractice && other.settings == settings;

  @override
  int get hashCode => settings.hashCode;
}

/// Open another part of the app.
final class TipOpens extends TipDestination {
  const TipOpens(this.location);

  final String location;

  @override
  bool operator ==(Object other) => other is TipOpens && other.location == location;

  @override
  int get hashCode => location.hashCode;
}

/// Maps a tip's `action` and `params` to what its button does, following the
/// table in `docs/api-learn.md`. Null when the app can't act on it (an
/// unknown action, or params the action needs are missing).
TipDestination? tipDestination(Tip tip) {
  final params = tip.params;
  final subject = params['subject'];
  final chapter = params['chapter'];
  final topic = params['topic'];
  final count = _count(params['count']);

  /// A topic set when the tip names a topic, otherwise the chapter (or, with
  /// neither, the whole subject).
  SessionSettings? focused({bool timed = false}) {
    if (subject == null) return null;
    return SessionSettings(
      mode: topic == null ? PracticeMode.chapter : PracticeMode.topic,
      subject: subject,
      chapters: [if (topic == null && chapter != null) chapter],
      topic: topic,
      count: count,
      timed: timed,
      perQuestionS: timed ? SessionSettings.defaultPerQuestionS : null,
    );
  }

  SessionSettings? chapterAt(Difficulty difficulty) => subject == null || chapter == null
      ? null
      : SessionSettings(
          mode: PracticeMode.chapter,
          subject: subject,
          chapters: [chapter],
          count: count,
          difficulty: difficulty,
        );

  final category = params['category'];
  final settings = switch (tip.action) {
    TipAction.practice => focused(),
    TipAction.timedPractice => focused(timed: true),
    TipAction.practiceCategory when subject != null && category != null => SessionSettings(
      mode: PracticeMode.category,
      subject: subject,
      category: category,
      count: count,
    ),
    TipAction.practiceCategory => null,
    TipAction.review => SessionSettings(
      mode: PracticeMode.review,
      subject: subject,
      count: _count(params['count'], fallback: 20),
    ),
    TipAction.startChapter => chapterAt(Difficulty.easy),
    TipAction.practiceMedium => chapterAt(Difficulty.medium),
    TipAction.battle => null,
    null => null,
  };
  // The Battle tab opens with the tip's subject and chapter picked.
  if (tip.action == TipAction.battle) {
    return TipOpens(Routes.battleWith(subject: subject, chapter: chapter));
  }
  return settings == null ? null : TipPractice(settings);
}

/// The label of a tip's button ("Practise 10", "Timed practice"…).
String tipButtonLabel(Tip tip) {
  final count = _count(tip.params['count']);
  return switch (tip.action) {
    TipAction.practice => 'Practise $count',
    TipAction.timedPractice => 'Timed practice',
    TipAction.practiceCategory => switch (tip.params['category']) {
      'numerical' => 'Practise $count numericals',
      _ => 'Practise $count',
    },
    TipAction.review => 'Review',
    TipAction.startChapter => 'Start',
    TipAction.practiceMedium => 'Practise medium',
    TipAction.battle => 'Battle',
    null => 'Open',
  };
}

/// Runs a tip's button: creates the practice set it suggests and opens it, or
/// opens the Battle tab. [replace] swaps the current screen for the new
/// session (used on a practice result screen).
Future<void> openTip(BuildContext context, WidgetRef ref, Tip tip, {bool replace = false}) async {
  switch (tipDestination(tip)) {
    case TipOpens(:final location):
      context.go(location);
    case TipPractice(:final settings):
      try {
        final session = await ref
            .read(practiceStarterProvider)
            .start(settings, idempotencyKey: randomHexId());
        if (!context.mounted) return;
        final location = Routes.practiceSession(session.sessionId);
        if (replace) {
          context.pushReplacement(location);
        } else {
          unawaited(context.push(location));
        }
      } on AppFailure catch (failure) {
        if (context.mounted) {
          showAppToast(context, practiceStartError(failure), icon: AppIcons.alert);
        }
      }
    case null:
      break;
  }
}

/// `params.count` as a session size the server accepts (5–50).
int _count(String? value, {int fallback = 10}) =>
    (int.tryParse(value ?? '') ?? fallback).clamp(5, 50);
