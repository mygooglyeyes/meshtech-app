// THE NODE / ROUTE DETAIL PAGE (Brett, 2026-09-30): what the map's
// tap pop-ups carry, as a full page with a BACK button - opened from
// the lists, where rows used to do nothing. The route page leads with
// a VISUAL of its trail's nodes (Brett: "a visual representation of
// the route nodes, with names and details underneath"), then the
// names and details, then the clinic data. LISTS ONLY - the map's
// health-card pop-ups stay exactly as they are (Brett's pick).
//
// Pages ride OVER the app in the shell's stack (the house pattern -
// Navigator routes are never used); the back button hands control
// to onClose.

import 'dart:math' as math;

import 'package:flutter/material.dart' hide Route;
import 'package:maplibre/maplibre.dart';

import 'clinic_store.dart';
import 'codec.dart'; // the WIRE Route (Flutter's Route is hidden above)
import 'map_model.dart';
import 'map_screen.dart' show mapStyleUrl;
import 'store.dart';

/// How long ago, in the list's own words (the same honest rounding
/// the browser rows use).
String ageText(int minutes) {
  if (minutes < 0) return '0 min';
  if (minutes < 60) return '$minutes min';
  if (minutes < 1440) return '${minutes ~/ 60} h';
  return '${minutes ~/ 1440} d';
}

/// One node's identity line: its NAME when one is known (Brett,
/// 2026-10-02: "the node name if possible, not the 2byte prefix,
/// unless the name is not known"), its place (honestly "NO
/// POSITION" - never invented), and when it was last heard.
String nodeIdentity(NodeStore store, int prefix, {required int nowMs}) {
  final hex = prefix.toRadixString(16).padLeft(2, '0');
  final n = store.nodes[prefix];
  if (n == null) return 'prefix $hex - nothing heard about it yet';
  final pos = (n.lat == null || n.lon == null)
      ? 'NO POSITION'
      : '${n.lat!.toStringAsFixed(3)}, ${n.lon!.toStringAsFixed(3)}';
  final ageMin = ((nowMs - n.lastHeardMs) / 60000).round();
  final who = (n.name == null || n.name!.isEmpty) ? 'prefix $hex' : n.name!;
  return '$who \u00b7 $pos \u00b7 heard ${ageText(ageMin)} ago';
}

class NodeDetailScreen extends StatelessWidget {
  final NodeStore store;
  final ClinicStore clinic;
  final int prefix;
  final VoidCallback onClose;

  /// THE MAP SEAM (the section page's own pattern): tests pump a
  /// placeholder instead of a live map.
  final WidgetBuilder? mapBuilder;

  const NodeDetailScreen({
    super.key,
    required this.store,
    required this.clinic,
    required this.prefix,
    required this.onClose,
    this.mapBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rows =
        ClinicCards.nodeHealthCard(clinic, prefix, nowMs: nowMs);
    final node = store.nodes[prefix];
    final hasFix = node?.lat != null && node?.lon != null;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('detail-back'),
          tooltip: 'Back to the list',
          icon: const Icon(Icons.arrow_back),
          onPressed: onClose,
        ),
        title: Text(ClinicCards.nodeTitle(store, prefix)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // THE NODE'S OWN ROUTE MAP (Brett, 2026-10-01) on top -
          // the node with NO position gets NO map: the identity line
          // below already says NO POSITION, honestly.
          if (hasFix)
            SizedBox(
              height: 240,
              child: mapBuilder != null
                  ? mapBuilder!(context)
                  : _NodeRouteMap(store: store, prefix: prefix),
            ),
          if (hasFix) const SizedBox(height: 10),
          Text(
            nodeIdentity(store, prefix, nowMs: nowMs),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          for (final row in rows) HealthRowView(row: row),
        ],
      ),
    );
  }
}

/// THE NODE'S OWN ROUTE MAP (Brett, 2026-10-01): the page's node at
/// the center, its routes' lines under the route-line law - each
/// line stops at 75%, chevrons show which way the packets move (in
/// at a dot, out by the end being sent to, one at each end when both
/// ways). Far-node names need a tap (Brett, 2026-10-02), and this
/// map has no tapping - its dots carry the names. Auto-zoomed to
/// the node's nearby hops.
class _NodeRouteMap extends StatelessWidget {
  final NodeStore store;
  final int prefix;
  const _NodeRouteMap({required this.store, required this.prefix});

  List<Route> get _mine => [
        for (final r in store.routes)
          if (r.prefixes.contains(prefix)) r
      ];

  /// Every dot on those routes that has a position (honest: no fix,
  /// no dot), focal node first.
  List<(int, String, double, double)> _dots(List<Route> mine) {
    final out = <(int, String, double, double)>[];
    final seen = <int>{};
    void add(int pfx) {
      if (!seen.add(pfx)) return;
      final d = store.nodes[pfx];
      if (d?.lat == null || d?.lon == null) return;
      out.add((pfx, d!.label, d.lat!, d.lon!));
    }

    add(prefix);
    for (final r in mine) {
      for (final pfx in r.prefixes) {
        add(pfx);
      }
    }
    return out;
  }

  /// The page this map paints: the dots' box, padded 30% (a lone
  /// node gets a small neighborhood box around itself).
  (double, double, double, double) _bounds(
      List<(int, String, double, double)> dots) {
    const padDeg = 0.015;
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final d in dots) {
      minLat = math.min(minLat, d.$3);
      maxLat = math.max(maxLat, d.$3);
      minLon = math.min(minLon, d.$4);
      maxLon = math.max(maxLon, d.$4);
    }
    if (minLat > maxLat) return (-1, -1, 1, 1);
    final padLat = math.max((maxLat - minLat) * 0.3, padDeg);
    final padLon = math.max((maxLon - minLon) * 0.3, padDeg);
    return (minLon - padLon, minLat - padLat, maxLon + padLon, maxLat + padLat);
  }

  /// The span to zoom for: the dots' box in meters (or a small
  /// neighborhood for a lone node).
  double _spanM(List<(int, String, double, double)> dots) {
    const mPerDeg = 111320.0;
    if (dots.length < 2) return 2000.0;
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final d in dots) {
      minLat = math.min(minLat, d.$3);
      maxLat = math.max(maxLat, d.$3);
      minLon = math.min(minLon, d.$4);
      maxLon = math.max(maxLon, d.$4);
    }
    final midLat = (minLat + maxLat) / 2;
    final dy = (maxLat - minLat) * mPerDeg;
    final dx = (maxLon - minLon) * mPerDeg * math.cos(midLat * math.pi / 180);
    return math.max(dx, dy) * 1.6; // margin so labels fit
  }

  @override
  Widget build(BuildContext context) {
    final n = store.nodes[prefix]!;
    final mine = _mine;
    final dots = _dots(mine);
    final edges = MapViewModel.routeEdges(store,
        highlightIds: {for (final r in mine) r.routeId},
        showBackground: false,
        bounds: _bounds(dots));
    return MapLibreMap(
      key: ValueKey('nodemap-$prefix'),
      options: MapOptions(
        initStyle: mapStyleUrl,
        initCenter: Geographic(lon: n.lon!, lat: n.lat!),
        initZoom: MapViewModel.zoomForSpan(_spanM(dots)),
        // Same map lock as the other pages: fingers may zoom, the
        // camera never strays on its own.
        gestures: const MapGestures.none(zoom: true),
      ),
      layers: [
        CircleLayer(
          points: [
            for (final d in dots)
              Feature(geometry: Point(Geographic(lon: d.$4, lat: d.$3))),
          ],
          radius: 6,
          color: const Color(0xFF4A90D9),
          strokeColor: const Color(0xFFFFFFFF),
          strokeWidth: 1,
        ),
        if (edges.isNotEmpty)
          PolylineLayer(
            polylines: edgeLineFeatures(edges),
            color: const Color(0xFFE07A2F),
            width: 3,
          ),
      ],
      children: [
        WidgetLayer(
          allowInteraction: false,
          markers: [
            for (final d in dots)
              Marker(
                point: Geographic(lon: d.$4, lat: d.$3),
                size: const Size(120, 24),
                alignment: Alignment.topCenter,
                child: Text(d.$2,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.black87)),
              ),
            ...routeEdgeMarkers(edges),
          ],
        ),
      ],
    );
  }
}

/// The drawn lines under the route-line law: from each sending dot
/// to its 75% stop - or, for a stub (off-list sender), from the
/// listed node's dot out to the stop, never reaching the sender
/// (Brett, 2026-10-02, corrected). The map engine only ever sees
/// ON-PAGE lines. SHARED with the section page.
List<Feature<LineString>> edgeLineFeatures(Iterable<RouteEdgeVM> edges) => [
      for (final e in edges)
        Feature(
          geometry: LineString([
            e.drawn[0].$1,
            e.drawn[0].$2,
            e.drawn[1].$1,
            e.drawn[1].$2,
          ].positions(Coords.xy)),
        ),
    ];

/// The route-line law's markers - SHARED with the section page:
/// the direction chevrons at every line (at the stop pointing away
/// when the node sends, at the dots pointing in when packets
/// arrive, one at each end when the route runs both ways), and the
/// NEXT node's name ONLY at the tapped route's line (Brett,
/// 2026-10-02: "only show the far node name when the route is
/// tapped on"). A map with no tapping (the node page) shows no
/// names at all.
List<Marker> routeEdgeMarkers(List<RouteEdgeVM> edges,
        {int selectedRoute = 0}) =>
    [
      for (final e in edges) ...[
        if (selectedRoute != 0 && e.routeId == selectedRoute)
          Marker(
            point: Geographic(lon: e.stop.$1, lat: e.stop.$2),
            size: const Size(120, 24),
            alignment: Alignment.topCenter,
            // Only the tapped route's name is ever drawn, so it is
            // always the warm (selected) color.
            child: Text(e.toName,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFFE07A2F))),
          ),
        // A stub's only arrow is the one AT the listed node's dot,
        // pointing into it (Brett's words, 2026-10-02).
        if (e.outArrow && !e.stub)
          _chevron(e.stop, e.bearingDeg, e.hot || e.routeId == selectedRoute),
        if (e.inArrowTo)
          _chevron(e.to, e.bearingDeg, e.hot || e.routeId == selectedRoute),
        if (e.inArrowFrom && !e.stub)
          _chevron(e.from, e.bearingDeg + 180,
              e.hot || e.routeId == selectedRoute),
      ],
    ];

Marker _chevron(MapPoint p, double bearingDeg, bool warm) => Marker(
      point: Geographic(lon: p.$1, lat: p.$2),
      size: const Size(24, 24),
      alignment: Alignment.center,
      child: Transform.rotate(
        // arrow_forward points east; the map is north-up.
        angle: (bearingDeg - 90.0) * math.pi / 180.0,
        child: Icon(Icons.arrow_forward,
            size: 13,
            color: warm ? const Color(0xFFE07A2F) : Colors.black87),
      ),
    );

class RouteDetailScreen extends StatelessWidget {
  final NodeStore store;
  final ClinicStore clinic;
  final Route route; // the wire's record: id, trail, counts, timing
  final VoidCallback onClose;

  const RouteDetailScreen({
    super.key,
    required this.store,
    required this.clinic,
    required this.route,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rows = ClinicCards.routeHealthCard(clinic, route.prefixes,
        nowMs: nowMs);
    final timing =
        route.delayMedS > 0 ? '${route.delayMedS} s' : 'unknown';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('detail-back'),
          tooltip: 'Back to the list',
          icon: const Icon(Icons.arrow_back),
          onPressed: onClose,
        ),
        // NAMED BY ITS HOPS (Brett 2026-10-02): the route's id is a
        // wire number no human can read - the hops' names are.
        title: Text(ClinicCards.routeTitle(store, route.prefixes)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // THE TRAIL VISUAL first (Brett): its nodes, travel order.
          _TrailView(store: store, path: route.prefixes),
          const SizedBox(height: 10),
          Text(
            '${route.prefixes.length} hop(s)'
            ' \u00b7 ${route.packetCount} packet(s)'
            ' \u00b7 time start-to-end: $timing'
            ' \u00b7 last used ${ageText(route.lastHeardMin)} ago'
            ' \u00b7 section ${route.sectionId}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          // ...with names and details underneath.
          for (final p in route.prefixes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                nodeIdentity(store, p, nowMs: nowMs),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          for (final row in rows) HealthRowView(row: row),
        ],
      ),
    );
  }
}

/// THE TRAIL VISUAL (Brett, 2026-09-30: "a visual representation of
/// the route nodes"): the hops laid out in TRAVEL ORDER - a labeled
/// dot per node, arrows between them. A hop the store does not know
/// is honestly grey and unnamed (never invented).
class _TrailView extends StatelessWidget {
  final NodeStore store;
  final List<int> path;
  const _TrailView({required this.store, required this.path});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < path.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Icon(Icons.arrow_forward,
                    size: 14, color: Colors.white54),
              ),            SizedBox(
              key: ValueKey('trail-hop-${path[i]}'),
              width: 64,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: store.nodes[path[i]] == null
                        ? Colors.white24
                        : const Color(0xFF4A90D9),
                    child: Text(
                      path[i].toRadixString(16).padLeft(2, '0'),
                      style: const TextStyle(
                          fontSize: 10, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    // NAME FIRST (Brett 2026-10-02); no name = the
                    // node's own hex key, never an invented word.
                    store.nodes[path[i]]?.name ??
                        'prefix ${path[i].toRadixString(16).padLeft(2, '0')}',
                    key: ValueKey('trail-name-${path[i]}'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 10, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One health row drawn per Brett's approved design (2026-09-29):
/// fixed-scale bars (the pale span runs worst..best, the white tick
/// sits at the average - the wide span IS the coin flip), block bars,
/// the 24-hour strip, compact flag lines, and the muted honest gaps.
/// SHARED: the section map's tap pop-ups and these detail pages draw
/// the same rows (moved here from section_screen, 2026-09-30).
class HealthRowView extends StatelessWidget {
  final HealthRow row;
  const HealthRowView({super.key, required this.row});

  static const _bar = Color(0xFF7FC4FF);
  static const _mute = Color(0xFF9FC0E8);
  static const _amber = Color(0xFFFFD9A8);

  /// One label cell that NEVER wraps mid-word (Brett's bench
  /// 2026-09-29: 'share'/'heard' pushed their last letter to the
  /// next line in the fixed column). A tight fit shrinks the text
  /// instead of breaking it.
  static Widget _cell(String text,
      {required double width,
      TextAlign align = TextAlign.left,
      double fontSize = 12,
      Color? color}) {
    return SizedBox(
        width: width,
        child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment:
                align == TextAlign.right ? Alignment.centerRight : Alignment.centerLeft,
            child: Text(text,
                textAlign: align,
                maxLines: 1,
                style: TextStyle(fontSize: fontSize, color: color))));
  }

  @override
  Widget build(BuildContext context) {
    switch (row) {
      case HealthFamily(:final name):
        return Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6),
          child: Container(
            padding: const EdgeInsets.only(bottom: 3),
            decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.white24))),
            child: SizedBox(
                width: double.infinity,
                child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(name.toUpperCase(),
                        maxLines: 1,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                            color: _amber)))),
          ),
        );
      case HealthChip(:final label):
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(top: 2, bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: label.startsWith('Reported')
                  ? const Color(0xFF22507F)
                  : const Color(0xFF164A85),
              border: Border.all(color: Colors.white54),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.white)),
          ),
        );
      case HealthBar(
          :final key,
          :final value,
          :final spread,
          :final note,
          :final start,
          :final end,
          :final tick
        ):
        return Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Row(children: [
            _cell(key, width: 42, color: _mute),
            _cell(value, width: 58, align: TextAlign.right),
            Expanded(
              child: LayoutBuilder(builder: (ctx, box) {
                final w = box.maxWidth;
                return SizedBox(
                  height: 14,
                  child: Stack(clipBehavior: Clip.none, children: [
                    Positioned(
                        left: 0,
                        top: 3,
                        width: w,
                        height: 8,
                        child: Container(
                            decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(4)))),
                    Positioned(
                        left: w * start,
                        top: 3,
                        width: math.max(2.0, w * (end - start)),
                        height: 8,
                        child: Container(
                            decoration: BoxDecoration(
                                color: _bar,
                                borderRadius: BorderRadius.circular(4)))),
                    Positioned(
                        left: w * tick - 1,
                        top: 0,
                        width: 2,
                        height: 14,
                        child: Container(color: Colors.white)),
                  ]),
                );
              }),
            ),
            _cell(spread.isNotEmpty ? spread : note,
                width: 52, fontSize: 11, color: _mute),
          ]),
        );
      case HealthBlocks(:final key, :final value, :final filled, :final total):
        return Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Row(children: [
            _cell(key, width: 42, color: _mute),
            _cell(value, width: 58, align: TextAlign.right),
            Expanded(
              child: RichText(
                  text: TextSpan(
                      style: const TextStyle(fontSize: 12),
                      children: [
                    TextSpan(
                        text: '\u2588' * filled,
                        style: const TextStyle(
                            color: _bar, letterSpacing: 1)),
                    TextSpan(
                        text: '\u2591' * (total - filled),
                        style: const TextStyle(
                            color: Colors.white24, letterSpacing: 1)),
                  ])),
            ),
          ]),
        );
      case HealthStrip(:final key, :final value, :final bits):
        return Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Row(children: [
            _cell(key, width: 42, color: _mute),
            _cell(value, width: 58, align: TextAlign.right),
            Expanded(
              child: Row(children: [
                for (var i = 0; i < 24; i++)
                  Container(
                    width: 5,
                    height: 10,
                    margin: const EdgeInsets.only(right: 1),
                    color: ((bits >> i) & 1) == 1 ? _bar : Colors.white24,
                  ),
              ]),
            ),
          ]),
        );
      case HealthFlag(:final name, :final detail):
        return Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Text.rich(TextSpan(children: [
            TextSpan(
                text: '\u26a0 $name',
                style: const TextStyle(color: _amber)),
            TextSpan(text: ' \u2014 $detail'),
          ]), style: const TextStyle(fontSize: 12, color: Colors.white)),
        );
      case HealthNote(:final text):
        return Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child:
              Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
        );
      case HealthGap(:final text):
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(text, style: const TextStyle(fontSize: 11, color: _mute)),
        );
    }
  }
}
