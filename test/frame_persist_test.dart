// THE LINES SURVIVE A RESTART (Brett, 2026-09-27): the map frame is
// RECEIVED DATA - closing and reopening the app must not lose it.
// The store already persisted dots + sync marker; the frame joins
// them. A fresh install has NO frame (the app waits for a real
// LAYOUT), and a node-restart reset drops it (the node's RAM frame
// died with it - honest blank, never stale lines).

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

  test('a node-restart reset drops the frame (honest blank, not stale)',
      () async {
    final store = NodeStore();
    await store.load();
    store.noteFrame(_hilltop);
    await store.save();

    store.resetAll();
    await store.save();

    final reopened = NodeStore();
    await reopened.load();
    expect(reopened.frame, isNull);
  });

  test('the wipe erases the frame from flash too (bench first-run law)',
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
}
