// Wire codec for the scope feed protocol v1 (Dart port).
//
// Ported from the reference implementation (meshtech-node
// src/meshtech_node/codec.py) via its TypeScript sibling
// (meshtech-phone app/src/lib/codec.ts). Byte-compatible with both
// and proven against the SAME golden vectors (node repo
// tests/golden_vectors.json; test/codec_test.dart here).
//
// All multi-byte integers are little-endian (MeshCore convention).
//
// Protocol history (see the reference for the full story):
// v1.2 (0x03): section ids are 1-based on the wire; 0 is RESERVED
//   (whole-area in a REFRESH_REQ target) and malformed in a
//   SECT_SUM/ROUTE.
// v1.3 (0x04): REFRESH_REQ gains span_km (2 LE), 0 = host decides.
// v1.5 (0x05): INTRO carries its own span_m (2 LE) - the client
//   never guesses scale again.
// v1.6 (0x06, 2026-09-24, VECTORED-SYNC-DESIGN.md): PER-PACKET
//   versioning - only changed shapes declare 0x06: REFRESH_REQ gains
//   sync_marker (2 LE; the phone's vectored-sync marker; 0 = not
//   vectored = the full roster), and TYPE_GONE (0x5312) carries
//   retired prefixes so the phone can REMOVE dots. Unchanged shapes
//   stay 0x05.

import 'dart:convert';
import 'dart:typed_data';

const int protoVersion = 0x05;
const int protoVersionRefresh = 0x06;
const int protoVersionGone = 0x06;
const int protoVersionIntro = 0x06; // INTRO: the ruler span, 3 LE bytes

const int typeGone = 0x5312;
// HEARTBEAT (0x5313, Brett's airtime rule 2026-09-26): the app's tiny
// keep-alive - header only, NOTHING else. Its arrival on hilltop is
// the whole message: a live app is listening. The node keeps its own
// broadcasts flowing for 5 minutes after the last one heard.
const int typeHeartbeat = 0x5313;
// CLINIC (0x5314, Mesh Clinic): the mesh clinic's facts + provenance,
// governed byte-for-byte by meshtech-node's CLINIC-WIRE.md (written
// BEFORE any bytes were wired). One type, a stream of small RECORDS;
// every record carries `source` = the box that MEASURED/REPORTED it.
const int typeClinic = 0x5314;
const int maxGonePerPacket = 8;

// data_type values (the 0x53 magic marks scope traffic).
const int typePulse = 0x5301;
const int typeSectSum = 0x5302;
const int typeRoute = 0x5303;
const int typeIntro = 0x5304;
const int typeLayout = 0x5305;
const int typeSnap = 0x5306;
const int typeRefreshReq = 0x5311;

const int refreshWholeArea = 0;
const int refreshKindSection = 1;
const int refreshKindRoute = 2;
const int refreshHostAny = 0x0000;
const int refreshSpanHostDecides = 0;

const int maxName = 31;

// INTRO flags bits 2-3: node class (0 = unknown, the honest default).
const int nodeClassUnknown = 0x00;
const int nodeClassRepeater = 0x01;
const int nodeClassCompanion = 0x02;
const int nodeClassReserved = 0x03;
const int nodeClassShift = 2;
const int nodeClassMask = 0x03;

class CodecError implements Exception {
  final String message;
  CodecError(this.message);
  @override
  String toString() => 'CodecError: $message';
}

// ---------------------------------------------------------------------------
// Range guards
// ---------------------------------------------------------------------------

void _checkRange(int value, int lo, int hi, String what) {
  if (value < lo || value > hi) {
    throw CodecError('$what out of range: $value');
  }
}

int _u8(int value, String what) {
  _checkRange(value, 0, 0xFF, what);
  return value;
}

int _u16(int value, String what) {
  _checkRange(value, 0, 0xFFFF, what);
  return value;
}

// ---------------------------------------------------------------------------
// Header helpers
// ---------------------------------------------------------------------------

class Header {
  final int version;
  final int seq;
  final int origin;
  const Header(this.version, this.seq, this.origin);
}

/// proto_version(1) + seq(2 LE) + origin(2 LE). [version] is the
/// PER-PACKET protocol version (v1.6): only the shapes whose wire
/// changed declare 0x06 (REFRESH_REQ, GONE); unchanged shapes stay
/// 0x05 so the old web app's strict decoder never notices.
Uint8List packHeader(int seq, int origin, {int version = protoVersion}) {
  _checkRange(seq, 0, 0xFFFF, 'seq');
  _checkRange(origin, 0, 0xFFFF, 'origin');
  final b = Uint8List(5);
  final bd = ByteData.view(b.buffer);
  b[0] = version;
  bd.setUint16(1, seq, Endian.little);
  bd.setUint16(3, origin, Endian.little);
  return b;
}

/// Returns (header, offset past the header). v1 (0x01) packets carry a
/// 3-byte header with no origin (mapped to origin 0). Unknown versions
/// are REJECTED loudly - never misread with wrong field widths.
(Header, int) unpackHeader(Uint8List payload, [int offset = 0]) {
  if (payload.length < offset + 3) {
    throw CodecError('payload too short for header');
  }
  final version = payload[offset];
  if (version == 0x01) {
    final seq = ByteData.sublistView(payload)
        .getUint16(offset + 1, Endian.little);
    return (Header(version, seq, 0), offset + 3);
  }
  if (version != 0x02 && version != 0x03 && version != 0x04 &&
      version != 0x05 && version != 0x06) {
    final hex = version.toRadixString(16).padLeft(2, '0');
    throw CodecError('unsupported protocol version 0x$hex');
  }
  if (payload.length < offset + 5) {
    throw CodecError('payload too short for v1.1 header');
  }
  final bd = ByteData.sublistView(payload);
  final seq = bd.getUint16(offset + 1, Endian.little);
  final origin = bd.getUint16(offset + 3, Endian.little);
  return (Header(version, seq, origin), offset + 5);
}

/// Full GRP_DATA plaintext: data_type(2 LE) + data_len(1) + body.
/// data_len covers header+body (everything after data_type).
Uint8List dataTypeBytes(int dataType, List<int> body) {
  _checkRange(dataType, 0, 0xFFFF, 'data_type');
  if (body.length > 255) {
    throw CodecError('body too long: ${body.length} > 255');
  }
  final out = Uint8List(3 + body.length);
  ByteData.view(out.buffer).setUint16(0, dataType, Endian.little);
  out[2] = body.length;
  out.setRange(3, out.length, body);
  return out;
}

// CONTRACT (matching the reference exactly): every decode* function
// takes the BODY - the 3-byte data_type/len envelope already stripped
// (the reference's decode_body contract; decodeAny does the
// stripping). Every encode* function returns the FULL GRP_DATA
// plaintext including that envelope.

// ---------------------------------------------------------------------------
// PULSE (0x5301)
// ---------------------------------------------------------------------------

class Pulse {
  final int seq;
  final int uptimeMin;
  final int rxPerHour;
  final int feedAirtimeSPerH;
  final int activeTotal;
  final int origin;
  final List<int> sectionCounts;
  const Pulse({
    required this.seq,
    required this.uptimeMin,
    required this.rxPerHour,
    required this.feedAirtimeSPerH,
    required this.activeTotal,
    this.origin = 0,
    this.sectionCounts = const [],
  });
}

Uint8List encodePulse(Pulse p) {
  if (p.sectionCounts.length > 255) throw CodecError('too many sections');
  final body = BytesBuilder();
  body.add(packHeader(p.seq, p.origin));
  final fixed = Uint8List(9);
  final bd = ByteData.view(fixed.buffer);
  bd.setUint16(0, _u16(p.uptimeMin, 'uptime_min'), Endian.little);
  bd.setUint16(2, _u16(p.rxPerHour, 'rx_per_hour'), Endian.little);
  bd.setUint16(
      4, _u16(p.feedAirtimeSPerH, 'feed_airtime_s_per_h'), Endian.little);
  bd.setUint16(6, _u16(p.activeTotal, 'active_total'), Endian.little);
  fixed[8] = p.sectionCounts.length;
  body.add(fixed);
  for (final count in p.sectionCounts) {
    body.add([_u8(count, 'section count')]);
  }
  return dataTypeBytes(typePulse, body.toBytes());
}

Pulse decodePulse(Uint8List payload) {
  final (header, off0) = unpackHeader(payload);
  var off = off0;
  if (payload.length < off + 9) throw CodecError('PULSE too short');
  final bd = ByteData.sublistView(payload);
  final uptime = bd.getUint16(off, Endian.little);
  final rx = bd.getUint16(off + 2, Endian.little);
  final air = bd.getUint16(off + 4, Endian.little);
  final total = bd.getUint16(off + 6, Endian.little);
  final n = payload[off + 8];
  off += 9;
  if (payload.length - off < n) {
    throw CodecError('PULSE section counts truncated');
  }
  final counts = [for (var i = 0; i < n; i++) payload[off + i]];
  return Pulse(
      seq: header.seq, uptimeMin: uptime, rxPerHour: rx,
      feedAirtimeSPerH: air, activeTotal: total, origin: header.origin,
      sectionCounts: counts);
}

// ---------------------------------------------------------------------------
// SECT_SUM (0x5302)
// ---------------------------------------------------------------------------

class SectSum {
  final int seq;
  final int sectionId;
  final int activeNodes;
  final int packetCount;
  final int delayP50S;
  final int delayP90S;
  final int origin;
  final List<int> routeStubs; // route_ids
  const SectSum({
    required this.seq,
    required this.sectionId,
    required this.activeNodes,
    required this.packetCount,
    required this.delayP50S,
    required this.delayP90S,
    this.origin = 0,
    this.routeStubs = const [],
  });
}

/// Wire section ids are 1-BASED (v1.2): 1..255 valid on the byte.
/// 0 is reserved (whole-area marker) - a SECT_SUM/ROUTE carrying 0 is
/// malformed and rejected at the boundary.
int _checkSectionId(int value, String where) {
  _u8(value, where);
  if (value == refreshWholeArea) {
    throw CodecError('$where: 0 is reserved (whole-area)');
  }
  return value;
}

Uint8List encodeSectSum(SectSum s) {
  if (s.routeStubs.length > 255) throw CodecError('too many route stubs');
  final body = BytesBuilder();
  body.add(packHeader(s.seq, s.origin));
  final fixed = Uint8List(10);
  final bd = ByteData.view(fixed.buffer);
  fixed[0] = _checkSectionId(s.sectionId, 'section_id');
  fixed[1] = _u8(s.activeNodes, 'active_nodes');
  bd.setUint16(2, _u16(s.packetCount, 'packet_count'), Endian.little);
  bd.setUint16(4, _u16(s.delayP50S, 'delay_p50_s'), Endian.little);
  bd.setUint16(6, _u16(s.delayP90S, 'delay_p90_s'), Endian.little);
  fixed[8] = 0; // reserved byte keeps the struct readable
  fixed[9] = s.routeStubs.length;
  body.add(fixed);
  for (final rid in s.routeStubs) {
    final two = Uint8List(2);
    ByteData.view(two.buffer)
        .setUint16(0, _u16(rid, 'route_id'), Endian.little);
    body.add(two);
  }
  return dataTypeBytes(typeSectSum, body.toBytes());
}

SectSum decodeSectSum(Uint8List payload) {
  final (header, off0) = unpackHeader(payload);
  var off = off0;
  if (payload.length < off + 10) throw CodecError('SECT_SUM too short');
  final bd = ByteData.sublistView(payload);
  final sectionId = payload[off];
  final active = payload[off + 1];
  final packets = bd.getUint16(off + 2, Endian.little);
  final p50 = bd.getUint16(off + 4, Endian.little);
  final p90 = bd.getUint16(off + 6, Endian.little);
  final n = payload[off + 9];
  off += 10;
  _checkSectionId(sectionId, 'decoded section_id');
  if (payload.length < off + 2 * n) {
    throw CodecError('SECT_SUM stubs truncated');
  }
  final stubs = [
    for (var i = 0; i < n; i++) bd.getUint16(off + 2 * i, Endian.little)
  ];
  return SectSum(
      seq: header.seq, sectionId: sectionId, activeNodes: active,
      packetCount: packets, delayP50S: p50, delayP90S: p90,
      origin: header.origin, routeStubs: stubs);
}

// ---------------------------------------------------------------------------
// ROUTE (0x5303)
// ---------------------------------------------------------------------------

class Route {
  final int seq;
  final int sectionId;
  final int routeId;
  final int packetCount;
  final int delayMedS;
  final int lastHeardMin;
  final int origin;
  final List<int> prefixes; // 1 byte each
  const Route({
    required this.seq,
    required this.sectionId,
    required this.routeId,
    required this.packetCount,
    required this.delayMedS,
    required this.lastHeardMin,
    this.origin = 0,
    this.prefixes = const [],
  });
}

Uint8List encodeRoute(Route r) {
  if (r.prefixes.length > 255) throw CodecError('too many prefixes');
  final body = BytesBuilder();
  body.add(packHeader(r.seq, r.origin));
  final fixed = Uint8List(10);
  final bd = ByteData.view(fixed.buffer);
  fixed[0] = _checkSectionId(r.sectionId, 'section_id');
  bd.setUint16(1, _u16(r.routeId, 'route_id'), Endian.little);
  bd.setUint16(3, _u16(r.packetCount, 'packet_count'), Endian.little);
  bd.setUint16(5, _u16(r.delayMedS, 'delay_med_s'), Endian.little);
  bd.setUint16(7, _u16(r.lastHeardMin, 'last_heard_min'), Endian.little);
  fixed[9] = r.prefixes.length;
  body.add(fixed);
  for (final pfx in r.prefixes) {
    body.add([_u8(pfx, 'prefix')]);
  }
  return dataTypeBytes(typeRoute, body.toBytes());
}

Route decodeRoute(Uint8List payload) {
  final (header, off0) = unpackHeader(payload);
  var off = off0;
  if (payload.length < off + 10) throw CodecError('ROUTE too short');
  final bd = ByteData.sublistView(payload);
  final sectionId = payload[off];
  final routeId = bd.getUint16(off + 1, Endian.little);
  final packets = bd.getUint16(off + 3, Endian.little);
  final delay = bd.getUint16(off + 5, Endian.little);
  final last = bd.getUint16(off + 7, Endian.little);
  final n = payload[off + 9];
  _checkSectionId(sectionId, 'decoded section_id');
  off += 10;
  if (payload.length < off + n) {
    throw CodecError('ROUTE prefixes truncated');
  }
  final prefixes = [for (var i = 0; i < n; i++) payload[off + i]];
  return Route(
      seq: header.seq, sectionId: sectionId, routeId: routeId,
      packetCount: packets, delayMedS: delay, lastHeardMin: last,
      origin: header.origin, prefixes: prefixes);
}

// ---------------------------------------------------------------------------
// INTRO (0x5304)
// ---------------------------------------------------------------------------

class IntroEntry {
  final int prefix;
  final String? name;
  final double? lat;
  final double? lon;
  final int nodeClass;
  const IntroEntry({
    required this.prefix,
    this.name,
    this.lat,
    this.lon,
    this.nodeClass = nodeClassUnknown,
  });

  int get flags {
    var f = 0;
    if (name != null && name!.isNotEmpty) f |= 0x01;
    if (lat != null && lon != null) f |= 0x02;
    f |= (nodeClass & nodeClassMask) << nodeClassShift;
    return f;
  }
}

class Intro {
  final int seq;
  final int origin;
  final List<IntroEntry> entries;
  // Deltas are relative to the LAYOUT centre and the packet's RULER;
  // the codec needs them to encode and returns them on decode.
  final double centerLat;
  final double centerLon;
  final double spanM;
  // v1.5: the span the packet itself carried (null for pre-v1.5).
  // v1.6 (Brett's fix, 2026-09-26): it is THE RULER - the scale
  // measured to REACH every node in the packet (3 LE meters), so no
  // position is ever pinned at a window edge and none is dropped.
  final int? wireSpanM;
  const Intro({
    this.seq = 0,
    this.origin = 0,
    this.entries = const [],
    this.centerLat = 0.0,
    this.centerLon = 0.0,
    this.spanM = 40000.0,
    this.wireSpanM,
  });
}

(int, int) _positionDeltas(
    double centerLat, double centerLon, double spanM,
    double lat, double lon) {
  final spanDeg = spanM / 111320.0;
  final dlat = ((lat - centerLat) / spanDeg * 32767).round();
  final dlon = ((lon - centerLon) / spanDeg * 32767).round();
  // Note: Dart rounds half away from zero; the reference (Python)
  // rounds half to even. The golden vectors never hit an exact .5,
  // and the decode->re-encode roundtrip is FP-stable, so the byte
  // compatibility guarantee holds where it is tested.
  //
  // NEVER PIN (Brett's hard rule 2, 2026-09-26): a delta past the
  // ruler's end used to be clamped there - a FABRICATED position
  // (the pile-of-dots ring the 60 km view exposed). A ruler that
  // cannot reach a node is a bug: refuse loudly, never fake it.
  if (dlat < -32767 || dlat > 32767 || dlon < -32767 || dlon > 32767) {
    throw CodecError('position ($lat, $lon) falls outside the intro '
        'ruler ($spanM m) - widen the ruler; never pin a fake position');
  }
  return (dlat, dlon);
}

(double, double) _positionFromDeltas(
    double centerLat, double centerLon, double spanM, int dlat, int dlon) {
  final spanDeg = spanM / 111320.0;
  return (
    centerLat + dlat / 32767.0 * spanDeg,
    centerLon + dlon / 32767.0 * spanDeg,
  );
}

Uint8List encodeIntro(Intro i) {
  if (i.entries.length > 255) throw CodecError('too many intro entries');
  final spanWire = i.spanM.round();
  if (spanWire <= 0 || spanWire > 0xFFFFFF) {
    throw CodecError('intro span_m out of wire range: ${i.spanM}');
  }
  final body = BytesBuilder();
  body.add(packHeader(i.seq, i.origin, version: protoVersionIntro));
  // v1.6: the ruler, 3 LE bytes (the 2-byte meters field capped at
  // 65.5 km and pinned every farther node at its end).
  body.add([spanWire & 0xFF, (spanWire >> 8) & 0xFF, (spanWire >> 16) & 0xFF]);
  body.add([i.entries.length]);
  for (final entry in i.entries) {
    final nameBytes = utf8.encode(entry.name ?? '');
    final trimmed = nameBytes.length > maxName
        ? nameBytes.sublist(0, maxName)
        : nameBytes;
    final head = Uint8List(3);
    head[0] = _u8(entry.prefix, 'prefix');
    head[1] = entry.flags;
    head[2] = trimmed.length;
    body.add(head);
    if (trimmed.isNotEmpty) body.add(trimmed);
    if (entry.flags & 0x02 != 0) {
      final (dlat, dlon) = _positionDeltas(
          i.centerLat, i.centerLon, i.spanM, entry.lat!, entry.lon!);
      final pos = Uint8List(4);
      final bd = ByteData.view(pos.buffer);
      bd.setInt16(0, dlat, Endian.little);
      bd.setInt16(2, dlon, Endian.little);
      body.add(pos);
    }
  }
  return dataTypeBytes(typeIntro, body.toBytes());
}

/// Decode INTRO. Positions are reconstructed from deltas against the
/// span THE PACKET CARRIES (since v1.5) and the LAYOUT center the
/// client already has (pass it here). [spanM] is a fallback ONLY for
/// pre-v1.5 packets. v1.6: the span is THE RULER - the scale
/// measured to reach every node in the packet, so no position is
/// ever pinned at a window edge and none is dropped (Brett's fix,
/// 2026-09-26). The old span cross-check is gone: the packet's span
/// is the truth.
Intro decodeIntro(Uint8List payload,
    {double centerLat = 0.0, double centerLon = 0.0, double? spanM}) {
  final (header, off0) = unpackHeader(payload);
  var off = off0;
  final bd = ByteData.sublistView(payload);
  int wireSpan;
  if (header.version >= 0x06) {
    // v1.6: the ruler, 3 LE meters.
    if (payload.length < off + 3) {
      throw CodecError('INTRO too short for span field');
    }
    wireSpan = bd.getUint16(off, Endian.little) | (payload[off + 2] << 16);
    off += 3;
    if (wireSpan <= 0) {
      throw CodecError('INTRO span must be positive, got $wireSpan');
    }
  } else if (header.version >= 0x05) {
    // v1.5: 2 LE meters (packets still in flight from an old host).
    if (payload.length < off + 2) {
      throw CodecError('INTRO too short for span field');
    }
    wireSpan = bd.getUint16(off, Endian.little);
    off += 2;
    if (wireSpan <= 0) {
      throw CodecError('INTRO span must be positive, got $wireSpan');
    }
  } else {
    // v1.0-1.4: no span on the wire - fall back to the caller's span
    // or the era's 40 km assumption (kept only for old hosts).
    wireSpan = spanM?.round() ?? 40000;
    if (wireSpan <= 0) {
      throw CodecError('INTRO span must be positive, got $wireSpan');
    }
  }
  final count = payload[off];
  off += 1;
  final entries = <IntroEntry>[];
  for (var i = 0; i < count; i++) {
    if (payload.length < off + 3) throw CodecError('INTRO entry truncated');
    final prefix = payload[off];
    final flags = payload[off + 1];
    final nameLen = payload[off + 2];
    off += 3;
    final nodeClass = (flags >> nodeClassShift) & nodeClassMask;
    String? name;
    if (flags & 0x01 != 0) {
      if (payload.length < off + nameLen) {
        throw CodecError('INTRO name truncated');
      }
      name = utf8.decode(payload.sublist(off, off + nameLen),
          allowMalformed: true);
    }
    off += nameLen;
    double? lat;
    double? lon;
    if (flags & 0x02 != 0) {
      if (payload.length < off + 4) {
        throw CodecError('INTRO position truncated');
      }
      final dlat = bd.getInt16(off, Endian.little);
      final dlon = bd.getInt16(off + 2, Endian.little);
      off += 4;
      (lat, lon) = _positionFromDeltas(
          centerLat, centerLon, wireSpan.toDouble(), dlat, dlon);
    }
    entries.add(IntroEntry(prefix: prefix, name: name, lat: lat,
        lon: lon, nodeClass: nodeClass));
  }
  return Intro(
      seq: header.seq, origin: header.origin, entries: entries,
      centerLat: centerLat, centerLon: centerLon,
      spanM: wireSpan.toDouble(),
      wireSpanM: header.version >= 0x05 ? wireSpan : null);
}

// ---------------------------------------------------------------------------
// LAYOUT (0x5305)
// ---------------------------------------------------------------------------

class Layout {
  final int seq;

  /// Sections ACROSS (columns) - the wire's grid byte.
  final int grid;
  final double centerLat;
  final double centerLon;
  final int spanM;
  final int origin;
  final String name;

  /// Sections DOWN. 0 = the legacy square wire (grid x grid); the
  /// v1.6 rows byte rides at the END of the body (after the name),
  /// so one wire serves old and new packets (Brett, 2026-09-25).
  final int rows;
  const Layout({
    required this.seq,
    required this.grid,
    required this.centerLat,
    required this.centerLon,
    required this.spanM,
    this.origin = 0,
    this.name = '',
    this.rows = 0,
  });
}

Uint8List encodeLayout(Layout l) {
  if (l.grid < 2 || l.grid > 5) throw CodecError('grid out of range: ${l.grid}');
  final rows = l.rows > 0 ? l.rows : l.grid;
  if (rows < 2 || rows > 5) throw CodecError('rows out of range: $rows');
  final nameBytes = utf8.encode(l.name);
  final trimmed = nameBytes.length > maxName
      ? nameBytes.sublist(0, maxName)
      : nameBytes;
  final body = BytesBuilder();
  body.add(packHeader(l.seq, l.origin));
  body.add([l.grid]);
  final geo = Uint8List(8);
  final bd = ByteData.view(geo.buffer);
  bd.setInt32(0, (l.centerLat * 1e6).round(), Endian.little);
  bd.setInt32(4, (l.centerLon * 1e6).round(), Endian.little);
  body.add(geo);
  final spanB = Uint8List(2);
  ByteData.view(spanB.buffer)
      .setUint16(0, _u16(l.spanM, 'span_m'), Endian.little);
  body.add(spanB);
  body.add([trimmed.length]);
  if (trimmed.isNotEmpty) body.add(trimmed);
  body.add([rows]); // v1.6: AFTER the name (old decoders skip it)
  return dataTypeBytes(typeLayout, body.toBytes());
}

Layout decodeLayout(Uint8List payload) {
  final (header, off0) = unpackHeader(payload);
  var off = off0;
  if (payload.length < off + 8) throw CodecError('LAYOUT too short');
  final bd = ByteData.sublistView(payload);
  final grid = payload[off];
  off += 1;
  final latE6 = bd.getInt32(off, Endian.little);
  final lonE6 = bd.getInt32(off + 4, Endian.little);
  off += 8;
  final spanM = bd.getUint16(off, Endian.little);
  off += 2;
  if (payload.length < off + 1) {
    throw CodecError('LAYOUT name length missing');
  }
  final nameLen = payload[off];
  off += 1;
  if (payload.length < off + nameLen) {
    throw CodecError('LAYOUT name truncated');
  }
  final name = utf8.decode(payload.sublist(off, off + nameLen),
      allowMalformed: true);
  off += nameLen;
  // v1.6 trailing rows byte; absent = the legacy square (grid x grid).
  var rows = grid;
  if (payload.length > off) {
    rows = payload[off];
    if (rows < 2 || rows > 5) {
      throw CodecError('LAYOUT rows out of range: $rows');
    }
  }
  return Layout(
      seq: header.seq, grid: grid, centerLat: latE6 / 1e6,
      centerLon: lonE6 / 1e6, spanM: spanM, origin: header.origin,
      name: name, rows: rows);
}

// ---------------------------------------------------------------------------
// SNAP (0x5306)
// ---------------------------------------------------------------------------

class Snap {
  final int seq;
  final int snapId;
  final int part;
  final int parts;
  final Uint8List body;
  final int origin;
  const Snap({
    required this.seq,
    required this.snapId,
    required this.part,
    required this.parts,
    required this.body,
    this.origin = 0,
  });
}

Uint8List encodeSnap(Snap s) {
  if (s.body.length > 255) throw CodecError('SNAP body too long: ${s.body.length}');
  final head = BytesBuilder();
  head.add(packHeader(s.seq, s.origin));
  final fixed = Uint8List(3);
  fixed[0] = _u8(s.snapId, 'snap_id');
  fixed[1] = _u8(s.part, 'part');
  fixed[2] = _u8(s.parts, 'parts');
  head.add(fixed);
  head.add(s.body);
  return dataTypeBytes(typeSnap, head.toBytes());
}

Snap decodeSnap(Uint8List payload) {
  final (header, off0) = unpackHeader(payload);
  var off = off0;
  if (payload.length < off + 3) throw CodecError('SNAP too short');
  final snapId = payload[off];
  final part = payload[off + 1];
  final parts = payload[off + 2];
  off += 3;
  return Snap(
      seq: header.seq, snapId: snapId, part: part, parts: parts,
      origin: header.origin, body: payload.sublist(off));
}

// ---------------------------------------------------------------------------
// REFRESH_REQ (0x5311) - client -> host
// ---------------------------------------------------------------------------

class RefreshReq {
  final int seq;
  final int kind; // 1 = section, 2 = route
  final int target; // section_id or route_id
  final int nonce;
  final int origin; // client's own 2-byte id (v1.1)
  final int host; // preferred origin, 0 = owner decides
  final int spanKm; // v1.3: 20/40/60; 0 = host decides
  final int syncMarker; // v1.6: vectored-sync marker; 0 = not vectored
  const RefreshReq({
    required this.seq,
    required this.kind,
    required this.target,
    required this.nonce,
    this.origin = 0,
    this.host = refreshHostAny,
    this.spanKm = refreshSpanHostDecides,
    this.syncMarker = 0,
  });
}

Uint8List encodeRefreshReq(RefreshReq r) {
  if (r.kind != refreshKindSection && r.kind != refreshKindRoute) {
    throw CodecError('refresh kind invalid: ${r.kind}');
  }
  final body = BytesBuilder();
  // v1.6: REFRESH_REQ declares the bumped per-packet version (it
  // carries sync_marker, which pre-v1.6 decoders cannot read).
  body.add(packHeader(r.seq, r.origin, version: protoVersionRefresh));
  final fixed = Uint8List(7);
  final bd = ByteData.view(fixed.buffer);
  fixed[0] = r.kind;
  bd.setUint16(1, _u16(r.target, 'target'), Endian.little);
  bd.setUint16(3, _u16(r.host, 'host'), Endian.little);
  bd.setUint16(5, _u16(r.nonce, 'nonce'), Endian.little);
  body.add(fixed);
  // v1.3 (0x04): + span_km(2 LE). The header version byte is what
  // tells an old decoder the body is longer than it thinks - and a
  // strict old decoder rejects it loudly rather than misreads.
  final spanB = Uint8List(2);
  ByteData.view(spanB.buffer)
      .setUint16(0, _u16(r.spanKm, 'span_km'), Endian.little);
  body.add(spanB);
  // v1.6 (0x06): + sync_marker(2 LE) - 0 = not vectored.
  final markerB = Uint8List(2);
  ByteData.view(markerB.buffer)
      .setUint16(0, _u16(r.syncMarker, 'sync_marker'), Endian.little);
  body.add(markerB);
  return dataTypeBytes(typeRefreshReq, body.toBytes());
}

RefreshReq decodeRefreshReq(Uint8List payload) {
  final (header, off0) = unpackHeader(payload);
  final off = off0;
  final bd = ByteData.sublistView(payload);
  int kind, target, host, nonce, spanKm, syncMarker;
  if (header.version >= 0x06) {
    // v1.6 body: kind(1) target(2) host(2) nonce(2) span_km(2)
    //             sync_marker(2)
    if (payload.length < off + 11) throw CodecError('REFRESH_REQ too short');
    kind = payload[off];
    target = bd.getUint16(off + 1, Endian.little);
    host = bd.getUint16(off + 3, Endian.little);
    nonce = bd.getUint16(off + 5, Endian.little);
    spanKm = bd.getUint16(off + 7, Endian.little);
    syncMarker = bd.getUint16(off + 9, Endian.little);
  } else if (header.version >= 0x04) {
    // v1.3 body: kind(1) target(2) host(2) nonce(2) span_km(2)
    if (payload.length < off + 9) throw CodecError('REFRESH_REQ too short');
    kind = payload[off];
    target = bd.getUint16(off + 1, Endian.little);
    host = bd.getUint16(off + 3, Endian.little);
    nonce = bd.getUint16(off + 5, Endian.little);
    spanKm = bd.getUint16(off + 7, Endian.little);
    syncMarker = 0;
  } else if (header.version >= 0x02) {
    // v1.1 body: kind(1) target(2) host(2) nonce(2), no span_km
    if (payload.length < off + 7) throw CodecError('REFRESH_REQ too short');
    kind = payload[off];
    target = bd.getUint16(off + 1, Endian.little);
    host = bd.getUint16(off + 3, Endian.little);
    nonce = bd.getUint16(off + 5, Endian.little);
    spanKm = refreshSpanHostDecides;
    syncMarker = 0;
  } else {
    // v1 body: kind(1) target(2) nonce(2), no host field
    if (payload.length < off + 5) throw CodecError('REFRESH_REQ too short');
    kind = payload[off];
    target = bd.getUint16(off + 1, Endian.little);
    nonce = bd.getUint16(off + 3, Endian.little);
    host = refreshHostAny;
    spanKm = refreshSpanHostDecides;
    syncMarker = 0;
  }
  return RefreshReq(
      seq: header.seq, kind: kind, target: target, nonce: nonce,
      origin: header.origin, host: host, spanKm: spanKm,
      syncMarker: syncMarker);
}

// ---------------------------------------------------------------------------
// GONE (0x5312) - vectored sync deletion notice (v1.6)
// ---------------------------------------------------------------------------

class Gone {
  final int seq;
  final int origin;
  final List<int> prefixes; // 1 byte each
  const Gone({
    required this.seq,
    this.origin = 0,
    this.prefixes = const [],
  });
}

Uint8List encodeGone({required int seq, int origin = 0,
    required List<int> prefixes}) {
  if (prefixes.length > maxGonePerPacket) {
    throw CodecError(
        'too many gone prefixes: ${prefixes.length} > $maxGonePerPacket');
  }
  final body = BytesBuilder();
  body.add(packHeader(seq, origin, version: protoVersionGone));
  body.add([prefixes.length]);
  for (final pfx in prefixes) {
    body.add([_u8(pfx, 'gone prefix')]);
  }
  return dataTypeBytes(typeGone, body.toBytes());
}

Gone decodeGone(Uint8List body) {
  final (header, off0) = unpackHeader(body);
  final off = off0;
  if (body.length < off + 1) throw CodecError('GONE too short');
  final n = body[off];
  final off2 = off + 1;
  if (body.length < off2 + n) throw CodecError('GONE prefixes truncated');
  final prefixes = [for (var i = 0; i < n; i++) body[off2 + i]];
  return Gone(seq: header.seq, origin: header.origin, prefixes: prefixes);
}

// ---------------------------------------------------------------------------
// HEARTBEAT (0x5313) - the app's keep-alive (Brett's airtime rule)
// ---------------------------------------------------------------------------

class Heartbeat {
  final int seq;
  final int origin;
  const Heartbeat({required this.seq, this.origin = 0});
}

Uint8List encodeHeartbeat(Heartbeat h) {
  // Header ONLY (5 bytes) inside the 3-byte envelope: 8 bytes of
  // plaintext, the smallest packet the format can carry - nothing to
  // decode wrong on either side.
  return dataTypeBytes(typeHeartbeat, packHeader(h.seq, h.origin));
}

Heartbeat decodeHeartbeat(Uint8List body) {
  final (header, _) = unpackHeader(body);
  return Heartbeat(seq: header.seq, origin: header.origin);
}

// ---------------------------------------------------------------------------
// CLINIC (0x5314) - the mesh clinic's facts + provenance
// (meshtech-node CLINIC-WIRE.md governs these bytes.)
//
// body = header(5) + count(1) + records; each record is
// kind(1) + len(1) + payload(len). The WHOLE plaintext stays within
// maxChannelData (163 B) so at most clinicMaxRecords ride at once.
// Byte-parity: tests/golden_vectors.json "clinic" (both repos).
// ---------------------------------------------------------------------------

const int maxChannelData = 163; // the channel data cap (wire page)
const int clinicMaxRecords = 7;
const int clinicMaxName = 24; // peer intro names this wire can carry

const int clinicKindNode = 1;
const int clinicKindRoute = 2;
const int clinicKindFlag = 3;
const int clinicKindPeer = 4;
const int clinicKindAirtime = 5;
const int clinicKindSender = 6;
const int clinicKindExchange = 7;
const int clinicKindCollision = 8;

// Trouble flags (kind 3) - FACTS with evidence, never verdicts.
const int flagSigFail = 1;
const int flagTsBackwards = 2;
const int flagRateStorm = 3;
const int flagCorruptShare = 4;

// Peer reports (kind 4) - what another box SAID (second-hand).
const int reportPulse = 1;
const int reportSectSum = 2;
const int reportRoute = 3;
const int reportIntro = 4;

// Wire sentinels: missing stays missing, never a plausible constant.
const int ageUnknownMin = 0xFFFF; // minute fields: older than the wire says
const int shareUnknownPct = 255; // node fact: no identified traffic counted
const int signalUnknown = -128; // i8 signal stats: no samples
const int signalSdUnknown = 255; // u8 signal spread: fewer than 2 samples
const int numUnknown = 0xFFFF; // health counts (kinds 5-8): never counted

class ClinicNodeFact {
  // Kind 1: one node's chart as THIS box heard it (20 B payload).
  final int source;
  final int prefix;
  final int lastAgeMin;
  final int ageDays;
  final int strip; // 24-bit: bit 0 oldest hour ... bit 23 now
  final int hopsTyp; // typical radio hops (0 = unknown)
  final int sharePct; // of identified traffic, 24 h (255 = none)
  final int snrEwma;
  final int snrBest;
  final int snrWorst;
  final int snrSd;
  final int rssiEwma;
  final int rssiBest;
  final int rssiWorst;
  final int rssiSd;
  const ClinicNodeFact({
    required this.source,
    required this.prefix,
    required this.lastAgeMin,
    required this.ageDays,
    required this.strip,
    required this.hopsTyp,
    required this.sharePct,
    this.snrEwma = signalUnknown,
    this.snrBest = signalUnknown,
    this.snrWorst = signalUnknown,
    this.snrSd = signalSdUnknown,
    this.rssiEwma = signalUnknown,
    this.rssiBest = signalUnknown,
    this.rssiWorst = signalUnknown,
    this.rssiSd = signalSdUnknown,
  });
}

class ClinicRouteFact {
  // Kind 2: one route's chart (delay 0 = unknown, honest stamps only).
  final int source;
  final List<int> path; // repeater trail, travel order (1..8)
  final int uses;
  final int direct; // 1 = heard straight from the sender
  final int delayMinS;
  final int delayMedS;
  final int delayMaxS;
  final int lastAgeMin;
  final int ageDays;
  const ClinicRouteFact({
    required this.source,
    required this.path,
    required this.uses,
    required this.direct,
    required this.delayMinS,
    required this.delayMedS,
    required this.delayMaxS,
    required this.lastAgeMin,
    required this.ageDays,
  });
}

class ClinicFlagFact {
  // Kind 3: one trouble flag - what was measured, not a verdict.
  final int source;
  final int flag; // FLAG_*
  final int subject; // key prefix; 0 = mesh-wide (corrupt share)
  final int events;
  final int firstAgeMin;
  final int lastAgeMin;
  final int detail; // worst jump s / peak packets-per-min / per-mille
  const ClinicFlagFact({
    required this.source,
    required this.flag,
    required this.subject,
    required this.events,
    required this.firstAgeMin,
    required this.lastAgeMin,
    required this.detail,
  });
}

class ClinicPeerFact {
  // Kind 4: what a peer box said (source = the peer, never us).
  final int source;
  final int report; // REPORT_*
  final int subject; // 0 / section id / route id / node prefix
  final int heardAgeMin;
  final List<int> values; // 4 u16; pulse/sect_sum use all 4, route 3
  final List<int> path; // report route only (1..8)
  final int cls; // report intro only
  final double? lat; // report intro only; null = peer reported no position
  final double? lon;
  final String name;
  const ClinicPeerFact({
    required this.source,
    required this.report,
    required this.subject,
    required this.heardAgeMin,
    this.values = const [0, 0, 0, 0],
    this.path = const [],
    this.cls = 0,
    this.lat,
    this.lon,
    this.name = '',
  });
}

class ClinicAirtimeFact {
  // Kind 5: the mesh's air, as THIS box counts it (12 B payload).
  // Per-mille fields carry numUnknown = never counted; windowMin is
  // the counting window's REAL length (60 = a full hour).
  final int source;
  final int windowMin;
  final int dupPerMille;
  final int occupancyPerMille;
  final int dutyHeadroomS;
  final int txUsedS;
  const ClinicAirtimeFact({
    required this.source,
    required this.windowMin,
    required this.dupPerMille,
    required this.occupancyPerMille,
    required this.dutyHeadroomS,
    required this.txUsedS,
  });
}

class ClinicSenderFact {
  // Kind 6: one sender's behavior (14 B payload) - the tag the
  // traffic self-identifies with (the scope header's 2-byte origin).
  // NOT the map's node key: sender facts are never pinned to a node.
  final int source;
  final int sender;
  final int windowMin;
  final int dupPerMille;
  final int lost;
  final int reordered;
  final int flaps;
  const ClinicSenderFact({
    required this.source,
    required this.sender,
    required this.windowMin,
    required this.dupPerMille,
    required this.lost,
    required this.reordered,
    required this.flaps,
  });
}

class ClinicExchangeFact {
  // Kind 7: overheard asks answered (10 B payload). The window is
  // honest; medianAnswerS 0 = unknown.
  final int source;
  final int windowMin;
  final int asked;
  final int answered;
  final int medianAnswerS;
  const ClinicExchangeFact({
    required this.source,
    required this.windowMin,
    required this.asked,
    required this.answered,
    required this.medianAnswerS,
  });
}

class ClinicCollisionFact {
  // Kind 8: one PROVEN hash collision (22..24 B payload) - the same
  // short tag carried TWO different advert keys on air.
  final int source;
  final List<int> tag; // 1..3 bytes, as heard
  final List<int> keyA; // 8-byte pubkey prefix
  final List<int> keyB;
  final int lastAgeMin;
  const ClinicCollisionFact({
    required this.source,
    required this.tag,
    required this.keyA,
    required this.keyB,
    required this.lastAgeMin,
  });
}

class Clinic {
  final int seq;
  final int origin; // the box SENDING this packet
  final List<Object> records;
  const Clinic({required this.seq, this.origin = 0, this.records = const []});
}

/// Minutes since, on the wire: capped at ageUnknownMin (never a
/// wrapped-around small number pretending to be fresh).
int ageMinutes(double seconds) {
  final minutes = seconds ~/ 60;
  if (minutes < 0) return 0;
  return minutes > ageUnknownMin ? ageUnknownMin : minutes;
}

int _i8(int value, String what) {
  if (value < -128 || value > 127) {
    throw CodecError('$what out of range: $value');
  }
  return value;
}

int _clinicKind(Object record) => switch (record) {
      ClinicNodeFact() => clinicKindNode,
      ClinicRouteFact() => clinicKindRoute,
      ClinicFlagFact() => clinicKindFlag,
      ClinicPeerFact() => clinicKindPeer,
      ClinicAirtimeFact() => clinicKindAirtime,
      ClinicSenderFact() => clinicKindSender,
      ClinicExchangeFact() => clinicKindExchange,
      ClinicCollisionFact() => clinicKindCollision,
      _ => throw CodecError('unknown clinic record ${record.runtimeType}'),
    };

/// One record: kind(1) + len(1) + payload. Raises loudly when the
/// wire cannot carry the truth (never pins, never fabricates).
Uint8List encodeClinicRecord(Object record) {
  final body = BytesBuilder();
  switch (record) {
    case ClinicNodeFact(:final strip):
      if (strip < 0 || strip > 0xFFFFFF) {
        throw CodecError('node strip out of range: $strip');
      }
      final f = Uint8List(20);
      final bd = ByteData.view(f.buffer);
      bd.setUint16(0, _u16(record.source, 'node source'), Endian.little);
      f[2] = _u8(record.prefix, 'node prefix');
      bd.setUint32(3, (_u16(record.lastAgeMin, 'node last_age_min') |
              (_u16(record.ageDays, 'node age_days') << 16)),
          Endian.little);
      f[7] = strip & 0xff;
      f[8] = (strip >> 8) & 0xff;
      f[9] = (strip >> 16) & 0xff;
      f[10] = _u8(record.hopsTyp, 'node hops_typ');
      f[11] = _u8(record.sharePct, 'node share_pct');
      f[12] = _i8(record.snrEwma, 'snr_ewma') & 0xff;
      f[13] = _i8(record.snrBest, 'snr_best') & 0xff;
      f[14] = _i8(record.snrWorst, 'snr_worst') & 0xff;
      f[15] = _u8(record.snrSd, 'snr_sd');
      f[16] = _i8(record.rssiEwma, 'rssi_ewma') & 0xff;
      f[17] = _i8(record.rssiBest, 'rssi_best') & 0xff;
      f[18] = _i8(record.rssiWorst, 'rssi_worst') & 0xff;
      f[19] = _u8(record.rssiSd, 'rssi_sd');
      body.add(f);
    case ClinicRouteFact(:final path):
      if (path.isEmpty || path.length > 8) {
        throw CodecError('route fact path length ${path.length} outside 1..8');
      }
      body.add([_u16(record.source, 'route source') & 0xff,
          (_u16(record.source, 'route source') >> 8) & 0xff, path.length]);
      body.add([for (final p in path) _u8(p, 'route path byte')]);
      final f = Uint8List(13);
      final bd = ByteData.view(f.buffer);
      bd.setUint16(0, _u16(record.uses, 'route uses'), Endian.little);
      f[2] = _u8(record.direct, 'route direct');
      bd.setUint16(3, _u16(record.delayMinS, 'route delay_min_s'), Endian.little);
      bd.setUint16(5, _u16(record.delayMedS, 'route delay_med_s'), Endian.little);
      bd.setUint16(7, _u16(record.delayMaxS, 'route delay_max_s'), Endian.little);
      bd.setUint16(9, _u16(record.lastAgeMin, 'route last_age_min'),
          Endian.little);
      bd.setUint16(11, _u16(record.ageDays, 'route age_days'), Endian.little);
      body.add(f);
    case ClinicFlagFact():
      final f = Uint8List(12);
      final bd = ByteData.view(f.buffer);
      bd.setUint16(0, _u16(record.source, 'flag source'), Endian.little);
      f[2] = _u8(record.flag, 'flag kind');
      f[3] = _u8(record.subject, 'flag subject');
      bd.setUint16(4, _u16(record.events, 'flag events'), Endian.little);
      bd.setUint16(6, _u16(record.firstAgeMin, 'flag first_age_min'),
          Endian.little);
      bd.setUint16(8, _u16(record.lastAgeMin, 'flag last_age_min'),
          Endian.little);
      bd.setUint16(10, _u16(record.detail, 'flag detail'), Endian.little);
      body.add(f);
    case ClinicPeerFact():
      final head = Uint8List(7);
      final bd = ByteData.view(head.buffer);
      bd.setUint16(0, _u16(record.source, 'peer source'), Endian.little);
      head[2] = _u8(record.report, 'peer report');
      bd.setUint16(3, _u16(record.subject, 'peer subject'), Endian.little);
      bd.setUint16(5, _u16(record.heardAgeMin, 'peer heard_age_min'),
          Endian.little);
      body.add(head);
      final values = record.values;
      if (values.length != 4) {
        throw CodecError('peer values must be 4 numbers');
      }
      if (record.report == reportPulse || record.report == reportSectSum) {
        final f = Uint8List(8);
        final vb = ByteData.view(f.buffer);
        for (var i = 0; i < 4; i++) {
          vb.setUint16(i * 2, _u16(values[i], 'peer v${i + 1}'), Endian.little);
        }
        body.add(f);
      } else if (record.report == reportRoute) {
        final path = record.path;
        if (path.isEmpty || path.length > 8) {
          throw CodecError(
              'peer route path length ${path.length} outside 1..8');
        }
        final f = Uint8List(7);
        final vb = ByteData.view(f.buffer);
        vb.setUint16(0, _u16(values[0], 'peer uses'), Endian.little);
        vb.setUint16(2, _u16(values[1], 'peer delay_med'), Endian.little);
        vb.setUint16(4, _u16(values[2], 'peer last_age'), Endian.little);
        f[6] = path.length;
        body.add(f);
        body.add([for (final p in path) _u8(p, 'peer path byte')]);
      } else if (record.report == reportIntro) {
        final nameBytes = utf8.encode(record.name);
        if (nameBytes.length > clinicMaxName) {
          // Refuse to mint - never truncate a name (wire page).
          throw CodecError('peer intro name longer than $clinicMaxName B '
              '- refuse to mint, never truncate a name');
        }
        final latE7 = record.lat == null
            ? 0
            : (record.lat! * 1e7).round();
        final lonE7 = record.lon == null
            ? 0
            : (record.lon! * 1e7).round();
        // 0/0 = NO POSITION (the node table's null-island rule).
        if (latE7 < -2147483648 ||
            latE7 > 2147483647 ||
            lonE7 < -2147483648 ||
            lonE7 > 2147483647) {
          throw CodecError('peer intro position out of e7 range');
        }
        final f = Uint8List(10);
        final vb = ByteData.view(f.buffer);
        f[0] = _u8(record.cls, 'peer class');
        vb.setInt32(1, latE7, Endian.little);
        vb.setInt32(5, lonE7, Endian.little);
        f[9] = nameBytes.length;
        body.add(f);
        body.add(nameBytes);
      } else {
        throw CodecError('unknown peer report kind ${record.report}');
      }
    case ClinicAirtimeFact():
      final f = Uint8List(12);
      final bd = ByteData.view(f.buffer);
      bd.setUint16(0, _u16(record.source, 'airtime source'), Endian.little);
      bd.setUint16(2, _u16(record.windowMin, 'airtime window_min'),
          Endian.little);
      bd.setUint16(4, _u16(record.dupPerMille, 'airtime dup_per_mille'),
          Endian.little);
      bd.setUint16(6,
          _u16(record.occupancyPerMille, 'airtime occupancy_per_mille'),
          Endian.little);
      bd.setUint16(8, _u16(record.dutyHeadroomS, 'airtime duty_headroom_s'),
          Endian.little);
      bd.setUint16(10, _u16(record.txUsedS, 'airtime tx_used_s'),
          Endian.little);
      body.add(f);
    case ClinicSenderFact():
      final f = Uint8List(14);
      final bd = ByteData.view(f.buffer);
      bd.setUint16(0, _u16(record.source, 'sender source'), Endian.little);
      bd.setUint16(2, _u16(record.sender, 'sender tag'), Endian.little);
      bd.setUint16(4, _u16(record.windowMin, 'sender window_min'),
          Endian.little);
      bd.setUint16(6, _u16(record.dupPerMille, 'sender dup_per_mille'),
          Endian.little);
      bd.setUint16(8, _u16(record.lost, 'sender lost'), Endian.little);
      bd.setUint16(10, _u16(record.reordered, 'sender reordered'),
          Endian.little);
      bd.setUint16(12, _u16(record.flaps, 'sender flaps'), Endian.little);
      body.add(f);
    case ClinicExchangeFact():
      final f = Uint8List(10);
      final bd = ByteData.view(f.buffer);
      bd.setUint16(0, _u16(record.source, 'exchange source'), Endian.little);
      bd.setUint16(2, _u16(record.windowMin, 'exchange window_min'),
          Endian.little);
      bd.setUint16(4, _u16(record.asked, 'exchange asked'), Endian.little);
      bd.setUint16(6, _u16(record.answered, 'exchange answered'),
          Endian.little);
      bd.setUint16(8, _u16(record.medianAnswerS, 'exchange median_answer_s'),
          Endian.little);
      body.add(f);
    case ClinicCollisionFact(:final tag, :final keyA, :final keyB):
      if (tag.isEmpty || tag.length > 3) {
        throw CodecError('collision tag length ${tag.length} outside 1..3');
      }
      // Refuse loudly - never pad a key (the wire page's law).
      if (keyA.length != 8 || keyB.length != 8) {
        throw CodecError('collision keys must be 8 bytes - refuse to mint');
      }
      final head = Uint8List(3);
      final bd = ByteData.view(head.buffer);
      bd.setUint16(0, _u16(record.source, 'collision source'), Endian.little);
      head[2] = tag.length;
      body.add(head);
      body.add([for (final t in tag) _u8(t, 'collision tag byte')]);
      body.add(keyA);
      body.add(keyB);
      final tail = Uint8List(2);
      ByteData.view(tail.buffer)
          .setUint16(0, _u16(record.lastAgeMin, 'collision last_age_min'),
              Endian.little);
      body.add(tail);
    default:
      throw CodecError('unknown clinic record ${record.runtimeType}');
  }
  final payload = body.toBytes();
  if (payload.length > 255) {
    throw CodecError('clinic record too long: ${payload.length} B');
  }
  return Uint8List.fromList(
      [_clinicKind(record), payload.length, ...payload]);
}

/// Full CLINIC plaintext (with envelope). Hard caps from the wire
/// page: at most 7 records, whole plaintext <= maxChannelData.
Uint8List encodeClinic(List<Object> records,
    {required int seq, int origin = 0}) {
  if (records.length > clinicMaxRecords) {
    throw CodecError('too many clinic records: ${records.length} > '
        '$clinicMaxRecords');
  }
  final body = BytesBuilder();
  body.add(packHeader(seq, origin));
  body.add([records.length]);
  for (final record in records) {
    body.add(encodeClinicRecord(record));
  }
  final plaintext = dataTypeBytes(typeClinic, body.toBytes());
  if (plaintext.length > maxChannelData) {
    throw CodecError('clinic packet ${plaintext.length} B exceeds '
        'the $maxChannelData B channel cap');
  }
  return plaintext;
}

/// Decode one record at [off]; returns (record, offset past it).
(Object, int) _decodeClinicRecord(Uint8List payload, int off) {
  if (payload.length < off + 2) {
    throw CodecError('CLINIC record truncated (kind/len)');
  }
  final kind = payload[off];
  final length = payload[off + 1];
  off += 2;
  if (payload.length < off + length) {
    throw CodecError('CLINIC record truncated (payload)');
  }
  final body = Uint8List.sublistView(payload, off, off + length);
  off += length;
  final bd = ByteData.sublistView(body);
  switch (kind) {
    case clinicKindNode:
      if (body.length != 20) {
        throw CodecError(
            'CLINIC node fact must be 20 B, got ${body.length}');
      }
      final record = ClinicNodeFact(
        source: bd.getUint16(0, Endian.little),
        prefix: body[2],
        lastAgeMin: bd.getUint16(3, Endian.little),
        ageDays: bd.getUint16(5, Endian.little),
        strip: body[7] | (body[8] << 8) | (body[9] << 16),
        hopsTyp: body[10],
        sharePct: body[11],
        snrEwma: bd.getInt8(12),
        snrBest: bd.getInt8(13),
        snrWorst: bd.getInt8(14),
        snrSd: body[15],
        rssiEwma: bd.getInt8(16),
        rssiBest: bd.getInt8(17),
        rssiWorst: bd.getInt8(18),
        rssiSd: body[19],
      );
      return (record, off);
    case clinicKindRoute:
      if (body.length < 3) throw CodecError('CLINIC route fact too short');
      final pathLen = body[2];
      if (pathLen < 1 || pathLen > 8 || body.length != 3 + pathLen + 13) {
        throw CodecError('CLINIC route fact malformed');
      }
      final record = ClinicRouteFact(
        source: bd.getUint16(0, Endian.little),
        path: List<int>.from(body.sublist(3, 3 + pathLen)),
        uses: bd.getUint16(3 + pathLen, Endian.little),
        direct: body[3 + pathLen + 2],
        delayMinS: bd.getUint16(3 + pathLen + 3, Endian.little),
        delayMedS: bd.getUint16(3 + pathLen + 5, Endian.little),
        delayMaxS: bd.getUint16(3 + pathLen + 7, Endian.little),
        lastAgeMin: bd.getUint16(3 + pathLen + 9, Endian.little),
        ageDays: bd.getUint16(3 + pathLen + 11, Endian.little),
      );
      return (record, off);
    case clinicKindFlag:
      if (body.length != 12) {
        throw CodecError('CLINIC flag must be 12 B, got ${body.length}');
      }
      final record = ClinicFlagFact(
        source: bd.getUint16(0, Endian.little),
        flag: body[2],
        subject: body[3],
        events: bd.getUint16(4, Endian.little),
        firstAgeMin: bd.getUint16(6, Endian.little),
        lastAgeMin: bd.getUint16(8, Endian.little),
        detail: bd.getUint16(10, Endian.little),
      );
      return (record, off);
    case clinicKindPeer:
      if (body.length < 7) throw CodecError('CLINIC peer report too short');
      final source = bd.getUint16(0, Endian.little);
      final report = body[2];
      final subject = bd.getUint16(3, Endian.little);
      final heardAge = bd.getUint16(5, Endian.little);
      final rest = Uint8List.sublistView(body, 7);
      final rb = ByteData.sublistView(rest);
      var values = const [0, 0, 0, 0];
      var path = const <int>[];
      var cls = 0;
      double? lat, lon;
      var name = '';
      if (report == reportPulse || report == reportSectSum) {
        if (rest.length != 8) {
          throw CodecError('CLINIC peer numbers must be 8 B');
        }
        values = [
          rb.getUint16(0, Endian.little),
          rb.getUint16(2, Endian.little),
          rb.getUint16(4, Endian.little),
          rb.getUint16(6, Endian.little),
        ];
      } else if (report == reportRoute) {
        if (rest.length < 7) {
          throw CodecError('CLINIC peer route too short');
        }
        final pathLen = rest[6];
        if (pathLen < 1 || pathLen > 8 || rest.length != 7 + pathLen) {
          throw CodecError('CLINIC peer route malformed');
        }
        values = [
          rb.getUint16(0, Endian.little),
          rb.getUint16(2, Endian.little),
          rb.getUint16(4, Endian.little),
          0,
        ];
        path = List<int>.from(rest.sublist(7, 7 + pathLen));
      } else if (report == reportIntro) {
        if (rest.length < 10) {
          throw CodecError('CLINIC peer intro too short');
        }
        final nameLen = rest[9];
        if (rest.length != 10 + nameLen) {
          throw CodecError('CLINIC peer intro name malformed');
        }
        cls = rest[0];
        final latE7 = rb.getInt32(1, Endian.little);
        final lonE7 = rb.getInt32(5, Endian.little);
        if (nameLen > 0) {
          try {
            name = utf8.decode(rest.sublist(10, 10 + nameLen));
          } catch (_) {
            throw CodecError('CLINIC peer name not UTF-8');
          }
        }
        // 0/0 = the peer reported NO position (null-island rule).
        if (latE7 == 0 && lonE7 == 0) {
          lat = null;
          lon = null;
        } else {
          lat = latE7 / 1e7;
          lon = lonE7 / 1e7;
        }
      } else {
        throw CodecError('unknown peer report kind $report');
      }
      final record = ClinicPeerFact(
        source: source,
        report: report,
        subject: subject,
        heardAgeMin: heardAge,
        values: values,
        path: path,
        cls: cls,
        lat: lat,
        lon: lon,
        name: name,
      );
      return (record, off);
    case clinicKindAirtime:
      if (body.length != 12) {
        throw CodecError(
            'CLINIC airtime fact must be 12 B, got ${body.length}');
      }
      final record = ClinicAirtimeFact(
        source: bd.getUint16(0, Endian.little),
        windowMin: bd.getUint16(2, Endian.little),
        dupPerMille: bd.getUint16(4, Endian.little),
        occupancyPerMille: bd.getUint16(6, Endian.little),
        dutyHeadroomS: bd.getUint16(8, Endian.little),
        txUsedS: bd.getUint16(10, Endian.little),
      );
      return (record, off);
    case clinicKindSender:
      if (body.length != 14) {
        throw CodecError('CLINIC sender fact must be 14 B, got ${body.length}');
      }
      final record = ClinicSenderFact(
        source: bd.getUint16(0, Endian.little),
        sender: bd.getUint16(2, Endian.little),
        windowMin: bd.getUint16(4, Endian.little),
        dupPerMille: bd.getUint16(6, Endian.little),
        lost: bd.getUint16(8, Endian.little),
        reordered: bd.getUint16(10, Endian.little),
        flaps: bd.getUint16(12, Endian.little),
      );
      return (record, off);
    case clinicKindExchange:
      if (body.length != 10) {
        throw CodecError(
            'CLINIC exchange fact must be 10 B, got ${body.length}');
      }
      final record = ClinicExchangeFact(
        source: bd.getUint16(0, Endian.little),
        windowMin: bd.getUint16(2, Endian.little),
        asked: bd.getUint16(4, Endian.little),
        answered: bd.getUint16(6, Endian.little),
        medianAnswerS: bd.getUint16(8, Endian.little),
      );
      return (record, off);
    case clinicKindCollision:
      if (body.length < 3) {
        throw CodecError('CLINIC collision fact too short');
      }
      final tagLen = body[2];
      if (tagLen < 1 || tagLen > 3 || body.length != 3 + tagLen + 18) {
        throw CodecError('CLINIC collision fact malformed');
      }
      final record = ClinicCollisionFact(
        source: bd.getUint16(0, Endian.little),
        tag: List<int>.from(body.sublist(3, 3 + tagLen)),
        keyA: List<int>.from(body.sublist(3 + tagLen, 3 + tagLen + 8)),
        keyB: List<int>.from(body.sublist(3 + tagLen + 8, 3 + tagLen + 16)),
        lastAgeMin: bd.getUint16(3 + tagLen + 16, Endian.little),
      );
      return (record, off);
    default:
      throw CodecError('unknown CLINIC record kind $kind');
  }
}

/// Decode ONE record's own bytes (kind+len+payload) - the exact
/// inverse of encodeClinicRecord (the persistence round-trip).
Object decodeClinicRecord(Uint8List recordBytes) {
  final (record, off) = _decodeClinicRecord(recordBytes, 0);
  if (off != recordBytes.length) {
    throw CodecError('clinic record has trailing bytes');
  }
  return record;
}

/// Decode a CLINIC body (envelope already stripped).
Clinic decodeClinic(Uint8List payload) {
  final (header, off0) = unpackHeader(payload);
  var off = off0;
  if (payload.length < off + 1) throw CodecError('CLINIC too short (count)');
  final count = payload[off];
  off += 1;
  final records = <Object>[];
  for (var i = 0; i < count; i++) {
    final (record, next) = _decodeClinicRecord(payload, off);
    records.add(record);
    off = next;
  }
  return Clinic(seq: header.seq, origin: header.origin, records: records);
}

// ---------------------------------------------------------------------------
// Generic decode + helpers
// ---------------------------------------------------------------------------

/// The data_type of a full GRP_DATA plaintext (before decoding).
int peekDataType(Uint8List payload) {
  if (payload.length < 3) {
    throw CodecError('payload too short for data_type');
  }
  return ByteData.sublistView(payload).getUint16(0, Endian.little);
}

/// Decode any scope packet by its data_type. A v1.5+ INTRO decodes by
/// its OWN carried span (no caller knowledge needed).
Object decodeAny(Uint8List payload) {
  final dataType = peekDataType(payload);
  return decodeBody(dataType, payload.sublist(3));
}

/// Decode a scope BODY whose 3-byte type/len envelope is already
/// stripped (what a companion delivers in CHANNEL_DATA_RECV).
Object decodeBody(int dataType, Uint8List body) {
  switch (dataType) {
    case typePulse:
      return decodePulse(body);
    case typeSectSum:
      return decodeSectSum(body);
    case typeRoute:
      return decodeRoute(body);
    case typeIntro:
      return decodeIntro(body);
    case typeLayout:
      return decodeLayout(body);
    case typeSnap:
      return decodeSnap(body);
    case typeRefreshReq:
      return decodeRefreshReq(body);
    case typeGone:
      return decodeGone(body);
    case typeHeartbeat:
      return decodeHeartbeat(body);
    case typeClinic:
      return decodeClinic(body);
    default:
      final hex = dataType.toRadixString(16).padLeft(6, '0');
      throw CodecError('unknown data_type 0x$hex');
  }
}
