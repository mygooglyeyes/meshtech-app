// Step-2 tests: the store's Brett-laws, the grid re-cut, and the
// TcpLink's door protocol (fed the exact message shapes the web app
// documents, through a FAKE socket - no live network, no package:web
// under the VM test runner; the stub-the-WebSocket lesson).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/door_socket.dart';
import 'package:meshtech_app/grid.dart';
import 'package:meshtech_app/link.dart';
import 'package:meshtech_app/store.dart';

/// A fake door socket: records what the link sends, lets tests push
/// what "the server" said - no network, no browser.
class FakeDoorSocket implements DoorSocket {
  List<String> sent = [];
  String? openedUrl;
  List<String>? openedProtocols;
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
  void open(String url, List<String>? protocols) {
    openedUrl = url;
    openedProtocols = protocols;
  }

  @override
  void send(String data) => sent.add(data);

  @override
  void close() {}

  void serverSays(Map<String, Object?> msg) =>
      onMessageFn!(jsonEncode(msg));
}

void main() {
  group('NodeStore - Brett\'s laws', () {
    test('upsert REPLACES: a moved node never shows twice', () {
      final s = NodeStore();
      s.upsert(const NodeRecord(
          prefix: 0x11, name: 'Alpha', lat: 38.0, lon: -122.0,
          lastHeardMs: 1000));
      s.upsert(const NodeRecord(
          prefix: 0x11, name: 'Alpha', lat: 38.5, lon: -122.5,
          lastHeardMs: 2000));
      expect(s.nodes.length, 1); // ONE dot
      expect(s.nodes[0x11]!.lat, 38.5); // the NEW position
      expect(s.nodes[0x11]!.lastHeardMs, 2000);
    });

    test('unknown never overwrites known on INTRO entries', () {
      final s = NodeStore();
      s.upsert(const NodeRecord(
          prefix: 0x11, name: 'Alpha', lat: 38.0, lon: -122.0,
          lastHeardMs: 1000));
      s.applyIntroEntry(
          const IntroEntry(prefix: 0x11, nodeClass: nodeClassRepeater),
          heardMs: 2000);
      final n = s.nodes[0x11]!;
      expect(n.name, 'Alpha'); // kept
      expect(n.lat, 38.0); // kept (entry had none)
      expect(n.nodeClass, nodeClassRepeater); // NEW known fact applied
      expect(n.lastHeardMs, 2000); // heard NOW
    });

    test('gone means gone - the dot is removed, honestly', () {
      final s = NodeStore();
      s.upsert(const NodeRecord(
          prefix: 0x33, name: 'Ghost', lastHeardMs: 1));
      expect(s.removeGone(0x33), isTrue);
      expect(s.nodes.containsKey(0x33), isFalse);
      expect(s.gonePending, [0x33]);
      expect(s.removeGone(0x33), isFalse); // nothing to erase twice
    });

    test('the marker only moves forward', () {
      final s = NodeStore();
      s.noteSyncMarker(10);
      s.noteSyncMarker(5);
      expect(s.syncMarker, 10);
    });

    test('labels: name + pubkey head (design section 8)', () {
      const named = NodeRecord(prefix: 0xab, name: 'Hilltop',
          lastHeardMs: 1);
      const nameless = NodeRecord(prefix: 0x3c, lastHeardMs: 1);
      expect(named.label, 'Hilltop ab');
      expect(nameless.label, 'node 3c');
    });
  });

  group('Grid re-cut - translate any held data to the chosen size', () {
    const frame60 = MapFrame(
        grid: 3, centerLat: 38.0, centerLon: -122.0, spanM: 60000);

    test('a node heard at 60 km draws correctly on a 20 km view', () {
      // 0.01 deg north is ~1113 m of real displacement. Zooming 60 ->
      // 20 km means the same node sits 3x FARTHER from center as a
      // fraction of the view - that is what zooming in IS. The real
      // place never moves; its fraction of the window does.
      final at60 = frame60.project(38.01, -122.0);
      final at20 = frame60.recut(20000).project(38.01, -122.0);
      expect(at60.y, closeTo(1113.2 / 60000, 1e-4));
      expect(at20.y, closeTo(1113.2 / 20000, 1e-4));
      expect(at20.y, closeTo(at60.y * 3, 1e-9));
      expect(at60.x, 0.0); // due north: no easting on either view
      expect(at20.x, 0.0);
    });

    test('sections are a property of the VIEW, not the node', () {
      const node = (lat: 38.20, lon: -122.0); // ~22 km north of center
      // On the 60 km view: inside, row 0 (north), middle column = 2.
      expect(frame60.sectionOf(node.lat, node.lon), 2);
      // On the 20 km view: the same node is OUTSIDE the window.
      expect(frame60.recut(20000).sectionOf(node.lat, node.lon), 0);
    });

    test('the center is always section 5 on a 3x3', () {
      expect(frame60.sectionOf(38.0, -122.0), 5);
    });
  });

  group('TcpLink - the door protocol (shapes from directclient.ts)', () {
    late TcpLink link;
    late FakeDoorSocket socket;
    late List<Object> packets;
    late List<String> logs;
    late List<(LinkState, String)> states;
    var resets = 0;

    setUp(() {
      packets = [];
      logs = [];
      states = [];
      resets = 0;
      socket = FakeDoorSocket();
      link = TcpLink(
        LinkEvents(
          onState: (s, d) => states.add((s, d)),
          onPacket: (p, {heardMs}) => packets.add(p),
          onLog: logs.add,
          onReset: () => resets++,
        ),
        host: '192.168.12.145',
        password: 'secret',
        socketFactory: () => socket,
        watchdogMs: 50,
        watchdogTickMs: 10, // injectable: the test can outwait it
      );
    });

    Future<void> dial() async {
      await link.connect();
      socket.onOpenFn!();
    }

    test('dials the door like the web app: bearer subprotocol carries the password', () async {
      await dial();
      expect(socket.openedUrl, 'ws://192.168.12.145:8710/feed');
      expect(socket.openedProtocols, ['bearer.secret']);
    });

    test('hello arms the link, seq regression triggers a reset, resume is sent', () async {
      await dial();
      socket.serverSays({'type': 'hello', 'proto': 6, 'last_seq': 500});
      expect(link.state, LinkState.connected);
      expect(states.last.$1, LinkState.connected);
      expect(
          socket.sent.any((s) => s.contains('"after_seq":0')), isTrue);
      socket.serverSays({
        'type': 'packet',
        'seq': 501,
        'wire': '0153170513017eb1d20404000900280009090305080200010406'
      });
      socket.serverSays({'type': 'hello', 'proto': 6, 'last_seq': 100});
      expect(resets, 1);
      expect(packets.length, 1); // the PULSE decoded from wire hex
      expect(packets.single, isA<Pulse>());
    });

    test('wire-hex packets decode through the SAME codec', () async {
      await dial();
      socket.serverSays({'type': 'hello', 'proto': 6, 'last_seq': 0});
      socket.serverSays({
        'type': 'packet',
        'seq': 1,
        'wire': '0253130504007eb101017e003000300300022102cdab'
      });
      final s = packets.single as SectSum;
      expect(s.sectionId, 1);
      expect(s.routeStubs, [0x0221, 0xabcd]);
    });

    test('duplicate resume packets are dropped, not re-shown', () async {
      await dial();
      socket.serverSays({'type': 'hello', 'proto': 6, 'last_seq': 0});
      const wire = '0353120502007eb101efbe38000400110003112233';
      socket.serverSays({'type': 'packet', 'seq': 7, 'wire': wire});
      socket.serverSays({'type': 'packet', 'seq': 7, 'wire': wire});
      expect(packets.length, 1);
    });

    test('refusal acks speak plain words (the v12 rule)', () async {
      await dial();
      socket.serverSays({'type': 'hello', 'proto': 6, 'last_seq': 0});
      socket.serverSays({
        'type': 'ack',
        'accepted': false,
        'reason': 'map_budget',
        'retry_after_s': 300
      });
      expect(logs.any((l) => l.contains('budget is spent')), isTrue);
      socket.serverSays({
        'type': 'ack',
        'accepted': false,
        'reason': 'cooldown',
        'retry_after_s': 12
      });
      expect(logs.any((l) => l.contains('one ask per 30s')), isTrue);
    });

    test('the watchdog ends a starved link (silent-drop law)', () async {
      await dial();
      socket.serverSays({'type': 'hello', 'proto': 6, 'last_seq': 0});
      await Future.delayed(const Duration(milliseconds: 120));
      expect(link.state, LinkState.disabled);
      expect(states.last.$2, 'link lost (no feed)');
    });

    test('doorUrl: bare host = port 8710, host:port respected', () {
      expect(TcpLink.doorUrl('192.168.12.145'),
          'ws://192.168.12.145:8710/feed');
      expect(TcpLink.doorUrl('hilltop.local:9000'),
          'ws://hilltop.local:9000/feed');
    });
  });
}
