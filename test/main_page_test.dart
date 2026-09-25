// THE MAIN PAGE (Brett's layout chapter, 2026-09-25): four section
// bars - Connection, Map/List, Feed health, Logs - each folding its
// own body on a header tap, and the header's switch swapping map for
// list (the Routes tab rides along, never lost).

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
        onDotTap: (_) {},
        // The test seam: no live map engine in widget tests.
        mapBuilder: (_) => const SizedBox(key: Key('fake-map')),
      ),
    );

void main() {
  testWidgets('four section bars; feed health folds on a header tap',
      (tester) async {
    await tester.pumpWidget(_page());
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Feed health'), findsOneWidget);
    expect(find.text('Logs'), findsOneWidget);
    expect(find.byKey(const Key('fake-map')), findsOneWidget);
    expect(find.text('waiting for the first pulse'), findsOneWidget);

    // Tap the Feed health bar: the body folds, the bar stays (+ -> -).
    await tester.tap(find.text('Feed health'));
    await tester.pump();
    expect(find.text('waiting for the first pulse'), findsNothing);
    expect(find.text('Feed health'), findsOneWidget);

    // Tap again: the body returns.
    await tester.tap(find.text('Feed health'));
    await tester.pump();
    expect(find.text('waiting for the first pulse'), findsOneWidget);
  });

  testWidgets('the header switch swaps map for the list and back',
      (tester) async {
    await tester.pumpWidget(_page());
    expect(find.byKey(const Key('fake-map')), findsOneWidget);

    await tester.tap(find.byIcon(Icons.list));
    await tester.pump();
    expect(find.byKey(const Key('fake-map')), findsNothing);
    expect(find.text('List'), findsOneWidget);   // the section bar
    expect(find.text('Nodes (0)'), findsOneWidget);
    expect(find.text('Routes (0)'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.map));
    await tester.pump();
    expect(find.byKey(const Key('fake-map')), findsOneWidget);
    expect(find.text('Map'), findsOneWidget);
  });
}
