// The phone's own store (DESIGN.md section 4): the ONE place data
// lives. New OTA/downloaded data lands here the moment it arrives and
// the map is the store's live window.
//
// Brett's laws baked in:
// - AN UPDATE REPLACES THE OLD: one node is ONE dot; a moved node's
//   old position is gone the moment the new one lands. No twins ever.
// - HONEST AGES: "when did we last hear this node" is stored as
//   received time, shown as age - never fabricated.
// - GONE MEANS GONE: a vectored "node is gone" notice REMOVES the
//   dot (an honest deletion, not a stale fade).
// - THE MARKER SURVIVES RESTARTS (vectored sync): the phone's change
//   counter is persisted, or the air-savings vanish.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'codec.dart';

class NodeRecord {
  final int prefix;
  final String? name;
  final double? lat;
  final double? lon;
  final int nodeClass;
  final int lastHeardMs; // epoch ms - the honest age source

  const NodeRecord({
    required this.prefix,
    this.name,
    this.lat,
    this.lon,
    this.nodeClass = nodeClassUnknown,
    required this.lastHeardMs,
  });

  NodeRecord copyWith({String? name, double? lat, double? lon,
      int? nodeClass, int? lastHeardMs}) =>
      NodeRecord(
        prefix: prefix,
        name: name ?? this.name,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        nodeClass: nodeClass ?? this.nodeClass,
        lastHeardMs: lastHeardMs ?? this.lastHeardMs,
      );

  Map<String, Object?> toJson() => {
        'p': prefix,
        'n': name,
        'lat': lat,
        'lon': lon,
        'c': nodeClass,
        't': lastHeardMs,
      };

  static NodeRecord fromJson(Map<String, Object?> j) => NodeRecord(
        prefix: j['p'] as int,
        name: j['n'] as String?,
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        nodeClass: (j['c'] as int?) ?? nodeClassUnknown,
        lastHeardMs: j['t'] as int,
      );

  /// The map label (DESIGN.md section 8): name + first 1/2/3 pubkey
  /// bytes, matching the node's path-hash width. The prefix byte(s)
  /// ARE the pubkey head the mesh addresses it by; the hash width is
  /// the path-tag width the server observed - here we show the same
  /// hex head the wire gives us (1 byte = 2 hex chars), the honest
  /// identity the packets themselves carry.
  String get label {
    final head = prefix.toRadixString(16).padLeft(2, '0');
    final nm = (name == null || name!.isEmpty) ? 'node' : name;
    return '$nm $head';
  }
}

class NodeStore {
  final Map<int, NodeRecord> _nodes = {};
  int _syncMarker = 0;
  final List<int> _gonePending = []; // prefixes seen gone, not yet acked to UI

  static const _persistKey = 'node_store';
  static const _markerKey = 'sync_marker';

  Map<int, NodeRecord> get nodes => Map.unmodifiable(_nodes);
  int get syncMarker => _syncMarker;
  List<int> get gonePending => List.unmodifiable(_gonePending);

  /// UPSERT-REPLACE (Brett's law): the new record REPLACES the old
  /// facts wholesale - a moved node's old position is gone the moment
  /// the new one lands. One prefix = one dot, always.
  void upsert(NodeRecord rec) {
    _nodes[rec.prefix] = rec;
  }

  /// Convenience: apply an INTRO entry as heard now.
  void applyIntroEntry(IntroEntry e, {required int heardMs}) {
    final existing = _nodes[e.prefix];
    _nodes[e.prefix] = NodeRecord(
      prefix: e.prefix,
      // Unknown never overwrites known (the server's own rule).
      name: e.name ?? existing?.name,
      lat: e.lat ?? existing?.lat,
      lon: e.lon ?? existing?.lon,
      nodeClass: e.nodeClass != nodeClassUnknown
          ? e.nodeClass
          : (existing?.nodeClass ?? nodeClassUnknown),
      lastHeardMs: heardMs,
    );
  }

  /// GONE MEANS GONE: remove the dot. Returns true if something was
  /// actually removed (UI: nothing to erase = no redraw needed).
  bool removeGone(int prefix) {
    final existed = _nodes.remove(prefix) != null;
    if (existed) _gonePending.add(prefix);
    return existed;
  }

  /// After the UI has redrawn: acknowledge the gone batch.
  void clearGonePending() => _gonePending.clear();

  void noteSyncMarker(int marker) {
    if (marker > _syncMarker) _syncMarker = marker;
  }

  int? nodeChangeSeq(int prefix) => _nodes[prefix] != null ? _syncMarker : null;

  // ----------------------------------------------------------- persistence

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_persistKey,
        jsonEncode([for (final n in _nodes.values) n.toJson()]));
    await sp.setInt(_markerKey, _syncMarker);
  }

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _syncMarker = sp.getInt(_markerKey) ?? 0;
    final raw = sp.getString(_persistKey);
    if (raw == null) return;
    final list = jsonDecode(raw) as List;
    _nodes
      ..clear()
      ..addEntries([for (final j in list)
        MapEntry((j as Map<String, Object?>)['p'] as int,
            NodeRecord.fromJson(j.cast<String, Object?>()))]);
  }

  /// Forget everything (the node restarted and its seq regressed -
  /// the phone's view is stale; a fresh LAYOUT redraws it).
  void resetAll() {
    _nodes.clear();
    _gonePending.clear();
  }
}
