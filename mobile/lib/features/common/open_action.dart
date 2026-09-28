import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/app_failure.dart';
import '../../core/utils/ids.dart';
import '../inbox/data/inbox_models.dart';
import '../practice/data/practice_models.dart';
import '../practice/start_practice.dart';

/// Opens where an [AppAction] points: a tab is switched to, anything else opens on top so Back
/// returns here. An unknown route lands on Home (the router's `onException`).
///
/// Two server actions carry intent in their params: `/learn {"mode": "review"}` starts a review
/// practice session, and `/profile {"section": "achievements"}` opens achievements.
void openAppAction(BuildContext context, AppAction action) {
  if (action.route == Routes.learn && action.params['mode'] == 'review') {
    unawaited(_startReview(context));
    return;
  }
  if (action.route == Routes.profile && action.params['section'] == 'achievements') {
    unawaited(context.push(Routes.achievements));
    return;
  }
  if (action.route == Routes.leaderboards && action.params['board'] != null) {
    unawaited(context.push(Routes.board(action.params['board']!)));
    return;
  }
  if (action.route == '/rooms/invite' || action.route == '/rooms') {
    final roomId = action.params['room_id'];
    if (roomId != null && roomId.isNotEmpty) {
      unawaited(context.push(Routes.room(roomId)));
      return;
    }
    context.go(Routes.battle);
    return;
  }
  if (action.opensTab) {
    context.go(action.location);
  } else {
    unawaited(context.push(action.location));
  }
}

Future<void> _startReview(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    final session = await container
        .read(practiceStarterProvider)
        .start(
          const SessionSettings(mode: PracticeMode.review, count: 20),
          idempotencyKey: randomHexId(),
        );
    if (context.mounted) unawaited(context.push(Routes.practiceSession(session.sessionId)));
  } on AppFailure catch (failure) {
    if (!context.mounted) return;
    showAppToast(
      context,
      practiceStartError(
        failure,
        noQuestions: 'Nothing to review yet. Questions you miss show up here.',
      ),
      icon: AppIcons.info,
    );
    context.go(Routes.learn);
  }
}
