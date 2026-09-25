// The wire feed: raw scope plaintext -> decoded packets, with THE
// ZERO-DOTS LAW applied once, shared by BOTH links (door + companion).
// Extracted from TcpLink (2026-09-25, the BLE companion link) so the
// law lives in one place: INTRO positions are DELTAS against the map
// center - decoding them against (0,0) lands every dot ~10,000 km
// away. The LAYOUT always arrives first in a burst; an INTRO that
// arrives before any LAYOUT is HELD (loudly), never silently
// mis-placed, and flushes the moment the center is known.
//
// The feed is a decoder, never a transport: links hand it bytes and
// it hands back packets through the same callbacks the shell already
// consumes (onPacket -> store, onLog -> the event log).

import 'dart:typed_data';

import 'codec.dart';

class WireFeed {
  /// 'door' or 'air' - the receipt log names the pipe a packet came
  /// in on (Brett's honest-receipt law): "door <- route 12".
  final String pipe;
  final void Function(Object packet, {int? heardMs}) onPacket;
  final void Function(String line) onLog;

  WireFeed({required this.pipe, required this.onPacket, required this.onLog});

  Layout? _layout;
  final List<Uint8List> _held = [];

  /// The heard map geometry (what INTROs decode against, what
  /// section asks are computed against). Null until a LAYOUT lands.
  Layout? get layout => _layout;

  /// The node restarted (seq regressed): its RAM map frame died with
  /// it - the old center is no longer the truth.
  void reset() {
    _layout = null;
    _held.clear();
  }

  /// Feed one FULL plaintext (3-byte type/len envelope + body - what
  /// both the door's `wire` hex and the companion's CHANNEL_DATA
  /// extraction deliver). Decodes, logs the receipt, applies the
  /// INTRO gate, emits through onPacket. A decode failure is
  /// diagnostic - logged, never swallowed.
  void feed(Uint8List wire, {int? heardMs}) {
    final ts = heardMs ?? DateTime.now().millisecondsSinceEpoch;
    try {
      if (peekDataType(wire) == typeIntro) {
        if (_layout == null) {
          // Honest hold: no center yet, and a wrong center is the
          // zero-dots bug wearing a disguise.
          _held.add(wire);
          onLog('INTRO held - no map center heard yet');
          return;
        }
        onPacket(_decodeIntroAt(wire), heardMs: ts);
        return;
      }
      final packet = decodeAny(wire);
      onLog('$pipe <- ${packetName(packet)}');
      if (packet is Layout) {
        _layout = packet;
        // Flush anything held while the center was unknown - the
        // LAYOUT itself is emitted after them, so the burst arrives
        // in wire order (the door link's proven shape, unchanged).
        final held = List<Uint8List>.from(_held);
        _held.clear();
        for (final b in held) {
          onPacket(_decodeIntroAt(b), heardMs: ts);
        }
      }
      onPacket(packet, heardMs: ts);
    } catch (err) {
      onLog('decode failed: $err');
    }
  }

  Intro _decodeIntroAt(Uint8List wire) => decodeIntro(wire.sublist(3),
      centerLat: _layout!.centerLat, centerLon: _layout!.centerLon);
}

/// A packet's plain name for the receipt log (was TcpLink's private
/// helper; shared now that two links write receipts).
String packetName(Object p) => switch (p) {
      Layout() => 'layout (map frame)',
      Intro i => 'intro (${i.entries.length} node(s))',
      Pulse() => 'pulse (feed health)',
      SectSum s => 'section ${s.sectionId} summary',
      Route r => 'route ${r.routeId} (${r.prefixes.length} hop(s))',
      Gone g => 'gone (${g.prefixes.length} node(s))',
      _ => 'packet',
    };
