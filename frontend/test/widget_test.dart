import 'package:flutter_test/flutter_test.dart';

import 'package:reliquary_fe/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Reliquary'), findsWidgets);
  });
}
