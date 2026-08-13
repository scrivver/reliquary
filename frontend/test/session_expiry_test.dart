import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reliquary_fe/main.dart';

// The reported failure was that an expired token left the user sitting on a
// screen that could no longer load anything: the 401 handler was an empty
// method, so nothing moved them. These assert that the handlers navigate.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSignedInApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('SIGNED_IN_SCREEN')),
      ),
    );
    expect(find.text('SIGNED_IN_SCREEN'), findsOneWidget);
  }

  testWidgets('an expired session leaves the signed-in screen', (tester) async {
    await pumpSignedInApp(tester);

    handleSessionExpired();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('SIGNED_IN_SCREEN'), findsNothing);
  });

  testWidgets('an explicit sign-out leaves the signed-in screen', (
    tester,
  ) async {
    await pumpSignedInApp(tester);

    returnToAuthGate();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('SIGNED_IN_SCREEN'), findsNothing);
  });

  // A token expiring fails every request a screen has in flight, so the
  // handler is called several times over. The end state must still be one
  // auth gate. (The guard in returnToAuthGate additionally stops the repeats
  // from each re-running the gate's startup checks, which is not visible from
  // here — the navigation itself is idempotent because every push clears the
  // stack below it.)
  testWidgets('repeated failures settle on a single auth gate', (tester) async {
    await pumpSignedInApp(tester);

    handleSessionExpired();
    handleSessionExpired();
    handleSessionExpired();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('SIGNED_IN_SCREEN'), findsNothing);
    expect(find.byType(AuthGate), findsOneWidget);
  });
}
