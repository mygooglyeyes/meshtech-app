// THE 4-WAY LINK SELECTOR (Brett 2026-09-25): four chips - BLE / USB
// / WiFi / TCP. Laws pinned here: nothing connects on its own (the
// Connect button is unpressable until a chip is chosen), a press acts
// for THAT chip alone (BLE goes through the companion link, never the
// door), and the not-yet-built chips say so in plain words instead of
// pretending.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/app_shell.dart';
import 'package:meshtech_app/ble_transport.dart';
import 'package:meshtech_app/door_socket.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what the shell asked the door to dial - no network.
class RecordingSocket implements DoorSocket {
  static String? lastUrl;

  @override
  set onOpen(void Function() f) {}
  @override
  set onMessage(void Function(String raw) f) {}
  @override
  set onClose(void Function(int code, bool clean) f) {}

  @override
  void open(String url, List<String>? protocols) {
    lastUrl = url;
  }

  @override
  void send(String data) {}

  @override
  void close() {}
}

/// A radio that hears TWO companions - enough to need a picker box.
class FakeBle implements BleTransport {
  @override
  Stream<Uint8List> get incoming => const Stream.empty();
  @override
  set onDisconnect(void Function(String why) f) {}
  @override
  String get name => 'Heltec-A';
  @override
  Future<List<BleCandidate>> scan(
          {Duration timeout = const Duration(seconds: 5)}) async =>
      const [
        BleCandidate('id-a', 'Heltec-A'),
        BleCandidate('id-b', 'Heltec-B'),
      ];
  @override
  Future<void> connect(BleCandidate pick) async {}
  @override
  Future<void> write(Uint8List data) async {}
  @override
  Future<void> close() async {}
}

void main() {
  setUp(() {
    RecordingSocket.lastUrl = null;
    SharedPreferences.setMockInitialValues({});
  });

  FilledButton connectButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton));

  Future<void> pumpApp(WidgetTester tester) async {
    await tester
        .pumpWidget(const MeshtechApp(socketFactory: RecordingSocket.new));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Connect stays unpressable until a chip is chosen, then pressable',
      (tester) async {
    await pumpApp(tester);
    expect(connectButton(tester).onPressed, isNull); // no chip yet
    // THE RADIO STATUS LINE: one fixed spot, honest from launch.
    expect(find.byKey(const ValueKey('radio-status')), findsOneWidget);
    expect(find.text('Radio: not connected'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'BLE'));
    await tester.pumpAndSettle();
    expect(connectButton(tester).onPressed, isNotNull);
  });

  testWidgets('a BLE press goes through the companion link, not the door',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'BLE'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    // The door was NEVER dialed (BLE is not TCP).
    expect(RecordingSocket.lastUrl, isNull);
    // No BLE is wired in tests: the companion link says so in plain
    // words (on-screen detail + device log) instead of pretending.
    expect(find.textContaining('BLE transport wired'), findsWidgets);
    // ...and the status line carries the refusal too.
    final status = tester.widget<Text>(
        find.byKey(const ValueKey('radio-status')));
    expect(status.data, contains('BLE transport wired'));
    expect(status.data, startsWith('Radio: '));
  });

  testWidgets('the USB chip is honest: not built yet, door untouched',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'USB'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(find.textContaining('USB link: not built yet'), findsWidgets);
    expect(RecordingSocket.lastUrl, isNull);
  });

  testWidgets('the WiFi chip is honest too (it is NOT the TCP door)',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'WiFi'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(find.textContaining('WiFi link: not built yet'), findsWidgets);
    expect(RecordingSocket.lastUrl, isNull);
  });

  testWidgets('a TCP press still dials the door (the test path)', //
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'TCP'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Hilltop address'), '10.0.0.5');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(RecordingSocket.lastUrl, 'ws://10.0.0.5:8710/feed');
  });

  testWidgets(
      'THE PICKER BOX lists the scan finds; cancelling connects nothing',
      (tester) async {
    await tester.pumpWidget(const MeshtechApp(
        socketFactory: RecordingSocket.new, bleFactory: FakeBle.new));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'BLE'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    // The box: both radios, by name (Brett 2026-09-25).
    expect(find.text('Choose the radio'), findsOneWidget);
    expect(find.text('Heltec-A'), findsOneWidget);
    expect(find.text('Heltec-B'), findsOneWidget);
    // The status line walks him through it.
    var status = tester.widget<Text>(
        find.byKey(const ValueKey('radio-status')));
    expect(status.data, contains('choose a radio'));

    // Cancel = no pick = nothing connects, said plainly.
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Choose the radio'), findsNothing);
    status =
        tester.widget<Text>(find.byKey(const ValueKey('radio-status')));
    expect(status.data, contains('radio selection cancelled'));
    expect(RecordingSocket.lastUrl, isNull);
  });
}
