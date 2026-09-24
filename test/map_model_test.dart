// Map view-model tests: Brett's laws visible in what the map draws.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/grid.dart';
import 'package:meshtech_app/map_model.dart';
import 'package:meshtech_app/store.dart';

void main() {
  test('one dot per node; a moved node keeps ONE dot at the NEW place',
      () {
    final s = NodeStore();
    s.upsert(const NodeRecord(
        prefix: 0x11, name: 'Alpha', lat: 38.0, lon: -122.0,
        lastHeardMs: 0));
    s.upsert(const NodeRecord(
        prefix: 0x11, name: 'Alpha', lat: 38.5, lon: -122.5,
        lastHeardMs: 1000));
    final dots = MapViewModel.dots(s, nowMs: 2000);
    expect(dots.length, 1);
    expect(dots.single.lat, 38.5);
  });

  test('no fix = no dot (honest gaps, never invented positions)', () {
    final s = NodeStore();
    s.upsert(const NodeRecord(prefix: 0x11, name: 'NoFix',
        lastHeardMs: 1000));
    s.upsert(const NodeRecord(prefix: 0x22, name: 'Fixed',
        lat: 38.0, lon: -122.0, lastHeardMs: 1000));
    final dots = MapViewModel.dots(s, nowMs: 2000);
    expect(dots.length, 1);
    expect(dots.single.prefix, 0x22);
  });

  test('stale = the 14-day line, exactly', () {
    final s = NodeStore();
    const now = 100 * 24 * 3600 * 1000; // day 100
    s.upsert(const NodeRecord(prefix: 0x11, name: 'Fresh',
        lat: 38.0, lon: -122.0, lastHeardMs: now - 13 * 24 * 3600 * 1000));
    s.upsert(const NodeRecord(prefix: 0x22, name: 'Old',
        lat: 38.1, lon: -122.1, lastHeardMs: now - 15 * 24 * 3600 * 1000));
    final dots = MapViewModel.dots(s, nowMs: now);
    expect(dots[0].color, DotColor.fresh); // 13 days: still blue
    expect(dots[1].color, DotColor.stale); // 15 days: yellow
  });

  test('section counts are counted on the VIEW (re-cut honest)', () {
    final s = NodeStore();
    s.upsert(const NodeRecord(
        prefix: 0x11, name: 'North', lat: 38.2, lon: -122.0,
        lastHeardMs: 1000)); // ~22 km north: inside 60 km, outside 20 km
    s.upsert(const NodeRecord(
        prefix: 0x22, name: 'Center', lat: 38.0, lon: -122.0,
        lastHeardMs: 1000));
    const frame60 = MapFrame(
        grid: 3, centerLat: 38.0, centerLon: -122.0, spanM: 60000);
    // Row-major from NW: due north of center = top-middle = section 2;
    // the center node = section 5.
    expect(MapViewModel.sectionCounts(s, frame60, nowMs: 2000),
        [0, 1, 0, 0, 1, 0, 0, 0, 0]);
    final counts20 =
        MapViewModel.sectionCounts(s, frame60.recut(20000), nowMs: 2000);
    expect(counts20[1], 0); // the north node is OUTSIDE the 20 km window
    expect(counts20[4], 1); // the center node is section 5
  });

  test('labels ride on the dots (section 8: name + pubkey head)', () {
    final s = NodeStore();
    s.upsert(const NodeRecord(
        prefix: 0xab, name: 'Hilltop', lat: 38.0, lon: -122.0,
        lastHeardMs: 1000));
    expect(MapViewModel.dots(s, nowMs: 2000).single.label, 'Hilltop ab');
  });
}
