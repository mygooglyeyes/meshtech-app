// The BLE companion link, tested on the VM through the BleTransport
// seam (the DoorSocket lesson applied to Bluetooth): a fake radio
// feeds the VERIFIED meshclient.ts frame shapes at CompanionLink, and
// packets must land exactly like the door's - honest receipts ('air
// <- ...'), the zero-dots law (INTRO held until the LAYOUT names the
// center), the #scope probe, and a TX path that reports its fate.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/ble_transport.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/companion_protocol.dart';
import 'package:meshtech_app/link.dart';

class FakeBleTransport implements BleTransport {
  final _incoming = StreamController<Uint8List>.broadcast();
  final writes = <Uint8List>[];
  void Function(String why)? onDisconnectFn;
  bool closed = false;

  /// What scan() hears (tests override) and who got connected.
  List<BleCandidate> scanResults = const [
    BleCandidate('fake-1', 'FakeHeltec')
  ];
  BleCandidate? connectedTo;

  /// The pairing bounce: fail the next N connect() calls the way the
  /// real stack does ('Device is disconnected'), optionally firing
  /// the stale drop event first (what the bench saw).
  int failConnects = 0;
  int connectCalls = 0;
  bool fireDisconnectOnFail = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  set onDisconnect(void Function(String why) f) => onDisconnectFn = f;

  @override
  String get name => 'FakeHeltec';

  @override
  Future<List<BleCandidate>> scan(
          {Duration timeout = const Duration(seconds: 5)}) async =>
      scanResults;

  @override
  Future<void> connect(BleCandidate pick) async {
    connectCalls++;
    if (connectCalls <= failConnects) {
      if (fireDisconnectOnFail) onDisconnectFn?.call('radio disconnected');
      throw StateError('Device is disconnected');
    }
    connectedTo = pick;
  }

  @override
  Future<void> write(Uint8List data) async {
    writes.add(Uint8List.fromList(data));
    onWrite?.call(Uint8List.fromList(data));
  }

  /// v019 race rigging: fires WHILE a write is in flight - the real
  /// radio's OK can land before our BLE write future settles (the
  /// 2026-09-25 16:19 bench race).
  void Function(Uint8List data)? onWrite;

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }

  void emit(List<int> bytes) => _incoming.add(Uint8List.fromList(bytes));
}

// The golden wire bytes the codec tests pin (same vectors the door
// link is verified against): a LAYOUT centred at (1.2345, -1.5) with
// span 40000 m, and an INTRO whose positioned entry carries deltas
// 36/36 against that span.
const layoutWire =
    '0553150503007eb10344d61200a01ce9ff409c0464656d6f';
const introWire =
    '04531e0502007eb1409c0211030748696c6c746f7024002400220105416c696365';

Uint8List bytesOf(String hex) => Uint8List.fromList([
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

/// A CHANNEL_DATA_RECV (0x1B) response wrapped around a FULL scope
/// plaintext - the exact envelope the firmware queues for
/// CMD_SYNC_NEXT_MESSAGE (meshclient.ts: code+snr+rsv+chan+path_len+
/// data_type(2)+data_len+body).
Uint8List channelDataRecv(String wireHex, {int snrRaw = 48}) {
  final wire = bytesOf(wireHex);
  final body = wire.sublist(3);
  final out = Uint8List(9 + body.length);
  out[0] = 0x1b; // RESPONSE_CHANNEL_DATA_RECV
  out[1] = snrRaw; // signed 8-bit / 4 -> 48 = 12.0 dB
  out[4] = 1; // channel idx
  out[5] = 0; // path_len
  out[6] = wire[0]; // data_type LE lo
  out[7] = wire[1]; // data_type LE hi
  out[8] = body.length;
  out.setAll(9, body);
  return out;
}

/// A CHANNEL_INFO (0x12) response: idx(1) name(32) secret(16).
Uint8List channelInfo(int slot, String name, List<int> secret) {
  final out = Uint8List(50);
  out[0] = 0x12;
  out[1] = slot;
  out.setAll(2, utf8.encode(name));
  out.setAll(34, secret);
  return out;
}

List<int> scopeSecret() =>
    sha256.convert(utf8.encode('#scope')).bytes.sublist(0, 16);

void main() {
  // Short timings: the proven defaults (1 s poll, 8x120 ms probe) are
  // slow for a test's event loop.
  CompanionLink buildLink(LinkEvents events, FakeBleTransport fake) =>
      CompanionLink(
        events,
        transportFactory: () => fake,
        pollInterval: const Duration(milliseconds: 30),
        slotProbeGap: const Duration(milliseconds: 5),
        probeSummaryDelay: const Duration(milliseconds: 60),
        retryPause: const Duration(milliseconds: 10),
      );

  test('connect runs the proven init: APP_START, device query, poll',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);

    await link.connect();
    expect(link.state, LinkState.connected);

    // FIRST after connect: CMD_APP_START with the app name at offset 8
    // (7 reserved bytes follow the command byte).
    final appStart = fake.writes[0];
    expect(appStart[0], 0x01);
    expect(utf8.decode(appStart.sublist(8)), 'meshtech-app');
    // Then the device query (0x16 0x03).
    expect(fake.writes[1], equals([0x16, 0x03]));
    expect(logs.any((l) => l.contains('companion init sent')), isTrue);
    expect(logs.any((l) => l.contains('channel probe sent')), isTrue);

    // RX polling: a bare CMD_SYNC_NEXT_MESSAGE (0x0A) goes out on the
    // timer - the 2026-09-18 lesson (a passive listener sees nothing).
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
        fake.writes.any((w) => w.length == 1 && w[0] == 0x0a), isTrue);

    link.disconnect();
    expect(link.state, LinkState.disabled);
    // The teardown (stop polling, close the transport) is async.
    await Future<void>.delayed(Duration.zero);
    expect(fake.closed, isTrue);
  });

  test('an OTA scope packet lands as a receipt on the air pipe',
      () async {
    final fake = FakeBleTransport();
    final received = <Object>[];
    final logs = <String>[];
    final link = buildLink(
        LinkEvents(onPacket: (p, {heardMs}) => received.add(p),
            onLog: logs.add),
        fake);
    await link.connect();

    fake.emit(channelDataRecv(layoutWire));
    await Future<void>.delayed(Duration.zero);

    expect(received.whereType<Layout>(), hasLength(1));
    // THE HONEST RECEIPT names the pipe: air, not door.
    expect(logs.any((l) => l.startsWith('air <- layout')), isTrue);
    // The first OTA packet announces itself with its SNR (12.0 dB).
    expect(
        logs.any((l) => l.contains('first OTA packet heard') &&
            l.contains('12.0 dB')),
        isTrue);

    link.disconnect();
  });

  test('zero-dots law over the air: INTRO held, flushed by the LAYOUT',
      () async {
    final fake = FakeBleTransport();
    final received = <Object>[];
    final logs = <String>[];
    final link = buildLink(
        LinkEvents(onPacket: (p, {heardMs}) => received.add(p),
            onLog: logs.add),
        fake);
    await link.connect();

    // INTRO FIRST - no map center heard yet: held, loudly.
    fake.emit(channelDataRecv(introWire));
    await Future<void>.delayed(Duration.zero);
    expect(received.whereType<Intro>(), isEmpty);
    expect(logs.any((l) => l.contains('INTRO held')), isTrue);

    // The LAYOUT names the center: the held INTRO flushes decoded
    // against it (36 deltas of a 40000 m span off (1.2345, -1.5)).
    fake.emit(channelDataRecv(layoutWire));
    await Future<void>.delayed(Duration.zero);
    final intro = received.whereType<Intro>().single;
    final stepDeg = 36 / 32767.0 * (40000.0 / 111320.0);
    expect(intro.entries.first.lat!, closeTo(1.2345 + stepDeg, 1e-9));
    expect(intro.entries.first.lon!, closeTo(-1.5 + stepDeg, 1e-9));
    expect(received.whereType<Layout>(), hasLength(1));

    link.disconnect();
  });

  test('#meshtech probe finds the slot and reports the key honestly',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();

    fake.emit(channelInfo(3, 'meshtech', scopeSecret()));
    await Future<void>.delayed(Duration.zero);
    expect(
        logs.contains(
            '#meshtech found in radio slot 3 - key read from the radio '
            '(16B) - the node must hold the same'),
        isTrue);

    link.disconnect();
  });

  test('an empty slot key is reported as empty, never trusted',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();

    fake.emit(channelInfo(1, 'meshtech', List<int>.filled(16, 0)));
    await Future<void>.delayed(Duration.zero);
    expect(
        logs.any((l) =>
            l.contains('slot 1') && l.contains('slot key is EMPTY')),
        isTrue);

    link.disconnect();
  });

  test('the probe sweep reports slots when no #scope shows up',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();

    fake.emit(channelInfo(0, 'chat', scopeSecret()));
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(
        logs.any((l) =>
            l.contains('no #meshtech among them') && l.contains("0:'chat'")),
        isTrue);

    link.disconnect();
  });

  test('an uplink refuses honestly until the slot is known', () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();

    await link.sendVectoredAsk(syncMarker: 0, spanKm: 40, origin: 1);
    expect(
        logs.any((l) => l.contains('#meshtech slot not found yet')), isTrue);
    // NOT one CMD_SEND_CHANNEL_DATA byte on the wire (polls may have
    // ticked meanwhile - the uplink itself must be absent).
    expect(
        fake.writes.any((w) => w.isNotEmpty && w[0] == cmdSendChannelData),
        isFalse);

    link.disconnect();
  });

  test('the scope uplink wraps REFRESH_REQ for the radio, and the OK '
      'verdict prints', () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();
    fake.emit(channelInfo(2, 'meshtech', scopeSecret()));
    await Future<void>.delayed(Duration.zero);

    await link.sendVectoredAsk(syncMarker: 7, spanKm: 40, origin: 0x1234);
    final uplink = fake.writes.last;
    // [62][slot][0xFF flood][data_type 2 LE] + the REFRESH_REQ body.
    // The radio wraps type+len into the on-air plaintext itself, so
    // the body carries NO 3-byte envelope - but data_type is its own
    // frame field (frame_server.py): v017 omitted it, the radio read
    // the type from the body's first two bytes, and hilltop dropped
    // every air ask as not-scope traffic (2026-09-25 trace).
    expect(uplink[0], cmdSendChannelData);
    expect(uplink[1], 2); // the discovered slot
    expect(uplink[2], 0xff);
    expect(uplink[3], 0x11); // data_type 0x5311 little-endian
    expect(uplink[4], 0x53);
    expect(uplink[5], 0x06); // body starts: proto version 0x06
    expect(uplink.length, 5 + 16); // frame header + 16B REFRESH_REQ body
    expect(logs.any((l) => l.contains('scope uplink sent') &&
        l.contains('slot 2')), isTrue);

    // The radio's verdict lands as a bare OK - never invisible.
    fake.emit([0x00]);
    await Future<void>.delayed(Duration.zero);
    expect(
        logs.any((l) => l.contains('uplink ACCEPTED by radio')), isTrue);

    link.disconnect();
  });

  test('an OK that lands DURING the write still counts (v019 race)',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();
    fake.emit(channelInfo(2, 'meshtech', scopeSecret()));
    await Future<void>.delayed(Duration.zero);

    // The bench race (2026-09-25 16:19): hilltop heard the packet
    // 278 ms before our BLE write future returned, and the OK that
    // arrived inside that gap was dropped with the flag still down -
    // six seconds later the app printed "verdict MISSING" for a send
    // that had worked. The flag must be armed BEFORE the write.
    fake.onWrite = (_) => fake.emit([0x00]);
    await link.sendVectoredAsk(syncMarker: 0, spanKm: 40, origin: 1);
    await Future<void>.delayed(Duration.zero);
    expect(logs.any((l) => l.contains('uplink ACCEPTED by radio')), isTrue);
    expect(logs.any((l) => l.contains('verdict MISSING')), isFalse);

    link.disconnect();
  });

  test('the radio dropping mid-session is reported in plain words',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final states = <LinkState>[];
    final link = buildLink(
        LinkEvents(onState: (s, d) => states.add(s), onLog: logs.add),
        fake);
    await link.connect();
    expect(states, [LinkState.connecting, LinkState.connected]);

    fake.onDisconnectFn!('radio disconnected');
    await Future<void>.delayed(Duration.zero);
    expect(link.state, LinkState.disabled);
    expect(logs.any((l) => l.contains('radio disconnected')), isTrue);
    expect(fake.closed, isTrue);
  });

  test("the picker's choice is the radio that gets connected", () async {
    final fake = FakeBleTransport()
      ..scanResults = const [
        BleCandidate('id-a', 'Heltec-A'),
        BleCandidate('id-b', 'Heltec-B'),
      ];
    final link = CompanionLink(
      LinkEvents(onLog: (_) {}),
      transportFactory: () => fake,
      // The human taps the SECOND radio in the box.
      devicePicker: (found) async => found.last.id,
      pollInterval: const Duration(milliseconds: 30),
      slotProbeGap: const Duration(milliseconds: 5),
      probeSummaryDelay: const Duration(milliseconds: 60),
    );
    await link.connect();
    expect(link.state, LinkState.connected);
    expect(fake.connectedTo?.id, 'id-b');
    link.disconnect();
    await Future<void>.delayed(Duration.zero);
  });

  test('cancelling the picker connects NOTHING - honestly', () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = CompanionLink(
      LinkEvents(onLog: logs.add),
      transportFactory: () => fake,
      devicePicker: (found) async => null, // dismissed the box
      pollInterval: const Duration(milliseconds: 30),
      slotProbeGap: const Duration(milliseconds: 5),
      probeSummaryDelay: const Duration(milliseconds: 60),
    );
    await link.connect();
    expect(link.state, LinkState.disabled);
    expect(fake.connectedTo, isNull);
    expect(logs.any((l) => l.contains('radio selection cancelled')), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(fake.closed, isTrue);
  });

  test('an empty scan refuses in plain words - the box never opens',
      () async {
    final fake = FakeBleTransport()..scanResults = const [];
    final logs = <String>[];
    final link = CompanionLink(
      LinkEvents(onLog: logs.add),
      transportFactory: () => fake,
      devicePicker: (found) async =>
          fail('the picker must not run on an empty scan'),
      pollInterval: const Duration(milliseconds: 30),
      slotProbeGap: const Duration(milliseconds: 5),
      probeSummaryDelay: const Duration(milliseconds: 60),
    );
    await link.connect();
    expect(link.state, LinkState.disabled);
    expect(
        logs.any((l) => l.contains('no companion radio found nearby')),
        isTrue);
    expect(fake.connectedTo, isNull);
  });

  test('the pairing bounce is retried by the app itself - one press',
      () async {
    final fake = FakeBleTransport()..failConnects = 1;
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();
    expect(link.state, LinkState.connected);
    expect(fake.connectCalls, 2); // died once, the app retried
    expect(logs.any((l) => l.contains('retry')), isTrue);
    link.disconnect();
    await Future<void>.delayed(Duration.zero);
  });

  test('a stale drop event inside the retry window is ignored', () async {
    final fake = FakeBleTransport()
      ..failConnects = 1
      ..fireDisconnectOnFail = true;
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();
    expect(link.state, LinkState.connected);
    expect(logs.any((l) => l.contains('radio disconnected')), isFalse);
    link.disconnect();
    await Future<void>.delayed(Duration.zero);
  });

  test('three bounces in a row end honestly - disabled, not hung',
      () async {
    final fake = FakeBleTransport()..failConnects = 99;
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();
    expect(link.state, LinkState.disabled);
    expect(fake.connectCalls, 3); // tried exactly three times
    expect(logs.any((l) => l.contains('retry')), isTrue);
    expect(logs.any((l) => l.contains('Device is disconnected')), isTrue);
  });

  test('no BLE wired refuses in plain words - never a fake scan',
      () async {
    final logs = <String>[];
    final states = <LinkState>[];
    final link = CompanionLink(
      LinkEvents(onState: (s, d) => states.add(s), onLog: logs.add),
      transportFactory: () =>
          throw UnsupportedError('no BLE transport wired'),
    );
    await link.connect();
    expect(link.state, LinkState.disabled);
    expect(logs.any((l) => l.contains('no BLE transport wired')), isTrue);
  });

  // --------------------------------------------------- channel provisioning

  String hexOf(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  test('provision: a slot already holding the exact key writes nothing',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();
    final secret = [for (var i = 1; i <= 16; i++) i];
    fake.onWrite = (w) {
      if (w[0] == cmdGetChannel) fake.emit(channelInfo(5, 'scope', secret));
    };
    var asked = false;
    final out = await link.provisionChannel(5, '#scope', hexOf(secret),
        confirm: (situation) async {
      asked = true;
      return true;
    });
    expect(out, contains('already holds'));
    expect(out, contains('nothing written'));
    expect(asked, isFalse); // the check BEFORE the ask
    expect(
        fake.writes.any((w) => w.isNotEmpty && w[0] == cmdSetChannel),
        isFalse);
    link.disconnect();
  });

  test('provision: a DIFFERENT key needs the confirm, and declining '
      'touches nothing', () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();
    final old = [for (var i = 1; i <= 16; i++) i];
    final fresh = [for (var i = 16; i >= 1; i--) i];
    fake.onWrite = (w) {
      if (w[0] == cmdGetChannel) fake.emit(channelInfo(5, 'scope', old));
    };
    String? situation;
    final out = await link.provisionChannel(5, '#scope', hexOf(fresh),
        confirm: (s) async {
      situation = s;
      return false;
    });
    expect(situation, contains('DIFFERENT key'));
    expect(out, contains('cancelled'));
    expect(
        fake.writes.any((w) => w.isNotEmpty && w[0] == cmdSetChannel),
        isFalse);
    link.disconnect();
  });

  test('provision: writes the exact CMD_SET_CHANNEL frame and proves '
      'it by read-back', () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();
    final secret = [for (var i = 1; i <= 16; i++) i];
    // Slot 2 holds a DIFFERENT channel until the SET write lands -
    // then every read answers with the new truth (the read-back).
    var current = channelInfo(2, 'public', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    fake.onWrite = (w) {
      if (w[0] == cmdGetChannel) {
        fake.emit(current);
      } else if (w[0] == cmdSetChannel) {
        final name = utf8
            .decode(w.sublist(2, 34), allowMalformed: true)
            .split('\x00')
            .first;
        current = channelInfo(w[1], name, w.sublist(34));
        fake.emit([0x00]); // the radio's verdict for the write
      }
    };
    final out = await link.provisionChannel(2, '#meshtech', hexOf(secret),
        confirm: (situation) async => true);
    expect(out, contains('read back MATCHES'));
    expect(out, contains('#meshtech'));
    // The exact reference frame: [32][slot][name 32 NUL-padded][key].
    final set = fake.writes
        .firstWhere((w) => w.isNotEmpty && w[0] == cmdSetChannel);
    expect(set.length, 50);
    expect(set[1], 2);
    expect(utf8.decode(set.sublist(2, 34)).split('\x00').first,
        'meshtech');
    expect(set.sublist(34), equals(secret));
    expect(logs.any((l) => l.contains('channel write ACCEPTED by radio')),
        isTrue);
    link.disconnect();
  });

  test('provision: a malformed key refuses before touching the radio',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();
    final out = await link.provisionChannel(5, '#meshtech', 'nothex!!');
    expect(out, contains('32 hex characters'));
    expect(
        fake.writes.any((w) => w.isNotEmpty && w[0] == cmdSetChannel),
        isFalse);
    link.disconnect();
  });

  test('provision: with the link down the refusal is in plain words',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake); // no connect
    final out = await link.provisionChannel(
        5, '#meshtech', hexOf([for (var i = 0; i < 16; i++) i]));
    expect(out, contains('companion link is down'));
    expect(
        fake.writes.any((w) => w.isNotEmpty && w[0] == cmdSetChannel),
        isFalse);
  });

  // ------------------------------------------------- the automatic channel check
  //
  // v022 (Brett 2026-09-25): the app settles the channel on its own
  // the moment the radio links up - probe, compare against THE shared
  // key, write what is missing, read it back. No human in the middle.

  /// A radio whose channel table the test owns - the probe's reads
  /// answer with it, CMD_SET_CHANNEL rewrites it, verdict included.
  Map<int, Uint8List> radioTable(Map<int, Uint8List> initial,
      FakeBleTransport fake) {
    final table = Map<int, Uint8List>.of(initial);
    fake.onWrite = (w) {
      if (w.isEmpty) return;
      if (w[0] == cmdGetChannel) {
        final slot = w[1];
        fake.emit(table[slot] ?? channelInfo(slot, '', List.filled(16, 0)));
      } else if (w[0] == cmdSetChannel) {
        final name = utf8
            .decode(w.sublist(2, 34), allowMalformed: true)
            .split('\x00')
            .first;
        table[w[1]] = channelInfo(w[1], name, w.sublist(34));
        fake.emit([0x00]); // the radio's verdict for the write
      }
    };
    return table;
  }

  test('ensureChannel: already there with THE key - nothing written',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    radioTable({5: channelInfo(5, 'meshtech', bytesOf(channelSecretHex))},
        fake);
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();

    final out =
        await link.ensureChannel(secretHex: channelSecretHex, stage: logs.add);
    expect(out, contains('already holds'));
    expect(out, contains('nothing written'));
    expect(
        fake.writes.any((w) => w.isNotEmpty && w[0] == cmdSetChannel),
        isFalse);
    expect(link.scopeSlot, 5); // the probe named it for the uplink
    link.disconnect();
  });

  test('ensureChannel: a radio still on the old channel is written '
      'without asking - and proved by read-back', () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    radioTable({5: channelInfo(5, 'scope', scopeSecret())}, fake);
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();

    final out =
        await link.ensureChannel(secretHex: channelSecretHex, stage: logs.add);
    expect(out, contains('read back MATCHES'));
    expect(out, contains('slot 5'));
    final set = fake.writes
        .firstWhere((w) => w.isNotEmpty && w[0] == cmdSetChannel);
    expect(set[1], 5); // the slot the probe found the OLD channel in
    expect(utf8.decode(set.sublist(2, 34)).split('\x00').first,
        scopeChannelName);
    expect(set.sublist(34), equals(bytesOf(channelSecretHex)));
    // Nobody was asked - but the app SAYS it answered for the human.
    expect(logs.any((l) => l.contains('channel check writes it')), isTrue);
    expect(link.scopeSlot, 5);
    link.disconnect();
  });

  test('ensureChannel: the right name with the WRONG key is rewritten',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    radioTable({5: channelInfo(5, 'meshtech', List.filled(16, 7))}, fake);
    final link = buildLink(LinkEvents(onLog: logs.add), fake);
    await link.connect();

    final out =
        await link.ensureChannel(secretHex: channelSecretHex, stage: logs.add);
    // The mismatch is named in the confirm line the app speaks aloud.
    expect(logs.any((l) => l.contains('DIFFERENT key')), isTrue);
    expect(out, contains('read back MATCHES'));
    final set = fake.writes
        .firstWhere((w) => w.isNotEmpty && w[0] == cmdSetChannel);
    expect(set.sublist(34), equals(bytesOf(channelSecretHex)));
    link.disconnect();
  });

  test('ensureChannel: with the link down the refusal is in plain words',
      () async {
    final fake = FakeBleTransport();
    final logs = <String>[];
    final link = buildLink(LinkEvents(onLog: logs.add), fake); // no connect
    final out = await link.ensureChannel(secretHex: channelSecretHex);
    expect(out, contains('companion link is down'));
    expect(
        fake.writes.any((w) => w.isNotEmpty && w[0] == cmdSetChannel),
        isFalse);
  });
}
