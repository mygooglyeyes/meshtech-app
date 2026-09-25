// The link layer (DESIGN.md section 2): the companion radio is the
// app's radio - ears AND voice, established at the start. TCP is the
// helper: a one-time download for off-wire use, and (until Brett's TX
// go) the way step-2 data is TESTABLE today.
//
// Shape: one Link interface, two implementations.
//   TcpLink      - speaks the web app's EXACT door protocol (verified
//                  line-for-line against meshtech-phone
//                  directclient.ts: ws://host:port/feed, the password
//                  as a "bearer.<token>" subprotocol, JSON frames
//                  carrying `wire` hex of the SAME codec packets,
//                  resume-after-hello, plain-words refusal acks,
//                  NO auto-reconnect, silent-drop watchdog).
//   CompanionLink- the BLE slot for Brett's Heltec (MeshCore
//                  companion protocol). INERT until the hardware go:
//                  it reports "no radio" rather than pretending.
//
// Both feed the SAME decoded packets to the same callbacks - the link
// is a transport, never a second decoder. The socket is injected
// (DoorSocket): the native build passes IoDoorSocket.new, tests
// pass a fake - the web app's stub-the-WebSocket lesson.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'codec.dart';
import 'door_socket.dart';

enum LinkState { disabled, connecting, connected }

class LinkEvents {
  final void Function(LinkState state, String detail)? onState;
  final void Function(Object packet, {int? heardMs})? onPacket;
  final void Function(String line)? onLog;
  final void Function()? onReset; // the node restarted (seq regressed)
  final void Function()? onConnected; // the door said hello (state ok)
  const LinkEvents(
      {this.onState, this.onPacket, this.onLog, this.onReset, this.onConnected});
}

abstract class Link {
  LinkState get state;
  Future<void> connect();
  void disconnect();
}

// ---------------------------------------------------------------------------
// TcpLink - the data door, byte-for-byte the web app's protocol
// ---------------------------------------------------------------------------

class TcpLink implements Link {
  static const watchdogTimeoutMs = 660_000; // 11 min (2x pulse cadence)
  static const _watchdogTickMs = 15_000;

  final LinkEvents events;
  final String host; // "192.168.12.145" or "host:port"
  final String password; // data-door token ("" = loopback use)
  final DoorSocketFactory socketFactory;
  final int watchdogMs;
  final int watchdogTickMs;
  // THE FIRST-CONNECT ASK (DESIGN.md 10): when the door says hello,
  // the phone asks for the area data BY ITSELF - marker 0 = full
  // roster (Brett's law), marker N = only changes. spanKm 0 = no ask
  // (tests / not-yet-wired shells).
  final int askMarker;
  final int askSpanKm;
  final int askOrigin;
  DoorSocket? _socket;
  LinkState _state = LinkState.disabled;
  int _lastSeq = 0;
  bool _wantRun = false;
  int _lastAliveMs = 0;
  Timer? _watchdog;
  // THE ZERO-DOTS LAW (the web app's lesson, re-learned on this
  // bench 2026-09-24): INTRO positions are DELTAS against the map
  // center - decoding them against (0,0) lands every dot ~10,000 km
  // away. The server sends the LAYOUT first; the link remembers it
  // and decodes every INTRO against it. An INTRO that arrives before
  // any LAYOUT is HELD (loudly), never silently mis-placed.
  Layout? _layout;

  /// The heard map geometry (the server's 3x3 frame): what section
  /// asks are computed against and what INTROs decode against.
  Layout? get layout => _layout;
  final List<Uint8List> _heldIntros = [];

  TcpLink(this.events,
      {required this.host,
      required this.password,
      required this.socketFactory,
      this.watchdogMs = watchdogTimeoutMs,
      this.watchdogTickMs = _watchdogTickMs,
      this.askMarker = 0,
      this.askSpanKm = 0,
      this.askOrigin = 0});

  @override
  LinkState get state => _state;

  void _setState(LinkState s, [String detail = '']) {
    _state = s;
    events.onState?.call(s, detail);
  }

  void _log(String line) => events.onLog?.call(line);

  /// The door URL - the web app's exact shape (App.ts onConnect):
  /// `ws://host:port/feed`, bare host = the node's web port 8710.
  static String doorUrl(String host) {
    final parts = host.split(':');
    final port = parts.length > 1 ? parts[1] : '8710';
    return 'ws://${parts[0]}:$port/feed';
  }

  @override
  Future<void> connect() async {
    if (host.trim().isEmpty) {
      _setState(LinkState.disabled, 'no address to dial');
      return;
    }
    _wantRun = true;
    _setState(LinkState.connecting);
    try {
      // The factory INSIDE the try: a missing/unwired socket must
      // refuse in plain words, never hang the button on Connecting
      // (bench lesson 2026-09-24).
      final socket = socketFactory();
      socket.onOpen = () {
        // hello arrives as the first message; state is reported there.
      };
      socket.onMessage = _onMessage;
      socket.onClose = (code, clean) {
        _log('link closed: code=$code clean=$clean');
        _stopWatchdog();
        if (!_wantRun) return;
        _wantRun = false;
        _setState(LinkState.disabled, 'link closed (code $code)');
      };
      socket.open(doorUrl(host),
          password.isEmpty ? null : ['bearer.$password']);
      _socket = socket;
    } catch (err) {
      _wantRun = false;
      _setState(LinkState.disabled, 'bad address: $err');
      return;
    }
  }

  @override
  void disconnect() {
    _wantRun = false;
    _stopWatchdog();
    _socket?.close();
    _socket = null;
    _setState(LinkState.disabled);
  }

  void _onMessage(String raw) {
    Map<String, Object?> msg;
    try {
      msg = jsonDecode(raw) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    final type = msg['type'] as String?;
    if (type == 'hello') {
      _setState(LinkState.connected, 'node proto ${msg['proto'] ?? '?'}');
      _log('door connected: ${doorUrl(host)} - receiving on the TCP pipe');
      _lastAliveMs = DateTime.now().millisecondsSinceEpoch;
      _startWatchdog();
      final lastSeq = (msg['last_seq'] as num?)?.toInt() ?? 0;
      if (lastSeq < _lastSeq) {
        _lastSeq = 0;
        // The node restarted: its map geometry died with its RAM -
        // the old center is no longer the truth.
        _layout = null;
        _heldIntros.clear();
        events.onReset?.call();
      }
      _send({'type': 'resume', 'after_seq': _lastSeq});
      // THE FIRST-CONNECT ASK, BY ITSELF (DESIGN.md 10 + the
      // Brett's-law restatement 2026-09-24): hello = the door is open
      // -> ask for the area data. Marker 0 (first run / nothing yet)
      // = the server sends the FULL roster it holds for the area;
      // marker N = only what changed since. No button, no waiting
      // on the background schedule.
      if (askSpanKm > 0) {
        sendVectoredAsk(
            syncMarker: askMarker, spanKm: askSpanKm, origin: askOrigin);
      }
      return;
    }
    if (type == 'packet') {
      _lastAliveMs = DateTime.now().millisecondsSinceEpoch;
      final seq = (msg['seq'] as num?)?.toInt() ?? 0;
      if (seq <= _lastSeq) return; // duplicate from resume
      _lastSeq = seq;
      final wire = msg['wire'] as String? ?? '';
      try {
        final bytes = [
          for (var i = 0; i + 1 < wire.length; i += 2)
            int.parse(wire.substring(i, i + 2), radix: 16),
        ];
        final packetBytes = Uint8List.fromList(bytes);
        if (peekDataType(packetBytes) == typeIntro) {
          if (_layout == null) {
            // Honest hold: no center yet, and a wrong center is the
            // zero-dots bug wearing a disguise. The LAYOUT is always
            // first in a burst, so this flushes within milliseconds.
            _heldIntros.add(packetBytes);
            _log('INTRO held - no map center heard yet');
            return;
          }
          final intro = decodeIntro(packetBytes.sublist(3),
              centerLat: _layout!.centerLat,
              centerLon: _layout!.centerLon);
          events.onPacket?.call(intro,
              heardMs: DateTime.now().millisecondsSinceEpoch);
          return;
        }
        final packet = decodeAny(packetBytes);
        // THE HONEST RECEIPT (Brett, 2026-09-24): every packet the
        // phone receives is logged with its type and the pipe it
        // came in on - no silent data, no guessed pipes.
        _log('door <- ${_packetName(packet)}');
        if (packet is Layout) {
          _layout = packet;
          // Flush anything held while the center was unknown.
          final held = List<Uint8List>.from(_heldIntros);
          _heldIntros.clear();
          for (final b in held) {
            final intro = decodeIntro(b.sublist(3),
                centerLat: _layout!.centerLat,
                centerLon: _layout!.centerLon);
            events.onPacket?.call(intro,
                heardMs: DateTime.now().millisecondsSinceEpoch);
          }
        }
        events.onPacket?.call(packet,
            heardMs: DateTime.now().millisecondsSinceEpoch);
      } catch (err) {
        _log('decode failed: $err');
      }
      return;
    }
    if (type == 'pong') {
      _lastAliveMs = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    if (type == 'ack') {
      final accepted = msg['accepted'] as bool? ?? false;
      final why = msg['reason'] as String? ?? 'refused';
      final wait = (msg['retry_after_s'] as num?)?.toInt() ?? 0;
      if (accepted) {
        _log('refresh accepted');
      } else {
        final mins = (wait / 60).ceil();
        _log(switch (why) {
          'map_budget' =>
            'refresh refused - the map budget is spent, ~$mins min',
          'hourly_cap' =>
            "refresh refused - this size's pool is spent, ~$mins min",
          'cooldown' => 'refresh refused - one ask per 30s, ${wait}s',
          'listen_only' =>
            'refresh refused - listen-only device; the map fills from heard packets',
          _ => 'refresh refused ($why)',
        });
      }
      return;
    }
  }

  /// A refresh ask over the door - the SAME codec bytes as radio mode
  /// would send. The vectored-sync marker rides inside the encoded
  /// RefreshReq payload; the door just ferries `wire` hex.
  void sendRefreshWire(List<int> payload, String reqId, String kind,
      int target, int origin, int spanKm) {
    if (_socket == null) {
      _log('not connected - refresh NOT sent');
      return;
    }
    // THE DOOR'S PER-KIND FIELD (bench-found bug 2026-09-24): the
    // server reads the section number from 'section' and a route id
    // from 'target' - the web app's exact JSON (App.ts). A wrong
    // field name is a SILENT server-side drop: no log, no answer.
    _send({
      'type': 'refresh',
      'req_id': reqId,
      'kind': kind,
      if (kind == 'section') 'section': target else 'target': target,
      'origin': origin,
      'span_km': spanKm,
      'wire': [for (final b in payload)
        b.toRadixString(16).padLeft(2, '0')].join(),
    });
    _log('refresh sent (kind=$kind target=$target'
        '${spanKm > 0 ? ', $spanKm km window' : ''})');
  }

  /// The vectored ask (VECTORED-SYNC-DESIGN section 3, DESIGN.md 10):
  /// a whole-area REFRESH_REQ with the phone's marker riding it.
  /// Marker 0 = first run = the server answers with the FULL roster
  /// it holds for the area (Brett's first-connect law). Kind 1 +
  /// target 0 is the exact whole-area shape the web app sends
  /// (App.ts sendRefresh(REFRESH_KIND_SECTION, REFRESH_WHOLE_AREA));
  /// the answer arrives as INTRO batches + PULSE (+ GONE packets).
  void sendVectoredAsk(
      {required int syncMarker, required int spanKm, int origin = 0}) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final req = RefreshReq(
      seq: nowMs & 0xFFFF,
      kind: refreshKindSection,
      target: refreshWholeArea,
      nonce: (nowMs >> 4) & 0xFFFF,
      origin: origin,
      spanKm: spanKm,
      syncMarker: syncMarker,
    );
    sendRefreshWire(encodeRefreshReq(req), 'ask-${req.seq}', 'map',
        refreshWholeArea, origin, spanKm);
  }

  /// THE TAP-ASK (design section 10): tapping a node asks the SERVER
  /// section that node sits in - the answer carries SECT_SUM + its
  /// top routes + the section's nodes. Section asks carry span 0
  /// (the web app's exact pattern, App.ts) and marker 0: the
  /// vectored filter is the roster's business, not a section's.
  void sendSectionAsk(
      {required int sectionId, required int origin}) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final req = RefreshReq(
      seq: nowMs & 0xFFFF,
      kind: refreshKindSection,
      target: sectionId,
      nonce: (nowMs >> 4) & 0xFFFF,
      origin: origin,
    );
    sendRefreshWire(encodeRefreshReq(req), 'sec-${req.seq}-$sectionId',
        'section', sectionId, origin, 0);
  }

  void _send(Map<String, Object?> obj) => _socket?.send(jsonEncode(obj));

  /// The packet's plain name for the receipt log.
  static String _packetName(Object p) => switch (p) {
        Layout() => 'layout (map frame)',
        Intro i => 'intro (${i.entries.length} node(s))',
        Pulse() => 'pulse (feed health)',
        SectSum s => 'section ${s.sectionId} summary',
        Route r => 'route ${r.routeId} (${r.prefixes.length} hop(s))',
        Gone g => 'gone (${g.prefixes.length} node(s))',
        _ => 'packet',
      };

  void _startWatchdog() {
    _stopWatchdog();
    _watchdog = Timer.periodic(
        Duration(milliseconds: watchdogTickMs), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastAliveMs > watchdogMs) {
        _log('link lost - no feed for ${watchdogMs ~/ 1000}s');
        disconnect();
        _setState(LinkState.disabled, 'link lost (no feed)');
      }
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }
}

// ---------------------------------------------------------------------------
// CompanionLink - the MAIN feature's slot (inert until the hardware go)
// ---------------------------------------------------------------------------

class CompanionLink implements Link {
  final LinkEvents events;
  LinkState _state = LinkState.disabled;

  CompanionLink(this.events);

  @override
  LinkState get state => _state;

  @override
  Future<void> connect() async {
    // HONEST UNTIL THE HARDWARE GO (design law: never a fake read):
    // BLE to the Heltec companion is designed (section 2) but not
    // built - the radio is not flashed, TX is not on. The app says so
    // plainly instead of pretending to scan.
    _state = LinkState.disabled;
    events.onState?.call(LinkState.disabled,
        'companion radio not connected - no BLE device paired yet');
    events.onLog?.call(
        'companion link: waiting for the radio (stage 2 hardware)');
  }

  @override
  void disconnect() {
    _state = LinkState.disabled;
    events.onState?.call(LinkState.disabled, '');
  }
}
