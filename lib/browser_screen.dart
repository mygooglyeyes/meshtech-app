// THE LIST PANE (Brett, 2026-09-25): the browsable list of every
// node and route the phone holds from the server (connect + refresh
// fills) - now the LIST half of the main page's map/list swap. The
// map draws beside it under the same section bars; feed health and
// logs live in their own sections on the main page. (History:
// 2026-09-24 this view TEMPORARILY replaced the map so a partial
// list was a data fact, not a rendering question.)

import 'package:flutter/material.dart' hide Route;

import 'codec.dart'; // the WIRE Route (Flutter's Route is hidden above)
import 'map_model.dart';
import 'settings.dart';
import 'store.dart';

class BrowserScreen extends StatefulWidget {
  final NodeStore store;
  final ConnectionSettings settings;
  final String? frameName;
  final VoidCallback onAsk; // the ↻ refresh (the vectored ask)

  const BrowserScreen({
    super.key,
    required this.store,
    required this.settings,
    this.frameName,
    required this.onAsk,
  });

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dots = MapViewModel.dots(widget.store, nowMs: nowMs);
    final title = (widget.frameName == null || widget.frameName!.isEmpty)
        ? 'Hilltop area'
        : widget.frameName!;
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // THE LIST'S OWN BAR: area title + the Update ask (the main
          // page's section bars frame this view now, 2026-09-25).
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$title - ${widget.settings.mapSizeKm} km view',
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh now (ask the server)',
                  icon: const Icon(Icons.refresh),
                  onPressed: widget.onAsk,
                ),
              ],
            ),
          ),
          Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: TabBar(
              tabs: [
                Tab(text: 'Nodes (${dots.length})'),
                Tab(text: 'Routes (${widget.store.routes.length})'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _nodeList(context, dots),
                _routeList(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// EVERY node the phone holds - positioned or not, each row honest
  /// about which it is. Sorted by name.
  Widget _nodeList(BuildContext context, List<DotVM> dots) {
    final rows = [
      for (final n in widget.store.nodes.values)
        (
          n,
          dots.any((d) => d.prefix == n.prefix), // has a position?
        )
    ]..sort((a, b) => (a.$1.name ?? a.$1.prefix.toString())
        .toLowerCase()
        .compareTo((b.$1.name ?? b.$1.prefix.toString()).toLowerCase()));
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final (n, placed) = rows[i];
        final ageMin = ((DateTime.now().millisecondsSinceEpoch -
                    n.lastHeardMs) /
                60000)
            .round();
        final age = ageMin < 60
            ? '$ageMin min'
            : ageMin < 1440
                ? '${ageMin ~/ 60} h'
                : '${ageMin ~/ 1440} d';
        return ListTile(
          dense: true,
          leading: Icon(
            placed ? Icons.place : Icons.place_outlined,
            color: placed ? const Color(0xFF4A90D9) : Colors.grey,
            size: 20,
          ),
          title: Text(n.name ?? 'prefix ${n.prefix}'),
          subtitle: Text(
            'prefix ${n.prefix.toRadixString(16).padLeft(2, '0')}'
            '${placed ? '' : ' - NO POSITION'} - heard $age ago',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
      },
    );
  }

  /// Every route the phone holds, with its hop count and its MEASURED
  /// start-to-end time (median of honest sender stamps; 'unknown'
  /// when the wire carried none - never a fabricated number).
  /// BRETT'S FADE (2026-09-24): a route silent past its stale line is
  /// listed YELLOW - direct 3 days, multi-hop 7 days (dead routes are
  /// deleted server-side; the phone also drops the past-dead ones).
  Widget _routeList(BuildContext context) {
    final routes = widget.store.routes.toList()
      ..sort((a, b) => a.routeId.compareTo(b.routeId));
    if (routes.isEmpty) {
      return const Center(
          child: Text('No routes held (the server sent none yet)'));
    }
    final nowMin = DateTime.now().millisecondsSinceEpoch ~/ 60000;
    return ListView.builder(
      itemCount: routes.length,
      itemBuilder: (context, i) {
        final r = routes[i];
        // lastHeardMin rides the wire as the server's own age for the
        // route; the phone compares it against Brett's fade lines.
        final ageMin = nowMin - _routeLastHeardAbsMin(r);
        final isDirect = r.prefixes.length <= 1;
        final staleAfterMin = isDirect ? 3 * 1440 : 7 * 1440;
        final stale = ageMin > staleAfterMin;
        final timing = r.delayMedS > 0
            ? '${r.delayMedS} s'
            : 'unknown';
        return ListTile(
          dense: true,
          leading: Icon(Icons.route, size: 20,
              color: stale ? const Color(0xFFF5C518) : null),
          title: Text('route ${r.routeId}'
              '${stale ? '  -  STALE' : ''}',
              style: stale
                  ? const TextStyle(color: Color(0xFFF5C518))
                  : null),
          subtitle: Text(
            '${r.prefixes.length} hop(s) - ${r.packetCount} packet(s)'
            ' - time start-to-end: $timing'
            ' - last used ${_ageText(ageMin)} ago'
            ' - section ${r.sectionId}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
      },
    );
  }

  /// The route's last-heard as an absolute minute (the wire carries an
  /// AGE in minutes - so "now minus age" is the honest anchor; the
  /// seed's minute-of-epoch is a stable enough base for the age math).
  static int _routeLastHeardAbsMin(Route r) =>
      (DateTime.now().millisecondsSinceEpoch ~/ 60000) - r.lastHeardMin;

  static String _ageText(int minutes) {
    if (minutes < 0) return '0 min';
    if (minutes < 60) return '$minutes min';
    if (minutes < 1440) return '${minutes ~/ 60} h';
    return '${minutes ~/ 1440} d';
  }
}
