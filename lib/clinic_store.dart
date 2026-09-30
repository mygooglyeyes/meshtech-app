// The clinic store (CLINIC-WIRE.md governs): the phone's copy of the
// mesh clinic's facts - each one tagged with WHO measured it and HOW
// it reached us, kept exactly as long as its evidence is fresh.
//
// Laws baked in (the wire page's own words):
// - PROVENANCE: every fact carries `source` (the box that MEASURED or
//   REPORTED it) beside `viaOrigin` (the box that sent the packet).
//   source == origin = first-hand (that box's own radio); source !=
//   origin = second-hand (a peer box said it). Second-hand facts are
//   NEVER merged into first-hand ones and never re-worded as
//   first-hand - disagreement between boxes is preserved. Two boxes'
//   facts about one node are TWO rows.
// - AN UPDATE REPLACES THE OLD (Brett's law): one row per (fact
//   identity, measuring box) - the newest receipt IS that row.
// - HONEST AGES: the wire's minute rulers ride in as heard values and
//   GROW from the receipt anchor - persistence never freezes time.
// - MISSING STAYS MISSING: the wire sentinels (0xFFFF / 255 / -128)
//   are shown as missing, never a plausible constant.
// - REMOVAL AGES (the wire page): node charts are removed ONLY when
//   the node is gone (30 days without a hear, or forgotten); trouble
//   flags expire 30 days after their most recent event; peer reports
//   expire 30 days after the peer last said it; routes keep the
//   unchanged 7/14-day laws. Forgetting a node kills its chart, its
//   flags and its peer INTRO reports (route reports survive).

import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'codec.dart';
import 'store.dart' show NodeStore;

/// The wire sentinels, named for the UI: "unknown", never a number
/// that looks real. (Plain helpers - the sentinels themselves are the
/// codec's constants.)
bool ageIsUnknown(int ageMin) => ageMin >= ageUnknownMin;
bool shareIsUnknown(int pct) => pct == shareUnknownPct;
bool signalIsUnknown(int q) => q == signalUnknown;

/// Minutes since, on the phone's honest ruler: the wire's age at
/// receipt plus the minutes that REALLY passed since - capped at
/// ageUnknownMin (never a wrapped-around small number pretending to
/// be fresh).
int growAgeMin(int wireAgeMin, int heardMs, int nowMs) {
  final grown = wireAgeMin + ((nowMs - heardMs) / 60000).floor();
  if (grown < 0) return 0;
  return grown > ageUnknownMin ? ageUnknownMin : grown;
}

/// The provenance label shown on EVERY fact (Brett's words, 2026-09-29:
/// "Direct" / "Reported", no "box", no "said it"). The id is the
/// wire's u16 as hex - honest identity, no invented names (the tag is
/// a boot-random number, so it carries no name to quote).
String provenanceLabel(int source, int viaOrigin) {
  final head = source.toRadixString(16).padLeft(4, '0');
  return source == viaOrigin ? 'Direct ($head)' : 'Reported ($head)';
}

/// THE FLAG TABLE'S EXACT WORDS (CLINIC-WIRE.md: "meaning (exact
/// words shown to people)"). A flag is evidence, not a verdict - the
/// wording never says who is "bad", only what was measured.
String flagMeaning(ClinicFlagFact f) => switch (f.flag) {
      flagSigFail =>
        'bytes claiming this key failed signature checks (broken node'
            ' OR impersonation \u2014 the flag does not pick)',
      flagTsBackwards =>
        'advert timestamps went backwards (replay, reset, or drift)',
      flagRateStorm =>
        'packets from this key arriving far faster than advert cadence',
      flagCorruptShare =>
        'corrupt packets are ${_sharePct(f.detail)}% of heard traffic'
            ' (band noise or a broken transmitter \u2014 never blamed'
            ' on a sender)',
      _ => 'unknown flag ${f.flag}',
    };

/// Flag 4's detail rides as per-mille; the words show percent.
String _sharePct(int perMille) =>
    (perMille % 10 == 0 ? '${perMille ~/ 10}' : '${perMille / 10}');

/// One clinic fact beside its provenance and its age anchor.
class ClinicRow<T> {
  final T fact;
  final int viaOrigin;
  final int heardMs; // epoch ms this copy arrived (the honest anchor)
  const ClinicRow({required this.fact, required this.viaOrigin, required this.heardMs});

  bool get firstHand => _source == viaOrigin;

  int get _source => switch (fact) {
        ClinicNodeFact(:final source) => source,
        ClinicRouteFact(:final source) => source,
        ClinicFlagFact(:final source) => source,
        ClinicPeerFact(:final source) => source,
        _ => 0,
      };

  /// The measuring/reporting box (the wire's `source`).
  int get source => _source;

  String get label => provenanceLabel(_source, viaOrigin);

  /// The wire's minutes-since age, grown honestly since receipt.
  int ageMin(int wireAgeMin, int nowMs) => growAgeMin(wireAgeMin, heardMs, nowMs);
}

/// CLINIC-WIRE.md removal ages, in the wire's own minute ruler.
class ClinicLaws {
  // Node charts: removed ONLY when the node is gone - 30 days
  // without a hear (the node table's own forget law), or forgotten.
  static const chartsDieAfterMin = 30 * 1440;
  // Trouble flags: expire 30 days after their most recent event.
  static const flagsDieAfterMin = 30 * 1440;
  // Peer reports: expire 30 days after the peer last said it.
  static const peerReportsDieAfterMin = 30 * 1440;
  // Routes: the unchanged 7/14-day laws (the app's own route laws).
  static int routeDeadAfterMin(ClinicRouteFact f) =>
      routeIsDirect(f) ? NodeStore.directDeadAfterMin : NodeStore.multihopDeadAfterMin;
  static int routeStaleAfterMin(ClinicRouteFact f) =>
      routeIsDirect(f) ? NodeStore.directStaleAfterMin : NodeStore.multihopStaleAfterMin;
  // The wire's own direct flag, with the app's one-hop rule as the
  // fallback (both say "heard straight from the sender").
  static bool routeIsDirect(ClinicRouteFact f) =>
      f.direct == 1 || f.path.length <= 1;
}

class ClinicStore {
  // One row per (fact identity, measuring box) - never merged across
  // boxes. Newest receipt replaces the older (Brett's law).
  final Map<(int, int), ClinicRow<ClinicNodeFact>> _nodes = {};
  final Map<(String, int), ClinicRow<ClinicRouteFact>> _routes = {};
  final Map<(int, int, int), ClinicRow<ClinicFlagFact>> _flags = {};
  final Map<(int, int, int), ClinicRow<ClinicPeerFact>> _peers = {};

  Iterable<ClinicRow<ClinicNodeFact>> get nodeFacts => _nodes.values;
  Iterable<ClinicRow<ClinicRouteFact>> get routeFacts => _routes.values;
  Iterable<ClinicRow<ClinicFlagFact>> get flagFacts => _flags.values;
  Iterable<ClinicRow<ClinicPeerFact>> get peerFacts => _peers.values;

  /// Fold one heard CLINIC packet (both pipes land here - the store
  /// is the one place facts live, whatever carried them).
  void fold(Clinic packet, {required int heardMs}) {
    for (final record in packet.records) {
      switch (record) {
        case ClinicNodeFact():
          _nodes[(record.prefix, record.source)] =
              ClinicRow(fact: record, viaOrigin: packet.origin, heardMs: heardMs);
        case ClinicRouteFact():
          _routes[(_pathKey(record.path), record.source)] =
              ClinicRow(fact: record, viaOrigin: packet.origin, heardMs: heardMs);
        case ClinicFlagFact():
          _flags[(record.flag, record.subject, record.source)] =
              ClinicRow(fact: record, viaOrigin: packet.origin, heardMs: heardMs);
        case ClinicPeerFact():
          _peers[(record.report, record.subject, record.source)] =
              ClinicRow(fact: record, viaOrigin: packet.origin, heardMs: heardMs);
      }
    }
  }

  static String _pathKey(List<int> path) => path.join(',');

  // ------------------------------------------------------------- queries

  List<ClinicRow<ClinicNodeFact>> nodeFactsFor(int prefix) =>
      [for (final r in _nodes.values) if (r.fact.prefix == prefix) r];

  List<ClinicRow<ClinicFlagFact>> flagsFor(int subject) =>
      [for (final r in _flags.values) if (r.fact.subject == subject) r];

  /// Mesh-wide trouble (subject 0 = corrupt share) - no position, so
  /// the map lists it instead of drawing it.
  List<ClinicRow<ClinicFlagFact>> get meshWideFlags =>
      [for (final r in _flags.values) if (r.fact.subject == 0) r];

  /// Peer INTRO reports about one node (what other boxes last said
  /// it looks like - second-hand by construction).
  List<ClinicRow<ClinicPeerFact>> peerIntrosFor(int prefix) => [
        for (final r in _peers.values)
          if (r.fact.report == reportIntro && r.fact.subject == prefix) r
      ];

  // ---------------------------------------------------------- removals

  /// GONE / forget: a forgotten node's chart, flags and peer INTRO
  /// reports die with it (the wire page's forget law). Peer ROUTE
  /// reports survive - they are the route's facts, not the node's.
  /// Returns the number of rows removed (the UI redraws only then).
  int forgetNode(int prefix) {
    var removed = 0;
    removed += _nodes.length -
        _nodes.values.where((r) => r.fact.prefix != prefix).length;
    _nodes.removeWhere((_, r) => r.fact.prefix == prefix);
    removed += _flags.values.where((r) => r.fact.subject == prefix).length;
    _flags.removeWhere((_, r) => r.fact.subject == prefix);
    removed += _peers.values
        .where((r) =>
            r.fact.report == reportIntro && r.fact.subject == prefix)
        .length;
    _peers.removeWhere((_, r) =>
        r.fact.report == reportIntro && r.fact.subject == prefix);
    return removed;
  }

  /// The wire page's removal ages, enforced while running (load()
  /// prunes at launch too - closed time counts, persistence never
  /// freezes time). Returns the number of rows removed.
  int prune({required int nowMs}) {
    var before = _nodes.length + _routes.length + _flags.length + _peers.length;
    _nodes.removeWhere((_, r) =>
        r.ageMin(r.fact.lastAgeMin, nowMs) > ClinicLaws.chartsDieAfterMin);
    _routes.removeWhere((_, r) =>
        r.ageMin(r.fact.lastAgeMin, nowMs) >
        ClinicLaws.routeDeadAfterMin(r.fact));
    _flags.removeWhere((_, r) =>
        r.ageMin(r.fact.lastAgeMin, nowMs) > ClinicLaws.flagsDieAfterMin);
    _peers.removeWhere((_, r) =>
        r.ageMin(r.fact.heardAgeMin, nowMs) >
        ClinicLaws.peerReportsDieAfterMin);
    final after = _nodes.length + _routes.length + _flags.length + _peers.length;
    return before - after;
  }

  // ------------------------------------------------------- persistence

  static const _storeKey = 'clinic_store';

  /// Rows persist as the wire's own record BYTES (base64) beside the
  /// anchor and the relay - re-decoded through the same codec on
  /// load, so flash can never hold a shape the wire could not carry.
  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_storeKey, toJson());
  }

  Future<void> load({required int nowMs}) async {
    final sp = await SharedPreferences.getInstance();
    loadFrom(sp.getString(_storeKey), nowMs: nowMs);
  }

  /// The debug bench's fresh-install law: memory AND flash go.
  Future<void> wipe() async {
    clear();
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_storeKey);
  }

  String toJson() => jsonEncode({
        'n': [
          for (final r in _nodes.values)
            _rowJson(encodeClinicRecord(r.fact), r)
        ],
        'r': [
          for (final r in _routes.values)
            _rowJson(encodeClinicRecord(r.fact), r)
        ],
        'f': [
          for (final r in _flags.values)
            _rowJson(encodeClinicRecord(r.fact), r)
        ],
        'p': [
          for (final r in _peers.values)
            _rowJson(encodeClinicRecord(r.fact), r)
        ],
      });

  static Map<String, Object?> _rowJson(Uint8List bytes, ClinicRow row) => {
        'b': base64Encode(bytes),
        'v': row.viaOrigin,
        'h': row.heardMs,
      };

  /// Rebuild from flash, then apply the death law at launch: anything
  /// that died while the app was shut is gone the moment it reopens.
  void loadFrom(String? raw, {required int nowMs}) {
    clear();
    if (raw == null) return;
    final j = jsonDecode(raw) as Map<String, Object?>;
    void addAll<T>(List<Object?>? rows, void Function(Object fact, int v, int h) add) {
      for (final raw in rows ?? const []) {
        final m = (raw as Map).cast<String, Object?>();
        final bytes = base64Decode(m['b'] as String);
        add(decodeClinicRecord(Uint8List.fromList(bytes)),
            (m['v'] as num).toInt(), (m['h'] as num).toInt());
      }
    }

    addAll(j['n'] as List<Object?>?, (fact, v, h) {
      final f = fact as ClinicNodeFact;
      _nodes[(f.prefix, f.source)] = ClinicRow(fact: f, viaOrigin: v, heardMs: h);
    });
    addAll(j['r'] as List<Object?>?, (fact, v, h) {
      final f = fact as ClinicRouteFact;
      _routes[(_pathKey(f.path), f.source)] =
          ClinicRow(fact: f, viaOrigin: v, heardMs: h);
    });
    addAll(j['f'] as List<Object?>?, (fact, v, h) {
      final f = fact as ClinicFlagFact;
      _flags[(f.flag, f.subject, f.source)] =
          ClinicRow(fact: f, viaOrigin: v, heardMs: h);
    });
    addAll(j['p'] as List<Object?>?, (fact, v, h) {
      final f = fact as ClinicPeerFact;
      _peers[(f.report, f.subject, f.source)] =
          ClinicRow(fact: f, viaOrigin: v, heardMs: h);
    });
    prune(nowMs: nowMs);
  }

  void clear() {
    _nodes.clear();
    _routes.clear();
    _flags.clear();
    _peers.clear();
  }
}
