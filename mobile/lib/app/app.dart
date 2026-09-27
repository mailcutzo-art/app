import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/practice/data/answer_queue.dart';
import 'live/live_layer.dart';
import 'router.dart';

class QuizApp extends ConsumerWidget {
  const QuizApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Sends practice answers left over from an earlier run once signed in.
    ref.watch(answerSyncProvider);
    return MaterialApp.router(
      title: 'Quiz Arena',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => LiveLayer(child: child ?? const SizedBox.shrink()),
    );
  }
}
