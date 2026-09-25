// Link-level regression for the zero-dots law (bench 2026-09-24): the
// server's whole-area answer is LAYOUT first, then INTRO - and INTRO
// positions are DELTAS against the LAYOUT's center. The link must
// decode them against that center (not (0,0)) and must HOLD an INTRO
// that arrives before any LAYOUT, never silently mis-place it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/door_socket.dart';
import 'package:meshtech_app/link.dart';

class FakeDoorSocket implements DoorSocket {
  List<String> sent = [];
  void Function()? onOpenFn;
  void Function(String raw)? onMessageFn;
  void Function(int code, bool clean)? onCloseFn;

  @override
  set onOpen(void Function() f) => onOpenFn = f;
  @override
  set onMessage(void Function(String raw) f) => onMessageFn = f;
  @override
  set onClose(void Function(int code, bool clean) f) => onCloseFn = f;

  @override
  void open(String url, List<String>? protocols) {}

  @override
  void send(String data) => sent.add(data);

  @override
  void close() {}

  void serverSays(Map<String, Object?> msg) =>
      onMessageFn!(jsonEncode(msg));
}

// The golden wire bytes (same vectors the codec tests pin): a LAYOUT
// centred at (1.2345, -1.5) with span 40000 m, and an INTRO whose
// positioned entry carries deltas 36/36 against a 40000 m span.
const layoutWire =
    '0553150503007eb10344d61200a01ce9ff409c0464656d6f';
const introWire =
    '04531e0502007eb1409c0211030748696c6c746f7024002400220105416c696365';

Uint8List bytesOf(String hex) => Uint8List.fromList([
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

void main() {
  test('a section ask names its field "section" (the door dialect)',
      () {
    final fake = FakeDoorSocket();
    final link = TcpLink(
      LinkEvents(onLog: (_) {}),
      host: 'test',
      password: '',
      socketFactory: () => fake,
    );
    link.connect();
    fake.onOpenFn!();
    link.sendSectionAsk(sectionId: 5, origin: 0x1234);
    final frame = jsonDecode(fake.sent.last) as Map<String, Object?>;
    expect(frame['kind'], 'section');
    expect(frame['section'], 5); // NOT 'target' - a wrong name is a
    expect(frame.containsKey('target'), isFalse); // silent server drop
  });

  test('an INTRO after the LAYOUT decodes against the LAYOUT center',
      () {
    final fake = FakeDoorSocket();
    final received = <Object>[];
    final link = TcpLink(
      LinkEvents(
        onPacket: (p, {heardMs}) => received.add(p),
        onLog: (line) {},
      ),
      host: 'test',
      password: '',
      socketFactory: () => fake,
    );
    link.connect();
    fake.onOpenFn!();
    fake.serverSays(
        {'type': 'hello', 'proto': 6, 'last_seq': 0});
    fake.serverSays({'type': 'packet', 'seq': 1, 'wire': layoutWire});
    fake.serverSays({'type': 'packet', 'seq': 2, 'wire': introWire});

    final intro = received.whereType<Intro>().single;
    expect(intro.entries.first.lat, isNotNull);
    // 36 deltas of a 40000 m span: 36 / 32767 * (40000 / 111320) deg.
    final stepDeg = 36 / 32767.0 * (40000.0 / 111320.0);
    expect(intro.entries.first.lat!, closeTo(1.2345 + stepDeg, 1e-9));
    expect(intro.entries.first.lon!, closeTo(-1.5 + stepDeg, 1e-9));
  });

  test('an INTRO before any LAYOUT is held, then flushed by it', () {
    final fake = FakeDoorSocket();
    final received = <Object>[];
    final logs = <String>[];
    final link = TcpLink(
      LinkEvents(
        onPacket: (p, {heardMs}) => received.add(p),
        onLog: logs.add,
      ),
      host: 'test',
      password: '',
      socketFactory: () => fake,
    );
    link.connect();
    fake.onOpenFn!();
    fake.serverSays({'type': 'hello', 'proto': 6, 'last_seq': 0});
    // INTRO FIRST - no center known yet.
    fake.serverSays({'type': 'packet', 'seq': 1, 'wire': introWire});
    expect(received.whereType<Intro>(), isEmpty);
    expect(logs.any((l) => l.contains('held')), isTrue);
    // The LAYOUT lands: the held INTRO flushes, correctly centered.
    fake.serverSays({'type': 'packet', 'seq': 2, 'wire': layoutWire});
    final intro = received.whereType<Intro>().single;
    final stepDeg = 36 / 32767.0 * (40000.0 / 111320.0);
    expect(intro.entries.first.lat!, closeTo(1.2345 + stepDeg, 1e-9));
    // The LAYOUT itself was also delivered (the shell needs the frame).
    expect(received.whereType<Layout>().length, 1);
  });
}
