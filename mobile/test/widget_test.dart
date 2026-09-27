import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/main.dart';

void main() {
  testWidgets('app starts with the themed placeholder', (tester) async {
    await tester.pumpWidget(const QuizApp());
    expect(find.text('Quiz Arena'), findsOneWidget);
  });
}
