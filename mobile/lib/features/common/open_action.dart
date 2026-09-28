import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../inbox/data/inbox_models.dart';

/// Opens where an [AppAction] points: a tab is switched to, anything else opens on top so Back
/// returns here. An unknown route lands on Home (the router's `onException`).
void openAppAction(BuildContext context, AppAction action) {
  if (action.opensTab) {
    context.go(action.location);
  } else {
    unawaited(context.push(action.location));
  }
}
