// THE SECTION DETAIL PAGE (Brett, 2026-09-25): the page's own bar
// (back, section name, route toggle), its honest stats line, and the
// closing rules - pumped with the mapBuilder seam, so no live map
// engine is needed (the same seam MainPage's tests use).

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';

import 'package:meshtech_app/clinic_store.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/map_model.dart';
import 'package:meshtech_app/map_screen.dart' show MapScreen;
import 'package:meshtech_app/section_screen.dart';
import 'package:meshtech_app/store.dart';

// The square that was tapped: number 5 (its section id) and the
// geography the page's camera parks on.
const _cell = SectionCell(
    id: 5, centerLat: 38.0, centerLon: -122.0,
    spanLatM: 15000, spanLonM: 20000);

Widget _page(
        {SectSum? summary,
        VoidCallback? onClose,
        NodeStore? store,
        ClinicView? clinicView,
        int clinicWindowMin = 0,
        double initZoom = 9,
        ValueChanged<int>? onNodeTap,
        ValueChanged<Route>? onRouteTap}) =>
    MaterialApp(
      home: SectionScreen(
        store: store ?? NodeStore(),
        clinic: ClinicStore(),
        cell: _cell,
        initZoom: initZoom,
        summary: summary,
        clinicView: clinicView,
        clinicWindowMin: clinicWindowMin,
        onClose: onClose ?? () {},
        onNodeTap: onNodeTap ?? (_) {},
        onRouteTap: onRouteTap ?? (_) {},
        // The test seam: no live map engine in widget tests.
        mapBuilder: (_) => const SizedBox(key: Key('fake-sect-map')),
      ),
    );

void main() {
  testWidgets('from the Clinic flow the back button NAMES the clinic '
      'page - never a lie about where it goes', (tester) async {
    await tester.pumpWidget(_page());
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('section-back')))
            .tooltip,
        'Back to the map');
    await tester.pumpWidget(
        _page(clinicView: ClinicView.trouble, clinicWindowMin: 240));
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('section-back')))
            .tooltip,
        'Back to the clinic page');
  });

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
      "square's rows - and a row hands its node up to the detail "
      'page', (tester) async {
    final store = NodeStore();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    store.upsert(NodeRecord(
        prefix: 0x21, name: 'Hilltop', lat: 38.0, lon: -122.0,
        lastHeardMs: nowMs));
    store.upsert(NodeRecord(
        prefix: 0x22, name: 'Faraway', lat: 30.0, lon: -100.0,
        lastHeardMs: nowMs));
    final tapped = <int>[];
    await tester.pumpWidget(_page(store: store, onNodeTap: tapped.add));
    expect(find.byKey(const Key('fake-sect-map')), findsOneWidget);
    await tester.tap(find.byKey(const Key('section-list')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fake-sect-map')), findsNothing);
    expect(find.text('Hilltop'), findsOneWidget); // this square's node
    expect(find.text('Faraway'), findsNothing); // not this square's
    // a row tap hands the node to the shell's detail page (Brett,
    // 2026-09-30) - the page itself is pinned in detail_screen_test
    await tester.tap(find.text('Hilltop'));
    await tester.pump();
    expect(tapped, [0x21]);
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
    // Named by its hops (Brett 2026-10-02): the store knows nothing
    // about 11/12, so the honest hex fallback leads each hop.
    expect(find.text('route 11-12'), findsOneWidget); // this square
    expect(find.text('route 13-14'), findsNothing); // not this square
    await tester.tap(find.byKey(const Key('section-list')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fake-sect-map')), findsOneWidget);
  });

  testWidgets('the page opens at the MAIN map\'s current zoom - never '
      'fit-to-the-square (Brett, 2026-10-02)', (tester) async {
    // The shell passes MapScreen.zoomFor(settings.mapSizeKm): the
    // 60 km main view (z9) opens this page at z9 too, so the whole
    // square's neighborhood - edge nodes included - is in view.
    expect(MapScreen.zoomFor(60), 9);
    expect(MapScreen.zoomFor(40), 10);
    expect(MapScreen.zoomFor(20), 11);
    await tester.pumpWidget(_page(initZoom: 11));
    final page = tester.widget<SectionScreen>(find.byType(SectionScreen));
    expect(page.initZoom, 11); // the zoom arrives from outside
  });
}
