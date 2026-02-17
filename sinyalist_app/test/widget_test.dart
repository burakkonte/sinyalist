import 'package:flutter_test/flutter_test.dart';
import 'package:sinyalist/main.dart';

void main() {
  testWidgets('App launches without crash', (WidgetTester tester) async {
    await tester.pumpWidget(const SinyalistApp());
    await tester.pumpAndSettle();
    expect(find.text('Sinyalist'), findsOneWidget);
  });
}
