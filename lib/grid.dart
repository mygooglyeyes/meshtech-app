// Grid re-cut (DESIGN.md section 3, Brett's rule): the app translates
// whatever data it holds to the size chosen - data heard or downloaded
// at 60 km can be DRAWN at 20 km. The wire packets carry their true
// span (LAYOUT/INTRO v1.5), so this is honest math: re-derive each
// node's offset from the span its data arrived at, then re-scale onto
// the chosen span. The grid itself (3x3) stays the server's shape;
// the SECTION numbering maps onto the chosen window's corners.

import 'dart:math' as math;

import 'map_model.dart' show MapFrameLike;

class MapFrame implements MapFrameLike {
  final int grid;
  final double centerLat;
  final double centerLon;
  final double spanM; // THE TRUTH the data was measured at
  final String name;
  const MapFrame({
    required this.grid,
    required this.centerLat,
    required this.centerLon,
    required this.spanM,
    this.name = '',
  });

  @override
  int get sectionCount => grid * grid;

  /// The frame the user is LOOKING at now (the chosen size, same
  /// center) - section 3: changing the size changes the DRAWING only.
  MapFrame recut(double chosenSpanM) => MapFrame(
        grid: grid,
        centerLat: centerLat,
        centerLon: centerLon,
        spanM: chosenSpanM,
        name: name,
      );

  /// A node's absolute position expressed on THIS frame, as normalized
  /// fractions in [-0.5, +0.5] from the center (x east, y north).
  /// Data heard at a DIFFERENT span still lands correctly: the delta
  /// from the center is real geography, independent of the span it
  /// was quantized at (quantization error is the only residue - at
  /// 32767 steps per half-span it is far below GPS noise).
  ({double x, double y}) project(double lat, double lon) {
    const metersPerDegree = 111320.0;
    final dxMeters = (lon - centerLon) * metersPerDegree *
        math.cos(centerLat * math.pi / 180.0);
    final dyMeters = (lat - centerLat) * metersPerDegree;
    return (x: dxMeters / spanM, y: dyMeters / spanM);
  }

  /// Unpacked form for callers that destructure positionally.
  (double, double) projectXY(double lat, double lon) {
    final p = project(lat, lon);
    return (p.x, p.y);
  }

  /// Which 1-based section (row-major from NW) a position falls in on
  /// THIS frame - or 0 when it is outside the window. The same node
  /// can be section 1 on the 20 km view and outside the 20 km window
  /// entirely; the section grid is a property of the VIEW, never of
  /// the node.
  @override
  int sectionOf(double lat, double lon) {
    final (x, y) = projectXY(lat, lon);
    if (x < -0.5 || x > 0.5 || y < -0.5 || y > 0.5) return 0;
    final cols = grid;
    final col = ((x + 0.5) * cols).clamp(0, cols - 1).floor();
    final row = ((0.5 - y) * cols).clamp(0, cols - 1).floor();
    return row * cols + col + 1;
  }
}
