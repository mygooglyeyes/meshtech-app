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

/// ONE drawn route, named by id (see [MapViewModel.routeLayers]):
/// the hot flag says the open section's summary named it, [segs] are
/// its drawable runs in the wire's travel order, gaps split.
class RouteLayer {
  final int routeId;
  final bool hot;
  final List<List<MapPoint>> segs;
  const RouteLayer(
      {required this.routeId, required this.hot, required this.segs});
}

/// One drawn point, in wire order: (lon, lat) - exactly what the map
/// engine's positions are built from. The route lines are handed
/// around as these, so this file stays pure Dart (no map engine).
typedef MapPoint = (double lon, double lat);

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

  /// THE ROUTE LINES (design section 10): segments between KNOWN dots
  /// only - an unknown hop is an honest gap and the line resumes at
  /// the next known dot (never an invented position). The wire's
  /// travel order is the draw order.
  ///
  /// [showBackground] false hides ONLY the non-highlighted routes -
  /// Brett's route-line toggle (2026-09-25), kept on the main map
  /// AND given its own copy on each section detail page.
  static ({List<List<MapPoint>> background, List<List<MapPoint>> highlighted})
      routeLines(NodeStore store,
          {required Set<int> highlightIds, required bool showBackground}) {
    final background = <List<MapPoint>>[];
    final highlighted = <List<MapPoint>>[];
    for (final l in routeLayers(store,
        highlightIds: highlightIds, showBackground: showBackground)) {
      (l.hot ? highlighted : background).addAll(l.segs);
    }
    return (background: background, highlighted: highlighted);
  }

  /// ONE DRAWN ROUTE, named (Brett's section detail page,
  /// 2026-09-25): a tap on the map must be able to say WHICH route
  /// line it hit, so the lines travel per-route instead of pooled.
  /// [hot] marks the routes the open section's summary named - the
  /// warm layer. [segs] are gap-split: one entry per drawable run.
  static List<RouteLayer> routeLayers(NodeStore store,
      {required Set<int> highlightIds, required bool showBackground}) {
    final out = <RouteLayer>[];
    for (final r in store.routes) {
      final hot = highlightIds.contains(r.routeId);
      if (!hot && !showBackground) continue; // the toggle: background off
      final segs = <List<MapPoint>>[];
      var pts = <MapPoint>[];
      void flush() {
        if (pts.length > 1) segs.add(pts);
        pts = <MapPoint>[];
      }

      for (final pfx in r.prefixes) {
        final n = store.nodes[pfx];
        if (n?.lat == null || n?.lon == null) {
          flush(); // the honest gap: the line resumes at the next
          continue; // known dot - no invented position, ever
        }
        pts.add((n!.lon!, n.lat!));
      }
      flush();
      if (segs.isNotEmpty) {
        out.add(RouteLayer(routeId: r.routeId, hot: hot, segs: segs));
      }
    }
    return out;
  }

  /// THE TAP MATH (Brett's tap rule): the straight-line distance
  /// from a point to a segment - pure screen math, no engine.
  static double distToSegment(double px, double py, double ax, double ay,
      double bx, double by) {
    final dx = bx - ax;
    final dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
    final u = t.clamp(0.0, 1.0);
    final qx = ax + u * dx;
    final qy = ay + u * dy;
    return math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
  }

  /// WHICH ROUTE THE TAP HIT: the drawn line nearest the tap, within
  /// [tolerance] pixels - or null, an honest miss (a tap on empty
  /// map selects nothing, per Brett's rule: nothing sticks).
  /// [screenSegs] maps routeId -> its segments already projected to
  /// screen pixels.
  static int? routeIdNear(Map<int, List<List<MapPoint>>> screenSegs,
      MapPoint tap, double tolerance) {
    int? hit;
    var best = tolerance;
    for (final e in screenSegs.entries) {
      for (final seg in e.value) {
        for (var i = 0; i + 1 < seg.length; i++) {
          final d = distToSegment(tap.$1, tap.$2, seg[i].$1, seg[i].$2,
              seg[i + 1].$1, seg[i + 1].$2);
          if (d < best) {
            best = d;
            hit = e.key;
          }
        }
      }
    }
    return hit;
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

/// ONE square of the phone's grid - the tappable section unit (Brett,
/// 2026-09-25). Its NUMBER is the section id the wire speaks (1 upper
/// left .. 12 lower right on the 3x4 map) and its geography is where
/// the detail page parks its camera: the square he tapped, up close.
class SectionCell {
  final int id;
  final double centerLat;
  final double centerLon;
  final double spanLatM;
  final double spanLonM;
  const SectionCell({
    required this.id,
    required this.centerLat,
    required this.centerLon,
    required this.spanLatM,
    required this.spanLonM,
  });
}

/// THE PHONE'S VIEW GRID (Brett, 2026-09-24): 3 wide x 4 tall - the
/// tall screen's own cut of the view, drawn and counted from REAL
/// geography. Since 2026-09-25 its squares CARRY THE SECTION NUMBERS
/// (1 upper left .. 12 lower right - the same numbers the wire
/// speaks, matching the server's 3x4 sections), so tapping a square
/// opens the section with that number.
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

  /// Which square (0-based, row-major from NW) a position falls in -
  /// the SAME numbering counts() and cellCenters() use - or -1 when
  /// the position is outside the view. A tap lands in exactly one
  /// square, and the square's number IS the section it opens (Brett,
  /// 2026-09-25: no re-deriving sections from geography - what he
  /// sees is what he taps).
  int cellIndex(double lat, double lon) {
    const mPerDeg = 111320.0;
    final fx = (lon - centerLon) *
            mPerDeg *
            math.cos(centerLat * math.pi / 180.0) /
            spanLonM +
        0.5;
    final fy = (lat - centerLat) * mPerDeg / spanLatM + 0.5;
    if (fx < 0 || fx >= 1 || fy < 0 || fy >= 1) return -1;
    final col = (fx * cols).floor().clamp(0, cols - 1);
    final row = ((1 - fy) * rows).floor().clamp(0, rows - 1);
    return row * cols + col;
  }

  /// One square's descriptor: its number (1..cols*rows, row-major
  /// from NW - the section id the wire speaks) and its geography.
  SectionCell cell(int index) {
    final (lat, lon) = cellCenters()[index];
    return SectionCell(
      id: index + 1,
      centerLat: lat,
      centerLon: lon,
      spanLatM: spanLatM / rows,
      spanLonM: spanLonM / cols,
    );
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
