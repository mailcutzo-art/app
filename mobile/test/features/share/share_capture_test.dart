import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/share/share_card.dart';
import 'package:quiz_app/features/share/share_providers.dart';

import '../../support/share_samples.dart';

void main() {
  testWidgets('the card is captured off-screen as a 1080 × 1350 PNG and then removed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(body: Center(child: Text('Result'))),
      ),
    );
    final context = tester.element(find.text('Result'));

    final capture = captureShareCard(context, sampleWin);
    await tester.pump();
    expect(find.byType(ShareCard), findsOneWidget, reason: 'laid out for one frame');
    final left = tester.getTopLeft(find.byType(ShareCard)).dx;
    expect(left, lessThan(-shareCardSize.width), reason: 'out of sight');
    final png = (await tester.runAsync(() => capture))!;
    await tester.pump();

    expect(find.byType(ShareCard), findsNothing);
    expect(png.sublist(0, 4), Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]));
    final image = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(png);
      return (await codec.getNextFrame()).image;
    }))!;
    expect((image.width, image.height), (1080, 1350));
    image.dispose();
  });
}
