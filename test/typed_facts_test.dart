// Regression test for the first-run bug found on the bench emulator
// (2026-09-24): typing an address then pressing Connect produced
// "no real address to dial" - the screen saved the typed facts but
// the shell dialed the stale ones from app start. The law now: the
// TYPED facts lead. Pin: the URL the shell dials must contain the
// typed address, and the saved settings must hold it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/app_shell.dart';
import 'package:meshtech_app/door_socket.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what the shell actually asked it to dial - no network.
class RecordingSocket implements DoorSocket {
  static String? lastUrl;
  static List<String>? lastProtocols;

  @override
  set onOpen(void Function() f) {}
  @override
  set onMessage(void Function(String raw) f) {}
  @override
  set onClose(void Function(int code, bool clean) f) {}

  @override
  void open(String url, List<String>? protocols) {
    lastUrl = url;
    lastProtocols = protocols;
  }

  @override
  void send(String data) {}

  @override
  void close() {}
}

void main() {
  setUp(() {
    RecordingSocket.lastUrl = null;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the TYPED address is what the shell dials (and saves)',
      (tester) async {
    await tester.pumpWidget(const MeshtechApp(
        socketFactory: RecordingSocket.new));
    await tester.pumpAndSettle();

    // The door fields only exist once the TCP chip is chosen (the
    // 4-way selector's law: pick a link, THEN connect).
    await tester.tap(find.widgetWithText(ChoiceChip, 'TCP'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Hilltop address'),
        '192.168.12.145');
    await tester.enterText(
        find.widgetWithText(TextField, 'Data-door password'),
        'secret-token');
    await tester.tap(find.byType(FilledButton)); // the Connect button
    await tester.pumpAndSettle();

    expect(RecordingSocket.lastUrl, 'ws://192.168.12.145:8710/feed');
  });
}
