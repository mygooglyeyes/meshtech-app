// App-shell smoke test: the connect screen is the landing state with
// THE 4-WAY LINK SELECTOR (Brett 2026-09-25): four chips, nothing
// connected on its own, the door fields waiting behind the TCP chip,
// and the three saved facts (address, password, map size BEFORE
// connect - design section 3).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/app_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('app lands on the connect screen with the four chips',
      (tester) async {
    // The settings store rides SharedPreferences; the test binding
    // needs its in-memory mock channel before any load() runs.
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MeshtechApp());
    await tester.pumpAndSettle();
    expect(find.text('Connect'), findsWidgets);
    expect(find.widgetWithText(ChoiceChip, 'BLE'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'USB'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'WiFi'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'TCP'), findsOneWidget);
    // The door fields belong to TCP only - they wait behind its chip.
    expect(find.text('Hilltop address'), findsNothing);
    expect(find.text('Data-door password'), findsNothing);
    // Map size is chosen before connect, whichever chip wins.
    expect(find.textContaining('Map size'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'TCP'));
    await tester.pumpAndSettle();
    expect(find.text('Hilltop address'), findsOneWidget);
    expect(find.text('Data-door password'), findsOneWidget);
  });
}
