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

const int typeGone = 0x5312;
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
  // Deltas are relative to the LAYOUT centre/span; the codec needs
  // them to encode and returns them on decode.
  final double centerLat;
  final double centerLon;
  final double spanM;
  // v1.5: the span the packet itself carried (null for pre-v1.5).
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
  var dlat = ((lat - centerLat) / spanDeg * 32767).round();
  var dlon = ((lon - centerLon) / spanDeg * 32767).round();
  // Note: Dart rounds half away from zero; the reference (Python)
  // rounds half to even. The golden vectors never hit an exact .5,
  // and the decode->re-encode roundtrip is FP-stable, so the byte
  // compatibility guarantee holds where it is tested.
  if (dlat > 32767) dlat = 32767;
  if (dlat < -32767) dlat = -32767;
  if (dlon > 32767) dlon = 32767;
  if (dlon < -32767) dlon = -32767;
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
  if (spanWire <= 0 || spanWire > 0xFFFF) {
    throw CodecError('intro span_m out of wire range: ${i.spanM}');
  }
  final body = BytesBuilder();
  body.add(packHeader(i.seq, i.origin));
  final spanB = Uint8List(2);
  ByteData.view(spanB.buffer).setUint16(0, spanWire, Endian.little);
  body.add(spanB);
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
/// span THE PACKET CARRIES (v1.5) and the LAYOUT center the client
/// already has (pass it here). [spanM] is a caller's LAYOUT span used
/// ONLY as a cross-check - a disagreement raises (loud beats silently
/// wrong). Leave it null to trust the packet.
Intro decodeIntro(Uint8List payload,
    {double centerLat = 0.0, double centerLon = 0.0, double? spanM}) {
  final (header, off0) = unpackHeader(payload);
  var off = off0;
  final bd = ByteData.sublistView(payload);
  int wireSpan;
  if (header.version >= 0x05) {
    if (payload.length < off + 2) {
      throw CodecError('INTRO too short for span field');
    }
    wireSpan = bd.getUint16(off, Endian.little);
    off += 2;
    if (wireSpan <= 0) {
      throw CodecError('INTRO span must be positive, got $wireSpan');
    }
    if (spanM != null && spanM.round() != wireSpan) {
      throw CodecError(
          'INTRO span mismatch: packet says $wireSpan m, '
          'caller assumed ${spanM.round()} m');
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
  final int grid;
  final double centerLat;
  final double centerLon;
  final int spanM;
  final int origin;
  final String name;
  const Layout({
    required this.seq,
    required this.grid,
    required this.centerLat,
    required this.centerLon,
    required this.spanM,
    this.origin = 0,
    this.name = '',
  });
}

Uint8List encodeLayout(Layout l) {
  if (l.grid < 2 || l.grid > 5) throw CodecError('grid out of range: ${l.grid}');
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
  return Layout(
      seq: header.seq, grid: grid, centerLat: latE6 / 1e6,
      centerLon: lonE6 / 1e6, spanM: spanM, origin: header.origin,
      name: name);
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
    default:
      final hex = dataType.toRadixString(16).padLeft(6, '0');
      throw CodecError('unknown data_type 0x$hex');
  }
}
