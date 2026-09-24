// App-shell smoke test: the connect screen is the landing state, with
// the three saved facts present (address, password, map size BEFORE
// connect - design section 3).

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/app_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('app lands on the connect screen with the three facts',
      (tester) async {
    // The settings store rides SharedPreferences; the test binding
    // needs its in-memory mock channel before any load() runs.
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MeshtechApp());
    await tester.pumpAndSettle();
    expect(find.text('Connect'), findsWidgets);
    expect(find.text('Hilltop address'), findsOneWidget);
    expect(find.text('Data-door password'), findsOneWidget);
    expect(find.textContaining('Map size'), findsOneWidget);
  });
}
