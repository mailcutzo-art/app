import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/realtime/realtime_host.dart';
import '../features/arena/tournament_reminders.dart' show reminderTapsProvider;
import '../features/practice/data/answer_queue.dart';
import '../features/settings/settings_providers.dart';
import 'live/live_layer.dart';
import 'router.dart';

class QuizApp extends ConsumerWidget {
  const QuizApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Sends practice answers left over from an earlier run once signed in, and opens the
    // tournament of a tapped reminder.
    ref
      ..watch(answerSyncProvider)
      ..watch(reminderTapsProvider);
    final touch = ref.watch(touchPrefsProvider);
    return MaterialApp.router(
      title: 'Quiz Arena',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => TouchFeedback(
        haptics: touch.haptics,
        sounds: touch.sounds,
        child: LiveLayer(child: RealtimeHost(child: child ?? const SizedBox.shrink())),
      ),
    );
  }
}
