// THE MAIN PAGE (Brett's layout chapter, 2026-09-25): four section
// bars - Connection, Map/List, Feed health, Logs - each folding its
// own body on a header tap, and the header's switch swapping map for
// list (the Routes tab rides along, never lost). THE PAGE SWIPES
// ("swipe", 2026-09-25): one tall scrollable stack; the map keeps
// its ONE measured height, and closing a section slides home.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshtech_app/main_page.dart';
import 'package:meshtech_app/settings.dart';
import 'package:meshtech_app/store.dart';

Widget _page() => MaterialApp(
      home: MainPage(
        store: NodeStore(),
        settings: const ConnectionSettings(),
        onDisconnect: () {},
        onAsk: () {},
        onMapSizeChange: (_) {},
        onSectionTap: (_) {},
        // The test seam: no live map engine in widget tests.
        mapBuilder: (_) => const SizedBox(key: Key('fake-map')),
      ),
    );

/// Pump the page, then one more frame: the map's height is measured
/// after the first frame (one-time), and the map only exists from
/// the frame after that.
Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(_page());
  await tester.pump();
}

double _mapH(WidgetTester tester) =>
    tester.getSize(find.byKey(const Key('fake-map'))).height;

void main() {
  testWidgets('four section bars; feed health folds on a header tap',
      (tester) async {
    await _pumpPage(tester);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Feed health'), findsOneWidget);
    expect(find.text('Logs'), findsOneWidget);
    expect(find.byKey(const Key('fake-map')), findsOneWidget);
    expect(find.text('waiting for the first pulse'), findsOneWidget);

    // Tap the Feed health bar: the body folds, the bar stays (+ -> -).
    await tester.tap(find.text('Feed health'));
    await tester.pumpAndSettle();
    expect(find.text('waiting for the first pulse'), findsNothing);
    expect(find.text('Feed health'), findsOneWidget);

    // Tap again: the body returns.
    await tester.tap(find.text('Feed health'));
    await tester.pumpAndSettle();
    expect(find.text('waiting for the first pulse'), findsOneWidget);
  });

  testWidgets('the header switch swaps map for the list and back',
      (tester) async {
    await _pumpPage(tester);
    expect(find.byKey(const Key('fake-map')), findsOneWidget);

    await tester.tap(find.byIcon(Icons.list));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fake-map')), findsNothing);
    expect(find.text('List'), findsOneWidget); // the section bar
    expect(find.text('Nodes (0)'), findsOneWidget);
    expect(find.text('Routes (0)'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.map));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fake-map')), findsOneWidget);
    expect(find.text('Map'), findsOneWidget);
  });

  testWidgets('the map frame keeps ONE height; swiping never resizes it',
      (tester) async {
    await _pumpPage(tester);
    final before = _mapH(tester);
    expect(before, greaterThan(0));

    // Open Logs (below the map): the frame must not budge - the
    // distortion Brett caught needs a resize to happen at all.
    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();
    expect(_mapH(tester), before);

    // Swipe the WHOLE page up with the finger: same height, it only
    // moves on screen.
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(_mapH(tester), before);

    // Back to the top, fold the map's own bar: height is gone, not
    // squeezed.
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fake-map')), findsNothing);

    // Back open: the SAME height returns.
    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
    expect(_mapH(tester), before);
  });

  testWidgets('closing a section slides the page home by itself',
      (tester) async {
    await _pumpPage(tester);
    final scroll = find.byType(SingleChildScrollView);
    double offset() => tester.widget<SingleChildScrollView>(scroll).controller!.offset;

    // Swipe down the page (open Logs first so there is room).
    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();
    await tester.drag(scroll, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(offset(), greaterThan(0));

    // Close the Logs bar: the page returns to the top on its own.
    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();
    expect(offset(), 0);
    expect(find.text('Logs'), findsOneWidget); // the bar stays
  });
}
