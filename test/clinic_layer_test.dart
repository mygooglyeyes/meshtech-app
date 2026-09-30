// The clinic layer's laws (map_model.dart): the five fact-family
// views show exactly their family, every drawn fact wears its hand,
// facts without a place draw NOWHERE (counted out loud), and the tap-
// detail cards show missing numbers as missing.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/clinic_store.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/map_model.dart';
import 'package:meshtech_app/store.dart';

NodeStore _store({required int nowMs}) {
  final s = NodeStore();
  s.upsert(NodeRecord(
      prefix: 0x21, name: 'Hilltop', lat: 38.0, lon: -122.0, lastHeardMs: nowMs));
  s.upsert(NodeRecord(
      prefix: 0x22, name: 'Alice', lat: 38.01, lon: -122.0, lastHeardMs: nowMs));
  return s;
}

ClinicStore _clinic(int nowMs, List<Object> records, {int origin = 0xb17e}) {
  final c = ClinicStore();
  c.fold(Clinic(seq: 1, origin: origin, records: records), heardMs: nowMs);
  return c;
}

ClinicNodeFact _chart(
        {int source = 0xb17e,
        int prefix = 0x21,
        int lastAgeMin = 3,
        int hops = 2,
        int share = 37}) =>
    ClinicNodeFact(
        source: source,
        prefix: prefix,
        lastAgeMin: lastAgeMin,
        ageDays: 5,
        strip: 0x800007,
        hopsTyp: hops,
        sharePct: share);

void main() {
  final nowMs = DateTime.now().millisecondsSinceEpoch;

  group('the five fact-family views', () {
    test('each view shows exactly its family - all shows everything', () {
      final clinic = _clinic(nowMs, [
        _chart(source: 0xb17e), // kind 1 (first-hand)
        _chart(source: 0xbeef, prefix: 0x22), // kind 1 (second-hand)
        const ClinicRouteFact(
            source: 0xb17e,
            path: [0x21, 0x22],
            uses: 5,
            direct: 0,
            delayMinS: 1,
            delayMedS: 2,
            delayMaxS: 3,
            lastAgeMin: 4,
            ageDays: 1), // kind 2
        const ClinicFlagFact(
            source: 0xb17e,
            flag: flagRateStorm,
            subject: 0x21,
            events: 3,
            firstAgeMin: 9,
            lastAgeMin: 2,
            detail: 22), // kind 3
        const ClinicPeerFact(
            source: 0xbeef,
            report: reportIntro,
            subject: 0x22,
            heardAgeMin: 4,
            lat: 38.01,
            lon: -122.0,
            name: 'Alice'), // kind 4
      ]);
      final store = _store(nowMs: nowMs);

      final nodes = ClinicLayerVM.build(clinic, store, ClinicView.nodes,
          nowMs: nowMs);
      expect(nodes.markers.length, 2); // both chart rows
      expect(nodes.lines, isEmpty);

      final routes = ClinicLayerVM.build(clinic, store, ClinicView.routes,
          nowMs: nowMs);
      expect(routes.markers, isEmpty);
      expect(routes.lines.length, 1);

      final trouble = ClinicLayerVM.build(clinic, store, ClinicView.trouble,
          nowMs: nowMs);
      expect(trouble.markers.length, 1);
      expect(trouble.markers.single.color, ClinicColor.trouble);

      final second = ClinicLayerVM.build(clinic, store, ClinicView.secondHand,
          nowMs: nowMs);
      expect(second.markers.length, 1);
      expect(second.markers.single.color, ClinicColor.secondHand);

      final all = ClinicLayerVM.build(clinic, store, ClinicView.all,
          nowMs: nowMs);
      expect(all.markers.length, 4);
      expect(all.lines.length, 1);
      expect(all.unpositioned, 0);
    });

    test('a fresh chart is blue, an aging one yellow (the 3-day line)', () {
      final clinic = _clinic(nowMs, [
        _chart(source: 0xb17e, prefix: 0x21, lastAgeMin: 3),
        _chart(source: 0xb17e, prefix: 0x22, lastAgeMin: 4 * 1440),
      ]);
      final layer = ClinicLayerVM.build(
          clinic, _store(nowMs: nowMs), ClinicView.nodes,
          nowMs: nowMs);
      final byPrefix = {
        for (final m in layer.markers) m.target: m.color,
      };
      expect(byPrefix[const ClinicNodeTarget(0x21)], ClinicColor.fresh);
      expect(byPrefix[const ClinicNodeTarget(0x22)], ClinicColor.aging);
    });
  });

  group('honest gaps (a fact with no place draws nowhere)', () {
    test('mesh-wide flags, positionless claims and unknown hops count out loud',
        () {
      final clinic = _clinic(nowMs, [
        _chart(source: 0xb17e, prefix: 0x77), // node the phone never heard
        const ClinicFlagFact(
            source: 0xb17e,
            flag: flagCorruptShare,
            subject: 0, // mesh-wide: no place
            events: 4,
            firstAgeMin: 30,
            lastAgeMin: 5,
            detail: 125),
        const ClinicPeerFact(
            source: 0xbeef,
            report: reportIntro,
            subject: 0x22,
            heardAgeMin: 4,
            name: 'NoFix'), // the peer reported NO position
        const ClinicPeerFact(
            source: 0xbeef,
            report: reportPulse,
            subject: 0,
            heardAgeMin: 4,
            values: [1, 2, 3, 4]), // a pulse is not about a place
      ]);
      final layer = ClinicLayerVM.build(
          clinic, _store(nowMs: nowMs), ClinicView.all,
          nowMs: nowMs);
      expect(layer.markers, isEmpty);
      expect(layer.lines, isEmpty);
      expect(layer.unpositioned, 4);
    });

    test('a route with unknown hops draws only its known runs', () {
      final clinic = _clinic(nowMs, [
        const ClinicRouteFact(
            source: 0xb17e,
            path: [0x21, 0x77, 0x22], // the middle hop is unknown
            uses: 5,
            direct: 0,
            delayMinS: 1,
            delayMedS: 2,
            delayMaxS: 3,
            lastAgeMin: 4,
            ageDays: 1),
      ]);
      final layer = ClinicLayerVM.build(
          clinic, _store(nowMs: nowMs), ClinicView.routes,
          nowMs: nowMs);
      // Gap-split: the line NEVER crosses the invented middle - two
      // lone known ends are not bridged, and the fact counts out loud.
      expect(layer.lines, isEmpty);
      expect(layer.unpositioned, 1);

      // But a trail with two drawable runs draws exactly those runs.
      final twoRuns = _clinic(nowMs, [
        const ClinicRouteFact(
            source: 0xb17e,
            path: [0x21, 0x22, 0x77, 0x21, 0x22],
            uses: 5,
            direct: 0,
            delayMinS: 1,
            delayMedS: 2,
            delayMaxS: 3,
            lastAgeMin: 4,
            ageDays: 1),
      ]);
      final drawn = ClinicLayerVM.build(
          twoRuns, _store(nowMs: nowMs), ClinicView.routes,
          nowMs: nowMs);
      expect(drawn.lines.single.segs.length, 2);
      expect(drawn.unpositioned, 0);
    });
  });

  group('provenance on the map and in the cards', () {
    test('a second-hand fact wears its hand on the map label', () {
      final clinic = _clinic(nowMs, [
        _chart(source: 0xb17e),
        _chart(source: 0xbeef),
      ], origin: 0xb17e);
      final layer = ClinicLayerVM.build(
          clinic, _store(nowMs: nowMs), ClinicView.nodes,
          nowMs: nowMs);
      final labels = {for (final m in layer.markers) m.label};
      expect(labels, {'Hilltop 21', 'Hilltop 21 \u00b7 reported'});
    });

    test('EVERY card line about a fact carries its provenance label', () {
      final clinic = _clinic(nowMs, [
        _chart(source: 0xb17e),
        _chart(source: 0xbeef),
        const ClinicFlagFact(
            source: 0xbeef,
            flag: flagTsBackwards,
            subject: 0x21,
            events: 2,
            firstAgeMin: 30,
            lastAgeMin: 5,
            detail: 500),
        const ClinicPeerFact(
            source: 0xcafe,
            report: reportIntro,
            subject: 0x21,
            heardAgeMin: 4,
            lat: 38.0,
            lon: -122.0,
            name: 'Hilltop'),
      ], origin: 0xb17e);
      final card = ClinicCards.nodeCard(clinic, _store(nowMs: nowMs), 0x21,
          nowMs: nowMs);
      expect(card.first, 'Hilltop 21'); // the title is the node itself
      final factLines = card.skip(1).toList();
      expect(factLines.length, 4);
      for (final line in factLines) {
        expect(
            line.startsWith('Direct (') || line.startsWith('Reported ('),
            isTrue,
            reason: 'unlabeled fact: $line');
      }
      expect(factLines.where((l) => l.contains('(b17e)')).length, 1);
      expect(factLines.where((l) => l.contains('(beef)')).length, 2);
      expect(factLines.where((l) => l.contains('(cafe)')).length, 1);
    });
  });

  group('tap-detail cards', () {
    test('the tap finds the nearest fact within a finger, or nothing', () {
      final clinic = _clinic(nowMs, [
        _chart(source: 0xb17e, prefix: 0x21),
        const ClinicRouteFact(
            source: 0xb17e,
            path: [0x21, 0x22],
            uses: 5,
            direct: 0,
            delayMinS: 1,
            delayMedS: 2,
            delayMaxS: 3,
            lastAgeMin: 4,
            ageDays: 1),
      ]);
      final layer = ClinicLayerVM.build(
          clinic, _store(nowMs: nowMs), ClinicView.all,
          nowMs: nowMs);
      // On the marker (~0 m): its node card.
      expect(ClinicLayerVM.hitTest(layer, (-122.0, 38.0), 80),
          const ClinicNodeTarget(0x21));
      // Near the line's middle: the route card.
      expect(ClinicLayerVM.hitTest(layer, (-122.0, 38.005), 80),
          const ClinicRouteTarget([0x21, 0x22]));
      // Empty map: an honest miss - no card, the section tap lives.
      expect(ClinicLayerVM.hitTest(layer, (-122.05, 38.05), 80), isNull);
    });

    test('the route card names every box that charted the trail', () {
      final clinic = _clinic(nowMs, [
        const ClinicRouteFact(
            source: 0xb17e,
            path: [0x21, 0x22],
            uses: 56,
            direct: 0,
            delayMinS: 2,
            delayMedS: 4,
            delayMaxS: 9,
            lastAgeMin: 17,
            ageDays: 2),
        const ClinicRouteFact(
            source: 0xbeef,
            path: [0x21, 0x22],
            uses: 3,
            direct: 0,
            delayMinS: 0,
            delayMedS: 0,
            delayMaxS: 0,
            lastAgeMin: 0,
            ageDays: 1),
      ]);
      final card = ClinicCards.routeCard(clinic, const [0x21, 0x22],
          nowMs: nowMs);
      expect(card.first, 'route 21-22');
      expect(card[1],
          'Direct (b17e) - route: 56 uses, via trail, '
          'delay min/med/max 2 s/4 s/9 s, last used 17 min ago, 2 days old');
      // Missing delays stay missing - never a plausible constant.
      expect(card[2], contains('delay min/med/max unknown/unknown/unknown'));
    });

    test('the loose card lists what has no place - never pins it', () {
      final clinic = _clinic(nowMs, [
        const ClinicFlagFact(
            source: 0xb17e,
            flag: flagCorruptShare,
            subject: 0,
            events: 4,
            firstAgeMin: 30,
            lastAgeMin: 5,
            detail: 125),
        const ClinicPeerFact(
            source: 0xbeef,
            report: reportPulse,
            subject: 0,
            heardAgeMin: 4,
            values: [1234, 4, 40, 9]),
      ]);
      final card = ClinicCards.looseCard(clinic, nowMs: nowMs);
      expect(card.first, 'facts without a place');
      expect(
          card[1],
          'Direct (b17e) - corrupt packets are 12.5% of heard '
          'traffic (band noise or a broken transmitter \u2014 never '
          'blamed on a sender) - 4 event(s), first 30 min ago, '
          'last 5 min ago');
      expect(card[2],
          'Reported (beef) - pulse (said 4 min ago): '
          'uptime 21 h, 4/h, 40 active, airtime 9 s/h');
    });

    test('the sentinels speak as unknown in the cards', () {
      final clinic = _clinic(nowMs, [
        _chart(
            source: 0xb17e,
            lastAgeMin: ageUnknownMin,
            hops: 0,
            share: shareUnknownPct),
      ]);
      final card = ClinicCards.nodeCard(clinic, _store(nowMs: nowMs), 0x21,
          nowMs: nowMs);
      final line = card[1];
      expect(line, contains('heard unknown (older than the wire can say)'));
      expect(line, contains('hops unknown'));
      expect(line, contains('share unknown (no identified traffic counted)'));
      expect(line, contains('SNR unknown'));
      expect(line, contains('spread unknown'));
      // strip 0x800007 lights 4 of the 24 hour bits.
      expect(line, contains('heard in 4 of the last 24 hours'));
    });

    test('ages tell the truth in human words', () {
      expect(ClinicCards.ageText(3), '3 min ago');
      expect(ClinicCards.ageText(240), '4 h ago');
      expect(ClinicCards.ageText(3 * 1440), '3 d ago');
      expect(ClinicCards.ageText(ageUnknownMin),
          'unknown (older than the wire can say)');
    });
  });

  group('the health report cards (Brett, 2026-09-29)', () {
    test('a node report names the four families with the real numbers '
        'and the honest gaps', () {
      final clinic = _clinic(nowMs, [
        const ClinicNodeFact(
            source: 0xb17e,
            prefix: 0x21,
            lastAgeMin: 3,
            ageDays: 5,
            strip: 0x800007,
            hopsTyp: 2,
            sharePct: 37,
            snrEwma: 20,
            snrBest: 28,
            snrWorst: 8,
            snrSd: 8,
            rssiEwma: -96,
            rssiBest: -90,
            rssiWorst: -101,
            rssiSd: 3),
        const ClinicFlagFact(
            source: 0xb17e,
            flag: flagRateStorm,
            subject: 0x21,
            events: 3,
            firstAgeMin: 9,
            lastAgeMin: 2,
            detail: 22),
        const ClinicFlagFact(
            source: 0xb17e,
            flag: flagTsBackwards,
            subject: 0x21,
            events: 2,
            firstAgeMin: 30,
            lastAgeMin: 5,
            detail: 500),
        const ClinicRouteFact(
            source: 0xb17e,
            path: [0x21, 0x22],
            uses: 56,
            direct: 0,
            delayMinS: 2,
            delayMedS: 4,
            delayMaxS: 9,
            lastAgeMin: 17,
            ageDays: 2),
      ]);
      final card = ClinicCards.nodeHealthCard(clinic, 0x21, nowMs: nowMs);
      // The four families, Brett's words, Brett's order.
      expect([
        for (final r in card)
          if (r is HealthFamily) r.name
      ], [
        'Link quality margins',
        'Airtime & congestion',
        'Delivery reliability & latency',
        'Stability & hygiene',
      ]);
      // The provenance chip: Direct / Reported - no "box", no
      // "said it" (Brett, 2026-09-29).
      final chips = [for (final r in card) if (r is HealthChip) r.label];
      expect(chips, contains('Direct (b17e)'));
      // The margins: average AND spread on fixed-scale bars - the
      // numbers only, no grade.
      final snr = card.whereType<HealthBar>().firstWhere((b) => b.key == 'SNR');
      expect(snr.value, '5.0 dB');
      expect(snr.spread, '\u00b12.0');
      expect(snr.start, lessThan(snr.tick));
      expect(snr.tick, lessThan(snr.end));
      final rssi =
          card.whereType<HealthBar>().firstWhere((b) => b.key == 'RSSI');
      expect(rssi.value, '-96 dBm');
      expect(rssi.spread, '\u00b13');
      // Airtime: the share blocks + the rate-storm evidence.
      expect(card.whereType<HealthBlocks>().single.value, '37%');
      final storm = card
          .whereType<HealthFlag>()
          .firstWhere((f) => f.name == 'rate storm');
      expect(storm.detail, contains('peak 22/min'));
      // Delivery: hops in Brett's words + the route delay bar.
      expect(card.whereType<HealthNote>().map((n) => n.text),
          contains('Typical hops: 2'));
      final delay =
          card.whereType<HealthBar>().firstWhere((b) => b.key == 'delay');
      expect(delay.value, '2/4/9 s');
      // Stability: the strip + the clock-skew evidence.
      expect(card.whereType<HealthStrip>().single.value, '4/24 h');
      final ts = card
          .whereType<HealthFlag>()
          .firstWhere((f) => f.name == 'timestamps backwards');
      expect(ts.detail, contains('worst jump 500 s'));
      // The honest gaps, named out loud - never invented.
      final gaps = [for (final g in card.whereType<HealthGap>()) g.text];
      expect(
          gaps,
          contains('duplicates \u00b7 occupancy \u00b7 duty headroom: '
              'not measured yet'));
      expect(
          gaps,
          contains('loss \u00b7 retries \u00b7 reordering \u00b7 '
              'request\u2192answer: not measured yet'));
      expect(gaps, contains('churn \u00b7 hash collisions: not measured yet'));
    });

    test('a route report carries its chart and its honest gaps', () {
      final clinic = _clinic(nowMs, [
        const ClinicRouteFact(
            source: 0xb17e,
            path: [0x21, 0x22],
            uses: 56,
            direct: 0,
            delayMinS: 2,
            delayMedS: 4,
            delayMaxS: 9,
            lastAgeMin: 17,
            ageDays: 2),
      ]);
      final card =
          ClinicCards.routeHealthCard(clinic, const [0x21, 0x22], nowMs: nowMs);
      expect([
        for (final r in card)
          if (r is HealthFamily) r.name
      ], [
        'Link quality margins',
        'Airtime & congestion',
        'Delivery reliability & latency',
        'Stability & hygiene',
      ]);
      expect(card.whereType<HealthChip>().map((c) => c.label),
          contains('Direct (b17e)'));
      expect(card.whereType<HealthNote>().map((n) => n.text),
          contains('56 use(s) counted'));
      final delay = card.whereType<HealthBar>().single;
      expect(delay.value, '2/4/9 s');
      expect(delay.note, 'min/med/max');
      final gaps = [for (final g in card.whereType<HealthGap>()) g.text];
      expect(gaps, contains('per-hop signal: not measured yet'));
      expect(gaps, contains('duplicates: not measured yet'));
      expect(
          gaps,
          contains('loss \u00b7 retries \u00b7 reordering \u00b7 '
              'request\u2192answer: not measured yet'));
      expect(gaps, contains('churn \u00b7 hash collisions: not measured yet'));
    });

    test('a trail no box charted says so - and the sentinels stay '
        'unknown', () {
      final empty =
          ClinicCards.routeHealthCard(ClinicStore(), const [0x21, 0x22],
              nowMs: nowMs);
      expect(empty.whereType<HealthNote>().first.text, 'no chart yet');
      final clinic = _clinic(nowMs, [
        _chart(
            source: 0xb17e,
            lastAgeMin: ageUnknownMin,
            hops: 0,
            share: shareUnknownPct),
      ]);
      final card = ClinicCards.nodeHealthCard(clinic, 0x21, nowMs: nowMs);
      final notes = [for (final n in card.whereType<HealthNote>()) n.text];
      expect(notes, contains('SNR unknown'));
      expect(notes, contains('RSSI unknown'));
      expect(notes, contains('Typical hops: unknown'));
      expect(notes, contains('share unknown'));
    });
  });
}
