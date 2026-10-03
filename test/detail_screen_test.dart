// THE NODE / ROUTE DETAIL PAGE (Brett, 2026-09-30): the lists' rows
// open this page - the node (or route) and its clinic data, with a
// BACK button back to the list. The route page leads with a visual
// of its trail's nodes, with names and details underneath (his
// words). LISTS ONLY - the map's pop-up cards are unchanged.

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';

import 'package:meshtech_app/clinic_store.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/detail_screen.dart';
import 'package:meshtech_app/store.dart';

NodeStore _store() {
  final s = NodeStore();
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  s.upsert(NodeRecord(
      prefix: 0x21, name: 'Hilltop', lat: 38.0, lon: -122.0,
      lastHeardMs: nowMs));
  s.upsert(NodeRecord(
      prefix: 0x22, name: 'Petaluma', lat: 38.1, lon: -122.1,
      lastHeardMs: nowMs));
  return s;
}

void main() {
  testWidgets('the node page: identity, clinic data, and a back '
      'button to the list', (tester) async {
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      home: NodeDetailScreen(
        store: _store(),
        clinic: ClinicStore(),
        prefix: 0x21,
        onClose: () => closed = true,
        mapBuilder: (_) => const SizedBox(key: Key('fake-node-map')),
      ),
    ));
    expect(find.text('Hilltop'), findsOneWidget); // the title = the name
    // THE NODE'S OWN ROUTE MAP on top (Brett, 2026-10-01).
    expect(find.byKey(const Key('fake-node-map')), findsOneWidget);
    expect(find.textContaining('Hilltop \u00b7 38.000, -122.000'),
        findsOneWidget); // the name leads, no prefix
    expect(find.textContaining('NO POSITION'), findsNothing);
    expect(find.textContaining('prefix 21'), findsNothing);
    // its clinic data underneath - honest gaps (nothing folded yet)
    expect(find.textContaining('not measured yet'), findsWidgets);
    await tester.tap(find.byKey(const Key('detail-back')));
    await tester.pump();
    expect(closed, isTrue); // back = back to the list
  });

  testWidgets('the route page: a visual of its trail nodes, names '
      'and details underneath, then the clinic data', (tester) async {
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      home: RouteDetailScreen(
        store: _store(),
        clinic: ClinicStore(),
        route: Route(
            seq: 1,
            sectionId: 5,
            routeId: 77,
            packetCount: 4,
            delayMedS: 12,
            lastHeardMin: 5,
            prefixes: [0x21, 0x22]),
        onClose: () => closed = true,
      ),
    ));
    // NAMED BY ITS HOPS (Brett 2026-10-02), not by wire id.
    expect(find.text('route Hilltop-Petaluma'), findsOneWidget);
    // the VISUAL: both trail nodes drawn (0x21 = 33, 0x22 = 34)
    expect(find.byKey(const Key('trail-hop-33')), findsOneWidget);
    expect(find.byKey(const Key('trail-hop-34')), findsOneWidget);
    expect(find.byKey(const Key('trail-name-33')), findsOneWidget);
    // names and details underneath (names lead - Brett 2026-10-02)
    expect(find.textContaining('Hilltop \u00b7 38.000, -122.000'),
        findsOneWidget);
    expect(find.textContaining('Petaluma \u00b7 38.100, -122.100'),
        findsOneWidget);
    expect(find.textContaining('NO NAME'), findsNothing);
    expect(find.textContaining('prefix'), findsNothing); // named hops
    expect(find.textContaining('2 hop(s)'), findsOneWidget);
    // and the clinic data
    expect(find.textContaining('not measured yet'), findsWidgets);
    await tester.tap(find.byKey(const Key('detail-back')));
    await tester.pump();
    expect(closed, isTrue);
  });

  testWidgets('an unknown hop stays honestly unnamed - never '
      'invented', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: RouteDetailScreen(
        store: _store(),
        clinic: ClinicStore(),
        route: Route(
            seq: 1,
            sectionId: 5,
            routeId: 88,
            packetCount: 1,
            delayMedS: 0,
            lastHeardMin: 5,
            prefixes: [0x99]),
        onClose: () {},
      ),
    ));
    // 0x99 = 153: drawn, but the store knows nothing about it
    expect(find.byKey(const Key('trail-hop-153')), findsOneWidget);
    // No name in the store = the node's own hex key, never invented.
    expect(find.text('prefix 99'), findsOneWidget); // the trail label
    expect(find.textContaining('prefix 99 - nothing heard about it yet'),
        findsOneWidget);
  });

  test("a node's line says its NAME - the prefix only when no name "
      'is known', () {
    final s = _store();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    s.upsert(NodeRecord(
        prefix: 0x24, lat: 38.2, lon: -122.2,
        lastHeardMs: nowMs)); // never named
    expect(nodeIdentity(s, 0x21, nowMs: nowMs), startsWith('Hilltop \u00b7'));
    expect(nodeIdentity(s, 0x24, nowMs: nowMs),
        startsWith('prefix 24 \u00b7'));
    expect(nodeIdentity(s, 0x99, nowMs: nowMs),
        'prefix 99 - nothing heard about it yet');
  });
}
