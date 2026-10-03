// The clinic store's laws (CLINIC-WIRE.md governs): provenance never
// merges, an update replaces the old, ages grow honestly while the
// app is closed, and the removal ages are the wire page's exact ones.
// Every word a flag shows is the page's exact wording - evidence,
// never a verdict.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/clinic_store.dart';
import 'package:meshtech_app/codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _hourMs = 3600 * 1000;
const _dayMs = 24 * _hourMs;

Clinic _packet(
        {required int origin,
        required List<Object> records,
        String name = ''}) =>
    Clinic(seq: 1, origin: origin, records: records, name: name);

ClinicNodeFact _chart(
        {required int source, int prefix = 0x21, int lastAgeMin = 3}) =>
    ClinicNodeFact(
        source: source,
        prefix: prefix,
        lastAgeMin: lastAgeMin,
        ageDays: 5,
        strip: 0x800007,
        hopsTyp: 2,
        sharePct: 37);

ClinicFlagFact _flag(
        {required int source,
        int flag = flagTsBackwards,
        int subject = 0x21,
        int lastAgeMin = 5}) =>
    ClinicFlagFact(
        source: source,
        flag: flag,
        subject: subject,
        events: 2,
        firstAgeMin: 30,
        lastAgeMin: lastAgeMin,
        detail: 500);

ClinicPeerFact _intro(
        {required int source, int subject = 0x22, int heardAgeMin = 4}) =>
    ClinicPeerFact(
        source: source,
        report: reportIntro,
        subject: subject,
        heardAgeMin: heardAgeMin,
        name: 'Alice');

ClinicPeerFact _peerRoute(
        {required int source, int subject = 0xbeef, int heardAgeMin = 4}) =>
    ClinicPeerFact(
        source: source,
        report: reportRoute,
        subject: subject,
        heardAgeMin: heardAgeMin,
        values: const [7, 12, 3, 0],
        path: const [0x11, 0x22]);

ClinicRouteFact _routeFact(
        {required int source,
        int direct = 0,
        int lastAgeMin = 17,
        List<int> path = const [0x11, 0x22]}) =>
    ClinicRouteFact(
        source: source,
        path: path,
        uses: 56,
        direct: direct,
        delayMinS: 2,
        delayMedS: 4,
        delayMaxS: 9,
        lastAgeMin: lastAgeMin,
        ageDays: 2);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('provenance (the wire page rule)', () {
    test('source == origin = first-hand; source != origin = second-hand', () {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(
          _packet(origin: 0xb17e, records: [
            _chart(source: 0xb17e), // its own radio: first-hand
            _chart(source: 0xbeef, prefix: 0x33), // a peer said it
          ]),
          heardMs: now);
      final own = s.nodeFactsFor(0x21).single;
      expect(own.firstHand, isTrue);
      expect(own.label, 'Direct'); // home box, no hex, no invented name
      final peer = s.nodeFactsFor(0x33).single;
      expect(peer.firstHand, isFalse);
      expect(peer.label, 'unknown box'); // name never heard - honest gap
      // The peer's own named packet teaches the store its name; the
      // row folded EARLIER picks the name up (labels resolve live).
      s.fold(_packet(origin: 0xbeef, records: const [], name: 'TestBox'),
          heardMs: now);
      expect(peer.label, 'TestBox');
    });

    test('two boxes measuring one node = TWO rows, never merged', () {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(
          _packet(origin: 0xb17e, records: [_chart(source: 0xb17e)]),
          heardMs: now);
      s.fold(
          _packet(origin: 0xbeef, records: [_chart(source: 0xbeef)]),
          heardMs: now);
      expect(s.nodeFactsFor(0x21).length, 2);
      // Disagreement preserved: each row keeps its OWN numbers.
      final sources = {for (final r in s.nodeFactsFor(0x21)) r.source};
      expect(sources, {0xb17e, 0xbeef});
    });

    test('an update REPLACES the old for the same measuring box', () {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(
          _packet(origin: 0xb17e, records: [_chart(source: 0xb17e, lastAgeMin: 30)]),
          heardMs: now - _hourMs);
      s.fold(
          _packet(origin: 0xb17e, records: [_chart(source: 0xb17e, lastAgeMin: 3)]),
          heardMs: now);
      final row = s.nodeFactsFor(0x21).single;
      expect(row.fact.lastAgeMin, 3); // the newest IS the row
      expect(row.heardMs, now);
    });
  });

  group('honest ages (persistence never freezes time)', () {
    test('the wire age grows by the minutes that really passed', () {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(
          _packet(origin: 0xb17e, records: [_chart(source: 0xb17e, lastAgeMin: 5)]),
          heardMs: now - 10 * 60000);
      final row = s.nodeFactsFor(0x21).single;
      expect(row.ageMin(row.fact.lastAgeMin, now), 15);
    });

    test('the unknown sentinel stays unknown - never a small lie', () {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(
          _packet(origin: 0xb17e, records: [
            _chart(source: 0xb17e, lastAgeMin: ageUnknownMin),
          ]),
          heardMs: now - _dayMs);
      final row = s.nodeFactsFor(0x21).single;
      expect(row.ageMin(row.fact.lastAgeMin, now), ageUnknownMin);
      expect(ageIsUnknown(row.ageMin(row.fact.lastAgeMin, now)), isTrue);
    });
  });

  group('removal ages (the wire page, exact)', () {
    test('a node chart is removed ONLY when its node is gone - 30 days', () {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(
          _packet(origin: 0xb17e, records: [_chart(source: 0xb17e, lastAgeMin: 0)]),
          heardMs: now - 29 * _dayMs);
      s.fold(
          _packet(origin: 0xb17e, records: [
            _chart(source: 0xb17e, prefix: 0x44, lastAgeMin: 0),
          ]),
          heardMs: now - 31 * _dayMs);
      s.prune(nowMs: now);
      expect(s.nodeFactsFor(0x21).length, 1); // 29 d: alive
      expect(s.nodeFactsFor(0x44), isEmpty); // 31 d: gone
    });

    test('a trouble flag expires 30 days after its MOST RECENT event', () {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      // last event 29 d ago (first event 40 d ago): alive - the page
      // keys the death on the LAST event.
      s.fold(
          _packet(origin: 0xb17e, records: [
            ClinicFlagFact(
                source: 0xb17e,
                flag: flagRateStorm,
                subject: 0x21,
                events: 9,
                firstAgeMin: 40 * 1440,
                lastAgeMin: 29 * 1440,
                detail: 22),
          ]),
          heardMs: now);
      s.fold(
          _packet(origin: 0xb17e, records: [
            _flag(source: 0xb17e, flag: flagSigFail, lastAgeMin: 31 * 1440),
          ]),
          heardMs: now);
      s.prune(nowMs: now);
      expect(s.flagsFor(0x21).map((r) => r.fact.flag), [flagRateStorm]);
    });

    test('a peer report expires 30 days after the peer last said it', () {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(
          _packet(origin: 0xb17e, records: [
            _intro(source: 0xbeef, subject: 0x22, heardAgeMin: 29 * 1440),
          ]),
          heardMs: now);
      s.fold(
          _packet(origin: 0xb17e, records: [
            _intro(source: 0xcafe, subject: 0x33, heardAgeMin: 31 * 1440),
          ]),
          heardMs: now);
      s.prune(nowMs: now);
      expect(s.peerIntrosFor(0x22).length, 1);
      expect(s.peerIntrosFor(0x33), isEmpty);
    });

    test('route facts keep the unchanged 7/14-day laws', () {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      // direct: dead past 7 days. multi-hop: dead past 14.
      s.fold(
          _packet(origin: 0xb17e, records: [
            _routeFact(source: 0xb17e, direct: 1, lastAgeMin: 8 * 1440,
                path: const [0x11]),
          ]),
          heardMs: now);
      s.fold(
          _packet(origin: 0xb17e, records: [
            _routeFact(source: 0xbeef, lastAgeMin: 8 * 1440),
          ]),
          heardMs: now);
      s.fold(
          _packet(origin: 0xb17e, records: [
            _routeFact(source: 0xcafe, lastAgeMin: 15 * 1440),
          ]),
          heardMs: now);
      s.prune(nowMs: now);
      expect(s.routeFacts.map((r) => r.source), [0xbeef]); // multi-hop at 8 d
    });
  });

  group('forget (GONE means GONE for the node\'s facts)', () {
    test('the chart, flags and peer INTROs die; peer ROUTE reports live', () {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(
          _packet(origin: 0xb17e, records: [
            _chart(source: 0xb17e, prefix: 0x21),
            _chart(source: 0xbeef, prefix: 0x22), // another node survives
            _flag(source: 0xb17e, subject: 0x21),
            _flag(source: 0xb17e, flag: flagCorruptShare, subject: 0), // mesh-wide
            _intro(source: 0xbeef, subject: 0x21),
            _peerRoute(source: 0xbeef, subject: 0x21),
          ]),
          heardMs: now);
      final removed = s.forgetNode(0x21);
      expect(removed, 3); // chart + flag + peer intro
      expect(s.nodeFactsFor(0x21), isEmpty);
      expect(s.nodeFactsFor(0x22).length, 1);
      expect(s.flagsFor(0x21), isEmpty);
      expect(s.meshWideFlags.length, 1); // subject 0 never dies with a node
      expect(s.peerIntrosFor(0x21), isEmpty);
      expect(s.peerFacts.length, 1); // the route report survives
    });
  });

  group('persistence (the app comes up just like it shut down)', () {
    test('save -> load round-trips every row with its anchor and relay',
        () async {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(
          _packet(origin: 0xbeef, name: 'BeefBox', records: [
            _chart(source: 0xb17e, lastAgeMin: 5),
            _routeFact(source: 0xbeef),
            _flag(source: 0xbeef),
            _intro(source: 0xcafe),
          ]),
          heardMs: now - 10 * 60000);
      await s.save();

      final back = ClinicStore();
      await back.load(nowMs: now);
      final chart = back.nodeFactsFor(0x21).single;
      // The relay is preserved exactly: b17e measured it, beef sent
      // it - so the row is second-hand, never re-worded.
      expect(chart.firstHand, isFalse);
      expect(chart.viaOrigin, 0xbeef);
      // b17e's own name was never heard: the honest gap, not hex.
      expect(chart.label, 'unknown box');
      // The sending box's name rides through the restart too.
      expect(back.boxNameOf(0xbeef), 'BeefBox');
      expect(chart.ageMin(chart.fact.lastAgeMin, now), 15);
      expect(back.routeFacts.length, 1);
      expect(back.flagFacts.length, 1);
      expect(back.peerFacts.length, 1);
    });

    test('anything that died while closed is gone at re-open', () async {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(
          _packet(origin: 0xb17e, records: [
            _flag(source: 0xb17e, lastAgeMin: 31 * 1440),
            _flag(source: 0xb17e, flag: flagRateStorm, lastAgeMin: 1),
          ]),
          heardMs: now);
      await s.save();

      final back = ClinicStore();
      await back.load(nowMs: now);
      expect(back.flagFacts.map((r) => r.fact.flag), [flagRateStorm]);
    });

    test('wipe clears memory AND flash', () async {
      final s = ClinicStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.fold(_packet(origin: 0xb17e, records: [_chart(source: 0xb17e)]),
          heardMs: now);
      await s.save();
      await s.wipe();

      final back = ClinicStore();
      await back.load(nowMs: now);
      expect(back.nodeFacts, isEmpty);
    });
  });

  group('the flag table\'s exact words (evidence, never a verdict)', () {
    test('each flag shows the page\'s exact meaning', () {
      expect(
          flagMeaning(_flag(source: 1, flag: flagSigFail)),
          'bytes claiming this key failed signature checks (broken node'
          ' OR impersonation \u2014 the flag does not pick)');
      expect(
          flagMeaning(_flag(source: 1, flag: flagTsBackwards)),
          'advert timestamps went backwards (replay, reset, or drift)');
      expect(
          flagMeaning(_flag(source: 1, flag: flagRateStorm)),
          'packets from this key arriving far faster than advert cadence');
    });

    test('corrupt share speaks percent from its per-mille detail', () {
      // detail rides as per-mille: 125 -> 12.5%, 100 -> 10%.
      final at125 = ClinicFlagFact(
          source: 1,
          flag: flagCorruptShare,
          subject: 0,
          events: 1,
          firstAgeMin: 0,
          lastAgeMin: 0,
          detail: 125);
      expect(
          flagMeaning(at125),
          'corrupt packets are 12.5% of heard traffic (band noise or a'
          ' broken transmitter \u2014 never blamed on a sender)');
      final at100 = ClinicFlagFact(
          source: 1,
          flag: flagCorruptShare,
          subject: 0,
          events: 1,
          firstAgeMin: 0,
          lastAgeMin: 0,
          detail: 100);
      expect(
          flagMeaning(at100),
          'corrupt packets are 10% of heard traffic (band noise or a'
          ' broken transmitter \u2014 never blamed on a sender)');
    });

    test('the provenance label names the box honestly', () {
      // The home box reads plain Direct; another box shows its NAME
      // when known and the honest gap when not - never a hex tag.
      expect(provenanceLabel(0xb17e, 0xb17e), 'Direct');
      expect(provenanceLabel(0x0001, 0xb17e), 'unknown box');
      expect(provenanceLabel(0x0001, 0xb17e, 'Hilltop2'), 'Hilltop2');
    });
  });

  group('health facts (kinds 5-8) fold like every other fact', () {
    test('one row per (identity, box) - newest receipt wins, '
        'provenance rides along', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final c = ClinicStore();
      c.fold(
          Clinic(seq: 1, origin: 0xb17e, records: const [
            ClinicAirtimeFact(
                source: 0xb17e,
                windowMin: 60,
                dupPerMille: 286,
                occupancyPerMille: 167,
                dutyHeadroomS: 3500,
                txUsedS: 100),
            ClinicSenderFact(
                source: 0xbeef,
                sender: 0x1234,
                windowMin: 1440,
                dupPerMille: 0,
                lost: 4,
                reordered: 1,
                flaps: 1),
          ]),
          heardMs: nowMs);
      c.fold(
          Clinic(seq: 2, origin: 0xb17e, records: const [
            ClinicSenderFact(
                source: 0xbeef,
                sender: 0x1234,
                windowMin: 1440,
                dupPerMille: 0,
                lost: 5,
                reordered: 1,
                flaps: 1),
          ]),
          heardMs: nowMs + 60000);
      expect(c.airtimeFacts.length, 1);
      expect(c.senderFacts.length, 1); // same (tag, box): replaced
      expect(c.senderFacts.single.fact.lost, 5); // newest receipt wins
      expect(c.airtimeFacts.single.label, 'Direct');
      expect(c.senderFacts.single.label, 'unknown box');
      // The honest age grows from receipt, never frozen.
      expect(c.senderFacts.single.ageMin(0, nowMs + 120000), 1);
    });
  });
}
