// THE SECTION DETAIL PAGE (Brett, 2026-09-25): the page's own bar
// (back, section name, route toggle), its honest stats line, and the
// closing rules - pumped with the mapBuilder seam, so no live map
// engine is needed (the same seam MainPage's tests use).

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';

import 'package:meshtech_app/clinic_store.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/map_model.dart';
import 'package:meshtech_app/section_screen.dart';
import 'package:meshtech_app/store.dart';

// The square that was tapped: number 5 (its section id) and the
// geography the page's camera parks on.
const _cell = SectionCell(
    id: 5, centerLat: 38.0, centerLon: -122.0,
    spanLatM: 15000, spanLonM: 20000);

Widget _page({SectSum? summary, VoidCallback? onClose, NodeStore? store}) =>
    MaterialApp(
      home: SectionScreen(
        store: store ?? NodeStore(),
        clinic: ClinicStore(),
        cell: _cell,
        summary: summary,
        onClose: onClose ?? () {},
        // The test seam: no live map engine in widget tests.
        mapBuilder: (_) => const SizedBox(key: Key('fake-sect-map')),
      ),
    );

void main() {
  testWidgets('the page names its section and waits honestly for its '
      'own summary', (tester) async {
    await tester.pumpWidget(_page());
    expect(find.text('Section 5'), findsOneWidget);
    expect(find.text('section 5 - waiting for its summary'), findsOneWidget);
    expect(find.byKey(const Key('fake-sect-map')), findsOneWidget);
  });

  testWidgets("a summary's numbers show verbatim on the stats line",
      (tester) async {
    await tester.pumpWidget(_page(
        summary: const SectSum(
            seq: 1,
            sectionId: 5,
            activeNodes: 4,
            packetCount: 120,
            delayP50S: 3,
            delayP90S: 9)));
    expect(find.text('section 5 - 4 active - 120 pkt - p50 3s - p90 9s'),
        findsOneWidget);
  });

  testWidgets('the back arrow closes the page; the route toggle is '
      "this page's OWN and never sticks", (tester) async {
    var closed = false;
    await tester.pumpWidget(_page(onClose: () => closed = true));
    await tester.tap(find.byKey(const Key('section-back')));
    await tester.pump();
    expect(closed, isTrue);

    IconButton toggle() =>
        tester.widget<IconButton>(find.byKey(const Key('section-routes')));
    // Starts OFF (dim icon): the faint lines are hidden - push to
    // SEE (Brett, 2026-09-29).
    expect((toggle().icon as Icon).color, Colors.white38);
    await tester.tap(find.byKey(const Key('section-routes')));
    await tester.pump();
    expect((toggle().icon as Icon).color, Colors.white); // shown
    await tester.tap(find.byKey(const Key('section-routes')));
    await tester.pump();
    expect((toggle().icon as Icon).color, Colors.white38); // hidden again
  });

  testWidgets("the list option (the main page's own) swaps in this "
      "square's rows - and a row opens the health card", (tester) async {
    final store = NodeStore();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    store.upsert(NodeRecord(
        prefix: 0x21, name: 'Hilltop', lat: 38.0, lon: -122.0,
        lastHeardMs: nowMs));
    store.upsert(NodeRecord(
        prefix: 0x22, name: 'Faraway', lat: 30.0, lon: -100.0,
        lastHeardMs: nowMs));
    await tester.pumpWidget(_page(store: store));
    expect(find.byKey(const Key('fake-sect-map')), findsOneWidget);
    await tester.tap(find.byKey(const Key('section-list')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fake-sect-map')), findsNothing);
    expect(find.text('Hilltop'), findsOneWidget); // this square's node
    expect(find.text('Faraway'), findsNothing); // not this square's
    // a row tap opens the same health card the map does - proven by
    // its honest gap rows (this store holds no clinic facts yet)
    await tester.tap(find.text('Hilltop'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not measured yet'), findsWidgets);
  });

  testWidgets('the list scopes its routes to the square too, and the '
      'switch flips back to the map', (tester) async {
    final store = NodeStore();
    store.applyRoute(Route(
        seq: 1, sectionId: 5, routeId: 77, packetCount: 4,
        delayMedS: 12, lastHeardMin: 5, prefixes: [0x11, 0x12]));
    store.applyRoute(Route(
        seq: 2, sectionId: 6, routeId: 88, packetCount: 2,
        delayMedS: 8, lastHeardMin: 5, prefixes: [0x13, 0x14]));
    await tester.pumpWidget(_page(store: store));
    await tester.tap(find.byKey(const Key('section-list')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Routes'));
    await tester.pumpAndSettle();
    expect(find.text('route 77'), findsOneWidget); // this square
    expect(find.text('route 88'), findsNothing); // not this square
    await tester.tap(find.byKey(const Key('section-list')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fake-sect-map')), findsOneWidget);
  });
}
