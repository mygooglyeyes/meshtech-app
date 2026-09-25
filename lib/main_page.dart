// THE MAIN PAGE (Brett's layout chapter, 2026-09-25): four
// collapsible sections stacked on the blueline palette (the logo:
// #0f3a72 blue, white lines and text):
//   1. Connection - make/drop control, link-active pill, coverage
//      20/40/60 indicator (follows the map's +/-), map/list switch,
//      settings gear, disconnect.
//   2. Map or List - swapped by the header switch; the Routes tab
//      lives in the list, so nothing verified is ever lost.
//   3. Feed health - the PULSE line.
//   4. Logs - the event log, every line.
// Each section's header bar folds/unfolds its own section (+/- icon).
// The settings gear is honest until the settings step ships.

import 'package:flutter/material.dart' hide Route;

import 'browser_screen.dart';
import 'codec.dart';
import 'map_model.dart';
import 'map_screen.dart';
import 'settings.dart';
import 'store.dart';

class MainPage extends StatefulWidget {
  final NodeStore store;
  final ConnectionSettings settings;
  final String? frameName;
  final (double, double)? frameCenter;
  final Pulse? pulse;
  final List<String> log;
  final String linkDetail;
  final VoidCallback onDisconnect;
  final VoidCallback onAsk; // the vectored ask (Update)
  final ValueChanged<int> onMapSizeChange; // the map's +/- (rule 2)
  final ValueChanged<DotVM> onDotTap; // the map's tap-ask (section 10)
  final int tappedPrefix;
  final List<int> sectionRouteIds;

  /// Test seam: widget tests can stand a plain body in for the map
  /// so no live map engine is needed. Null in the real app.
  final WidgetBuilder? mapBuilder;

  const MainPage({
    super.key,
    required this.store,
    required this.settings,
    this.frameName,
    this.frameCenter,
    this.pulse,
    this.log = const [],
    this.linkDetail = '',
    required this.onDisconnect,
    required this.onAsk,
    required this.onMapSizeChange,
    required this.onDotTap,
    this.tappedPrefix = 0,
    this.sectionRouteIds = const [],
    this.mapBuilder,
  });

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  bool _showMap = true; // the header's switch starts on the map
  bool _connOpen = true;
  bool _viewOpen = true;
  bool _healthOpen = true;
  bool _logsOpen = false; // space first; the bar is one tap away

  void _toggleView() => setState(() => _showMap = !_showMap);

  @override
  Widget build(BuildContext context) {
    final p = widget.pulse;
    final view = _Section(
      label: _showMap ? 'Map' : 'List',
      open: _viewOpen,
      onToggle: () => setState(() => _viewOpen = !_viewOpen),
      // The map/list FILL the slack height (the section bar sits over
      // an Expanded frame) - a shrink-wrapped child would hand the
      // list's TabBarView an unbounded height.
      fill: true,
      child: _showMap ? _mapBody(context) : _listBody(),
    );
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Section(
              label: 'Connection',
              open: _connOpen,
              onToggle: () => setState(() => _connOpen = !_connOpen),
              child: _connectionRow(context),
            ),
            // The map/list takes the slack height; folded, the page
            // simply packs from the top over blueline paper.
            if (_viewOpen) Expanded(child: view) else view,
            _Section(
              label: 'Feed health',
              open: _healthOpen,
              onToggle: () => setState(() => _healthOpen = !_healthOpen),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(34, 4, 12, 8),
                child: Text(
                  p == null
                      ? 'waiting for the first pulse'
                      : '${p.rxPerHour} RX/h - ${p.activeTotal} active'
                          ' - airtime ${p.feedAirtimeSPerH} s/h'
                          ' - up ${p.uptimeMin} min',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            _Section(
              label: 'Logs',
              open: _logsOpen,
              onToggle: () => setState(() => _logsOpen = !_logsOpen),
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
      ),
    );
  }

  /// Section 1: the connection controls (Brett's fourth section).
  Widget _connectionRow(BuildContext context) {
    final s = widget.settings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          // Link-active pill: which door is live, at a glance.
          _Pill(label: 'TCP active', detail: widget.linkDetail),
          const SizedBox(width: 8),
          // Coverage indicator: follows the map's +/- (rule 2 redraw).
          _Pill(label: '${s.mapSizeKm} km'),
          const Spacer(),
          IconButton(
            tooltip: _showMap ? 'Switch to the list' : 'Switch to the map',
            icon: Icon(_showMap ? Icons.list : Icons.map),
            onPressed: _toggleView,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content:
                      Text('Settings arrive in the next step.')));
            },
          ),
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
            onPressed: widget.onDisconnect,
          ),
        ],
      ),
    );
  }

  Widget _mapBody(BuildContext context) {
    final map = widget.mapBuilder;
    if (map != null) return map(context);
    return MapScreen(
      store: widget.store,
      settings: widget.settings,
      frameCenter: widget.frameCenter,
      onAsk: widget.onAsk,
      onMapSizeChange: widget.onMapSizeChange,
      onDotTap: widget.onDotTap,
      tappedPrefix: widget.tappedPrefix,
      sectionRouteIds: widget.sectionRouteIds,
    );
  }

  Widget _listBody() => BrowserScreen(
        store: widget.store,
        settings: widget.settings,
        frameName: widget.frameName,
        onAsk: widget.onAsk,
      );
}

/// The pill look: a rounded drafting-outline chip (white edge on
/// deeper blue) - the logo's line-on-blue language, in widget form.
class _Pill extends StatelessWidget {
  final String label;
  final String detail;
  const _Pill({required this.label, this.detail = ''});

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF0B2E5A),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white54),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, color: Colors.white),
      ),
    );
    if (detail.isEmpty) return chip;
    return Tooltip(message: detail, child: chip);
  }
}

/// One collapsible section: a tappable header bar (+/-) over its
/// child. The bar carries the section's name in white on a lifted
/// blue plate with a drafting line underneath.
class _Section extends StatelessWidget {
  final String label;
  final bool open;
  final VoidCallback onToggle;

  /// fill = the child takes the section's remaining height (needs a
  /// bounded parent - the map/list section is Expanded for this).
  final bool fill;
  final Widget child;
  const _Section({
    required this.label,
    required this.open,
    required this.onToggle,
    this.fill = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Container(
            color: const Color(0xFF123F73),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                Icon(open ? Icons.remove : Icons.add,
                    size: 16, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, thickness: 1, color: Colors.white24),
        if (open)
          fill
              ? Expanded(child: child)
              : child,
      ],
    );
  }
}
