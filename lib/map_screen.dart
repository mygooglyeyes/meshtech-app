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
  final ConnectionSettings settings;
  final (double, double)? frameCenter;
  final VoidCallback onAsk; // THE UPDATE BUTTON: the phone asks, over the door
  final ValueChanged<int> onMapSizeChange; // +/- = 20/40/60, redraw only
  final ValueChanged<DotVM> onDotTap; // A TAP = AN ASK (section 10)
  final int tappedPrefix; // the node whose routes were asked (0 = none)
  final List<int> sectionRouteIds; // route stubs from the last tap-ask

  const MapScreen({
    super.key,
    required this.store,
    required this.settings,
    this.frameCenter,
    required this.onAsk,
    required this.onMapSizeChange,
    required this.onDotTap,
    this.tappedPrefix = 0,
    this.sectionRouteIds = const [],
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  MapController? _map;
  ViewGrid? _grid; // THE PHONE'S 3x4 VIEW GRID on the visible region
  int _overlayTick = 0; // bumped = labels/grid recompute their spots

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
    final s = widget.settings;
    // The grid's per-cell counts, computed ONCE per build.
    final cellCounts = _grid?.counts(widget.store);
    // THE ROUTE LINES: segments between KNOWN dots only (section 5:
    // an unknown hop never gets an invented position). Routes named
    // by the tapped node's section draw HIGHLIGHTED (their own
    // layer, thick + warm); anything else the store holds draws
    // faint underneath. The wire's travel order is the draw order.
    final highlightIds = widget.sectionRouteIds.toSet();
    final faintLines = <Feature<LineString>>[];
    final hotLines = <Feature<LineString>>[];
    for (final r in widget.store.routes) {
      final hot = highlightIds.contains(r.routeId);
      var pts = <Geographic>[];
      void flush() {
        if (pts.length > 1) {
          (hot ? hotLines : faintLines).add(Feature(
            geometry: LineString(
              [for (final p in pts) ...[p.lon, p.lat]]
                  .positions(Coords.xy),
            ),
          ));
        }
        pts = <Geographic>[];
      }

      for (final pfx in r.prefixes) {
        final n = widget.store.nodes[pfx];
        if (n?.lat == null || n?.lon == null) {
          flush(); // the honest gap: the line resumes at the next
          continue; // known dot - no invented position, ever
        }
        pts.add(Geographic(lon: n!.lon!, lat: n.lat!));
      }
      flush();
    }
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
                    // what the store holds, thick + warm for the
                    // tapped node's section's routes.
                    if (faintLines.isNotEmpty)
                      PolylineLayer(
                        polylines: faintLines,
                        color: const Color(0x554A90D9),
                        width: 2,
                      ),
                    if (hotLines.isNotEmpty)
                      PolylineLayer(
                        polylines: hotLines,
                        color: const Color(0xFFE07A2F),
                        width: 4,
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
                  ],
                  // Names on the map, every screen (section 8):
                  // "Hilltop ab" - name + pubkey head. The cell-count
                  // badges ride the same widget list.
                  children: [
                    if (_grid != null)
                      WidgetLayer(
                        // The tick key forces the badge layer to
                        // recompute its screen spots (startup fix).
                        key: ValueKey('badges-$_overlayTick'),
                        markers: [
                          // One badge per CELL, paired by index
                          // (center i <-> count i) - only non-empty
                          // cells draw a number (honest, quiet).
                          for (final (i, (lat, lon))
                              in _grid!.cellCenters().indexed)
                            if ((cellCounts?[i] ?? 0) > 0)
                              Marker(
                                point: Geographic(lon: lon, lat: lat),
                                size: const Size(36, 24),
                                child: Center(
                                  child: Text(
                                    '${cellCounts![i]}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF0F3A72),
                                    ),
                                  ),
                                ),
                              ),
                        ],
                      ),
                    WidgetLayer(
                      // TAPS ON: the layer defaults to passing every
                      // touch through to the map (TranslucentPointer)
                      // - without this flag the tap-ask can never
                      // fire (bench fact, from the package source).
                      // The tick key re-spots the labels (startup fix).
                      key: ValueKey('labels-$_overlayTick'),
                      allowInteraction: true,
                      markers: [
                        for (final d in dots)
                          Marker(
                            point:
                                Geographic(lon: d.lon, lat: d.lat),
                            size: const Size(120, 24),
                            alignment: Alignment.topCenter,
                            // THE TAP (design section 10): tapping a
                            // node's tag ASKS its section - routes
                            // come back and draw dot-to-dot. NO
                            // BACKGROUND (Brett, 2026-09-24): a
                            // painted box covered the map; the tag
                            // is bare text.
                            child: GestureDetector(
                              onTap: () => widget.onDotTap(d),
                              behavior: HitTestBehavior.opaque,
                              child: Text(
                                d.label,
                                style: TextStyle(
                                  fontSize: 11,
                                  // The tapped node's tag turns orange:
                                  // which node was asked, at a glance
                                  // (the old box highlight, now text).
                                  color: d.prefix == widget.tappedPrefix
                                      ? const Color(0xFFE07A2F)
                                      : Colors.black87,
                                ),
                              ),
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
                    ],
                  ),
                ),
              ],
            ),
          ),
          // THE MAP'S OWN STATS LINE: dots held, stale count, and
          // how many routes the last tap-ask named. (Feed health and
          // the log moved to the main page's own sections.)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '${dots.length} node(s) with positions - '
              '${dots.where((d) => d.color == DotColor.stale).length} stale'
              '${widget.sectionRouteIds.isEmpty ? '' : ' - '
                  '${widget.sectionRouteIds.length} route(s) asked'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),          ),
        ],
      ),
    );
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
  const _NavButton(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FloatingActionButton.small(
        heroTag: tooltip,
        tooltip: tooltip,
        onPressed: onTap,
        child: Icon(icon),
      ),
    );
  }
}
