// The map screen (design section 8): MapLibre draws the real map; the
// view-model (map_model.dart) decides WHAT is drawn - dots, labels,
// colors. The chosen size (settings) is the VIEW: the camera spans
// exactly that window, and the re-cut puts every node at its honest
// fraction of it. Changing the size later re-cuts the same data - it
// never asks hilltop for anything.
//
// THE WEB APP'S FURNITURE (Brett, 2026-09-24): on-screen navigation
// buttons (recenter on home, zoom), the feed-health box (fed by the
// PULSE that rides the whole-area answer), and the log - all here.
//
// API note: written against maplibre 0.3.6's DECLARATIVE layers
// (CircleLayer/MarkerLayer as widget state) - the map repaints when
// the store changes because the layers are rebuilt from the VM. The
// controller arrives via onMapCreated and drives the camera.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maplibre/maplibre.dart';

import 'clinic_store.dart';
import 'map_model.dart';
import 'settings.dart';
import 'store.dart';

/// The daylight style (design section 8: the colorful "real map"
/// look - CARTO Voyager, the free tile family; NO dark mode until
/// Brett's filters chapter).
const mapStyleUrl =
    'https://basemaps.cartocdn.com/gl/voyager-gl-style/style.json';

class MapScreen extends StatefulWidget {
  final NodeStore store;

  /// THE CLINIC (Mesh Clinic v2): the store's clinic facts - the
  /// simple health layer, its five fact-family views and the tap-
  /// detail cards draw from here (never from anywhere else).
  final ClinicStore clinic;
  final ConnectionSettings settings;
  final (double, double)? frameCenter;
  final VoidCallback onAsk; // THE UPDATE BUTTON: the phone asks, over the door
  final ValueChanged<int> onMapSizeChange; // +/- = 20/40/60, redraw only
  /// A TAP ON A SQUARE (Brett, 2026-09-25): the squares carry their
  /// section numbers (1 upper left .. 12 lower right), and tapping a
  /// square opens the section with that number. The map itself takes
  /// no node taps and holds no selection.
  final ValueChanged<SectionCell>? onSectionTap;

  const MapScreen({
    super.key,
    required this.store,
    required this.clinic,
    required this.settings,
    this.frameCenter,
    required this.onAsk,
    required this.onMapSizeChange,
    this.onSectionTap,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  MapController? _map;
  ViewGrid? _grid; // THE PHONE'S 3x4 VIEW GRID on the visible region
  int _overlayTick = 0; // bumped = labels/grid recompute their spots

  /// THE CLINIC VIEW (Brett's pick): which fact family the simple
  /// health layer draws - all facts / node health / route health /
  /// trouble flags / second-hand peer reports. Switching views only
  /// changes the DRAWING (rule 2) - never an ask, never a removal.
  ClinicView _clinicView = ClinicView.all;
  ClinicLayer? _clinicLayer; // last build's layer (tap targeting)

  /// The tap's tolerance as a FINGER'S WIDTH on the tall map: a
  /// fraction of the visible window (the size selector couples zoom
  /// to window, so this lands near-constant on screen).
  static const clinicTapFraction = 0.05;

  /// BRETT'S ROUTE-LINE TOGGLE (2026-09-25, reversed 2026-09-29):
  /// the PAST route lines (what the store holds) show/hide. PUSH TO
  /// SEE - hidden by default, the button reveals them. Not saved -
  /// a fresh launch starts OFF.
  bool _pastRoutes = false;

  /// Re-cut the view grid onto what the screen ACTUALLY shows right
  /// now (Brett's 3x4, 2026-09-24) - so the lines and cell counts
  /// always match the tall screen, at any size or pan.
  void _updateGrid() {
    final map = _map;
    if (map == null || !mounted) return;
    try {
      final b = map.getVisibleRegion();
      final lat = (b.latitudeNorth + b.latitudeSouth) / 2;
      final lon = (b.longitudeWest + b.longitudeEast) / 2;
      const mPerDeg = 111320.0;
      final next = ViewGrid(
        centerLat: lat,
        centerLon: lon,
        spanLatM: (b.latitudeNorth - b.latitudeSouth) * mPerDeg,
        spanLonM: (b.longitudeEast - b.longitudeWest) *
            mPerDeg *
            math.cos(lat * math.pi / 180.0),
      );
      if (_grid == null || _grid != next) {
        setState(() {
          _grid = next;
          _overlayTick++;
        });
      }
    } catch (_) {
      // The engine may not be ready in the first frames - the grid
      // simply arrives with the next camera event. Honest blank.
    }
  }

  /// Force the overlays (labels, badges) to recompute their screen
  /// spots. THE STARTUP BUG (Brett, 2026-09-24): labels landed way
  /// off until the first camera move, because the first compute ran
  /// before the engine settled its real size. The style-loaded event
  /// and a few short timers after creation each force one recompute
  /// - after that, camera events keep them honest.
  void _refreshOverlays() {
    if (!mounted) return;
    setState(() => _overlayTick++);
  }

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dots = MapViewModel.dots(widget.store, nowMs: nowMs);
    // THE CLINIC LAYER (Mesh Clinic v2): one ring per drawn fact,
    // colored by its honest state (fresh blue / aging yellow /
    // trouble red / second-hand teal). A second-hand fact NEVER
    // wears a first-hand color (CLINIC-WIRE provenance rule), and a
    // fact with no place draws nowhere - counted out loud below.
    final clinic =
        ClinicLayerVM.build(widget.clinic, widget.store, _clinicView,
            nowMs: nowMs);
    _clinicLayer = clinic; // tap targeting reads it between builds
    List<Feature<Point>> clinicDots(ClinicColor c) => [
          for (final m in clinic.markers)
            if (m.color == c)
              Feature(geometry: Point(Geographic(lon: m.lon, lat: m.lat))),
        ];
    List<Feature<LineString>> clinicLines(ClinicColor c) => [
          for (final l in clinic.lines)
            if (l.color == c)
              for (final seg in l.segs)
                Feature(
                  geometry: LineString([for (final p in seg) ...[p.$1, p.$2]]
                      .positions(Coords.xy)),
                ),
        ];
    const clinicColors = [
      (ClinicColor.fresh, Color(0xFF4A90D9)),
      (ClinicColor.aging, Color(0xFFF5C518)),
      (ClinicColor.trouble, Color(0xFFE53935)),
      (ClinicColor.secondHand, Color(0xFF26A69A)),
    ];
    const clinicLineColors = [
      (ClinicColor.fresh, Color(0xFF4A90D9)),
      (ClinicColor.aging, Color(0xFFF5C518)),
      (ClinicColor.secondHand, Color(0xFF26A69A)),
    ];
    final s = widget.settings;
    // The grid's per-cell counts, computed ONCE per build.
    final cellCounts = _grid?.counts(widget.store);
    // THE ROUTE LINES: the view-model DECIDES what is drawn (known
    // dots only, honest gaps) - this file only paints it. NO ORANGE
    // EVER ON THIS MAP (Brett, 2026-09-25): no highlight ids, no
    // selection - the warm layer lives on the section detail page.
    // _pastRoutes is Brett's toggle: OFF hides these lines.
    final lines = MapViewModel.routeLines(widget.store,
        highlightIds: const {}, showBackground: _pastRoutes);
    List<Feature<LineString>> paint(List<List<MapPoint>> segs) => [
          for (final seg in segs)
            Feature(
              geometry: LineString(
                  [for (final p in seg) ...[p.$1, p.$2]]
                      .positions(Coords.xy)),
            ),
        ];
    final faintLines = paint(lines.background);
    // Center: the ZIP home area (hard data, section 9) wins; a heard
    // LAYOUT fills it in for clients without a home ZIP yet.
    final home = s.homeLon != 0
        ? (s.homeLat, s.homeLon)
        : widget.frameCenter ?? (38.0, -122.0);
    return Scaffold(
      // No app bar of its own: the main page's SECTION BARS frame
      // the map (Brett's layout, 2026-09-25). The map keeps its own
      // furniture on the canvas - recenter, refresh, and the +/-
      // coverage steps.
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                MapLibreMap(
                  key: ValueKey('map-${home.$1}-${home.$2}'),
                  options: MapOptions(
                    initStyle: mapStyleUrl,
                    initCenter: Geographic(lon: home.$2, lat: home.$1),
                    initZoom: _zoomFor(s.mapSizeKm),
                    // THE MAP LOCK (Brett, 2026-09-26): the camera
                    // is PARKED - home area at the chosen size - and
                    // no finger can move it (no drag, pinch, turn or
                    // tilt). The +/- buttons are the ONLY camera
                    // move: they step the size 20/40/60 and re-centre
                    // on home. Taps still open their square's section.
                    gestures: const MapGestures.none(),
                  ),
                  onMapCreated: (c) {
                    _map = c;
                    // The engine settles over its first seconds:
                    // re-spot the overlays after style load AND on a
                    // few timers, so nothing waits for a human to
                    // move the camera (the startup-bug fix).
                    for (final delay in const [200, 600, 1500, 3000]) {
                      Future.delayed(
                          Duration(milliseconds: delay), _refreshOverlays);
                    }
                  },
                  onEvent: (e) {
                    _updateGrid();
                    if (e is MapEventStyleLoaded) _refreshOverlays();
                    // A TAP ON A SQUARE = THAT SECTION'S PAGE (Brett,
                    // 2026-09-25): the tapped square's NUMBER opens
                    // the section with that number - what he sees is
                    // what he taps, never re-derived from geography.
                    if (e is MapEventClick && _grid != null) {
                      // THE CLINIC TAP (Mesh Clinic v2): a tap ON a
                      // clinic fact opens its detail card - every
                      // line labeled first-hand/second-hand. A tap
                      // anywhere else opens the square's section:
                      // the section law, unchanged.
                      final layer = _clinicLayer;
                      if (layer != null) {
                        final hit = ClinicLayerVM.hitTest(
                            layer,
                            (e.point.lon, e.point.lat),
                            _grid!.spanLatM * clinicTapFraction);
                        if (hit != null) {
                          _showClinicCard(hit);
                          return;
                        }
                      }
                      final i = _grid!.cellIndex(e.point.lat, e.point.lon);
                      if (i >= 0) widget.onSectionTap?.call(_grid!.cell(i));
                    }
                  },
                  layers: [
                    // Fresh dots (blue), stale dots (YELLOW - Brett's
                    // color; the queued stale-packet will feed the
                    // server's own 14-day verdict instead of the age
                    // math here).
                    CircleLayer(
                      points: [
                        for (final d in dots)
                          if (d.color != DotColor.stale)
                            Feature(
                                geometry: Point(Geographic(
                                    lon: d.lon, lat: d.lat))),
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
                            Feature(
                                geometry: Point(Geographic(
                                    lon: d.lon, lat: d.lat))),
                      ],
                      radius: 6,
                      color: const Color(0xFFF5C518),
                      strokeColor: const Color(0xFFFFFFFF),
                      strokeWidth: 1,
                    ),
                    // THE ROUTE LINES (design section 10): faint for
                    // what the store holds - and NOTHING warm. The
                    // main map never draws orange (Brett, 2026-09-25);
                    // the detail page owns that layer.
                    if (faintLines.isNotEmpty)
                      PolylineLayer(
                        polylines: faintLines,
                        color: const Color(0x554A90D9),
                        width: 2,
                      ),
                    // THE PHONE'S GRID (3 wide x 4 tall, Brett's call)
                    // drawn over the map, cut on the VISIBLE region.
                    if (_grid != null)
                      PolylineLayer(
                        polylines: [
                          for (final (lon1, lat1, lon2, lat2)
                              in _grid!.lines())
                            Feature(
                              geometry: LineString(
                                [lon1, lat1, lon2, lat2]
                                    .positions(Coords.xy),
                              ),
                            ),
                        ],
                        color: const Color(0x664A90D9),
                        width: 1,
                      ),
                    // THE CLINIC LAYER draws ON TOP (the simple
                    // health layer): rings per fact + its lines.
                    for (final (c, col) in clinicColors)
                      if (clinicDots(c).isNotEmpty)
                        CircleLayer(
                          points: clinicDots(c),
                          radius: c == ClinicColor.trouble ? 9 : 8,
                          color: col,
                          strokeColor: const Color(0xFFFFFFFF),
                          strokeWidth: 2,
                        ),
                    for (final (c, col) in clinicLineColors)
                      if (clinicLines(c).isNotEmpty)
                        PolylineLayer(
                          polylines: clinicLines(c),
                          color: col,
                          width: 3,
                        ),
                  ],
                  // Names on the map, every screen (section 8):
                  // "Hilltop ab" - name + pubkey head. The cell-count
                  // badges ride the same widget list.
                  children: [
                    if (_grid != null)
                      WidgetLayer(
                        // The tick key forces the marker layer to
                        // recompute its screen spots (startup fix).
                        key: ValueKey('badges-$_overlayTick'),
                        markers: [
                          // THE SECTION NUMBERS (Brett, 2026-09-26,
                          // his exact spec): a SOLID BLUEPRINT-WHITE
                          // core - the same white as the blueline
                          // lines - so the whole number is always
                          // readable, wrapped in a fading outline in
                          // blueprint blue that dies out into the
                          // map. 1 upper left .. 12 lower right -
                          // the numbers the wire speaks: tap square
                          // N, open section N.
                          for (final (i, (lat, lon))
                              in _grid!.cellCenters().indexed)
                            Marker(
                              point: Geographic(lon: lon, lat: lat),
                              size: const Size(100, 100),
                              child: Center(
                                child: Text(
                                  '${i + 1}',
                                  style: const TextStyle(
                                    fontSize: 52,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFFFFFFFF),
                                    shadows: [
                                      // the fading blue outline:
                                      // tight at the white core's
                                      // edge, then wider and
                                      // fainter into the map
                                      Shadow(
                                          color: Color(0xFF0F3A72),
                                          blurRadius: 7),
                                      Shadow(
                                          color: Color(0x660F3A72),
                                          blurRadius: 20),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          // THE ACTIVE-NODE COUNTS (Brett): very
                          // small text in each square's UPPER LEFT
                          // (they used to sit in the middle). Only
                          // non-empty squares speak (honest, quiet).
                          for (final (i, (lat, lon))
                              in _grid!.cellCenters().indexed)
                            if ((cellCounts?[i] ?? 0) > 0)
                              Marker(
                                point: Geographic(
                                    lon: _cellNW(_grid!, lat, lon).$2,
                                    lat: _cellNW(_grid!, lat, lon).$1),
                                size: const Size(36, 16),
                                alignment: Alignment.topLeft,
                                child: Text(
                                  '${cellCounts![i]}',
                                  style: const TextStyle(
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0F3A72),
                                  ),
                                ),
                              ),
                        ],
                      ),
                    WidgetLayer(
                      // THE PEER CLAIMS (Mesh Clinic v2): the only
                      // clinic labels - a claim drawn where the peer
                      // SAID it is, wearing its '2nd' tag where
                      // nothing else names the spot. Everywhere else
                      // the base labels already name the node.
                      key: ValueKey('claims-$_overlayTick'),
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
                    WidgetLayer(
                      // NO NODE TAPS ON THE MAIN MAP (Brett,
                      // 2026-09-25): the layer's default
                      // (TranslucentPointer) passes every touch
                      // THROUGH to the map, so a tap on or between
                      // the tags resolves into a section and opens
                      // its detail page. The tick key re-spots the
                      // labels (startup fix).
                      key: ValueKey('labels-$_overlayTick'),
                      markers: [
                        for (final d in dots)
                          Marker(
                            point: Geographic(lon: d.lon, lat: d.lat),
                            size: const Size(120, 24),
                            alignment: Alignment.topCenter,
                            // Bare text over the map (Brett,
                            // 2026-09-24): no box, no highlight -
                            // this map holds no selection at all.
                            child: Text(
                              d.label,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.black87),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                // THE NAVIGATION BUTTONS: recenter on home, zoom in,
                // zoom out - the map stays in Brett's hands.
                Positioned(
                  right: 8,
                  top: 8,
                  child: Column(
                    children: [
                      _NavButton(
                        icon: Icons.home_outlined,
                        tooltip: 'Center on home',
                        onTap: () => _map?.moveCamera(
                            center: Geographic(
                                lon: home.$2, lat: home.$1),
                            zoom: _zoomFor(s.mapSizeKm)),
                      ),
                      // THE UPDATE (Brett, 2026-09-24): the phone asks
                      // for the area data NOW - map furniture, as the
                      // web app had it. Refusals land in the log
                      // section below.
                      _NavButton(
                        icon: Icons.refresh,
                        tooltip: 'Update now (ask hilltop)',
                        onTap: widget.onAsk,
                      ),
                      // THE SIZE BUTTONS (Brett, 2026-09-24): +/-
                      // step through the 20/40/60 map sizes and
                      // re-center - a REDRAW ONLY change (rule 2),
                      // never an ask to hilltop.
                      _NavButton(
                        icon: Icons.add,
                        tooltip: 'Map size: closer (20/40/60)',
                        onTap: () {
                          final km =
                              ConnectionSettings.nextCloser(
                                  s.mapSizeKm);
                          widget.onMapSizeChange(km);
                          _map?.moveCamera(
                              center: Geographic(
                                  lon: home.$2, lat: home.$1),
                              zoom: _zoomFor(km));
                        },
                      ),
                      _NavButton(
                        icon: Icons.remove,
                        tooltip: 'Map size: farther (20/40/60)',
                        onTap: () {
                          final km =
                              ConnectionSettings.nextFarther(
                                  s.mapSizeKm);
                          widget.onMapSizeChange(km);
                          _map?.moveCamera(
                              center: Geographic(
                                  lon: home.$2, lat: home.$1),
                              zoom: _zoomFor(km));
                        },
                      ),
                      // THE ROUTE-LINE TOGGLE (Brett 2026-09-25):
                      // hide/show the faint background lines. This
                      // map draws nothing else now - the warm layer
                      // lives on the section detail page.
                      _NavButton(
                        icon: Icons.route,
                        on: _pastRoutes,
                        tooltip: _pastRoutes
                            ? 'Past route lines: shown (tap to hide)'
                            : 'Past route lines: hidden (tap to show)',
                        onTap: () =>
                            setState(() => _pastRoutes = !_pastRoutes),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // THE CLINIC VIEWS (Mesh Clinic v2, Brett's pick): the
          // five fact-family views on the ONE map. Switching a view
          // redraws ONLY (rule 2) - no ask, no spend.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                for (final (view, name) in const [
                  (ClinicView.all, 'All facts'),
                  (ClinicView.nodes, 'Node health'),
                  (ClinicView.routes, 'Route health'),
                  (ClinicView.trouble, 'Trouble flags'),
                  (ClinicView.secondHand, 'Second-hand'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(name,
                          style: const TextStyle(fontSize: 11)),
                      selected: _clinicView == view,
                      onSelected: (_) => setState(() => _clinicView = view),
                    ),
                  ),
              ],
            ),
          ),
          // THE MAP'S OWN STATS LINE: dots held and stale count.
          // (Feed health and the log live in the main page's own
          // sections; the tap-ask counter left with the tap-ask.)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '${dots.length} node(s) with positions - '
              '${dots.where((d) => d.color == DotColor.stale).length} stale',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          // THE CLINIC STRIP: what the layer drew and what has no
          // place - the honest gap, said out loud (never invented).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '${clinic.markers.length + clinic.lines.length} clinic fact(s) '
              'drawn - ${clinic.secondHandDrawn} reported'
              '${clinic.unpositioned > 0 ? ' - ${clinic.unpositioned} without a place' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (clinic.unpositioned > 0)
            TextButton(
              onPressed: () => _openCardSheet(
                  ClinicCards.looseCard(widget.clinic, nowMs: nowMs)),
              child: Text(
                'read the ${clinic.unpositioned} fact(s) without a place',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  /// A tap on a clinic fact opens its detail card: one line per
  /// fact, EVERY line labeled first-hand/second-hand (the plan).
  void _showClinicCard(ClinicTarget target) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lines = switch (target) {
      ClinicNodeTarget(:final prefix) =>
        ClinicCards.nodeCard(widget.clinic, widget.store, prefix,
            nowMs: nowMs),
      ClinicRouteTarget(:final path) =>
        ClinicCards.routeCard(widget.clinic, path, nowMs: nowMs),
    };
    _openCardSheet(lines);
  }

  void _openCardSheet(List<String> lines) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            Text(lines.first, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final line in lines.skip(1))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(line,
                    style: Theme.of(ctx).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  /// The NW corner of a square whose CENTRE is (lat, lon) - where a
  /// square's tiny count draws (upper left, Brett, 2026-09-25).
  static (double, double) _cellNW(ViewGrid g, double lat, double lon) {
    const mPerDeg = 111320.0;
    final dLat = g.spanLatM / g.rows / 2 / mPerDeg;
    final dLon = g.spanLonM / g.cols / 2 /
        (mPerDeg * math.cos(lat * math.pi / 180.0));
    return (lat + dLat, lon - dLon);
  }

  /// Camera zoom that spans the chosen window: ~60 km -> z9,
  /// ~40 km -> z10, ~20 km -> z11 (Log2(60/km) rule of thumb).
  static double _zoomFor(int km) => switch (km) {
        60 => 9,
        40 => 10,
        _ => 11,
      };
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Draw dimmed when the control it stands for is OFF (the route
  /// line toggle's at-a-glance state).
  final bool on;
  const _NavButton(
      {required this.icon,
      required this.tooltip,
      required this.onTap,
      this.on = true});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FloatingActionButton.small(
        heroTag: tooltip,
        tooltip: tooltip,
        onPressed: onTap,
        child: Icon(icon, color: on ? null : Colors.white38),
      ),
    );
  }
}
