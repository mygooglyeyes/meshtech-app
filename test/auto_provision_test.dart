// THE AUTOMATIC CHANNEL CHECK (v022, Brett 2026-09-25): the app
// settles the radio's channel BY ITSELF the moment the BLE link comes
// up - his flow is "connect -> check/provision -> map", with no
// Connect screen in the middle. Three shapes are pinned here:
//
//   * the radio already holds #meshtech with THE key: nothing is
//     written, the map opens;
//   * the radio is still on the old channel: the app writes the
//     shared key into the slot the probe picked, proves it by
//     read-back, THEN the map opens;
//   * the write cannot be proved: the map stays down and the connect
//     screen keeps the honest line + the manual retry.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/app_shell.dart';
import 'package:meshtech_app/ble_transport.dart';
import 'package:meshtech_app/companion_protocol.dart';
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

Uint8List bytesOf(String hex) => Uint8List.fromList([
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

/// A CHANNEL_INFO (0x12) response: idx(1) name(32) secret(16).
Uint8List channelInfo(int slot, String name, List<int> secret) {
  final out = Uint8List(50);
  out[0] = 0x12;
  out[1] = slot;
  out.setAll(2, utf8.encode(name));
  out.setAll(34, secret);
  return out;
}

/// A radio that OWNS its channel table: the probe's CMD_GET_CHANNEL
/// reads answer from it, CMD_SET_CHANNEL rewrites it and answers OK -
/// the real firmware's conversation, minus the air. `muteReads` rigs
/// the honest-failure case: the radio simply never answers.
class AutoRadio implements BleTransport {
  final _incoming = StreamController<Uint8List>.broadcast();
  final writes = <Uint8List>[];
  final Map<int, Uint8List> table = {};
  bool muteReads = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  set onDisconnect(void Function(String why) f) {}

  @override
  String get name => 'Heltec-A';

  @override
  Future<List<BleCandidate>> scan(
          {Duration timeout = const Duration(seconds: 5)}) async =>
      const [BleCandidate('id-a', 'Heltec-A')];

  @override
  Future<void> connect(BleCandidate pick) async {}

  @override
  Future<void> close() async {
    await _incoming.close();
  }

  @override
  Future<void> write(Uint8List data) async {
    writes.add(Uint8List.fromList(data));
    if (data.isEmpty) return;
    if (data[0] == cmdGetChannel) {
      if (muteReads) return;
      final slot = data[1];
      _incoming.add(table[slot] ?? channelInfo(slot, '', List.filled(16, 0)));
    } else if (data[0] == cmdSetChannel) {
      final name = utf8
          .decode(data.sublist(2, 34), allowMalformed: true)
          .split('\x00')
          .first;
      table[data[1]] = channelInfo(data[1], name, data.sublist(34));
      // The radio's verdict for the write (OK).
      _incoming.add(Uint8List.fromList(const [0x00]));
    }
  }
}

void main() {
  setUp(() {
    RecordingSocket.lastUrl = null;
    SharedPreferences.setMockInitialValues({});
  });

  /// The bench's real steps: tap the BLE chip, Connect, pick the radio
  /// from the scan box (the PIN box is Android's, not ours).
  Future<void> connectBle(WidgetTester tester, AutoRadio radio) async {
    await tester.pumpWidget(MeshtechApp(
      socketFactory: RecordingSocket.new,
      bleFactory: () => radio,
      // The test seam: no live map engine in widget tests.
      mapBuilder: (_) => const SizedBox(key: Key('fake-map')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'BLE'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'Heltec-A'));
    await tester.pumpAndSettle();
  }

  /// Advance the fake clock in 100 ms steps so the probe's timers
  /// (8 slots x 120 ms, summary at 1400 ms) and the channel reads'
  /// waits actually fire; settle the frames afterwards.
  Future<void> runFor(WidgetTester tester, int milliseconds) async {
    for (var waited = 0; waited < milliseconds; waited += 100) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  final appKey = bytesOf(channelSecretHex);
  final oldScopeKey = bytesOf('00112233445566778899aabbccddeeff');

  testWidgets('radio already on #meshtech with THE key: no write, '
      'straight to the map', (tester) async {
    final radio = AutoRadio()
      ..table[5] = channelInfo(5, 'meshtech', appKey);
    await connectBle(tester, radio);
    await runFor(tester, 2500);

    expect(
        radio.writes.any((w) => w.isNotEmpty && w[0] == cmdSetChannel),
        isFalse);
    // The gate is open: the map is up, the connect screen is gone.
    expect(find.byKey(const Key('fake-map')), findsOneWidget);
    expect(find.byKey(const ValueKey('provision-channel')), findsNothing);
    expect(RecordingSocket.lastUrl, isNull); // never needed the door
  });

  testWidgets('radio still on the old channel: the app writes THE key, '
      'proves it, then opens the map', (tester) async {
    final radio = AutoRadio()..table[5] = channelInfo(5, 'scope', oldScopeKey);
    await connectBle(tester, radio);
    // The check cannot even start until the probe has swept the slots.
    await runFor(tester, 3000);

    final set = radio.writes
        .firstWhere((w) => w.isNotEmpty && w[0] == cmdSetChannel);
    expect(set[1], 5); // the slot the probe found the old channel in
    expect(utf8.decode(set.sublist(2, 34)).split('\x00').first,
        scopeChannelName);
    expect(set.sublist(34), equals(appKey));
    expect(find.byKey(const Key('fake-map')), findsOneWidget);
    expect(find.byKey(const ValueKey('provision-channel')), findsNothing);
  });

  testWidgets('an unanswerable radio: the write cannot be proved, so '
      'the map stays down with the honest line', (tester) async {
    final radio = AutoRadio()..muteReads = true;
    await connectBle(tester, radio);
    // probe summary (1400 ms) + a read that times out (1500 ms) + the
    // write + a read-back that times out (1500 ms).
    await runFor(tester, 6000);

    expect(find.byKey(const Key('fake-map')), findsNothing);
    // Still on the connect screen, retry button included.
    expect(find.byKey(const ValueKey('provision-channel')), findsOneWidget);
    expect(find.textContaining('write did NOT stick'), findsWidgets);
    expect(find.textContaining('the map stays down'), findsWidgets);
  });
}
