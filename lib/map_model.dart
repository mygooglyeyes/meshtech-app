// The map view-model (design section 8 + Brett's laws): everything
// the map DRAWS, derived from the store - pure Dart, fully testable
// without the map engine. The MapLibre widget (map_screen.dart) is a
// thin painter over this; the brains live here.

import 'store.dart';

/// Where a dot's color comes from - the honest states, no invented
/// middle ground. Stale = the SERVER's 14-day line (the queued
/// stale-packet will carry the server's own verdict; until that
/// ships, staleness derives from the node's honest lastHeardMs).
enum DotColor { fresh, stale, unknownClass }

class DotVM {
  final int prefix;
  final String label;
  final double lat;
  final double lon;
  final DotColor color;
  final int nodeClass;
  const DotVM({
    required this.prefix,
    required this.label,
    required this.lat,
    required this.lon,
    required this.color,
    required this.nodeClass,
  });
}

class MapViewModel {
  static const staleAfterMs = 14 * 24 * 3600 * 1000; // the 14-day line

  /// Dots for the current frame: one per node (the store guarantees
  /// it), colored by the honest states, labels per section 8.
  static List<DotVM> dots(NodeStore store, {required int nowMs}) {
    final out = <DotVM>[];
    for (final n in store.nodes.values) {
      if (n.lat == null || n.lon == null) continue; // honest: no fix, no dot
      final age = nowMs - n.lastHeardMs;
      out.add(DotVM(
        prefix: n.prefix,
        label: n.label,
        lat: n.lat!,
        lon: n.lon!,
        nodeClass: n.nodeClass,
        color: age > staleAfterMs ? DotColor.stale : DotColor.fresh,
      ));
    }
    out.sort((a, b) => a.prefix.compareTo(b.prefix));
    return out;
  }

  /// Corner counts for the drawn frame: active nodes per section,
  /// counted ON THE VIEW (a node outside the window counts nowhere).
  static List<int> sectionCounts(
      NodeStore store, MapFrameLike frame, {required int nowMs}) {
    final counts = List<int>.filled(frame.sectionCount, 0);
    for (final n in store.nodes.values) {
      if (n.lat == null || n.lon == null) continue;
      final s = frame.sectionOf(n.lat!, n.lon!);
      if (s > 0) counts[s - 1]++;
    }
    return counts;
  }
}

/// The slice of grid.dart's MapFrame the view-model needs (keeps the
/// model testable without dragging the whole geometry in).
abstract class MapFrameLike {
  int get sectionCount;
  int sectionOf(double lat, double lon);
}
