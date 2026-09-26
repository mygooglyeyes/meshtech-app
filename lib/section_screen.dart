// THE SECTION DETAIL PAGE (Brett, 2026-09-25): tapping a section of
// the main map opens THIS page over it - one server 3x3 section,
// camera parked on its center at the section's own span. What it
// shows: the nodes WITH their names (tappable), the background route
// lines with their OWN show/hide toggle, and the WARM layer - orange
// route lines, only ever fed by summaries of this exact section (the
// shell gates them; every other background summary is ignored).
//
// TAP RULES (Brett, 2026-09-25), applied here and nowhere skipped:
// a tap selects, the SAME tap deselects, tapping another element
// (node, route, button) moves the selection - nothing ever stays
// selected against his will. A tap on empty map clears everything.
// Route lines are SELECTABLE ONLY for now: the detail info they
// will carry is defined later (Brett) - the selection is the honest
// placeholder, never invented content.

import 'dart:math' as math;

import 'package:flutter/material.dart' hide Route;
import 'package:maplibre/maplibre.dart';

import 'codec.dart' show SectSum;
import 'map_model.dart';
import 'map_screen.dart' show mapStyleUrl;
import 'store.dart';

class SectionScreen extends StatefulWidget {
  /// The live store: dots and lines update as packets land (the
  /// shell rebuilds this page straight from its setState).
  final NodeStore store;

  /// The square that was tapped (Brett, 2026-09-25): its number IS
  /// the section id the wire speaks (1 upper left .. 12 lower
  /// right), and its geography is where this page's camera parks -
  /// the square he tapped, up close.
  final SectionCell cell;

  /// The warm layer: route ids the summaries of THIS section named.
  final List<int> hotRouteIds;

  /// This section's latest summary - the stats line. Null until the
  /// section's own ask-answer (or background rotation) arrives.
  final SectSum? summary;

  final VoidCallback onClose;

  /// Test seam (the same one MainPage offers): a widget test stands
  /// a plain body in for the map, so no live map engine is needed.
  /// Null in the real app.
  final WidgetBuilder? mapBuilder;

  const SectionScreen({
    super.key,
    required this.store,
    required this.cell,
    this.hotRouteIds = const [],
    this.summary,
    required this.onClose,
    this.mapBuilder,
  });

  @override
  State<SectionScreen> createState() => _SectionScreenState();
}

class _SectionScreenState extends State<SectionScreen> {
  MapController? _map;

  /// The page's OWN background toggle (Brett, 2026-09-25): independent
  /// of the main map's - a fresh page starts ON, not saved.
  bool _pastRoutes = true;

  /// THE SELECTION (Brett's tap rules): at most ONE element holds it
  /// - a node prefix OR a route id, 0 = none. Nothing else on the
  /// page ever keeps a selection.
  int _selPrefix = 0;
  int _selRoute = 0;

  /// How close (logical pixels) a tap must come to a drawn line to
  /// count as a hit on it.
  static const _pickTolerance = 22.0;

  /// The camera spans exactly the tapped square - the main map's
  /// own zoom rule (60 km -> z9, each doubling down -> +1, rounded)
  /// applied to the square's own N-S size.
  static double _zoomForSpan(double spanM) =>
      (9 + math.log(60000.0 / spanM) / math.ln2).roundToDouble();

  /// A node's tag tapped: it selects - the same tag again deselects,
  /// a different tag takes it over, and the route selection clears
  /// (ONE element holds the selection, per Brett's rule).
  void _selectNode(int prefix) {
    setState(() {
      _selPrefix = _selPrefix == prefix ? 0 : prefix;
      _selRoute = 0;
    });
  }

  /// The toggle button: flips the background lines AND moves the
  /// selection off whatever held it - a button press never leaves a
  /// selection stranded (Brett's rule: nothing stuck).
  void _toggleRoutes() {
    setState(() {
      _pastRoutes = !_pastRoutes;
      _selPrefix = 0;
      _selRoute = 0;
    });
  }

  /// A tap ON THE MAP (not on a tag - the interactive label layer
  /// eats those): which drawn route line did it hit? Nearest within
  /// the tolerance wins; the same route again deselects; a miss
  /// clears everything - an empty tap selects nothing, ever.
  void _onMapEvent(MapEvent e) {
    if (e is! MapEventClick) return;
    final map = _map;
    if (map == null) return;
    final layers = MapViewModel.routeLayers(widget.store,
        highlightIds: widget.hotRouteIds.toSet(),
        showBackground: _pastRoutes);
    if (layers.isEmpty) {
      setState(() {
        _selPrefix = 0;
        _selRoute = 0;
      });
      return;
    }
    // ONE batched projection of every drawn point to screen pixels,
    // then the pure pick math (unit-tested in map_model).
    final geos = <Geographic>[];
    final shape = <(int, int)>[]; // (routeId, points in this segment)
    for (final l in layers) {
      for (final seg in l.segs) {
        geos.addAll([for (final p in seg) Geographic(lon: p.$1, lat: p.$2)]);
        shape.add((l.routeId, seg.length));
      }
    }
    final pts = map.toScreenLocations(geos);
    final screen = <int, List<List<MapPoint>>>{};
    var i = 0;
    for (final (routeId, len) in shape) {
      final seg = [for (var k = 0; k < len; k++) (pts[i + k].dx, pts[i + k].dy)];
      i += len;
      (screen[routeId] ??= []).add(seg);
    }
    final hit = MapViewModel.routeIdNear(
        screen, (e.screenPoint.dx, e.screenPoint.dy), _pickTolerance);
    setState(() {
      if (hit == null) {
        _selPrefix = 0; // an empty tap clears the lot - nothing
        _selRoute = 0; // can stay selected against Brett's will
      } else if (hit == _selRoute) {
        _selRoute = 0; // the same tap deselects
      } else {
        _selRoute = hit; // a new element takes the selection
        _selPrefix = 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dots = MapViewModel.dots(widget.store, nowMs: nowMs);
    final layers = MapViewModel.routeLayers(widget.store,
        highlightIds: widget.hotRouteIds.toSet(),
        showBackground: _pastRoutes);
    // Paint order: faint background, then the warm summary lines,
    // then the selected line on top - orange lives HERE, never on
    // the main map (Brett, 2026-09-25).
    final faint = <List<MapPoint>>[];
    final hot = <List<MapPoint>>[];
    final sel = <List<MapPoint>>[];
    for (final l in layers) {
      if (l.routeId == _selRoute) {
        sel.addAll(l.segs);
      } else if (l.hot) {
        hot.addAll(l.segs);
      } else {
        faint.addAll(l.segs);
      }
    }
    final body = widget.mapBuilder != null
        ? widget.mapBuilder!(context)
        : _buildMap(dots, faint, hot, sel);
    return Scaffold(
      // The page's own bar: back to the map, which section this is,
      // and the background toggle (Brett: the routes get their OWN
      // button here, independent of the main map's).
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('section-back'),
          tooltip: 'Back to the map',
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onClose,
        ),
        title: Text('Section ${widget.cell.id}'),
        actions: [
          IconButton(
            key: const ValueKey('section-routes'),
            tooltip: _pastRoutes
                ? 'Past route lines: shown (tap to hide)'
                : 'Past route lines: hidden (tap to show)',
            icon: Icon(Icons.route,
                color: _pastRoutes ? Colors.white : Colors.white38),
            onPressed: _toggleRoutes,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // THE STATS LINE: this section's own summary, verbatim
          // from the wire - honest waiting text until it arrives,
          // and nothing at all from any other section (the shell's
          // gate keeps foreign summaries out of this page).
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: Text(
              _statsLine,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }

  /// Segments -> the engine's line features (same shape the main
  /// map paints with - this file only chooses WHAT gets painted).
  static List<Feature<LineString>> paint(List<List<MapPoint>> segs) => [
        for (final seg in segs)
          Feature(
            geometry: LineString(
                [for (final p in seg) ...[p.$1, p.$2]].positions(Coords.xy)),
          ),
      ];

  /// The summary's numbers, restated - no arithmetic, no invention.
  String get _statsLine {
    final s = widget.summary;
    if (s == null) {
      return 'section ${widget.cell.id} - waiting for its summary';
    }
    return 'section ${widget.cell.id} - ${s.activeNodes} active - '
        '${s.packetCount} pkt - p50 ${s.delayP50S}s - '
        'p90 ${s.delayP90S}s';
  }

  Widget _buildMap(
      List<DotVM> dots,
      List<List<MapPoint>> faint,
      List<List<MapPoint>> hot,
      List<List<MapPoint>> sel) {
    final c = widget.cell;
    return MapLibreMap(
      key: ValueKey('sectmap-${c.id}'),
      options: MapOptions(
        initStyle: mapStyleUrl,
        initCenter: Geographic(lon: c.centerLon, lat: c.centerLat),
        initZoom: _zoomForSpan(c.spanLatM),
        // THE MAP LOCK (Brett, 2026-09-26): the same law as the main
        // map - a FIXED close-up of the tapped square, no finger
        // moves it. Taps still select nodes and route lines.
        gestures: const MapGestures.none(),
      ),
      onMapCreated: (c) => _map = c,
      onEvent: _onMapEvent,
      layers: [
        CircleLayer(
          points: [
            for (final d in dots)
              if (d.color != DotColor.stale)
                Feature(geometry: Point(Geographic(lon: d.lon, lat: d.lat))),
          ],
          radius: 6,
          color: const Color(0xFF4A90D9),
          strokeColor: const Color(0xFFFFFFFF),
          strokeWidth: 1,
        ),
        CircleLayer(
          points: [
            for (final d in dots)
              if (d.color == DotColor.stale)
                Feature(geometry: Point(Geographic(lon: d.lon, lat: d.lat))),
          ],
          radius: 6,
          color: const Color(0xFFF5C518),
          strokeColor: const Color(0xFFFFFFFF),
          strokeWidth: 1,
        ),
        if (faint.isNotEmpty)
          PolylineLayer(
            polylines: paint(faint),
            color: const Color(0x554A90D9),
            width: 2,
          ),
        if (hot.isNotEmpty)
          PolylineLayer(
            polylines: paint(hot),
            color: const Color(0xFFE07A2F),
            width: 4,
          ),
        // The selected line draws LAST and heaviest: the selection
        // is visible at a glance, and it is the ONLY other orange.
        if (sel.isNotEmpty)
          PolylineLayer(
            polylines: paint(sel),
            color: const Color(0xFFE07A2F),
            width: 6,
          ),
      ],
      children: [
        WidgetLayer(
          // TAPS ON: names are tappable HERE (unlike the main map)
          // - a tap on a tag selects the node, the same tap
          // deselects (Brett's rule).
          allowInteraction: true,
          markers: [
            for (final d in dots)
              Marker(
                point: Geographic(lon: d.lon, lat: d.lat),
                size: const Size(120, 24),
                alignment: Alignment.topCenter,
                child: GestureDetector(
                  key: ValueKey('sect-node-${d.prefix}'),
                  onTap: () => _selectNode(d.prefix),
                  behavior: HitTestBehavior.opaque,
                  child: Text(
                    d.label,
                    style: TextStyle(
                      fontSize: 11,
                      color: d.prefix == _selPrefix
                          ? const Color(0xFFE07A2F)
                          : Colors.black87,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
