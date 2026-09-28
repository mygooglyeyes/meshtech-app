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
  static const _routesKey = 'route_store';
  // THE MAP FRAME SURVIVES RESTARTS (Brett, 2026-09-27): the lines
  // (name + center + shape) are RECEIVED DATA - closing the app must
  // not lose them, the same law the dots already follow.
  static const _frameKey = 'map_frame';
  Layout? _frame;
  // The age anchor per route: the epoch ms the wire answer arrived.
  // Ages fold forward from it on reload so the death clock keeps
  // ticking TRUTHFULLY while the app is closed (Brett's law:
  // persistence never freezes time).
  final Map<int, int> _routeHeardAt = {};

  Map<int, NodeRecord> get nodes => Map.unmodifiable(_nodes);
  int get syncMarker => _syncMarker;
  List<int> get gonePending => List.unmodifiable(_gonePending);

  /// The heard map frame (what the lines draw from). Null on a fresh
  /// install - the app then waits for a real LAYOUT, never draws
  /// stale lines. (A node restart no longer clears it: the frame is
  /// replaced like-for-like by the re-sync's fresh LAYOUT.)
  Layout? get frame => _frame;

  /// A LAYOUT landed (either pipe): it IS the frame now. UPSERT-
  /// REPLACE like every other fact - the newest layout wins whole.
  void noteFrame(Layout l) => _frame = l;

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

  /// A GONE notice also kills the dead node's routes (its lines are
  /// lines TO it - with the dot gone they are fiction). Returns the
  /// route ids removed, so the caller can repaint only if needed.
  List<int> removeGoneRoutes(int prefix) {
    final dropped = [
      for (final r in _routes.values)
        if (r.prefixes.contains(prefix & 0xFF)) r.routeId,
    ];
    for (final id in dropped) {
      _routes.remove(id);
      _routeHeardAt.remove(id);
    }
    return dropped;
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
    // ROUTES PERSIST TOO (Brett's law, 2026-09-27): the lines are
    // received data - the app must come up just like it shut down.
    // Each route saves its age anchor so reload folds the CLOSED
    // time into its age honestly.
    await sp.setString(
        _routesKey,
        jsonEncode([
          for (final r in _routes.values)
            {
              'r': _routeJson(r),
              'h': _routeHeardAt[r.routeId],
            }
        ]));
    final f = _frame;
    if (f != null) {
      await sp.setString(
          _frameKey,
          jsonEncode({
            'seq': f.seq,
            'grid': f.grid,
            'rows': f.rows,
            'centerLat': f.centerLat,
            'centerLon': f.centerLon,
            'spanM': f.spanM,
            'origin': f.origin,
            'name': f.name,
          }));
    } else {
      // Null truth erases the saved frame: after a node-restart reset
      // the flash must not hold the dead frame either (a reload would
      // resurrect stale lines - the exact bug this fixes).
      await sp.remove(_frameKey);
    }
  }

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _syncMarker = sp.getInt(_markerKey) ?? 0;
    final raw = sp.getString(_persistKey);
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      _nodes
        ..clear()
        ..addEntries([for (final j in list)
          MapEntry((j as Map<String, Object?>)['p'] as int,
              NodeRecord.fromJson(j.cast<String, Object?>()))]);
    }
    final fr = sp.getString(_frameKey);
    if (fr != null) {
      final j = jsonDecode(fr) as Map<String, Object?>;
      _frame = Layout(
        seq: (j['seq'] as num).toInt(),
        grid: (j['grid'] as num).toInt(),
        rows: (j['rows'] as num).toInt(),
        centerLat: (j['centerLat'] as num).toDouble(),
        centerLon: (j['centerLon'] as num).toDouble(),
        spanM: (j['spanM'] as num).toInt(),
        origin: (j['origin'] as num).toInt(),
        name: j['name'] as String? ?? '',
      );
    }
    final rr = sp.getString(_routesKey);
    if (rr != null) {
      _routes
        ..clear()
        ..addEntries([
          for (final j in jsonDecode(rr) as List)
            if (j is Map<String, Object?>)
              MapEntry(_routeFromJson((j['r'] as Map).cast<String, Object?>())
                  .routeId, _routeFromJson((j['r'] as Map).cast<String, Object?>()))
        ]);
      // Anchors second pass (the map above decodes each row twice -
      // cheap and honest; the anchors ride along separately).
      for (final j in jsonDecode(rr) as List) {
        if (j is! Map<String, Object?>) continue;
        final rid = ((j['r'] as Map)['rid'] as num).toInt();
        final h = (j['h'] as num?)?.toInt();
        if (h != null && _routes.containsKey(rid)) _routeHeardAt[rid] = h;
      }
    }
    // THE DEATH LAW AT LAUNCH: the closed time counts - anything that
    // died while the app was shut is gone the moment it reopens
    // (honest, not frozen).
    pruneDead();
  }

  static Map<String, Object?> _routeJson(Route r) => {
        'seq': r.seq,
        'sid': r.sectionId,
        'rid': r.routeId,
        'n': r.packetCount,
        'd': r.delayMedS,
        'age': r.lastHeardMin,
        'o': r.origin,
        'p': r.prefixes,
      };

  static Route _routeFromJson(Map<String, Object?> j) => Route(
        seq: (j['seq'] as num).toInt(),
        sectionId: (j['sid'] as num).toInt(),
        routeId: (j['rid'] as num).toInt(),
        packetCount: (j['n'] as num).toInt(),
        delayMedS: (j['d'] as num).toInt(),
        lastHeardMin: (j['age'] as num).toInt(),
        origin: (j['o'] as num?)?.toInt() ?? 0,
        prefixes: List<int>.from(j['p'] as List),
      );

  /// ROUTES (design section 10): the answer to a tap-ask. Keyed by
  /// the wire's route_id; UPSERT-REPLACE like everything else - the
  /// newest answer for a route IS the route. RAM-only for now: the
  /// bulk route history rides the initial TCP download (not built
  /// yet); air-learned routes re-ask cheaply after a restart.
  final Map<int, Route> _routes = {};

  /// BRETT'S ROUTE FADE (2026-09-24): a DIRECT route silent 3 days is
  /// STALE (listed yellow), 7 days DEAD; a MULTI-HOP route 7/14. The
  /// server deletes its dead routes; the phone also refuses to take a
  /// past-dead answer back (an honest deletion, not a stale fade).
  static const directStaleAfterMin = 3 * 1440;
  static const multihopStaleAfterMin = 7 * 1440;
  static const directDeadAfterMin = 7 * 1440;
  static const multihopDeadAfterMin = 14 * 1440;

  static bool routeIsDirect(Route r) => r.prefixes.length <= 1;

  static int routeDeadAfterMin(Route r) => routeIsDirect(r)
      ? directDeadAfterMin
      : multihopDeadAfterMin;

  void applyRoute(Route r, {int? heardMs}) {
    // lastHeardMin rides the wire as the route's age in minutes.
    if (r.lastHeardMin > routeDeadAfterMin(r)) return; // DEAD: drop it
    _routes[r.routeId] = r;
    _routeHeardAt[r.routeId] =
        heardMs ?? DateTime.now().millisecondsSinceEpoch;
  }

  Route? route(int routeId) => _routes[routeId];

  Iterable<Route> get routes => _routes.values;

  /// NODE DEATH LAW (Brett, 2026-09-27): the same lines the routes
  /// live on - a node silent 7 days is STALE (shown honestly), 14
  /// days DEAD (removed). Removal ways: dead, or a GONE update from
  /// any source. Nothing else ever deletes a dot.
  static const nodeStaleAfterMin = 7 * 1440;
  static const nodeDeadAfterMin = 14 * 1440;

  bool nodeIsStale(NodeRecord n, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return now - n.lastHeardMs > nodeStaleAfterMin * 60000;
  }

  bool nodeIsDead(NodeRecord n, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return now - n.lastHeardMs > nodeDeadAfterMin * 60000;
  }

  /// Drop dead dots and dead routes (the death law, enforced while
  /// running - load() prunes at launch too). Returns what changed so
  /// the caller only redraws on a real removal.
  int pruneDead({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    var removed = 0;
    final deadNodes = [
      for (final n in _nodes.values)
        if (now - n.lastHeardMs > nodeDeadAfterMin * 60000) n.prefix,
    ];
    for (final p in deadNodes) {
      _nodes.remove(p);
      removed++;
    }
    final deadRoutes = [
      for (final r in _routes.values)
        if (_routeAgeMin(r, nowMs: now) > routeDeadAfterMin(r)) r.routeId,
    ];
    for (final id in deadRoutes) {
      _routes.remove(id);
      _routeHeardAt.remove(id);
      removed++;
    }
    return removed;
  }

  /// A route's HONEST age: wire age + the minutes that really passed
  /// since this phone heard it (the anchor never resets - persistence
  /// does not freeze time).
  int _routeAgeMin(Route r, {int? nowMs}) {
    final heardAt = _routeHeardAt[r.routeId];
    if (heardAt == null) return r.lastHeardMin;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return r.lastHeardMin + ((now - heardAt) / 60000).floor();
  }

  /// NODE RESTART (Brett's law, 2026-09-27): a restart removes
  /// NOTHING - the server persists its map on disk, so the phone
  /// keeps every dot, line and the frame, and re-syncs fully by
  /// dropping its sync marker (marker 0 = the whole roster re-sent;
  /// the fresh LAYOUT replaces the frame like-for-like).
  void prepareResync() {
    _syncMarker = 0;
  }

  /// THE FULL WIPE (debug bench / first run ONLY - never a node
  /// restart; see prepareResync). Everything goes, memory and flash.
  void resetAll() {
    _nodes.clear();
    _gonePending.clear();
    _routes.clear();
    _routeHeardAt.clear();
    _frame = null;
  }

  /// FRESH-INSTALL WIPE (Brett's bench law, 2026-09-24): a DEBUG
  /// build calls this at every launch - data, routes and the sync
  /// marker erased from flash too, so the bench is a true first run
  /// every time. RELEASE builds never call this (section 4: the
  /// phone keeps its store for the offline trail). Connection
  /// settings (address/password/ZIP/size) are NOT part of this -
  /// they live in SettingsStore, not the data store.
  Future<void> wipe() async {
    resetAll();
    _syncMarker = 0;
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_persistKey);
    await sp.remove(_markerKey);
    await sp.remove(_frameKey);
    await sp.remove(_routesKey);
  }
}
