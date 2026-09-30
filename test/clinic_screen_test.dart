// THE CLINIC PAGE (Brett, 2026-09-30): the clinic chips, the time
// window and the section list live OFF the map now - this page is
// what the map's +clinic button opens. Its laws: the chips hand the
// choice up (the shell keeps it alive over the section round trip),
// the sections are the map's own numbers in BIGGER font, the honest
// strip says what the chosen family holds and what has no place,
// and the back button closes the page.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/clinic_screen.dart';
import 'package:meshtech_app/clinic_store.dart';
import 'package:meshtech_app/codec.dart';
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
  return s;
}

ClinicStore _clinic(int nowMs, List<Object> records) {
  final c = ClinicStore();
  c.fold(Clinic(seq: 1, origin: 0xb17e, records: records), heardMs: nowMs);
  return c;
}

ClinicNodeFact _chart({int source = 0xb17e, int prefix = 0x21}) =>
    ClinicNodeFact(
        source: source,
        prefix: prefix,
        lastAgeMin: 3,
        ageDays: 5,
        strip: 0x800007,
        hopsTyp: 2,
        sharePct: 37);

Future<void> _pump(WidgetTester tester,
    {required ClinicStore clinic,
    required NodeStore store,
    ClinicView view = ClinicView.nodes,
    int windowMin = 1440,
    ValueChanged<ClinicView>? onView,
    ValueChanged<int>? onWindow,
    ValueChanged<int>? onPick,
    VoidCallback? onClose}) async {
  await tester.pumpWidget(MaterialApp(
    home: ClinicScreen(
      clinic: clinic,
      store: store,
      view: view,
      windowMin: windowMin,
      onView: onView ?? (_) {},
      onWindow: onWindow ?? (_) {},
      onPick: onPick ?? (_) {},
      onClose: onClose ?? () {},
    ),
  ));
}

void main() {
  final nowMs = DateTime.now().millisecondsSinceEpoch;

  testWidgets('the clinic chips live HERE and hand the choice up',
      (tester) async {
    final views = <ClinicView>[];
    await _pump(tester,
        clinic: _clinic(nowMs, [_chart()]),
        store: _store(nowMs: nowMs),
        onView: views.add);
    expect(find.text('Node health'), findsOneWidget);
    expect(find.text('Route health'), findsOneWidget);
    expect(find.text('Trouble flags'), findsOneWidget);
    expect(find.text('Second-hand'), findsOneWidget);
    await tester.tap(find.text('Route health'));
    await tester.pump();
    expect(views, [ClinicView.routes]);
  });

  testWidgets('the time-window dropdown hands its minutes up',
      (tester) async {
    final windows = <int>[];
    await _pump(tester,
        clinic: _clinic(nowMs, [_chart()]),
        store: _store(nowMs: nowMs),
        onWindow: windows.add);
    await tester.tap(find.byKey(const ValueKey('clinic-window')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 hrs').last);
    await tester.pumpAndSettle();
    expect(windows, [240]);
  });

  testWidgets('the section list is the map\'s numbers in BIGGER font',
      (tester) async {
    final picks = <int>[];
    await _pump(tester,
        clinic: _clinic(nowMs, [_chart()]),
        store: _store(nowMs: nowMs),
        onPick: picks.add);
    void expectBig(String label) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.style?.fontSize, 20, reason: '$label must be big');
    }
    for (var id = 1; id <= 4; id++) {
      expectBig('Section $id');
    }
    await tester.tap(find.text('Section 5'));
    await tester.pump();
    expect(picks, [5]);
    // The list runs to the map's full grid (12 squares) - scroll
    // like a finger and the numbers keep coming.
    await tester.drag(find.text('Section 4'), const Offset(0, -600));
    await tester.pumpAndSettle();
    expectBig('Section 12');
    await tester.tap(find.text('Section 12'));
    await tester.pump();
    expect(picks, [5, 12]);
  });

  testWidgets('the honest strip counts the chosen family and its gaps',
      (tester) async {
    // 0x21 has a place (drawn); 0x99 has none (counted out loud).
    await _pump(tester,
        clinic: _clinic(nowMs, [_chart(), _chart(prefix: 0x99)]),
        store: _store(nowMs: nowMs));
    expect(
        find.textContaining('1 clinic fact(s) in this view'), findsOneWidget);
    expect(find.textContaining('1 without a place'), findsOneWidget);
    expect(find.byKey(const ValueKey('clinic-loose')), findsOneWidget);
  });

  testWidgets('the back button closes the page', (tester) async {
    var closed = false;
    await _pump(tester,
        clinic: _clinic(nowMs, [_chart()]),
        store: _store(nowMs: nowMs),
        onClose: () => closed = true);
    await tester.tap(find.byKey(const ValueKey('clinic-back')));
    await tester.pump();
    expect(closed, isTrue);
  });
}
