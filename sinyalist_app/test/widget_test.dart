// FIX: The original test used pumpAndSettle() which waits forever for all
// timers/futures to complete.  The app starts a real HTTP health-check timer
// (15 s interval) the moment it is built; pumpAndSettle never returns because
// TestWidgetsFlutterBinding converts all HTTP calls to 400s but the retries
// keep scheduling.  Instead we:
//   1. pump() once to trigger the first frame (renders SplashScreen).
//   2. pump(Duration(milliseconds: 100)) to allow synchronous init to settle.
// We then just verify the app renders at all — the splash screen is the
// correct initial state while async init is running.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinyalist/main.dart';

void main() {
  testWidgets('App launches and renders splash screen without crash',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SinyalistApp());
    // First frame: SplashScreen with 'Initializing...' text
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // App must have rendered at least one widget without throwing
    expect(find.byType(MaterialApp), findsOneWidget);

    // The splash screen is shown during async init — verify it is there
    expect(find.text('SINYALIST'), findsOneWidget);
  });
}
