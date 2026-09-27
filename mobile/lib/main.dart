import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

void main() => runApp(const QuizApp());

/// App root. Routing, auth and the five tabs arrive with the app shell
/// (plan phase 2); for now this just proves the theme wiring end to end.
class QuizApp extends StatelessWidget {
  const QuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quiz Arena',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const _ComingSoon(),
    );
  }
}

class _ComingSoon extends StatelessWidget {
  const _ComingSoon();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: EmptyState(
          icon: AppIcons.rocket,
          tone: PastelTone.lime,
          title: 'Quiz Arena',
          message: 'Live quiz battles for NEET and JEE. The full app is on its way.',
        ),
      ),
    );
  }
}
