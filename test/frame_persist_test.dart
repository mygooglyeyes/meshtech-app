// THE LINES SURVIVE A RESTART (Brett, 2026-09-27): the map frame is
// RECEIVED DATA - closing and reopening the app must not lose it.
// THE FULL STORE ROUND-TRIP (Brett's law, 2026-09-27): dots, route
// lines and the frame ALL survive a relaunch - the app comes up just
// like it shut down. Removal ways: death (7/14 for nodes, 7/14 for
// routes) or a GONE update from any source. Ages fold forward
// honestly - persistence never freezes time.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _hilltop = Layout(
  seq: 7,
  grid: 3,
  rows: 4,
  centerLat: 38.1074,
  centerLon: -122.5697,
  spanM: 60000,
  origin: 0xb17e,
  name: 'hilltop',
);

Route _route({required int routeId, required List<int> prefixes,
    required int lastHeardMin, int sectionId = 5}) =>
    Route(
        seq: 1,
        sectionId: sectionId,
        routeId: routeId,
        packetCount: 4,
        delayMedS: 12,
        lastHeardMin: lastHeardMin,
        prefixes: prefixes);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('a fresh install has NO frame - the app waits for a real LAYOUT',
      () async {
    final store = NodeStore();
    await store.load();
    expect(store.frame, isNull);
  });

  test('noteFrame holds the layout; save + load brings it back whole',
      () async {
    final store = NodeStore();
    await store.load();
    store.noteFrame(_hilltop);
    await store.save();

    // A NEW store instance = the app relaunched.
    final reopened = NodeStore();
    await reopened.load();
    final f = reopened.frame;
    expect(f, isNotNull);
    expect(f!.name, 'hilltop');
    expect(f.grid, 3);
    expect(f.rows, 4);
    expect(f.centerLat, closeTo(38.1074, 1e-9));
    expect(f.centerLon, closeTo(-122.5697, 1e-9));
    expect(f.spanM, 60000);
    expect(f.origin, 0xb17e);
    expect(f.seq, 7);
  });

  test('the newest layout wins whole (UPSERT-REPLACE, like every fact)',
      () async {
    final store = NodeStore();
    await store.load();
    store.noteFrame(_hilltop);
    store.noteFrame(const Layout(
      seq: 8,
      grid: 4,
      rows: 4,
      centerLat: 1.0,
      centerLon: 2.0,
      spanM: 40000,
      name: 'other',
    ));
    await store.save();

    final reopened = NodeStore();
    await reopened.load();
    expect(reopened.frame!.name, 'other');
    expect(reopened.frame!.grid, 4);
  });

  test('a node restart keeps the frame - restart is not death (Brett, 09-27)',
      () async {
    final store = NodeStore();
    await store.load();
    store.noteFrame(_hilltop);
    await store.save();

    // The node restarts: the phone re-syncs but keeps its map.
    store.prepareResync();
    await store.save();

    final reopened = NodeStore();
    await reopened.load();
    expect(reopened.frame, isNotNull);
    expect(reopened.frame!.name, 'hilltop');
    expect(reopened.syncMarker, 0); // marker dropped = full re-sync
  });

  test('the FULL wipe erases the frame from flash too (bench first-run law)',
      () async {
    final store = NodeStore();
    await store.load();
    store.noteFrame(_hilltop);
    await store.save();
    await store.wipe();

    final reopened = NodeStore();
    await reopened.load();
    expect(reopened.frame, isNull);
  });

  test('dots + routes + frame ALL survive close/reopen', () async {
    final s0 = NodeStore();
    await s0.load();
    s0.noteFrame(_hilltop);
    s0.applyIntroEntry(
        const IntroEntry(prefix: 0x42, name: 'Alpha',
            lat: 38.1, lon: -122.5),
        heardMs: DateTime.now().millisecondsSinceEpoch);
    s0.applyRoute(_route(routeId: 7, prefixes: [0x42], lastHeardMin: 10));
    await s0.save();

    final s1 = NodeStore(); // the relaunch
    await s1.load();
    expect(s1.frame!.name, 'hilltop');
    expect(s1.nodes[0x42]!.name, 'Alpha');
    expect(s1.route(7), isNotNull);
    expect(s1.route(7)!.prefixes, [0x42]);
  });

  test('a route saved 20 days ago is DEAD on reopen (age folds forward)',
      () async {
    final s0 = NodeStore();
    await s0.load();
    // Heard 10 min before the save, saved 20 days ago: 20 days silent.
    final savedAt = DateTime.now()
        .subtract(const Duration(days: 20))
        .millisecondsSinceEpoch;
    s0.applyRoute(_route(routeId: 9, prefixes: [0x42], lastHeardMin: 10),
        heardMs: savedAt);
    await s0.save();

    final s1 = NodeStore();
    await s1.load(); // pruneDead runs inside load
    expect(s1.route(9), isNull); // direct 7-day line, 20 days old: dead
  });

  test('a dot silent past 14 days is DEAD on reopen (7/14 node law)',
      () async {
    final s0 = NodeStore();
    await s0.load();
    final savedAt = DateTime.now()
        .subtract(const Duration(days: 15))
        .millisecondsSinceEpoch;
    s0.applyIntroEntry(
        const IntroEntry(prefix: 0x42, name: 'Alpha'),
        heardMs: savedAt);
    await s0.save();

    final s1 = NodeStore();
    await s1.load();
    expect(s1.nodes[0x42], isNull); // 14-day line passed while closed
  });

  test('a dot 8 days silent is STALE but kept (the 7-day line, shown)',
      () async {
    final s0 = NodeStore();
    await s0.load();
    final savedAt = DateTime.now()
        .subtract(const Duration(days: 8))
        .millisecondsSinceEpoch;
    s0.applyIntroEntry(
        const IntroEntry(prefix: 0x42, name: 'Alpha'),
        heardMs: savedAt);
    await s0.save();

    final s1 = NodeStore();
    await s1.load();
    expect(s1.nodes[0x42], isNotNull);
    expect(s1.nodeIsStale(s1.nodes[0x42]!), isTrue);
    expect(s1.nodeIsDead(s1.nodes[0x42]!), isFalse);
  });

  test('a GONE update removes the dot AND its route lines (any source)',
      () async {
    final s = NodeStore();
    await s.load();
    s.applyIntroEntry(
        const IntroEntry(prefix: 0x42, name: 'Alpha',
            lat: 38.1, lon: -122.5),
        heardMs: DateTime.now().millisecondsSinceEpoch);
    s.applyRoute(_route(routeId: 7, prefixes: [0x42], lastHeardMin: 10));
    s.applyRoute(_route(routeId: 8, prefixes: [0x99], lastHeardMin: 10));

    s.removeGone(0x42);
    s.removeGoneRoutes(0x42);
    expect(s.nodes[0x42], isNull);
    expect(s.route(7), isNull); // the line followed the dot out
    expect(s.route(8), isNotNull); // untouched
  });
}
