// The map view-model (design section 8 + Brett's laws): everything
// the map DRAWS, derived from the store - pure Dart, fully testable
// without the map engine. The MapLibre widget (map_screen.dart) is a
// thin painter over this; the brains live here.

import 'dart:math' as math;

import 'store.dart';

/// Where a dot's color comes from - the honest states, no invented
/// middle ground. silent (RED) = Brett's 3-day line (2026-09-24: a
/// node unheard for 3 days turns red; heard again, it returns to its
/// regular color). stale (YELLOW) = the node table's own 14-day law.
enum DotColor { fresh, silent, stale, unknownClass }

class DotVM {
  final int prefix;
  final String label;
  final double lat;
  final double lon;
  final DotColor color;
  final int nodeClass;
  const DotVM({
    required this.prefix,
    required this.label,
    required this.lat,
    required this.lon,
    required this.color,
    required this.nodeClass,
  });
}

class MapViewModel {
  /// BRETT'S NODE SILENCE LAW (2026-09-24): 3 days unheard = RED.
  /// Heard again = back to its regular color (the age is derived
  /// fresh every frame, so a heard node is instantly un-red).
  static const silentAfterMs = 3 * 24 * 3600 * 1000;
  static const staleAfterMs = 14 * 24 * 3600 * 1000; // the 14-day line

  /// Dots for the current frame: one per node (the store guarantees
  /// it), colored by the honest states, labels per section 8.
  static List<DotVM> dots(NodeStore store, {required int nowMs}) {
    final out = <DotVM>[];
    for (final n in store.nodes.values) {
      if (n.lat == null || n.lon == null) continue; // honest: no fix, no dot
      final age = nowMs - n.lastHeardMs;
      out.add(DotVM(
        prefix: n.prefix,
        label: n.label,
        lat: n.lat!,
        lon: n.lon!,
        nodeClass: n.nodeClass,
        color: age > staleAfterMs
            ? DotColor.stale
            : age > silentAfterMs
                ? DotColor.silent
                : DotColor.fresh,
      ));
    }
    out.sort((a, b) => a.prefix.compareTo(b.prefix));
    return out;
  }

  /// Corner counts for the drawn frame: active nodes per section,
  /// counted ON THE VIEW (a node outside the window counts nowhere).
  static List<int> sectionCounts(
      NodeStore store, MapFrameLike frame, {required int nowMs}) {
    final counts = List<int>.filled(frame.sectionCount, 0);
    for (final n in store.nodes.values) {
      if (n.lat == null || n.lon == null) continue;
      final s = frame.sectionOf(n.lat!, n.lon!);
      if (s > 0) counts[s - 1]++;
    }
    return counts;
  }
}

/// The slice of grid.dart's MapFrame the view-model needs (keeps the
/// model testable without dragging the whole geometry in).
abstract class MapFrameLike {
  int get sectionCount;
  int sectionOf(double lat, double lon);
}

/// THE PHONE'S VIEW GRID (Brett, 2026-09-24): 3 wide x 4 tall - the
/// tall screen's own cut of the view, drawn and counted from REAL
/// geography. The wire's 3x3 stays the server's shape; this grid is
/// a property of the phone's screen, like the map size itself.
class ViewGrid {
  static const viewCols = 3;
  static const viewRows = 4;
  final int cols;
  final int rows;
  final double centerLat;
  final double centerLon;
  final double spanLatM; // the view's north-south extent (the chosen km)
  final double spanLonM; // east-west extent (the screen's aspect applies)
  const ViewGrid({
    this.cols = viewCols,
    this.rows = viewRows,
    required this.centerLat,
    required this.centerLon,
    required this.spanLatM,
    required this.spanLonM,
  });

  /// The grid LINES as (lon1, lat1, lon2, lat2) segments.
  List<(double, double, double, double)> lines() {
    const mPerDeg = 111320.0;
    final spanLatDeg = spanLatM / mPerDeg;
    final spanLonDeg =
        spanLonM / (mPerDeg * math.cos(centerLat * math.pi / 180.0));
    final out = <(double, double, double, double)>[];
    for (var c = 1; c < cols; c++) {
      final lon = centerLon + (c / cols - 0.5) * spanLonDeg;
      out.add((
        lon,
        centerLat + spanLatDeg / 2,
        lon,
        centerLat - spanLatDeg / 2,
      ));
    }
    for (var r = 1; r < rows; r++) {
      final lat = centerLat + (0.5 - r / rows) * spanLatDeg;
      out.add((
        centerLon - spanLonDeg / 2,
        lat,
        centerLon + spanLonDeg / 2,
        lat,
      ));
    }
    return out;
  }

  /// Cell centers as (lat, lon), row-major from NW - where the
  /// per-cell count badges draw.
  List<(double, double)> cellCenters() {
    const mPerDeg = 111320.0;
    final spanLatDeg = spanLatM / mPerDeg;
    final spanLonDeg =
        spanLonM / (mPerDeg * math.cos(centerLat * math.pi / 180.0));
    return [
      for (var r = 0; r < rows; r++)
        for (var c = 0; c < cols; c++)
          (
            centerLat + (0.5 - (r + 0.5) / rows) * spanLatDeg,
            centerLon + ((c + 0.5) / cols - 0.5) * spanLonDeg,
          ),
    ];
  }

  /// Nodes per cell, counted ON THE VIEW from real geography
  /// (row-major from NW). A node outside the view counts nowhere;
  /// a node outside the home area was never a dot anyway.
  List<int> counts(NodeStore store) {
    const mPerDeg = 111320.0;
    final counts = List<int>.filled(cols * rows, 0);
    for (final n in store.nodes.values) {
      if (n.lat == null || n.lon == null) continue;
      final fx = (n.lon! - centerLon) *
              mPerDeg *
              math.cos(centerLat * math.pi / 180.0) /
              spanLonM +
          0.5;
      final fy = (n.lat! - centerLat) * mPerDeg / spanLatM + 0.5;
      if (fx < 0 || fx >= 1 || fy < 0 || fy >= 1) continue;
      final col = (fx * cols).floor().clamp(0, cols - 1);
      // fy runs 0 (south edge) -> 1 (north edge); row 0 is the NORTH
      // band, so flip: row = (1 - fy) * rows. (The test caught the
      // missing flip - a node 6 km north landed in the south mirror.)
      final row = ((1 - fy) * rows).floor().clamp(0, rows - 1);
      counts[row * cols + col]++;
    }
    return counts;
  }

  /// Epsilon equality: camera events jitter the visible region in
  /// the last decimal places - without this, every frame would
  /// "change" the grid and rebuild the map forever.
  @override
  bool operator ==(Object other) =>
      other is ViewGrid &&
      (other.centerLat - centerLat).abs() < 1e-9 &&
      (other.centerLon - centerLon).abs() < 1e-9 &&
      (other.spanLatM - spanLatM).abs() < 1.0 &&
      (other.spanLonM - spanLonM).abs() < 1.0;

  @override
  int get hashCode =>
      Object.hash(centerLat, centerLon, spanLatM.round(),
          spanLonM.round());
}
