// BRETT'S ROUTE-LINE LAW (2026-10-01): a route line stops partway
// (75% toward the NEXT node), chevrons say which way the packets
// move (out by the end being sent to, in at a dot, one at each end
// when both ways = the same trail heard reversed), and no line end
// ever leaves the page. The far node's name labels the line's end
// ONLY for the tapped route (Brett, 2026-10-02). The honest-gap
// rule stands: an unknown hop breaks the line.

import 'package:flutter/widgets.dart' hide Route; // the wire's Route
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/detail_screen.dart';
import 'package:meshtech_app/map_model.dart';
import 'package:meshtech_app/store.dart';

NodeStore _store({required int nowMs}) {
  final s = NodeStore();
  s.upsert(NodeRecord(
      prefix: 0x21,
      name: 'Hilltop',
      lat: 38.0,
      lon: -122.0,
      lastHeardMs: nowMs));
  s.upsert(NodeRecord(
      prefix: 0x22,
      name: 'Alice',
      lat: 38.0,
      lon: -121.99,
      lastHeardMs: nowMs));
  s.upsert(NodeRecord(
      prefix: 0x23, name: 'Bob', lat: 38.0, lon: -121.98, lastHeardMs: nowMs));
  return s;
}

Route _route(int id, List<int> prefixes) => Route(
    seq: 1,
    sectionId: 1,
    routeId: id,
    packetCount: 3,
    delayMedS: 2,
    lastHeardMin: 1,
    prefixes: prefixes);

void main() {
  final nowMs = DateTime.now().millisecondsSinceEpoch;

  group('the route-line law', () {
    test('each line stops at 75% toward the next node, name at the end',
        () {
      final s = _store(nowMs: nowMs);
      s.applyRoute(_route(7, [0x21, 0x22]), heardMs: nowMs);
      final edges =
          MapViewModel.routeEdges(s, highlightIds: {7}, showBackground: false);
      expect(edges, hasLength(1));
      final e = edges.single;
      // 75% of the way Hilltop -> Alice (the lon gap is 0.01).
      expect(e.stop.$1, closeTo(-122.0 + 0.0075, 1e-9));
      expect(e.stop.$2, closeTo(38.0, 1e-9));
      // ...and the NEXT node's name labels the line's end.
      expect(e.toName, s.nodes[0x22]!.label);
    });

    test('a line end that would leave the page stays on the page', () {
      final s = _store(nowMs: nowMs);
      s.applyRoute(_route(7, [0x21, 0x23]), heardMs: nowMs); // 0.02 apart
      final edges = MapViewModel.routeEdges(s,
          highlightIds: {7},
          showBackground: false,
          bounds: (-122.01, 37.99, -121.995, 38.01)); // page ends mid-way
      final e = edges.single;
      expect(e.stop.$1, lessThan(-121.995)); // on the page, past its start
      expect(e.stop.$1, greaterThan(-122.0));
    });

    test('chevrons: out by the name, in at the dot, both ends when both ways',
        () {
      final s = _store(nowMs: nowMs);
      s.applyRoute(_route(7, [0x21, 0x22]), heardMs: nowMs);
      var e = MapViewModel.routeEdges(s,
              highlightIds: {7}, showBackground: false)
          .single;
      expect(e.outArrow, isTrue); // the node sends: by the name end
      expect(e.inArrowTo, isTrue); // packets land at the next dot
      expect(e.inArrowFrom, isFalse); // one way: nothing at the sending dot
      expect(e.bothWays, isFalse);
      // The same trail heard reversed = both ways: one at each end.
      s.applyRoute(_route(8, [0x22, 0x21]), heardMs: nowMs);
      e = MapViewModel.routeEdges(s, highlightIds: {7}, showBackground: false)
          .single;
      expect(e.bothWays, isTrue);
      expect(e.inArrowFrom, isTrue);
    });

    test('the honest gap: an unknown hop breaks the line', () {
      final s = _store(nowMs: nowMs);
      s.applyRoute(_route(7, [0x21, 0x40, 0x23]), heardMs: nowMs); // 0x40 ?
      final edges =
          MapViewModel.routeEdges(s, highlightIds: {7}, showBackground: false);
      expect(edges, isEmpty); // never an invented position
    });

    test('bearing: due east is 90 degrees on a north-up screen', () {
      final s = _store(nowMs: nowMs);
      s.applyRoute(_route(7, [0x21, 0x22]), heardMs: nowMs);
      final e =
          MapViewModel.routeEdges(s, highlightIds: {7}, showBackground: false)
              .single;
      expect(e.bearingDeg, closeTo(90.0, 0.5));
    });

    test('the toggle: background lines off hides un-highlighted edges', () {
      final s = _store(nowMs: nowMs);
      s.applyRoute(_route(7, [0x21, 0x22]), heardMs: nowMs);
      expect(
          MapViewModel.routeEdges(s,
              highlightIds: const {}, showBackground: false),
          isEmpty);
    });

    test('a section draws only the lines that come to or leave its '
        'listed nodes', () {
      final s = _store(nowMs: nowMs);
      // Two neighbours the section does NOT list, east of Bob.
      s.upsert(NodeRecord(
          prefix: 0x24,
          name: 'Far1',
          lat: 38.0,
          lon: -121.97,
          lastHeardMs: nowMs));
      s.upsert(NodeRecord(
          prefix: 0x25,
          name: 'Far2',
          lat: 38.0,
          lon: -121.96,
          lastHeardMs: nowMs));
      // The section lists Bob (0x23) alone - the page's own list
      // rule (SectionCell.contains), and zooming never changes it.
      const cell = SectionCell(
          id: 5,
          centerLat: 38.0,
          centerLon: -121.98,
          spanLatM: 1000,
          spanLonM: 1000);
      // A trail through the section: in from Far1, out to Far2.
      s.applyRoute(_route(9, [0x24, 0x23, 0x25]), heardMs: nowMs);
      // ...and a hop between the two unlisted neighbours.
      s.applyRoute(_route(10, [0x24, 0x25]), heardMs: nowMs);
      final edges = MapViewModel.routeEdges(s,
          highlightIds: {9, 10}, showBackground: false, listedIn: cell);
      // The incoming leg (unlisted -> listed) and the outgoing leg
      // (listed -> unlisted) draw; the unlisted hop does not.
      expect(edges, hasLength(2));
      expect([for (final e in edges) e.routeId], [9, 9]);
      expect(edges[0].from.$1, closeTo(-121.97, 1e-9)); // Far1 -> Bob
      expect(edges[1].to.$1, closeTo(-121.96, 1e-9)); // Bob -> Far2
      // With no section's list (the node page map), all draw.
      expect(
          MapViewModel.routeEdges(s,
              highlightIds: {9, 10}, showBackground: false),
          hasLength(3));
    });

    test('the far-node name shows only for the tapped route', () {
      final s = _store(nowMs: nowMs);
      s.applyRoute(_route(7, [0x21, 0x22]), heardMs: nowMs);
      s.applyRoute(_route(8, [0x22, 0x23]), heardMs: nowMs);
      final edges = MapViewModel.routeEdges(s,
          highlightIds: {7, 8}, showBackground: false);
      List<String> names(List<Marker> ms) => [
            for (final m in ms)
              if (m.child is Text) (m.child as Text).data ?? '',
          ];
      // Nothing tapped: no names anywhere (the node page map lives
      // here) - but the lines keep their chevrons.
      expect(names(routeEdgeMarkers(edges)), isEmpty);
      expect(routeEdgeMarkers(edges), isNotEmpty);
      // Route 7 tapped: only ITS far node's name...
      expect(names(routeEdgeMarkers(edges, selectedRoute: 7)),
          [s.nodes[0x22]!.label]);
      // ...and tapping route 8 moves the name to its line's end.
      expect(names(routeEdgeMarkers(edges, selectedRoute: 8)),
          [s.nodes[0x23]!.label]);
    });
  });
}
