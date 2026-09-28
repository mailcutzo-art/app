import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/share/share_card.dart';
import 'package:quiz_app/features/share/share_models.dart';

import '../support/share_samples.dart';

/// Golden images of the share cards: the full card (what is shared, always light) and the
/// compact one the friends' feed shows, light and dark.
///
/// Update with `flutter test --update-goldens test/goldens/share_goldens_test.dart`.
void main() {
  setUpAll(() {
    final current = goldenFileComparator;
    if (current is LocalFileComparator) {
      goldenFileComparator = _TolerantComparator(
        current.basedir.resolve('share_goldens_test.dart'),
      );
    }
  });

  Future<void> pump(WidgetTester tester, Widget child, {required Size size, ThemeData? theme}) {
    tester.view
      ..physicalSize = size * 3
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme ?? AppTheme.light(),
        home: Scaffold(body: child),
      ),
    );
  }

  final cards = <String, ShareCardData>{
    'result_win': sampleWin,
    'result_loss': const MatchShareData(
      player: samplePlayer,
      matchId: 'm-2',
      outcome: ShareOutcome.loss,
      subject: 'Chemistry',
      score: 420,
      opponentScore: 515,
      opponentName: 'Practice Bot',
      opponentAvatar: AvatarData(tone: PastelTone.lavender, symbol: AppIcons.robot),
      answers: [ShareAnswer.correct, ShareAnswer.wrong, ShareAnswer.wrong],
    ),
    'progress': sampleProgress,
  };

  for (final MapEntry(key: name, value: data) in cards.entries) {
    testWidgets('full card: $name', (tester) async {
      await pump(
        tester,
        Center(child: ShareCard(data: data)),
        size: shareCardSize,
      );
      await expectLater(find.byType(ShareCard), matchesGoldenFile('share/full_$name.png'));
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('compact cards, ${brightness.name}', (tester) async {
      await pump(
        tester,
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            children: [
              ShareCard.compact(data: cards['result_win']!),
              const SizedBox(height: AppSpacing.md),
              ShareCard.compact(data: cards['result_loss']!),
              const SizedBox(height: AppSpacing.md),
              ShareCard.compact(data: cards['progress']!),
            ],
          ),
        ),
        size: const Size(390, 420),
        theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      );
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('share/compact_${brightness.name}.png'),
      );
    });
  }
}

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  static const _tolerance = 0.003;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
