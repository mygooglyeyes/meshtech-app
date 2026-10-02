// The map view-model (design section 8 + Brett's laws): everything
// the map DRAWS, derived from the store - pure Dart, fully testable
// without the map engine. The MapLibre widget (map_screen.dart) is a
// thin painter over this; the brains live here.

import 'dart:math' as math;

import 'clinic_store.dart';
import 'codec.dart';
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

/// ONE DRAWN ROUTE LINE under BRETT'S ROUTE-LINE LAW (2026-10-01):
/// a line never runs off the page - it stops partway (75% of the
/// way toward the NEXT node in the trail), that node's name labels
/// the line's end, and chevrons say which way the packets move:
/// pointing away from the sending node (next to the name being sent
/// to) when it sends, pointing AT a node's dot when packets arrive
/// there, and one at each end when the route runs both ways (the
/// same trail heard reversed).
class RouteEdgeVM {
  /// The sending node's dot (lon, lat).
  final MapPoint from;

  /// The NEXT node's true position - never drawn past [stop].
  final MapPoint to;

  /// Where the line stops: 75% toward [to], kept on the page.
  final MapPoint stop;

  /// The next node's name - the label at the line's end.
  final String toName;

  /// Travel direction on a north-up screen: degrees clockwise from
  /// up (0 = the packets fly north, 90 = east).
  final double bearingDeg;

  /// The same trail heard reversed = packets run both ways.
  final bool bothWays;

  /// Chevron at [stop], pointing away from the sending node.
  final bool outArrow;

  /// Chevron at [to]'s dot, pointing at it (packets arrive there).
  final bool inArrowTo;

  /// Chevron at [from]'s dot, pointing at it (both ways only).
  final bool inArrowFrom;
  final int routeId;
  final bool hot;
  const RouteEdgeVM({
    required this.routeId,
    required this.hot,
    required this.from,
    required this.to,
    required this.stop,
    required this.toName,
    required this.bearingDeg,
    required this.bothWays,
    this.outArrow = true,
    this.inArrowTo = true,
    this.inArrowFrom = false,
  });
}

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

  /// THE ROUTE EDGES (Brett's route-line law, 2026-10-01): one edge
  /// per trail-adjacent KNOWN dot pair, in travel order (the honest-
  /// gap rule stands: an unknown hop breaks the line and it never
  /// bridges the gap), each carrying its 75% stop, the next node's
  /// name at the line end, and the direction chevrons.
  ///
  /// [bounds] = (minLon, minLat, maxLon, maxLat) is the page the
  /// line must stay on: a stop that would leave it slides back along
  /// the line until it sits inside. Null = no page to respect.
  static List<RouteEdgeVM> routeEdges(NodeStore store,
      {required Set<int> highlightIds,
      required bool showBackground,
      (double, double, double, double)? bounds}) {
    final out = <RouteEdgeVM>[];
    // Both ways = the same trail heard reversed.
    final trails =
        <String>{for (final r in store.routes) r.prefixes.join(',')};
    for (final r in store.routes) {
      final hot = highlightIds.contains(r.routeId);
      if (!hot && !showBackground) continue;
      final bothWays = trails.contains(r.prefixes.reversed.join(','));
      for (var i = 0; i + 1 < r.prefixes.length; i++) {
        final a = store.nodes[r.prefixes[i]];
        final b = store.nodes[r.prefixes[i + 1]];
        // Honest gap: no known dot on either end, no line (never an
        // invented position).
        if (a?.lat == null || a?.lon == null) continue;
        if (b?.lat == null || b?.lon == null) continue;
        final from = (a!.lon!, a.lat!);
        final to = (b!.lon!, b.lat!);
        out.add(RouteEdgeVM(
          routeId: r.routeId,
          hot: hot,
          from: from,
          to: to,
          stop: _stopAt(from, to, bounds),
          toName: b.label,
          bearingDeg: _bearingDeg(from, to),
          bothWays: bothWays,
          inArrowFrom: bothWays,
        ));
      }
    }
    return out;
  }

  /// 75% toward the next dot - slid back along the line when that
  /// would leave the page (3% margin: room for the end label).
  static MapPoint _stopAt(
      MapPoint from, MapPoint to, (double, double, double, double)? bounds) {
    var t = 0.75;
    if (bounds != null) {
      const margin = 0.03;
      final (minLon, minLat, maxLon, maxLat) = bounds;
      final padLon = (maxLon - minLon) * margin;
      final padLat = (maxLat - minLat) * margin;
      // The crossing t along the FULL line (from + t*(to - from)):
      // v is where the 75% stop would land, `full` the whole step.
      double axis(double f, double v, double full, double lo, double hi) {
        if (v >= lo && v <= hi) return t; // on the page: no limit
        if (full == 0) return 0.05;
        final edge = v > hi ? hi : lo;
        return (edge - f) / full;
      }

      final tl = axis(from.$1, from.$1 + t * (to.$1 - from.$1),
          to.$1 - from.$1, minLon + padLon, maxLon - padLon);
      final ta = axis(from.$2, from.$2 + t * (to.$2 - from.$2),
          to.$2 - from.$2, minLat + padLat, maxLat - padLat);
      t = math.max(0.05, math.min(t, math.min(tl, ta)));
    }
    return (from.$1 + t * (to.$1 - from.$1),
        from.$2 + t * (to.$2 - from.$2));
  }

  /// Travel bearing on a north-up screen: degrees clockwise from up.
  static double _bearingDeg(MapPoint from, MapPoint to) {
    final dLat = to.$2 - from.$2;
    final dLon = (to.$1 - from.$1) *
        math.cos((from.$2 + to.$2) / 2 * math.pi / 180.0);
    return math.atan2(dLon, dLat) * 180.0 / math.pi;
  }

  /// The camera zoom for a north-south span (the map's own rule:
  /// 60 km -> z9, each doubling down -> +1, rounded).
  static double zoomForSpan(double spanM) =>
      (9 + math.log(60000.0 / spanM) / math.ln2).roundToDouble();

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

// ---------------------------------------------------------------------------
// THE CLINIC LAYER (Mesh Clinic v2): the map's SIMPLE health layer -
// one marker per positioned fact, colored by its honest state, tap-
// detail cards behind it. FIVE FACT-FAMILY VIEWS (Brett's pick):
// all facts / node health / route health / trouble flags / second-
// hand peer reports - exactly the wire's record families. EVERY fact
// is labeled first-hand/second-hand; second-hand facts are never
// drawn as first-hand (CLINIC-WIRE.md's provenance rule).
//
// Honest gaps: a fact with no known position draws NOWHERE and is
// counted out loud (never an invented place). Signal is not distance.
// Missing numbers show as missing in every card.
// ---------------------------------------------------------------------------

enum ClinicView { all, nodes, routes, trouble, secondHand }

/// The layer's simple palette: fresh (blue - the map's own fresh
/// dot), aging (yellow - past the 3-day silent line), trouble (red -
//  what deserves a look), secondHand (teal - a peer box's claim).
enum ClinicColor { fresh, aging, trouble, secondHand }

/// What a tap on a clinic element opens. Equality is by value so
/// tests can name a target exactly.
sealed class ClinicTarget {
  const ClinicTarget();
}

class ClinicNodeTarget extends ClinicTarget {
  final int prefix;
  const ClinicNodeTarget(this.prefix);
  @override
  bool operator ==(Object other) =>
      other is ClinicNodeTarget && other.prefix == prefix;
  @override
  int get hashCode => prefix.hashCode;
  @override
  String toString() => 'ClinicNodeTarget($prefix)';
}

class ClinicRouteTarget extends ClinicTarget {
  final List<int> path;
  const ClinicRouteTarget(this.path);
  @override
  bool operator ==(Object other) =>
      other is ClinicRouteTarget &&
      other.path.length == path.length &&
      List.generate(path.length, (i) => other.path[i] == path[i])
          .every((same) => same);
  @override
  int get hashCode => Object.hashAll(path);
  @override
  String toString() => 'ClinicRouteTarget(${path.map((p) => p.toRadixString(16).padLeft(2, '0')).join('-')})';
}

class ClinicMarker {
  final double lat;
  final double lon;
  final String label;
  final ClinicColor color;
  final ClinicTarget target;

  /// True when the marker sits at a PEER'S CLAIMED position (not at
  /// the phone's own dot place) - the only clinic labels the map
  /// draws, so the claim visibly wears its '2nd' tag where nothing
  /// else names the spot. Everywhere else the base map's labels
  /// already name the node.
  final bool claim;
  const ClinicMarker({
    required this.lat,
    required this.lon,
    required this.label,
    required this.color,
    required this.target,
    this.claim = false,
  });
}

class ClinicLine {
  final List<List<MapPoint>> segs;
  final ClinicColor color;
  final ClinicTarget target;
  const ClinicLine(
      {required this.segs, required this.color, required this.target});
}

class ClinicLayer {
  final List<ClinicMarker> markers;
  final List<ClinicLine> lines;

  /// Facts that draw NOWHERE (no known position): counted out loud,
  /// never pinned (the wire page's honest-gap law).
  final int unpositioned;

  /// How many DRAWN facts are second-hand (a peer box's claim) - the
  /// strip says it out loud, the color shows it at a glance.
  final int secondHandDrawn;
  const ClinicLayer({
    required this.markers,
    required this.lines,
    required this.unpositioned,
    required this.secondHandDrawn,
  });
}

class ClinicLayerVM {
  /// Brett's node silence line (the map's own): a chart last heard
  /// 3+ days ago is AGING (yellow), fresher is blue.
  static const silentAfterMs = MapViewModel.silentAfterMs;

  /// THE TIME WINDOW (Brett, 2026-09-30: "time frames 1hr 4hrs 12hrs
  /// 1day 7days 14days as a dropdown when selecting one of the clinic
  /// chips"): when a window is set, a fact draws only when its age
  /// says it was heard INSIDE it. An unknown age ("older than the
  /// wire says") fits no window - it stays hidden here and lives in
  /// the cards and the honest loose list, never invented as fresh.
  /// windowMin 0 = no window (draw everything).
  static bool _inWindow(int ageMin, int windowMin) =>
      windowMin <= 0 || (!ageIsUnknown(ageMin) && ageMin <= windowMin);

  static ClinicLayer build(ClinicStore clinic, NodeStore store, ClinicView view,
      {required int nowMs, int windowMin = 0}) {
    final markers = <ClinicMarker>[];
    final lines = <ClinicLine>[];
    var unpositioned = 0;
    var secondHand = 0;
    final wantNodes = view == ClinicView.all || view == ClinicView.nodes;
    final wantRoutes = view == ClinicView.all || view == ClinicView.routes;
    final wantTrouble = view == ClinicView.all || view == ClinicView.trouble;
    final wantPeers =
        view == ClinicView.all || view == ClinicView.secondHand;

    if (wantNodes) {
      for (final row in clinic.nodeFacts) {
        final n = store.nodes[row.fact.prefix];
        if (n?.lat == null || n?.lon == null) {
          unpositioned++;
          continue;
        }
        final ageMin = row.ageMin(row.fact.lastAgeMin, nowMs);
        if (!_inWindow(ageMin, windowMin)) continue;
        final ageMs = ageMin * 60000;
        if (!row.firstHand) secondHand++;
        markers.add(ClinicMarker(
          lat: n!.lat!,
          lon: n.lon!,
          label: _handLabel(n.label, row.firstHand),
          // A second-hand chart is TEAL whatever its age - it is a
          // peer's claim, never drawn as our own first-hand fact.
          color: !row.firstHand
              ? ClinicColor.secondHand
              : ageMs > silentAfterMs
                  ? ClinicColor.aging
                  : ClinicColor.fresh,
          target: ClinicNodeTarget(row.fact.prefix),
        ));
      }
    }
    if (wantRoutes) {
      for (final row in clinic.routeFacts) {
        final segs = _pathSegs(store, row.fact.path);
        if (segs.isEmpty) {
          unpositioned++;
          continue;
        }
        final ageMin = row.ageMin(row.fact.lastAgeMin, nowMs);
        if (!_inWindow(ageMin, windowMin)) continue;
        final ageMs = ageMin * 60000;
        if (!row.firstHand) secondHand++;
        lines.add(ClinicLine(
          segs: segs,
          color: !row.firstHand
              ? ClinicColor.secondHand
              : ageMs > silentAfterMs
                  ? ClinicColor.aging
                  : ClinicColor.fresh,
          target: ClinicRouteTarget(row.fact.path),
        ));
      }
    }
    if (wantTrouble) {
      for (final row in clinic.flagFacts) {
        if (row.fact.subject == 0) {
          unpositioned++; // mesh-wide: no place, listed instead
          continue;
        }
        final n = store.nodes[row.fact.subject];
        if (n?.lat == null || n?.lon == null) {
          unpositioned++;
          continue;
        }
        if (!_inWindow(row.ageMin(row.fact.lastAgeMin, nowMs), windowMin)) {
          continue;
        }
        if (!row.firstHand) secondHand++;
        markers.add(ClinicMarker(
          lat: n!.lat!,
          lon: n.lon!,
          label: _handLabel(n.label, row.firstHand),
          color: ClinicColor.trouble,
          target: ClinicNodeTarget(row.fact.subject),
        ));
      }
    }
    if (wantPeers) {
      for (final row in clinic.peerFacts) {
        final f = row.fact;
        switch (f.report) {
          case reportIntro:
            if (f.lat == null || f.lon == null) {
              unpositioned++; // the peer reported NO position
              continue;
            }
            // The claim is drawn where the PEER said it - the
            // phone's own dot stays where it was, never merged.
            if (!_inWindow(row.ageMin(f.heardAgeMin, nowMs), windowMin)) {
              continue;
            }
            final label = f.name.isEmpty
                ? 'node ${f.subject.toRadixString(16).padLeft(2, '0')}'
                : '${f.name} ${f.subject.toRadixString(16).padLeft(2, '0')}';
            secondHand++;
            markers.add(ClinicMarker(
              lat: f.lat!,
              lon: f.lon!,
              label: '$label \u00b7 reported',
              color: ClinicColor.secondHand,
              target: ClinicNodeTarget(f.subject),
              claim: true,
            ));
          case reportRoute:
            final segs = _pathSegs(store, f.path);
            if (segs.isEmpty) {
              unpositioned++;
              continue;
            }
            if (!_inWindow(row.ageMin(f.heardAgeMin, nowMs), windowMin)) {
              continue;
            }
            secondHand++;
            lines.add(ClinicLine(
              segs: segs,
              color: ClinicColor.secondHand,
              target: ClinicRouteTarget(f.path),
            ));
          default:
            unpositioned++; // pulse / section summaries: no place
        }
      }
    }
    return ClinicLayer(
        markers: markers,
        lines: lines,
        unpositioned: unpositioned,
        secondHandDrawn: secondHand);
  }

  /// The names law (section 8): every node drawn carries its label -
  /// and a second-hand fact wears its hand right on the tag.
  static String _handLabel(String label, bool firstHand) =>
      firstHand ? label : '$label \u00b7 reported';

  /// The wire's travel-order path -> drawable runs (gap-split: an
  /// unknown/positionless hop is an honest gap, never invented).
  static List<List<MapPoint>> _pathSegs(NodeStore store, List<int> path) {
    final segs = <List<MapPoint>>[];
    var pts = <MapPoint>[];
    for (final pfx in path) {
      final n = store.nodes[pfx];
      if (n?.lat == null || n?.lon == null) {
        if (pts.length > 1) segs.add(pts);
        pts = <MapPoint>[];
        continue;
      }
      pts.add((n!.lon!, n.lat!));
    }
    if (pts.length > 1) segs.add(pts);
    return segs;
  }

  /// WHICH FACT THE TAP HIT: the nearest marker or line within
  /// [toleranceM] meters of the tap - or null, an honest miss (a tap
  /// on empty map opens no card).
  static ClinicTarget? hitTest(
      ClinicLayer layer, MapPoint tap, double toleranceM) {
    ClinicTarget? best;
    var bestM = toleranceM;
    for (final m in layer.markers) {
      final d = _distM(tap, (m.lon, m.lat));
      if (d < bestM) {
        bestM = d;
        best = m.target;
      }
    }
    for (final l in layer.lines) {
      for (final seg in l.segs) {
        for (var i = 0; i + 1 < seg.length; i++) {
          final d = _distToSegM(tap, seg[i], seg[i + 1]);
          if (d < bestM) {
            bestM = d;
            best = l.target;
          }
        }
      }
    }
    return best;
  }

  /// Equirectangular meters around the tap's own latitude (the grid's
  /// honest projection - close enough for a finger, no engine).
  static (double, double) _m(MapPoint p, double latRef) {
    const mPerDeg = 111320.0;
    return (p.$1 * mPerDeg * math.cos(latRef * math.pi / 180.0),
        p.$2 * mPerDeg);
  }

  static double _distM(MapPoint a, MapPoint b) {
    final (ax, ay) = _m(a, a.$2);
    final (bx, by) = _m(b, a.$2);
    return math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));
  }

  static double _distToSegM(MapPoint p, MapPoint a, MapPoint b) {
    final (px, py) = _m(p, p.$2);
    final (ax, ay) = _m(a, p.$2);
    final (bx, by) = _m(b, p.$2);
    return MapViewModel.distToSegment(px, py, ax, ay, bx, by);
  }
}

/// THE TAP-DETAIL CARDS: one line per fact, EVERY line carrying its
/// provenance label first. Missing numbers show as missing - never a
/// plausible constant (the wire page's honesty rules).
/// ONE row of a graphical health card (Brett's approved design,
/// 2026-09-29): plain data, drawn by the section detail page. Facts
/// come in BLOCKS: a provenance chip first, then that box's rows.
sealed class HealthRow {
  const HealthRow();
}

/// A family heading - Brett's four names, verbatim.
class HealthFamily extends HealthRow {
  final String name;
  const HealthFamily(this.name);
}

/// The provenance chip: Direct (2f25) / Reported (beef).
class HealthChip extends HealthRow {
  final String label;
  const HealthChip(this.label);
}

/// A fixed-scale mini bar: the pale span runs worst..best, the white
/// tick sits at the average, [spread] reads at the side. Positions are
/// 0..1 fractions of the row's FIXED scale (shared by kind, so two
/// links compare at a glance - the wide bar IS the coin flip).
class HealthBar extends HealthRow {
  final String key; // 'SNR' / 'RSSI' / 'delay'
  final String value; // '12.0 dB'
  final String spread; // '+-0.5' or ''
  final String note; // 'min/med/max' or ''
  final double start;
  final double end;
  final double tick;
  const HealthBar({
    required this.key,
    required this.value,
    this.spread = '',
    this.note = '',
    required this.start,
    required this.end,
    required this.tick,
  });
}

/// A block bar (traffic share): [filled] of [total] blocks.
class HealthBlocks extends HealthRow {
  final String key;
  final String value;
  final int filled;
  final int total;
  const HealthBlocks(
      {required this.key,
      required this.value,
      required this.filled,
      required this.total});
}

/// The 24-hour availability strip, as its honest bits.
class HealthStrip extends HealthRow {
  final String key;
  final String value;
  final int bits;
  const HealthStrip(
      {required this.key, required this.value, required this.bits});
}

/// One trouble flag - evidence in compact words, never a verdict.
class HealthFlag extends HealthRow {
  final String name; // 'rate storm'
  final String detail; // '3 event(s), peak 22/min, last 2 min ago'
  const HealthFlag({required this.name, required this.detail});
}

/// A small neutral fact note (ages, hops, route lines).
class HealthNote extends HealthRow {
  final String text;
  const HealthNote(this.text);
}

/// An honest gap: a fact the mesh does not carry yet.
class HealthGap extends HealthRow {
  final String text;
  const HealthGap(this.text);
}

/// The bars' FIXED scales (dB / dBm / seconds) - one scale per kind,
/// so every row shares its axis and rows compare at a glance.
const double snrScaleLo = -10, snrScaleHi = 20;
const double rssiScaleLo = -120, rssiScaleHi = -70;
const double delayScaleLo = 0, delayScaleHi = 15;
// The trail's own rulers (Brett's bars, 2026-09-30): the wire trail
// is 1..8 hops; uses is a u16 count whose ruler's end means "this
// much or more" (the _cap_u16 law).
const double hopsScaleLo = 0, hopsScaleHi = 8;
const double usesScaleLo = 0, usesScaleHi = 1000;
double barFrac(double v, double lo, double hi) =>
    ((v - lo) / (hi - lo)).clamp(0.0, 1.0);

class ClinicCards {
  /// The node's whole clinic picture from every box: charts, its
  /// trouble flags, and what the peer boxes said about it.
  static List<String> nodeCard(ClinicStore clinic, NodeStore store, int prefix,
      {required int nowMs}) {
    final out = <String>[];
    out.add(nodeTitle(store, prefix));
    for (final row in clinic.nodeFactsFor(prefix)) {
      out.add('${row.label} - chart: ${_chartText(row, nowMs)}');
    }
    for (final row in clinic.flagsFor(prefix)) {
      out.add('${row.label} - ${_flagText(row, nowMs)}');
    }
    for (final row in clinic.peerIntrosFor(prefix)) {
      out.add('${row.label} - ${_peerText(row, nowMs)}');
    }
    return out;
  }

  /// Every box's chart of ONE route (the trail, travel order).
  static List<String> routeCard(ClinicStore clinic, List<int> path,
      {required int nowMs}) {
    final out = <String>[routeTitle(path)];
    for (final row in clinic.routeFacts) {
      if (row.fact.path.length != path.length) continue;
      var same = true;
      for (var i = 0; i < path.length; i++) {
        if (row.fact.path[i] != path[i]) same = false;
      }
      if (!same) continue;
      out.add('${row.label} - ${_routeText(row, nowMs)}');
    }
    return out;
  }

  // THE HEALTH REPORT'S HONEST GAPS (Brett, 2026-09-29): facts the
  // wire carries NO version of, named out loud - never invented.
  // The node card fills its gaps measurement by measurement (035);
  // the route card keeps these (the wire has no route-scoped facts).
  static const _gapDelivery = 'loss \u00b7 retries \u00b7 reordering \u00b7 '
      'request\u2192answer: not measured yet';
  static const _gapStability =
      'churn \u00b7 hash collisions: not measured yet';

  /// The card titles (shared by the text cards and the section page).
  static String nodeTitle(NodeStore store, int prefix) {
    final n = store.nodes[prefix];
    return n == null
        ? 'node ${prefix.toRadixString(16).padLeft(2, '0')}'
        : n.label;
  }

  static String routeTitle(List<int> path) =>
      'route ${path.map((p) => p.toRadixString(16).padLeft(2, '0')).join('-')}';

  /// THE HEALTH REPORT (Brett's approved graphical design,
  /// 2026-09-29): a node's four health families - real numbers as
  /// bars and strips (every block chipped Direct/Reported), and the
  /// honest gaps where the mesh carries no such fact. No grades, no
  /// verdicts - the numbers only.
  static List<HealthRow> nodeHealthCard(ClinicStore clinic, int prefix,
      {required int nowMs}) {
    final out = <HealthRow>[];
    final charts = clinic.nodeFactsFor(prefix);
    final flags = clinic.flagsFor(prefix);
    // THE HEALTH NUMBERS (kinds 5-8, app 035): the mesh's air and
    // the senders' behavior are NOT one node's facts - they ride
    // their box's chip, and only the TOP SENDERS appear (Brett's
    // rule 2026-09-29: most lost first; a sender-to-node
    // 'connection' does not exist on the wire, so none is claimed).
    final air = [...clinic.airtimeFacts]
      ..sort((a, b) => a.source.compareTo(b.source));
    final senders = _topSenders(clinic.senderFacts);
    final exchange = [...clinic.exchangeFacts]
      ..sort((a, b) => a.source.compareTo(b.source));
    final collisions = [...clinic.collisionFacts]
      ..sort((a, b) => a.source.compareTo(b.source));
    if (charts.isEmpty) out.add(const HealthNote('no chart yet'));
    var chip = '';
    void family(String name) {
      out.add(HealthFamily(name));
      chip = ''; // the chip repeats per family block
    }

    void wear(String label) {
      if (label == chip) return;
      out.add(HealthChip(label));
      chip = label;
    }

    family('Link quality margins');
    for (final row in charts) {
      wear(row.label);
      out.addAll(_marginBars(row.fact));
    }

    family('Airtime & congestion');
    for (final row in charts) {
      wear(row.label);
      final f = row.fact;
      out.add(shareIsUnknown(f.sharePct)
          ? const HealthNote('share unknown')
          : HealthBlocks(
              key: 'share',
              value: '${f.sharePct}%',
              filled: (f.sharePct / 10).round(),
              total: 10));
    }
    for (final row in flags) {
      if (row.fact.flag != flagRateStorm) continue;
      wear(row.label);
      out.add(_flagRow(row, nowMs));
    }
    for (final row in air) {
      wear(row.label);
      out.add(HealthNote(_airText(row)));
    }
    for (final row in senders) {
      wear(row.label);
      out.add(HealthNote('sender ${tagHex(row.fact.sender)}: duplicates '
          '${perMillePct(row.fact.dupPerMille)}'));
    }
    _gapRows(out, [
      if (air.isEmpty && senders.isEmpty) 'duplicates',
      if (air.isEmpty) ...['occupancy', 'duty headroom'],
    ]);

    family('Delivery reliability & latency');
    for (final row in charts) {
      wear(row.label);
      final h = row.fact.hopsTyp;
      out.add(HealthNote(h == 0 ? 'Typical hops: unknown' : 'Typical hops: $h'));
    }
    // THE AGGREGATE BARS (Brett, 2026-09-30, corrected at the bench
    // the same day): a TOTAL of three bars under this heading -
    // hops, delay, uses - not one set per reporting node ("I only
    // wanted a total of 3"). Each merges every number gathered for
    // this node across all measuring boxes: the tick at the
    // average, the span lowest..highest.
    final facts = <ClinicRouteFact>[
      for (final row in clinic.routeFacts)
        if (row.fact.path.contains(prefix)) row.fact,
    ];
    if (facts.isEmpty) {
      _gapRows(out, ['hops', 'delay', 'uses']);
    } else {
      out.addAll(_statBars(facts));
    }
    for (final row in exchange) {
      wear(row.label);
      out.add(HealthNote(_exchangeText(row)));
    }
    for (final row in senders) {
      wear(row.label);
      out.add(HealthNote('sender ${tagHex(row.fact.sender)}: '
          'lost ${row.fact.lost} \u00b7 reordered ${row.fact.reordered}'));
    }
    _gapRows(out, [
      if (senders.isEmpty) 'loss',
      'retries',
      if (senders.isEmpty) 'reordering',
      if (exchange.isEmpty) 'request\u2192answer',
    ]);

    family('Stability & hygiene');
    for (final row in charts) {
      wear(row.label);
      final f = row.fact;
      out.add(HealthStrip(
          key: 'heard', value: '${_popcount(f.strip)}/24 h', bits: f.strip));
      out.add(HealthNote('chart ${f.ageDays} days old \u00b7 '
          'last heard ${ageText(row.ageMin(f.lastAgeMin, nowMs))}'));
    }
    for (final row in flags) {
      final fl = row.fact.flag;
      if (fl != flagSigFail && fl != flagTsBackwards) continue;
      wear(row.label);
      out.add(_flagRow(row, nowMs));
    }
    for (final row in collisions) {
      wear(row.label);
      out.add(HealthNote(_collisionText(row, nowMs)));
    }
    for (final row in senders) {
      wear(row.label);
      out.add(HealthNote(
          'sender ${tagHex(row.fact.sender)}: flaps ${row.fact.flaps}'));
    }
    _gapRows(out, [
      if (senders.isEmpty) 'churn',
      if (collisions.isEmpty) 'hash collisions',
    ]);
    return out;
  }

  /// A route's health report: the same four families. The wire
  /// carries NO per-hop signal for a trail - that family says so
  /// honestly instead of borrowing a number from somewhere else.
  static List<HealthRow> routeHealthCard(ClinicStore clinic, List<int> path,
      {required int nowMs}) {
    final rows = [
      for (final row in clinic.routeFacts)
        if (_samePath(row.fact.path, path)) row
    ];
    final out = <HealthRow>[];
    if (rows.isEmpty) out.add(const HealthNote('no chart yet'));
    var chip = '';
    void family(String name) {
      out.add(HealthFamily(name));
      chip = '';
    }

    void wear(String label) {
      if (label == chip) return;
      out.add(HealthChip(label));
      chip = label;
    }

    family('Link quality margins');
    out.add(const HealthGap('per-hop signal: not measured yet'));

    family('Airtime & congestion');
    for (final row in rows) {
      wear(row.label);
      out.add(HealthNote('${row.fact.uses} use(s) counted'));
    }
    out.add(const HealthGap('duplicates: not measured yet'));

    family('Delivery reliability & latency');
    // THE AGGREGATE BARS (Brett, 2026-09-30): the node card's own
    // three-bar grammar - a TOTAL of three bars merging every
    // number gathered for this route, not one set per reporting
    // node.
    if (rows.isEmpty) {
      _gapRows(out, ['hops', 'delay', 'uses']);
    } else {
      out.addAll(_statBars([for (final row in rows) row.fact]));
    }
    for (final row in rows) {
      wear(row.label);
      final f = row.fact;
      out.add(HealthNote(
          '${f.direct == 1 ? 'straight from sender' : 'via trail'} \u00b7 '
          'last used ${ageText(row.ageMin(f.lastAgeMin, nowMs))} \u00b7 '
          'chart ${f.ageDays} days old'));
    }
    out.add(const HealthGap(_gapDelivery));

    family('Stability & hygiene');
    out.add(const HealthGap(_gapStability));
    return out;
  }

  /// Brett's top-3 rule (2026-09-29): most lost first, ties broken
  /// by flaps, then reordering, then duplicates. The wire carries no
  /// sender-to-node connection, so none is ever claimed.
  static List<ClinicRow<ClinicSenderFact>> _topSenders(
      Iterable<ClinicRow<ClinicSenderFact>> rows) {
    final all = [...rows];
    all.sort((a, b) {
      final f = a.fact, g = b.fact;
      if (g.lost != f.lost) return g.lost.compareTo(f.lost);
      if (g.flaps != f.flaps) return g.flaps.compareTo(f.flaps);
      if (g.reordered != f.reordered) {
        return g.reordered.compareTo(f.reordered);
      }
      return g.dupPerMille.compareTo(f.dupPerMille);
    });
    return all.take(3).toList();
  }

  /// What the card still cannot show, named out loud.
  static void _gapRows(List<HealthRow> out, List<String> missing) {
    if (missing.isEmpty) return;
    out.add(HealthGap('${missing.join(' \u00b7 ')}: not measured yet'));
  }

  static String _airText(ClinicRow<ClinicAirtimeFact> row) {
    final f = row.fact;
    final parts = <String>[
      'duplicates ${perMillePct(f.dupPerMille)}',
      'occupancy ${perMillePct(f.occupancyPerMille)}',
      f.dutyHeadroomS == numUnknown
          ? 'duty headroom unknown'
          : 'duty headroom ${f.dutyHeadroomS} s',
    ];
    if (f.txUsedS != numUnknown) {
      parts.add('sent ${f.txUsedS} s');
    }
    return parts.join(' \u00b7 ');
  }

  static String _exchangeText(ClinicRow<ClinicExchangeFact> row) {
    final f = row.fact;
    final med =
        f.medianAnswerS == 0 ? 'median unknown' : 'median ${f.medianAnswerS} s';
    return 'ask\u2192answer: asked ${f.asked} \u00b7 answered ${f.answered}'
        ' \u00b7 $med';
  }

  static String _collisionText(ClinicRow<ClinicCollisionFact> row, int nowMs) {
    final f = row.fact;
    final tag =
        f.tag.map((t) => t.toRadixString(16).padLeft(2, '0')).join('-');
    return 'hash collision: tag $tag carried two different keys \u00b7 '
        'proven ${ageText(row.ageMin(f.lastAgeMin, nowMs))}';
  }

  /// The margin rows: one fixed-scale bar per signal kind. Missing
  /// stays missing - a bar is drawn only from real samples.
  static List<HealthRow> _marginBars(ClinicNodeFact f) {
    final out = <HealthRow>[];
    if (signalIsUnknown(f.snrEwma)) {
      out.add(const HealthNote('SNR unknown'));
    } else {
      final e = f.snrEwma / 4.0; // SNR rides quarter-dB
      final lo = signalIsUnknown(f.snrWorst) ? e : f.snrWorst / 4.0;
      final hi = signalIsUnknown(f.snrBest) ? e : f.snrBest / 4.0;
      out.add(HealthBar(
          key: 'SNR',
          value: _sigQ(f.snrEwma),
          spread: f.snrSd == signalSdUnknown
              ? '\u00b1 n/a'
              : '\u00b1${f.snrSd / 4}',
          start: barFrac(lo, snrScaleLo, snrScaleHi),
          end: barFrac(hi, snrScaleLo, snrScaleHi),
          tick: barFrac(e, snrScaleLo, snrScaleHi)));
    }
    if (signalIsUnknown(f.rssiEwma)) {
      out.add(const HealthNote('RSSI unknown'));
    } else {
      final e = f.rssiEwma.toDouble();
      final lo = signalIsUnknown(f.rssiWorst) ? e : f.rssiWorst.toDouble();
      final hi = signalIsUnknown(f.rssiBest) ? e : f.rssiBest.toDouble();
      out.add(HealthBar(
          key: 'RSSI',
          value: '${f.rssiEwma} dBm',
          spread:
              f.rssiSd == signalSdUnknown ? '\u00b1 n/a' : '\u00b1${f.rssiSd}',
          start: barFrac(lo, rssiScaleLo, rssiScaleHi),
          end: barFrac(hi, rssiScaleLo, rssiScaleHi),
          tick: barFrac(e, rssiScaleLo, rssiScaleHi)));
    }
    return out;
  }

  /// One box's trail-metrics as three aggregate bars (Brett,
  /// 2026-09-30: "Hops: average, highest, lowest; delay: ...; Uses:
  /// ..." - every metric the old list carried, in one row each).
  /// A delay the wire never carried stays out of the average - the
  /// honest gap line below names what was not measured.
  static List<HealthRow> _statBars(List<ClinicRouteFact> facts) {
    final out = <HealthRow>[
      _statBar('hops', [for (final f in facts) f.path.length.toDouble()],
          hopsScaleLo, hopsScaleHi),
    ];
    final known = [for (final f in facts) if (_delayKnown(f)) f];
    if (known.isEmpty) {
      out.add(const HealthNote('delay unknown'));
    } else {
      var lo = 0x7FFFFFFF, hi = 0, sum = 0;
      for (final f in known) {
        final loV = f.delayMinS > 0
            ? f.delayMinS
            : (f.delayMedS > 0 ? f.delayMedS : f.delayMaxS);
        final hiV = f.delayMaxS > 0
            ? f.delayMaxS
            : (f.delayMedS > 0 ? f.delayMedS : f.delayMinS);
        final midV = f.delayMedS > 0 ? f.delayMedS : ((loV + hiV) ~/ 2);
        lo = math.min(lo, loV);
        hi = math.max(hi, hiV);
        sum += midV;
      }
      final avg = sum ~/ known.length;
      out.add(HealthBar(
          key: 'delay',
          value: '$lo/$avg/$hi s',
          note: 'low/avg/high',
          start: barFrac(lo.toDouble(), delayScaleLo, delayScaleHi),
          end: barFrac(hi.toDouble(), delayScaleLo, delayScaleHi),
          tick: barFrac(avg.toDouble(), delayScaleLo, delayScaleHi)));
    }
    out.add(_statBar('uses', [for (final f in facts) f.uses.toDouble()],
        usesScaleLo, usesScaleHi));
    return out;
  }

  static bool _delayKnown(ClinicRouteFact f) =>
      f.delayMinS > 0 || f.delayMedS > 0 || f.delayMaxS > 0;

  /// ONE AGGREGATE BAR: value reads low/avg/high (the delay bars'
  /// own min/med/max grammar), the pale span runs low..high, the
  /// white tick sits at the average.
  static HealthBar _statBar(
      String key, List<double> values, double scaleLo, double scaleHi) {
    final sorted = [...values]..sort();
    final lo = sorted.first;
    final hi = sorted.last;
    final avg = sorted.reduce((a, b) => a + b) / sorted.length;
    String v(double x) =>
        x == x.roundToDouble() ? '${x.round()}' : x.toStringAsFixed(1);
    return HealthBar(
        key: key,
        value: '${v(lo)}/${v(avg)}/${v(hi)}',
        note: 'low/avg/high',
        start: barFrac(lo, scaleLo, scaleHi),
        end: barFrac(hi, scaleLo, scaleHi),
        tick: barFrac(avg, scaleLo, scaleHi));
  }

  /// The flag in compact words (Brett, 2026-09-29): name, count,
  /// detail, last seen. Evidence, never a verdict.
  static HealthFlag _flagRow(ClinicRow<ClinicFlagFact> row, int nowMs) {
    final f = row.fact;
    final name = switch (f.flag) {
      flagSigFail => 'signature failures',
      flagTsBackwards => 'timestamps backwards',
      flagRateStorm => 'rate storm',
      flagCorruptShare => 'corrupt packets',
      _ => 'flag ${f.flag}',
    };
    final detail = switch (f.flag) {
      flagTsBackwards => ', worst jump ${f.detail} s',
      flagRateStorm => ', peak ${f.detail}/min',
      _ => '',
    };
    return HealthFlag(
        name: name,
        detail: '${f.events} ${f.events == 1 ? 'event' : 'events'}$detail, '
            'last ${ageText(row.ageMin(f.lastAgeMin, nowMs))}');
  }

  static bool _samePath(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The facts with NO place on the map (mesh-wide trouble + the
  /// peer pulses/summaries) - listed, never pinned somewhere false.
  static List<String> looseCard(ClinicStore clinic, {required int nowMs}) {
    final out = <String>['facts without a place'];
    for (final row in clinic.meshWideFlags) {
      out.add('${row.label} - ${_flagText(row, nowMs)}');
    }
    for (final row in clinic.peerFacts) {
      final f = row.fact;
      if (f.report == reportPulse || f.report == reportSectSum) {
        out.add('${row.label} - ${_peerText(row, nowMs)}');
      }
    }
    return out;
  }

  static String _chartText(ClinicRow<ClinicNodeFact> row, int nowMs) {
    final f = row.fact;
    final parts = <String>[
      'heard ${ageText(row.ageMin(f.lastAgeMin, nowMs))}',
      '${f.ageDays} days old',
      'hops ${f.hopsTyp == 0 ? 'unknown' : f.hopsTyp}',
      shareIsUnknown(f.sharePct)
          ? 'share unknown (no identified traffic counted)'
          : 'share ${f.sharePct}% of identified traffic',
      'heard in ${_popcount(f.strip)} of the last 24 hours',
      'SNR ${_sigQ(f.snrEwma)} (best ${_sigQ(f.snrBest)}, '
          'worst ${_sigQ(f.snrWorst)}, spread ${_sdQ(f.snrSd)})',
      'RSSI ${_sigRaw(f.rssiEwma)} (best ${_sigRaw(f.rssiBest)}, '
          'worst ${_sigRaw(f.rssiWorst)}, spread ${_sdRaw(f.rssiSd)})',
    ];
    return parts.join('; ');
  }

  static String _routeText(ClinicRow<ClinicRouteFact> row, int nowMs) {
    final f = row.fact;
    String d(int v) => v == 0 ? 'unknown' : '$v s';
    return 'route: ${f.uses} uses, ${f.direct == 1 ? 'heard straight from the sender' : 'via trail'}, '
        'delay min/med/max ${d(f.delayMinS)}/${d(f.delayMedS)}/${d(f.delayMaxS)}, '
        'last used ${ageText(row.ageMin(f.lastAgeMin, nowMs))}, '
        '${f.ageDays} days old';
  }

  static String _flagText(ClinicRow<ClinicFlagFact> row, int nowMs) {
    final f = row.fact;
    final detail = switch (f.flag) {
      flagTsBackwards => ', worst jump ${f.detail} s',
      flagRateStorm => ', peak ${f.detail} packets/min',
      flagCorruptShare => '', // the share already rides in the words
      _ => '',
    };
    return '${flagMeaning(f)} - ${f.events} event(s), '
        'first ${ageText(row.ageMin(f.firstAgeMin, nowMs))}, '
        'last ${ageText(row.ageMin(f.lastAgeMin, nowMs))}$detail';
  }

  static String _peerText(ClinicRow<ClinicPeerFact> row, int nowMs) {
    final f = row.fact;
    final said = ageText(row.ageMin(f.heardAgeMin, nowMs));
    switch (f.report) {
      case reportPulse:
        final v = f.values;
        return 'pulse (said $said): uptime ${_hours(v[0])}, '
            '${v[1]}/h, ${v[2]} active, airtime ${v[3]} s/h';
      case reportSectSum:
        final v = f.values;
        return 'section ${f.subject} summary (said $said): '
            '${v[0]} active, ${v[1]} packets, '
            'delay p50 ${_secOrUnknown(v[2])} / p90 ${_secOrUnknown(v[3])}';
      case reportRoute:
        final v = f.values;
        return 'route report (said $said): ${v[0]} uses, '
            'delay med ${_secOrUnknown(v[1])}, '
            'last used ${ageText(v[2])}, '
            'path ${f.path.map((p) => p.toRadixString(16).padLeft(2, '0')).join('-')}';
      case reportIntro:
        final place = f.lat == null
            ? 'no position reported'
            : 'at ${f.lat!.toStringAsFixed(5)}, ${f.lon!.toStringAsFixed(5)}';
        // The name, if present, wears ' ' (Brett, 2026-09-29).
      final name = f.name.isEmpty ? '(no name)' : "'${f.name}'";
        return 'said (said $said): $name, class ${f.cls}, $place';
      default:
        return 'unknown report (said $said)';
    }
  }

  /// Missing stays missing - the sentinels speak as unknown.
  static String ageText(int min) => ageIsUnknown(min)
      ? 'unknown (older than the wire can say)'
      : min < 90
          ? '$min min ago'
          : min < 48 * 60
              ? '${(min / 60).round()} h ago'
              : '${(min / 1440).round()} d ago';

  static String _hours(int uptimeMin) =>
      '${(uptimeMin / 60).round()} h';

  static String _secOrUnknown(int s) => s == 0 ? 'unknown' : '$s s';

  /// SNR rides quarter-dB (like discover); a receiver never reports
  /// -128, so that sentinel is honest 'unknown'.
  static String _sigQ(int q) =>
      signalIsUnknown(q) ? 'unknown' : '${q / 4} dB';

  static String _sigRaw(int v) =>
      signalIsUnknown(v) ? 'unknown' : '$v dBm';

  /// SNR spread rides quarter-dB like SNR itself; RSSI spread is dB.
  static String _sdQ(int v) =>
      v == signalSdUnknown ? 'unknown' : '${v / 4} dB';

  static String _sdRaw(int v) =>
      v == signalSdUnknown ? 'unknown' : '$v dB';

  static int _popcount(int strip) {
    var count = 0;
    for (var i = 0; i < 24; i++) {
      if ((strip >> i) & 1 == 1) count++;
    }
    return count;
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

  /// The square's own geography (Brett, 2026-09-30: the section LIST
  /// scopes to the tapped square): is this point inside the cell?
  /// The same meters-per-degree math the grid lines speak.
  bool contains(double lat, double lon) {
    const mPerDeg = 111320.0;
    final dLat = (lat - centerLat).abs() * mPerDeg;
    final dLon = (lon - centerLon).abs() *
        mPerDeg *
        math.cos(centerLat * math.pi / 180.0);
    return dLat <= spanLatM / 2 && dLon <= spanLonM / 2;
  }

  /// The page this cell paints - what keeps route lines from running
  /// off it (Brett's route-line law, 2026-10-01):
  /// (minLon, minLat, maxLon, maxLat).
  (double, double, double, double) bounds() {
    const mPerDeg = 111320.0;
    final halfLat = (spanLatM / 2) / mPerDeg;
    final halfLon = (spanLonM / 2) /
        (mPerDeg * math.cos(centerLat * math.pi / 180.0));
    return (centerLon - halfLon, centerLat - halfLat,
        centerLon + halfLon, centerLat + halfLat);
  }
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
