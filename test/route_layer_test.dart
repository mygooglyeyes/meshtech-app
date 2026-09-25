// Route chapter tests (design section 10: tap = ask = answer):
// the store's route laws + the wire round-trip on the golden vector.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/store.dart';

const routeWire =
    '0353120502007eb101efbe38000400110003112233';

Uint8List bytesOf(String hex) => Uint8List.fromList([
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

void main() {
  test('the golden ROUTE decodes: hops in travel order (1-byte prefixes)',
      () {
    final r = decodeRoute(bytesOf(routeWire).sublist(3));
    expect(r.sectionId, 1);
    expect(r.routeId, 0xbeef);
    expect(r.packetCount, 56); // bytes 38 00 LE
    expect(r.delayMedS, 4); // bytes 04 00 LE
    expect(r.lastHeardMin, 17); // bytes 11 00 LE
    expect(r.prefixes, [0x11, 0x22, 0x33]); // travel order
  });

  test("the store's route law: the newest answer for a route IS the route",
      () {
    final s = NodeStore();
    s.applyRoute(const Route(
        seq: 1, sectionId: 1, routeId: 7, packetCount: 4, delayMedS: 10,
        lastHeardMin: 1, prefixes: [0x11, 0x22]));
    s.applyRoute(const Route(
        seq: 2, sectionId: 1, routeId: 7, packetCount: 9, delayMedS: 12,
        lastHeardMin: 1, prefixes: [0x11, 0x33]));
    expect(s.routes.length, 1); // ONE route, not two
    expect(s.route(7)!.packetCount, 9); // the NEW answer replaced it
    expect(s.route(7)!.prefixes, [0x11, 0x33]);
  });

  test('a reset (node restarted) forgets routes with everything else',
      () {
    final s = NodeStore();
    s.applyRoute(const Route(
        seq: 1, sectionId: 1, routeId: 7, packetCount: 4, delayMedS: 10,
        lastHeardMin: 1, prefixes: [0x11, 0x22]));
    s.resetAll();
    expect(s.routes, isEmpty);
  });

  test("Brett's fade law on the phone: a past-DEAD route is never taken back", () {
    final s = NodeStore();
    // a DIRECT route (one hop) silent 8 days: dead (7-day line) -> dropped
    s.applyRoute(const Route(
        seq: 1, sectionId: 1, routeId: 7, packetCount: 4, delayMedS: 10,
        lastHeardMin: 8 * 1440, prefixes: [0x11]));
    expect(s.routes, isEmpty);
    // the same route heard 4 days ago: alive, kept
    s.applyRoute(const Route(
        seq: 1, sectionId: 1, routeId: 7, packetCount: 4, delayMedS: 10,
        lastHeardMin: 4 * 1440, prefixes: [0x11]));
    expect(s.routes.length, 1);
    // a MULTI-HOP route silent 8 days: only STALE (7-day line), kept
    s.applyRoute(const Route(
        seq: 2, sectionId: 1, routeId: 9, packetCount: 4, delayMedS: 10,
        lastHeardMin: 8 * 1440, prefixes: [0x11, 0x22]));
    expect(s.route(9), isNotNull);
    // a MULTI-HOP route silent 15 days: dead (14-day line) -> dropped
    s.applyRoute(const Route(
        seq: 2, sectionId: 1, routeId: 10, packetCount: 4, delayMedS: 10,
        lastHeardMin: 15 * 1440, prefixes: [0x11, 0x33]));
    expect(s.route(10), isNull);
  });
}
