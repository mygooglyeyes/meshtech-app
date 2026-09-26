// Route chapter tests (design section 10: tap = ask = answer):
// the store's route laws + the wire round-trip on the golden vector.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/map_model.dart';
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

  // ---------------------------------------- the lines the map draws
  // (the view-model decides; map_screen only paints. 2026-09-25
  // toggle: OFF hides the past/background lines, nothing else.)

  NodeStore twoRouteStore() {
    final s = NodeStore();
    s.upsert(const NodeRecord(
        prefix: 0x11, name: 'A', lat: 38.0, lon: -122.0,
        lastHeardMs: 1000));
    s.upsert(const NodeRecord(
        prefix: 0x22, name: 'B', lat: 38.1, lon: -122.1,
        lastHeardMs: 1000));
    s.upsert(const NodeRecord(
        prefix: 0x33, name: 'C', lat: 38.2, lon: -122.2,
        lastHeardMs: 1000));
    s.applyRoute(const Route(
        seq: 1, sectionId: 1, routeId: 7, packetCount: 4, delayMedS: 10,
        lastHeardMin: 1, prefixes: [0x11, 0x22]));
    s.applyRoute(const Route(
        seq: 1, sectionId: 1, routeId: 9, packetCount: 4, delayMedS: 10,
        lastHeardMin: 1, prefixes: [0x22, 0x33, 0x11]));
    return s;
  }

  test('route toggle: OFF hides ONLY the past lines - the tapped '
      'section keeps its own', () {
    final s = twoRouteStore();
    final on = MapViewModel.routeLines(s,
        highlightIds: {7}, showBackground: true);
    expect(on.background.length, 1); // route 9, the faint one
    expect(on.highlighted.length, 1); // route 7, the tapped section's
    expect(on.background.single.length, 3);

    final off = MapViewModel.routeLines(s,
        highlightIds: {7}, showBackground: false);
    expect(off.background, isEmpty); // the past lines are hidden
    expect(off.highlighted.length, 1); // ...and the tap's lines STAY
    // (lon, lat) pairs, in the wire's travel order.
    expect(off.highlighted.single, [(-122.0, 38.0), (-122.1, 38.1)]);
  });

  test('an unknown hop is an honest gap - the line splits, it never '
      'invents a position', () {
    final s = NodeStore();
    s.upsert(const NodeRecord(
        prefix: 0x11, name: 'A', lat: 38.0, lon: -122.0,
        lastHeardMs: 1000));
    s.upsert(const NodeRecord(
        prefix: 0x33, name: 'C', lat: 38.2, lon: -122.2,
        lastHeardMs: 1000));
    s.upsert(const NodeRecord(
        prefix: 0x22, name: 'NoFix', lastHeardMs: 1000)); // no position
    s.applyRoute(const Route(
        seq: 1, sectionId: 1, routeId: 5, packetCount: 4, delayMedS: 10,
        lastHeardMin: 1, prefixes: [0x11, 0x22, 0x33, 0x11]));
    final lines = MapViewModel.routeLines(s,
        highlightIds: const {}, showBackground: true);
    expect(lines.background.length, 1); // the lone A leg is too short
    expect(lines.background.single.length, 2); // C -> A, after the gap
  });

  // ------------------ the section detail page's NAMED lines
  // (Brett, 2026-09-25): a tap on the map must be able to say WHICH
  // route line it hit - so the lines travel per-route, hot flagged.

  test('routeLayers names every drawn route - warm or faint - and '
      'the page toggle keeps only the warm ones', () {
    final s = twoRouteStore();
    final layers = MapViewModel.routeLayers(s,
        highlightIds: {7}, showBackground: true);
    expect(layers.length, 2);
    final byId = {for (final l in layers) l.routeId: l};
    expect(byId[7]!.hot, isTrue); // the open section's summary's route
    expect(byId[9]!.hot, isFalse); // the faint background
    // (lon, lat) in the wire's travel order, gaps split.
    expect(byId[7]!.segs.single, [(-122.0, 38.0), (-122.1, 38.1)]);

    // The detail page's OWN toggle: background OFF leaves exactly
    // the summary's warm lines (the main map's toggle is separate).
    final off = MapViewModel.routeLayers(s,
        highlightIds: {7}, showBackground: false);
    expect(off.map((l) => l.routeId).toList(), [7]);
  });

  test('distToSegment: straight-line distance - perpendicular, and '
      'the nearest end once the tap is past the segment', () {
    expect(MapViewModel.distToSegment(5, 3, 0, 0, 10, 0), 3); // across
    expect(MapViewModel.distToSegment(-4, 0, 0, 0, 10, 0), 4); // past A
    expect(MapViewModel.distToSegment(14, 0, 0, 0, 10, 0), 4); // past B
    expect(MapViewModel.distToSegment(3, 4, 3, 4, 3, 4), 0); // degenerate
  });

  test('the tap pick: the NEAREST line inside the tolerance wins, a '
      'tap on empty map selects nothing (nothing sticks)', () {
    final segs = <int, List<List<(double, double)>>>{
      7: [
        [(0.0, 0.0), (10.0, 0.0)],
      ],
      9: [
        [(0.0, 20.0), (10.0, 20.0)],
      ],
    };
    expect(MapViewModel.routeIdNear(segs, (5.0, 3.0), 6.0), 7);
    expect(MapViewModel.routeIdNear(segs, (5.0, 17.0), 6.0), 9);
    // Both inside the tolerance: the NEARER one wins.
    expect(MapViewModel.routeIdNear(segs, (5.0, 13.0), 10.0), 9);
    // An honest miss - far from every line.
    expect(MapViewModel.routeIdNear(segs, (50.0, 50.0), 6.0), isNull);
    // Nothing drawn: nothing can be selected.
    expect(MapViewModel.routeIdNear(const {}, (5.0, 3.0), 6.0), isNull);
  });
}
