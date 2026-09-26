// THE SECTION DETAIL PAGE (Brett, 2026-09-25): the page's own bar
// (back, section name, route toggle), its honest stats line, and the
// closing rules - pumped with the mapBuilder seam, so no live map
// engine is needed (the same seam MainPage's tests use).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/map_model.dart';
import 'package:meshtech_app/section_screen.dart';
import 'package:meshtech_app/store.dart';

// The square that was tapped: number 5 (its section id) and the
// geography the page's camera parks on.
const _cell = SectionCell(
    id: 5, centerLat: 38.0, centerLon: -122.0,
    spanLatM: 15000, spanLonM: 20000);

Widget _page({SectSum? summary, VoidCallback? onClose}) => MaterialApp(
      home: SectionScreen(
        store: NodeStore(),
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
    // Starts ON (bright icon): the background lines are shown.
    expect((toggle().icon as Icon).color, Colors.white);
    await tester.tap(find.byKey(const Key('section-routes')));
    await tester.pump();
    expect((toggle().icon as Icon).color, Colors.white38); // hidden
    await tester.tap(find.byKey(const Key('section-routes')));
    await tester.pump();
    expect((toggle().icon as Icon).color, Colors.white); // shown again
  });
}
