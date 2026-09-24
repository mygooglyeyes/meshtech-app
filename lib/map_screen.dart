// The map screen (design section 8): MapLibre draws the real map; the
// view-model (map_model.dart) decides WHAT is drawn - dots, labels,
// colors. The chosen size (settings) is the VIEW: the camera spans
// exactly that window, and the re-cut puts every node at its honest
// fraction of it. Changing the size later re-cuts the same data - it
// never asks hilltop for anything.
//
// API note: written against maplibre 0.3.6's DECLARATIVE layers
// (CircleLayer/MarkerLayer as widget state) - the map repaints when
// the store changes because the layers are rebuilt from the VM.

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

class MapScreen extends StatelessWidget {
  final NodeStore store;
  final ConnectionSettings settings;
  final String? frameName;
  final (double, double)? frameCenter;
  final VoidCallback onDisconnect;

  const MapScreen({
    super.key,
    required this.store,
    required this.settings,
    this.frameName,
    this.frameCenter,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dots = MapViewModel.dots(store, nowMs: nowMs);
    final center = frameCenter ?? (38.0, -122.0);
    final title = (frameName == null || frameName!.isEmpty)
        ? 'Hilltop area'
        : frameName!;
    return Scaffold(
      appBar: AppBar(
        title: Text('$title - ${settings.mapSizeKm} km view'),
        actions: [
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
            onPressed: onDisconnect,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: MapLibreMap(
              options: MapOptions(
                initStyle: mapStyleUrl,
                initCenter: Geographic(lon: center.$2, lat: center.$1),
                initZoom: _zoomFor(settings.mapSizeKm),
              ),
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
                            geometry: Point(
                                Geographic(lon: d.lon, lat: d.lat))),
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
                            geometry: Point(
                                Geographic(lon: d.lon, lat: d.lat))),
                  ],
                  radius: 6,
                  color: const Color(0xFFF5C518),
                  strokeColor: const Color(0xFFFFFFFF),
                  strokeWidth: 1,
                ),
              ],
              // Names on the map, every screen (section 8):
              // "Hilltop ab" - name + pubkey head. Flutter widgets
              // over the map via the WidgetLayer/Marker support.
              children: [
                WidgetLayer(
                  markers: [
                    for (final d in dots)
                      Marker(
                        point: Geographic(lon: d.lon, lat: d.lat),
                        size: const Size(120, 24),
                        alignment: Alignment.topCenter,
                        child: Text(
                          d.label,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.black87,
                            backgroundColor: Color(0x88FFFFFF),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '${dots.length} node(s) with positions - '
              '${dots.where((d) => d.color == DotColor.stale).length} stale',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
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
