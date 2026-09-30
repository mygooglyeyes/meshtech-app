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

import 'clinic_store.dart';
import 'codec.dart'; // the WIRE Route (Flutter's Route is hidden above)
import 'map_model.dart';
import 'store.dart';

/// How long ago, in the list's own words (the same honest rounding
/// the browser rows use).
String ageText(int minutes) {
  if (minutes < 0) return '0 min';
  if (minutes < 60) return '$minutes min';
  if (minutes < 1440) return '${minutes ~/ 60} h';
  return '${minutes ~/ 1440} d';
}

/// One node's identity line: prefix, its place (honestly "NO
/// POSITION" - never invented), and when it was last heard.
String nodeIdentity(NodeStore store, int prefix, {required int nowMs}) {
  final hex = prefix.toRadixString(16).padLeft(2, '0');
  final n = store.nodes[prefix];
  if (n == null) return 'prefix $hex - nothing heard about it yet';
  final pos = (n.lat == null || n.lon == null)
      ? 'NO POSITION'
      : '${n.lat!.toStringAsFixed(3)}, ${n.lon!.toStringAsFixed(3)}';
  final ageMin = ((nowMs - n.lastHeardMs) / 60000).round();
  return 'prefix $hex \u00b7 $pos \u00b7 heard ${ageText(ageMin)} ago';
}

class NodeDetailScreen extends StatelessWidget {
  final NodeStore store;
  final ClinicStore clinic;
  final int prefix;
  final VoidCallback onClose;

  const NodeDetailScreen({
    super.key,
    required this.store,
    required this.clinic,
    required this.prefix,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rows =
        ClinicCards.nodeHealthCard(clinic, prefix, nowMs: nowMs);
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
        title: Text('route ${route.routeId}'),
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
              ),
            SizedBox(
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
                    store.nodes[path[i]]?.name ?? 'unknown',
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
