import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Future<int> tap(WidgetTester tester, {TouchFeedback Function(Widget child)? wrap}) async {
    var taps = 0;
    final button = Pressable(onPressed: () => taps++, child: const Text('Tap me'));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: Center(child: wrap == null ? button : wrap(button))),
      ),
    );
    await tester.tap(find.text('Tap me'));
    await tester.pump();
    return taps;
  }

  List<String> methods() => [for (final call in calls) call.method];

  testWidgets('without preferences a tap ticks and makes no sound', (tester) async {
    expect(await tap(tester), 1);
    expect(methods(), contains('HapticFeedback.vibrate'));
    expect(methods(), isNot(contains('SystemSound.play')));
  });

  testWidgets('haptics off: the tap still works, silently', (tester) async {
    final taps = await tap(
      tester,
      wrap: (child) => TouchFeedback(haptics: false, sounds: false, child: child),
    );
    expect(taps, 1);
    expect(methods(), isNot(contains('HapticFeedback.vibrate')));
    expect(methods(), isNot(contains('SystemSound.play')));
  });

  testWidgets('sounds on: the platform click plays', (tester) async {
    await tap(tester, wrap: (child) => TouchFeedback(haptics: true, sounds: true, child: child));
    expect(methods(), containsAll(['SystemSound.play', 'HapticFeedback.vibrate']));
  });
}
