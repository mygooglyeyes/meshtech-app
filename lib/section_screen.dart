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
// THE DETAIL (Brett, 2026-09-29): a tap on a node or a route ALSO
// opens its health report card - the four health families as bars
// and strips (his approved graphical design), every fact chipped
// Direct/Reported, and an honest "not measured yet" wherever the
// mesh carries no such fact.

import 'dart:math' as math;

import 'package:flutter/material.dart' hide Route;
import 'package:maplibre/maplibre.dart';

import 'clinic_store.dart';
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

  /// The clinic facts - where a tap's health card reads from.
  final ClinicStore clinic;

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
    required this.clinic,
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

  /// The page's OWN background toggle (Brett, 2026-09-25, reversed
  /// 2026-09-29): independent of the main map's - PUSH TO SEE, hidden
  /// by default, not saved.
  bool _pastRoutes = false;

  /// MAP OR LIST (Brett, 2026-09-30: node labels overlap and taps
  /// miss - "pinch to zoom, and the same 'list' option as the main
  /// page"). The list shows THIS square's nodes and routes as
  /// tappable rows - the same tap rules and the same health cards.
  bool _showList = false;

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
  /// (ONE element holds the selection, per Brett's rule). The tap
  /// ALSO opens the node's health report card (Brett, 2026-09-29).
  void _selectNode(int prefix) {
    setState(() {
      _selPrefix = _selPrefix == prefix ? 0 : prefix;
      _selRoute = 0;
    });
    _openHealthCard(
        ClinicCards.nodeTitle(widget.store, prefix),
        ClinicCards.nodeHealthCard(widget.clinic, prefix,
            nowMs: DateTime.now().millisecondsSinceEpoch));
  }

  /// The detail card (Brett's approved graphical design): the title,
  /// then the rows - chips, fixed-scale bars, strips, flags, and the
  /// muted honest gaps.
  void _openHealthCard(String title, List<HealthRow> rows) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final row in rows) _HealthRowView(row: row),
          ],
        ),
      ),
    );
  }

  /// A route tapped from the LIST: the same tap rules as the map -
  /// the same route deselects, a new one takes over, and its health
  /// card opens (Brett, 2026-09-30).
  void _selectRoute(int routeId) {
    setState(() {
      _selRoute = _selRoute == routeId ? 0 : routeId;
      _selPrefix = 0;
    });
    final r = widget.store.route(routeId);
    if (r != null) {
      _openHealthCard(
          ClinicCards.routeTitle(r.prefixes),
          ClinicCards.routeHealthCard(widget.clinic, r.prefixes,
              nowMs: DateTime.now().millisecondsSinceEpoch));
    }
  }

  /// The map/list switch (the main page's own option, 2026-09-30):
  /// flipping it moves the selection off whatever held it - a button
  /// press never leaves a selection stranded (Brett's rule: nothing
  /// stuck).
  void _toggleList() {
    setState(() {
      _showList = !_showList;
      _selPrefix = 0;
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
    // A tap ON a route ALSO opens its health report card (Brett,
    // 2026-09-29) - the tap rules above never changed.
    if (hit != null) {
      final r = widget.store.route(hit);
      if (r != null) {
        _openHealthCard(
            ClinicCards.routeTitle(r.prefixes),
            ClinicCards.routeHealthCard(widget.clinic, r.prefixes,
                nowMs: DateTime.now().millisecondsSinceEpoch));
      }
    }
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
    final body = _showList
        ? _listBody()
        : widget.mapBuilder != null
            ? widget.mapBuilder!(context)
            : _buildMap(dots, faint, hot, sel);
    return Scaffold(
      // The page's own bar: back to the map, which section this is,
      // the map/list switch (Brett, 2026-09-30), and the background
      // toggle (Brett: the routes get their OWN button here,
      // independent of the main map's).
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
            key: const ValueKey('section-list'),
            tooltip: _showList ? 'Switch to the map' : 'Switch to the list',
            icon: Icon(_showList ? Icons.map : Icons.list),
            onPressed: _toggleList,
          ),
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

  /// THE LIST (Brett, 2026-09-30 - the main page's own option):
  /// THIS square's nodes and routes as tappable rows, because
  /// overlapping map labels eat taps. A row follows the page's tap
  /// rules and opens the same health card the map does.
  Widget _listBody() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cell = widget.cell;
    final nodes = [
      for (final n in widget.store.nodes.values)
        if (n.lat != null && n.lon != null && cell.contains(n.lat!, n.lon!))
          n,
    ]..sort((a, b) => (a.name ?? a.prefix.toString())
        .toLowerCase()
        .compareTo((b.name ?? b.prefix.toString()).toLowerCase()));
    final routes = [
      for (final r in widget.store.routes)
        if (r.sectionId == cell.id) r, // this square's own routes
    ]..sort((a, b) => a.routeId.compareTo(b.routeId));
    String ageText(int lastHeardMs) {
      final ageMin = ((nowMs - lastHeardMs) / 60000).round();
      return ageMin < 60
          ? '$ageMin min'
          : ageMin < 1440
              ? '${ageMin ~/ 60} h'
              : '${ageMin ~/ 1440} d';
    }
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: const TabBar(tabs: [
              Tab(text: 'Nodes'),
              Tab(text: 'Routes'),
            ]),
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView.builder(
                  itemCount: nodes.length,
                  itemBuilder: (context, i) {
                    final n = nodes[i];
                    return ListTile(
                      dense: true,
                      key: ValueKey('sect-list-node-${n.prefix}'),
                      leading: const Icon(Icons.place,
                          color: Color(0xFF4A90D9), size: 20),
                      title: Text(n.name ?? 'prefix ${n.prefix}'),
                      subtitle: Text(
                        'prefix ${n.prefix.toRadixString(16).padLeft(2, '0')}'
                        ' - heard ${ageText(n.lastHeardMs)} ago',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      onTap: () => _selectNode(n.prefix),
                    );
                  },
                ),
                ListView.builder(
                  itemCount: routes.length,
                  itemBuilder: (context, i) {
                    final r = routes[i];
                    return ListTile(
                      dense: true,
                      key: ValueKey('sect-list-route-${r.routeId}'),
                      leading: const Icon(Icons.route, size: 20),
                      title: Text('route ${r.routeId}'),
                      subtitle: Text(
                        '${r.prefixes.length} hop(s)'
                        ' - ${r.packetCount} packet(s)'
                        ' - section ${r.sectionId}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      onTap: () => _selectRoute(r.routeId),
                    );
                  },
                ),
              ],
            ),
          ),
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
        // PINCH TO ZOOM (Brett, 2026-09-30: node labels overlap and
        // taps miss - "we need to be able to zoom in"): the camera
        // still ignores stray drags and tilts (the map lock's
        // spirit), but the fingers may zoom - around their own
        // midpoint, so any crowded cluster is reachable.
        gestures: const MapGestures.none(zoom: true),
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

/// One health row drawn per Brett's approved design (2026-09-29):
/// fixed-scale bars (the pale span runs worst..best, the white tick
/// sits at the average - the wide span IS the coin flip), block bars,
/// the 24-hour strip, compact flag lines, and the muted honest gaps.
class _HealthRowView extends StatelessWidget {
  final HealthRow row;
  const _HealthRowView({required this.row});

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
