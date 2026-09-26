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
// THE PAGE SWIPES (Brett, 2026-09-25 - "swipe"): ONE tall stack he
// pushes up with his own finger to reach Feed health/Logs, and
// closing a section slides the page home by itself. The map/list
// frame is measured ONCE (screen minus the bars around it - its old
// full size) and then frozen for the app's life: nothing can ever
// resize it, so the native lines and labels can never mis-seat.
// The settings gear is honest until the settings step ships.

import 'package:flutter/material.dart' hide Route;

import 'dart:math' as math;

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

  /// The connection pill's label: which pipe is live (app_shell owns
  /// the dual-link truth: 'Radio active' / 'TCP active' / 'Radio + TCP').
  final String linkLabel;
  final VoidCallback onDisconnect;
  final VoidCallback onAsk; // the vectored ask (Update)
  final ValueChanged<int> onMapSizeChange; // the map's +/- (rule 2)

  /// A tap on a map square (Brett, 2026-09-25): the square's number
  /// opens that section's detail page. The map takes no node taps.
  final ValueChanged<SectionCell> onSectionTap;

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
    this.linkLabel = 'TCP active',
    required this.onDisconnect,
    required this.onAsk,
    required this.onMapSizeChange,
    required this.onSectionTap,
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

  // THE MAP'S ONE HEIGHT: measured after the first frame (the
  // three bars are laid out once, their real heights read back),
  // then never touched again - a resize after the map draws is
  // exactly what mis-seats the lines and labels.
  final _connKey = GlobalKey();
  final _healthKey = GlobalKey();
  final _logsKey = GlobalKey();
  double? _mapH;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureMap());
  }

  void _measureMap() {
    if (_mapH != null || !mounted) return;
    RenderBox? box(GlobalKey k) {
      final ro = k.currentContext?.findRenderObject();
      return (ro is RenderBox && ro.hasSize) ? ro : null;
    }

    final conn = box(_connKey);
    final health = box(_healthKey);
    final logs = box(_logsKey);
    if (conn == null || health == null || logs == null) {
      // Not laid out yet: try again after the next frame rather
      // than guess a number.
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureMap());
      return;
    }
    final mq = MediaQuery.of(context);
    final usable = mq.size.height - mq.padding.top - mq.padding.bottom;
    setState(() {
      _mapH = math.max(
          usable - conn.size.height - health.size.height - logs.size.height,
          200.0);
    });
  }

  /// One section bar tapped: fold/unfold it. CLOSING also slides
  /// the whole page home (Brett: "return when you are done").
  void _toggle(bool wasOpen, VoidCallback change) {
    setState(change);
    if (wasOpen && _scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic);
    }
  }

  void _toggleView() => setState(() => _showMap = !_showMap);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pulse;
    // The map/list body is built ONLY once its height is measured:
    // the map is never constructed at one size and re-laid at
    // another (that mismatch is the distortion bug).
    final body =
        _mapH == null ? null : (_showMap ? _mapBody(context) : _listBody());
    final view = _Section(
      label: _showMap ? 'Map' : 'List',
      open: _viewOpen,
      onToggle: () => _toggle(_viewOpen, () => _viewOpen = !_viewOpen),
      // The map/list fill their FIXED frame (the section bar sits
      // over it) - a shrink-wrapped child would hand the list's
      // TabBarView an unbounded height.
      fill: true,
      child: body,
    );
    return Scaffold(
      body: SafeArea(
        // THE SWIPE PAGE: one tall stack over blueline paper; his
        // finger does the moving, no inner scroll regions.
        child: SingleChildScrollView(
          controller: _scroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Section(
                key: _connKey,
                label: 'Connection',
                open: _connOpen,
                onToggle: () =>
                    _toggle(_connOpen, () => _connOpen = !_connOpen),
                child: _connectionRow(context),
              ),
              // THE MAP'S ONE HEIGHT: measured once (initState) as
              // the screen minus Connection + Feed health + Logs -
              // its old expanded size, back to full size. Frozen
              // for the app's life; folded bars leave blank paper,
              // never a smaller map.
              if (_viewOpen && _mapH != null)
                SizedBox(height: _mapH, child: view)
              else
                view,
              _Section(
                key: _healthKey,
                label: 'Feed health',
                open: _healthOpen,
                onToggle: () =>
                    _toggle(_healthOpen, () => _healthOpen = !_healthOpen),
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
                key: _logsKey,
                label: 'Logs',
                open: _logsOpen,
                onToggle: () => _toggle(_logsOpen, () => _logsOpen = !_logsOpen),
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
          // Link-active pill: which pipe is live, at a glance.
          _Pill(label: widget.linkLabel, detail: widget.linkDetail),
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
      onSectionTap: widget.onSectionTap,
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

  /// fill = the child takes the section's remaining height (only
  /// under the map's fixed-height SizedBox, which bounds it) - a
  /// shrink-wrapped child would hand the list's TabBarView an
  /// unbounded height. child is null for the first frame only,
  /// while the map's height is still being measured.
  final bool fill;
  final Widget? child;
  const _Section({
    super.key,
    required this.label,
    required this.open,
    required this.onToggle,
    this.fill = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final body = child;
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
        if (open && body != null)
          fill
              ? Expanded(child: body)
              : body,
      ],
    );
  }
}
