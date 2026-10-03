// THE SECTION DETAIL PAGE (Brett, 2026-09-25): tapping a section of
// the main map opens THIS page over it - one server 3x3 section, a
// SQUARE map (the main page's own shape) whose edges are the
// tapped square's OWN bounds (Brett, 2026-10-02: a bigger 60 km
// section opens wider, snug edge to edge - never the whole map),
// with the main page's Logs bar below it. What it
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

import 'package:flutter/material.dart' hide Route;
import 'package:maplibre/maplibre.dart';

import 'clinic_store.dart';
import 'codec.dart' show Route, SectSum;
import 'detail_screen.dart';
import 'main_page.dart' show SectionBar;
import 'map_model.dart';
import 'map_screen.dart' show mapStyleUrl;
import 'store.dart';

class SectionScreen extends StatefulWidget {
  /// The live store: dots and lines update as packets land (the
  /// shell rebuilds this page straight from its setState).
  final NodeStore store;

  /// The square that was tapped (Brett, 2026-09-25): its number IS
  /// the section id the wire speaks (1 upper left .. 12 lower
  /// right). Its OWN bounds are this page's map edges (Brett,
  /// 2026-10-02): the camera fits the square snug - a bigger 60 km
  /// section opens wider, and no part of the section ever falls
  /// outside the view.
  final SectionCell cell;

  /// THE LOGS (Brett, 2026-10-02: "a bottom section the same as the
  /// main page, that shows the logs as well"): the shell's event
  /// lines under the square map, behind the main page's own bar.
  final List<String> log;

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

  /// LIST ROWS OPEN THE DETAIL PAGE (Brett, 2026-09-30): the
  /// lists' node/route rows hand the tap up to the shell, which
  /// rides the node/route detail page over everything (with its
  /// back button to this list). The MAP's taps keep their own
  /// health-card pop-ups (Brett: lists only).
  final ValueChanged<int> onNodeTap;
  final ValueChanged<Route> onRouteTap;

  /// THE CHOSEN CLINIC FAMILY (Brett, 2026-09-30: "tap a clinic
  /// option, then a section number opens that section map with the
  /// clinic option details - routes or nodes or trouble flags,
  /// whatever was chosen"): when this page opens from the Clinic
  /// page, the chosen family draws on this map, inside the chosen
  /// time window. Null = the plain section page (the map's long
  /// press or a list row's section).
  final ClinicView? clinicView;
  final int clinicWindowMin;

  const SectionScreen({
    super.key,
    required this.store,
    required this.clinic,
    required this.cell,
    this.log = const [],
    this.hotRouteIds = const [],
    this.summary,
    required this.onClose,
    required this.onNodeTap,
    required this.onRouteTap,
    this.clinicView,
    this.clinicWindowMin = 0,
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

  /// THE LOGS BAR (the main page's own): closed by default - the
  /// square map keeps the space, one tap opens the lines.
  bool _logsOpen = false;

  /// THE ENGINE SETTLE (the main page's startup-bug lesson): the
  /// section-fit gets a few instant attempts while the engine
  /// finds its real size, then never touches the camera again -
  /// his pinch owns it from there.
  int _fitsLeft = 4;

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
            for (final row in rows) HealthRowView(row: row),
          ],
        ),
      ),
    );
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

  /// The drawn route line at this screen point: nearest within the
  /// tolerance wins (the pure pick math is unit-tested in
  /// map_model); null = a miss. ONE batched projection of every
  /// drawn point to screen pixels. The hit geometry is the DRAWN
  /// geometry ([RouteEdgeVM.drawn]), stubs included.
  int? _routeHitAt(Offset sp) {
    final map = _map;
    if (map == null) return null;
    final edges = MapViewModel.routeEdges(widget.store,
        highlightIds: widget.hotRouteIds.toSet(),
        showBackground: _pastRoutes,
        bounds: widget.cell.bounds(),
        listedIn: widget.cell);
    if (edges.isEmpty) return null;
    final geos = <Geographic>[];
    final shape = <(int, int)>[]; // (routeId, points in this segment)
    for (final e in edges) {
      geos.addAll([
        Geographic(lon: e.drawn[0].$1, lat: e.drawn[0].$2),
        Geographic(lon: e.drawn[1].$1, lat: e.drawn[1].$2),
      ]);
      shape.add((e.routeId, 2));
    }
    final pts = map.toScreenLocations(geos);
    final screen = <int, List<List<MapPoint>>>{};
    var i = 0;
    for (final (routeId, len) in shape) {
      final seg = [for (var k = 0; k < len; k++) (pts[i + k].dx, pts[i + k].dy)];
      i += len;
      (screen[routeId] ??= []).add(seg);
    }
    return MapViewModel.routeIdNear(screen, (sp.dx, sp.dy), _pickTolerance);
  }

  /// A tap OR A HOLD ON THE MAP (not on a tag - the interactive
  /// label layer eats those). TAP = THE SELECTION ONLY (Brett,
  /// 2026-10-02: the route's card stays hidden until the hold):
  /// nearest line wins, the same route again deselects, a miss
  /// clears everything - an empty tap selects nothing, ever. HOLD
  /// ON A ROUTE LINE = its health report card (the pop-up that used
  /// to ride along with the tap); a hold on bare map does nothing.
  void _onMapEvent(MapEvent e) {
    if (_map == null) return;
    // THE SETTLE FIT: once the engine has its style, the section's
    // exact bounds land (an earlier attempt may have been early).
    if (e is MapEventStyleLoaded) _fitToSection();
    if (e is MapEventClick) {
      final hit = _routeHitAt(e.screenPoint);
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
    } else if (e is MapEventLongClick) {
      // THE CARD OPENS HERE AND ONLY HERE (Brett, 2026-10-02).
      final hit = _routeHitAt(e.screenPoint);
      final r = hit == null ? null : widget.store.route(hit);
      if (r != null) {
        _openHealthCard(
            ClinicCards.routeTitle(widget.store, r.prefixes),
            ClinicCards.routeHealthCard(widget.clinic, r.prefixes,
                nowMs: DateTime.now().millisecondsSinceEpoch));
      }
    }
  }

  /// THE EXACT EDGES (Brett, 2026-10-02): the tapped square's own
  /// bounds ARE this page's map edges - the engine fits them to the
  /// real viewport (contain: the square's longer on-screen axis
  /// hits both edges; the other carries the least possible margin,
  /// never a cropped node and never the whole map). A few instant
  /// attempts ride the engine's settle (the schedule in
  /// onMapCreated); after that this stops touching the camera.
  void _fitToSection() {
    if (_map == null || !mounted || _fitsLeft <= 0) return;
    _fitsLeft--;
    final (minLon, minLat, maxLon, maxLat) = widget.cell.bounds();
    try {
      _map!.fitBounds(
        bounds: LngLatBounds(
          longitudeWest: minLon,
          longitudeEast: maxLon,
          latitudeSouth: minLat,
          latitudeNorth: maxLat,
        ),
        nativeDuration: Duration.zero,
      );
    } catch (_) {
      // The engine is not ready THIS attempt - the next settle
      // attempt carries it. Never fatal, never a fabricated view.
    }
  }

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dots = MapViewModel.dots(widget.store, nowMs: nowMs);
    // THE ROUTE-LINE LAW (Brett, 2026-10-01): lines stop at 75%,
    // chevrons show the packets' direction - and nothing draws off
    // this page. The NEXT node's name labels only the TAPPED
    // route's line end (Brett, 2026-10-02). And the LISTED LINES
    // RULE (same day): a line draws when it comes to or leaves a
    // node this section's list names - zooming out never paints
    // other sections' lines.
    final edges = MapViewModel.routeEdges(widget.store,
        highlightIds: widget.hotRouteIds.toSet(),
        showBackground: _pastRoutes,
        bounds: widget.cell.bounds(),
        listedIn: widget.cell);
    // Paint order: faint background, then the warm summary lines,
    // then the selected line on top - orange lives HERE, never on
    // the main map (Brett, 2026-09-25).
    final faint = <List<MapPoint>>[];
    final hot = <List<MapPoint>>[];
    final sel = <List<MapPoint>>[];
    for (final e in edges) {
      final line = [e.from, e.stop]; // the law: never past the stop
      if (e.routeId == _selRoute) {
        sel.add(line);
      } else if (e.hot) {
        hot.add(line);
      } else {
        faint.add(line);
      }
    }
    final body = _showList
        ? _listBody()
        : widget.mapBuilder != null
            ? widget.mapBuilder!(context)
            : _buildMap(dots, faint, hot, sel, _clinicLayer(nowMs), edges);
    return Scaffold(
      // The page's own bar: back to the map, which section this is,
      // the map/list switch (Brett, 2026-09-30), and the background
      // toggle (Brett: the routes get their OWN button here,
      // independent of the main map's).
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('section-back'),
          // The honest destination (Brett, 2026-09-30): from the
          // Clinic page's flow the button returns THERE, not to the
          // map.
          tooltip: widget.clinicView != null
              ? 'Back to the clinic page'
              : 'Back to the map',
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
          // THE SQUARE MAP (Brett, 2026-10-02): the main page's
          // own shape - the tapped section's bounds fit it edge to
          // edge (the settle fit above does the placing). Loose +
          // capped: a short screen shrinks the square instead of
          // overflowing, and the Logs bar keeps its room.
          Flexible(
            fit: FlexFit.loose,
            child: AspectRatio(aspectRatio: 1, child: body),
          ),
          // THE LOGS (Brett, same day: "a bottom section the same
          // as the main page, that shows the logs as well") - the
          // same bar, the same lines, closed by default like the
          // main page.
          SectionBar(
            label: 'Logs',
            open: _logsOpen,
            onToggle: () => setState(() {
              _logsOpen = !_logsOpen;
              // A resized map earns ONE fresh edge-fit.
              if (_fitsLeft <= 0) _fitsLeft = 1;
            }),
            child: SizedBox(
              height: 140,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(34, 6, 12, 8),
                children: [
                  for (final line in widget.log)
                    Text(line,
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// THE LIST (Brett, 2026-09-30 - the main page's own option):
  /// THIS square's nodes and routes as tappable rows, because
  /// overlapping map labels eat taps. A row opens the DETAIL page
  /// (Brett, same day) - its back button returns to this list.
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
                      title: Text(n.name ??
                          'prefix ${n.prefix.toRadixString(16).padLeft(2, '0')}'),
                      subtitle: Text(
                        'prefix ${n.prefix.toRadixString(16).padLeft(2, '0')}'
                        ' - heard ${ageText(n.lastHeardMs)} ago',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      onTap: () => widget.onNodeTap(n.prefix),
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
                      // NAMED BY ITS HOPS (Brett 2026-10-02): the
                      // route id is a wire number, never an identity.
                      title: Text(
                          ClinicCards.routeTitle(widget.store, r.prefixes)),
                      subtitle: Text(
                        '${r.prefixes.length} hop(s)'
                        ' - ${r.packetCount} packet(s)'
                        ' - section ${r.sectionId}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      onTap: () => widget.onRouteTap(r),
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

  /// THE CHOSEN CLINIC FAMILY (Brett, 2026-09-30): the family the
  /// Clinic page chose, built for THIS frame - rings and lines,
  /// colored by honest state. Null on the plain section page.
  ClinicLayer? _clinicLayer(int nowMs) => widget.clinicView == null
      ? null
      : ClinicLayerVM.build(widget.clinic, widget.store, widget.clinicView!,
          nowMs: nowMs, windowMin: widget.clinicWindowMin);

  static const _clinicColors = [
    (ClinicColor.fresh, Color(0xFF4A90D9)),
    (ClinicColor.aging, Color(0xFFF5C518)),
    (ClinicColor.trouble, Color(0xFFE53935)),
    (ClinicColor.secondHand, Color(0xFF26A69A)),
  ];
  static const _clinicLineColors = [
    (ClinicColor.fresh, Color(0xFF4A90D9)),
    (ClinicColor.aging, Color(0xFFF5C518)),
    (ClinicColor.secondHand, Color(0xFF26A69A)),
  ];
  static List<Feature<Point>> _clinicDots(ClinicLayer layer, ClinicColor c) => [
        for (final m in layer.markers)
          if (m.color == c)
            Feature(geometry: Point(Geographic(lon: m.lon, lat: m.lat))),
      ];
  static List<Feature<LineString>> _clinicLines(
          ClinicLayer layer, ClinicColor c) =>
      [
        for (final l in layer.lines)
          if (l.color == c)
            for (final seg in l.segs)
              Feature(
                geometry: LineString(
                    [for (final p in seg) ...[p.$1, p.$2]].positions(Coords.xy)),
              ),
      ];

  Widget _buildMap(
      List<DotVM> dots,
      List<List<MapPoint>> faint,
      List<List<MapPoint>> hot,
      List<List<MapPoint>> sel,
      ClinicLayer? clinic,
      List<RouteEdgeVM> edges) {
    final c = widget.cell;
    return MapLibreMap(
      key: ValueKey('sectmap-${c.id}'),
      options: MapOptions(
        initStyle: mapStyleUrl,
        initCenter: Geographic(lon: c.centerLon, lat: c.centerLat),
        initZoom: MapViewModel.zoomForSpan(c.spanLatM), // first frame only
        // PINCH TO ZOOM (Brett, 2026-09-30: node labels overlap and
        // taps miss - "we need to be able to zoom in"): the camera
        // still ignores stray drags and tilts (the map lock's
        // spirit), but the fingers may zoom - around their own
        // midpoint, so any crowded cluster is reachable.
        gestures: const MapGestures.none(zoom: true),
      ),
      onMapCreated: (c) {
        _map = c;
        _fitToSection();
        // The engine settles over its first seconds (the main
        // page's startup-bug lesson): two more instant attempts,
        // then the camera belongs to his fingers for good.
        for (final delay in const [400, 1500]) {
          Future.delayed(Duration(milliseconds: delay), _fitToSection);
        }
      },
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
        // THE CHOSEN CLINIC FAMILY (Brett, 2026-09-30): rings per
        // fact and its lines, colored by honest state (fresh blue /
        // aging yellow / trouble red / second-hand teal) - on top
        // of the plain map. A second-hand fact NEVER wears a
        // first-hand color (CLINIC-WIRE provenance rule).
        if (clinic != null)
          for (final (c2, col) in _clinicColors)
            if (_clinicDots(clinic, c2).isNotEmpty)
              CircleLayer(
                points: _clinicDots(clinic, c2),
                radius: c2 == ClinicColor.trouble ? 9 : 8,
                color: col,
                strokeColor: const Color(0xFFFFFFFF),
                strokeWidth: 2,
              ),
        if (clinic != null)
          for (final (c2, col) in _clinicLineColors)
            if (_clinicLines(clinic, c2).isNotEmpty)
              PolylineLayer(
                polylines: _clinicLines(clinic, c2),
                color: col,
                width: 3,
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
            // THE ROUTE-LINE LAW's markers: the direction chevrons
            // at every line + the next node's name only at the
            // tapped route's line end (Brett, 2026-10-02).
            ...routeEdgeMarkers(edges, selectedRoute: _selRoute),
          ],
        ),
        if (clinic != null)
          WidgetLayer(
            // THE PEER CLAIMS (the Second-hand family's labels): a
            // claim drawn where the peer SAID it is, wearing its
            // 'reported' tag - the phone's own dot stays where it
            // was, never merged.
            key: ValueKey('claims-${widget.cell.id}'),
            markers: [
              for (final m in clinic.markers)
                if (m.claim)
                  Marker(
                    point: Geographic(lon: m.lon, lat: m.lat),
                    size: const Size(120, 24),
                    alignment: Alignment.bottomCenter,
                    child: Text(
                      m.label,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black87),
                    ),
                  ),
            ],
          ),
      ],
    );
  }
}
