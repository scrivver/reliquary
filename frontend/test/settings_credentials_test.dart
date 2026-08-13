import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reliquary_fe/screens/settings_screen.dart';
import 'package:reliquary_fe/services/api_service.dart';
import 'package:reliquary_fe/services/auth_service.dart';

// Under OIDC there is no Reliquary-side password: the credential lives in the
// identity provider and `/api/users/me/password` is not served at all. The
// change-password form must stay out of reach, but its absence has to read as
// a deliberate boundary rather than as a feature that failed to load.
void main() {
  Future<void> pumpSettings(WidgetTester tester, {String? provider}) async {
    SharedPreferences.setMockInitialValues({
      if (provider != null) ...{
        'auth_provider': provider,
        'username': 'alice',
        'jwt_token': 'token',
      },
    });

    final auth = AuthService();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(authService: auth, apiService: ApiService(auth)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an OIDC session is told where its credential lives', (
    tester,
  ) async {
    await pumpSettings(tester, provider: 'oidc');

    expect(find.text('Security Credentials'), findsOneWidget);
    expect(find.text('Signed in as alice via SSO.'), findsOneWidget);
    expect(
      find.textContaining('handled by your identity provider'),
      findsOneWidget,
    );
    expect(find.text('CHANGE PASSWORD'), findsNothing);
  });

  testWidgets('a password session still gets the change-password form', (
    tester,
  ) async {
    await pumpSettings(tester, provider: 'password');

    expect(find.text('CHANGE PASSWORD'), findsOneWidget);
    expect(find.textContaining('identity provider'), findsNothing);
  });

  testWidgets('a session with no provider gets neither', (tester) async {
    await pumpSettings(tester);

    expect(find.text('CHANGE PASSWORD'), findsNothing);
    expect(find.text('Security Credentials'), findsNothing);
  });
}
