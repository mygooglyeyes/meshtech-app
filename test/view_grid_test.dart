// The phone's view grid (3 wide x 4 tall, Brett's call 2026-09-24):
// counted and drawn from REAL geography on the visible region. The
// wire's 3x3 stays the server's shape; this grid is the phone's own
// view, like the map size itself.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/map_model.dart';
import 'package:meshtech_app/store.dart';

ViewGrid grid() => const ViewGrid(
      centerLat: 38.0,
      centerLon: -122.5,
      spanLatM: 40000, // 40 km tall
      spanLonM: 20000, // 20 km wide (the tall screen's shape)
    );

void main() {
  test('a 3x4 grid has 12 cells, 2 vertical + 3 horizontal lines', () {
    final g = grid();
    expect(g.cols * g.rows, 12);
    expect(g.lines().length, 2 + 3); // inner lines only
    expect(g.cellCenters().length, 12);
  });

  test('a node lands in the right cell (west column, second band)', () {
    final s = NodeStore();
    // 6 km north = the SECOND band from the top (the top band is
    // +10..+20 km in a 40 km view); 4 km west = the west third.
    // Cell = row 1, col 0 -> index 3.
    s.upsert(const NodeRecord(
        prefix: 1,
        name: 'W2',
        lat: 38.0 + 6000 / 111320.0,
        lon: -122.5 - 4000 / (111320.0 * 0.788),
        lastHeardMs: 1000));
    final counts = grid().counts(s);
    expect(counts[3], 1); // row 1 (second from top), col 0 (west)
    expect(counts[0], 0); // the true top band is +10..+20 km
    expect(counts.sum, 1); // nowhere else
  });

  test('a node outside the view counts nowhere', () {
    final s = NodeStore();
    s.upsert(const NodeRecord(
        prefix: 2,
        name: 'Far',
        lat: 38.5, // ~55 km north - outside the 40 km view
        lon: -122.5,
        lastHeardMs: 1000));
    expect(grid().counts(s).sum, 0);
  });

  test('jittered camera bounds are the SAME grid (no rebuild storm)', () {
    final a = grid();
    final b = ViewGrid(
      centerLat: a.centerLat + 1e-10,
      centerLon: a.centerLon - 1e-10,
      spanLatM: a.spanLatM + 0.2,
      spanLonM: a.spanLonM - 0.2,
    );
    expect(a, b);
  });
}

extension _Sum on Iterable<int> {
  int get sum => fold(0, (a, b) => a + b);
}
