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
//   CompanionLink- the BLE link to Brett's Heltec (the MAIN
//                  feature): scan -> connect -> protocol init ->
//                  1s RX polling, ported from the VERIFIED
//                  meshclient.ts. No radio = a plain-words refusal,
//                  never a fake scan.
//
// Both feed the SAME decoded packets to the same callbacks - the link
// is a transport, never a second decoder. Both run intake through the
// ONE WireFeed (the zero-dots law lives there, not here). The socket
// is injected (DoorSocket): the native build passes IoDoorSocket.new,
// tests pass a fake - the web app's stub-the-WebSocket lesson. The BLE
// transport is injected the same way (BleTransportFactory).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'ble_transport.dart';
import 'codec.dart';
import 'companion_protocol.dart';
import 'door_socket.dart';
import 'wire_feed.dart';

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
  // away. That law lives in WireFeed (shared with the companion link):
  // the feed remembers the LAYOUT and holds any INTRO that arrives
  // before one, loudly, never silently mis-placing it.
  late final WireFeed _feed = WireFeed(
      pipe: 'door',
      onPacket: (packet, {heardMs}) =>
          events.onPacket?.call(packet, heardMs: heardMs),
      onLog: _log);

  /// The heard map geometry (the server's 3x3 frame): what section
  /// asks are computed against and what INTROs decode against.
  Layout? get layout => _feed.layout;

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
    _log('dialing ${doorUrl(host)}');
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
        _feed.reset();
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
        // THE ZERO-DOTS LAW + THE HONEST RECEIPT ("door <- <packet>")
        // live in WireFeed now - the same intake path the companion
        // link uses, with 'door' as the pipe name.
        _feed.feed(Uint8List.fromList(bytes));
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
// CompanionLink - the MAIN feature (DESIGN.md section 2): BLE to
// Brett's Heltec, the phone's radio (ears AND voice). Ported from the
// VERIFIED meshclient.ts over the BleTransport seam: the native build
// passes FbpBleTransport.new, tests pass a fake - the DoorSocket
// lesson applied to Bluetooth. Intake runs through the SAME WireFeed
// as the door's ('air' pipe), so packets land in the store through
// the one decoder path.
// ---------------------------------------------------------------------------

/// How long the automatic channel check waits for the 8-slot probe to
/// settle before it reads a slot anyway. The real sweep answers in
/// ~1.4 s (probeSummaryDelay); this is the belt-and-braces ceiling so
/// an unanswered radio can never hang the check - and with it the map.
const Duration channelCheckWait = Duration(seconds: 4);

class CompanionLink implements Link {
  final LinkEvents events;
  final BleTransportFactory transportFactory;

  // Timing knobs (the proven defaults; tests shorten them).
  final Duration pollInterval;
  final Duration slotProbeGap;
  final Duration probeSummaryDelay;

  // THE PICKER BOX (Brett 2026-09-25): given the scan's finds,
  // return the chosen candidate's id - or null when the human
  // cancelled. Null parameter = no box wired (tests, web): the
  // first-found radio is taken.
  final Future<String?> Function(List<BleCandidate> found)?
      devicePicker;

  /// How long to pause between connect attempts when the link bounces
  /// (the pairing box hops the connection - bench 2026-09-25). A knob
  /// so tests do not wait out the real seconds.
  final Duration retryPause;

  LinkState _state = LinkState.disabled;
  String _detail = '';
  bool _wantRun = false;

  /// True while the connect/retry loop runs: a 'radio disconnected'
  /// event during that window is the KNOWN pairing bounce (the app
  /// retries it), not news - handling it would kill our own retry.
  bool _retrying = false;
  BleTransport? _transport;
  CompanionProtocol? _proto;
  late final WireFeed _feed = WireFeed(
      pipe: 'air',
      onPacket: (packet, {heardMs}) =>
          events.onPacket?.call(packet, heardMs: heardMs),
      onLog: _log);

  CompanionLink(this.events,
      {required this.transportFactory,
      this.devicePicker,
      this.retryPause = const Duration(milliseconds: 1500),
      this.pollInterval = const Duration(seconds: 1),
      this.slotProbeGap = const Duration(milliseconds: 120),
      this.probeSummaryDelay = const Duration(milliseconds: 1400)});

  @override
  LinkState get state => _state;

  /// The plain-words detail of the LAST state change ("scanning for
  /// the radio", the device name, the refusal) - the connect screen's
  /// radio status line reads it, so the bench never depends on adb.
  String get detail => _detail;

  /// The #scope slot the probe found (null until it answers).
  int? get scopeSlot => _proto?.scopeSlot;

  /// The probe's slot table (slot -> name) for the provision dialog's
  /// current-truth preview. Empty when the link was never up.
  Map<int, String> get slotNames => _proto?.probeNames ?? const {};

  /// The probe's settle point (see CompanionProtocol.probeSettled):
  /// found, swept, or stopped - never a half-probed table.
  Future<void> get probeSettled async {
    final proto = _proto;
    if (proto == null) return;
    await proto.probeSettled;
  }

  /// THE AUTOMATIC CHANNEL CHECK (v022, Brett 2026-09-25): the app
  /// settles the channel BY ITSELF the moment the radio links up -
  /// connect -> check/provision -> map, no human in the middle.
  ///   * [name] with THE key already in a slot: nothing written.
  ///   * missing, empty-keyed or wrong-keyed: that slot is written
  ///     with [secretHex] and proved by read-back (the radio's verdict
  ///     is only its opinion - the read-back is the proof).
  /// The slot is the one the probe found, else the one still holding
  /// the old default channel, else 5. Returns the log's plain-words
  /// verdict; the caller decides what the map does with it.
  Future<String> ensureChannel({
    String name = scopeChannelName,
    required String secretHex,
    void Function(String stage)? stage,
  }) async {
    final proto = _proto;
    if (proto == null || _state != LinkState.connected) {
      return 'channel check refused - the companion link is down';
    }
    try {
      await proto.probeSettled.timeout(channelCheckWait);
    } on TimeoutException {
      // The sweep never settled. The fresh read inside the provision
      // is still the truth - it simply picks the likely slot itself.
      stage?.call('the slot probe never settled - reading a slot anyway');
    }
    var slot = scopeSlot;
    if (slot == null) {
      for (final e in slotNames.entries) {
        final held =
            e.value.replaceFirst(RegExp(r'^#'), '').toLowerCase();
        if (held == 'scope') {
          slot = e.key;
          break;
        }
      }
    }
    slot ??= 5;
    return provisionChannel(slot, name, secretHex,
        // THE APP ANSWERS ITSELF (v022): the check runs unattended, so
        // instead of asking a human who is not there it says out loud
        // what it is about to do - then does it.
        confirm: (situation) async {
          stage?.call('$situation - the channel check writes it');
          return true;
        },
        stage: stage);
  }

  /// Channel provisioning (v020): the check-first conversation -
  /// fresh read, confirm before touching, write, read back. Honest
  /// refusal when the link is down; the return string is the log's
  /// plain-words truth.
  Future<String> provisionChannel(int slot, String name, String secretHex,
      {Future<bool> Function(String situation)? confirm,
      void Function(String stage)? stage}) async {
    final proto = _proto;
    if (proto == null || _state != LinkState.connected) {
      return 'provision refused - the companion link is down';
    }
    return proto.provisionChannel(slot, name, secretHex,
        confirm: confirm, stage: stage);
  }

  /// The heard map geometry - the same zero-dots law as the door's
  /// (section asks computed against whatever frame either pipe heard).
  Layout? get layout => _feed.layout;

  void _setState(LinkState s, [String detail = '']) {
    _state = s;
    _detail = detail;
    events.onState?.call(s, detail);
  }

  void _log(String line) => events.onLog?.call(line);

  @override
  Future<void> connect() async {
    _wantRun = true;
    _setState(LinkState.connecting, 'scanning for the radio');
    _log('companion: scanning for the radio (BLE)');
    try {
      // The factory INSIDE the try: an unwired BLE (web, tests) or a
      // missing radio must refuse in plain words, never hang the app
      // on Connecting (the bench lesson from TcpLink, applied here).
      final transport = transportFactory();
      transport.onDisconnect = (why) {
        // A drop DURING the connect loop is the pairing bounce we
        // retry ourselves (bench 2026-09-25, "rock solid" ask).
        if (!_wantRun || _retrying) return;
        _wantRun = false;
        _log('companion link: $why');
        unawaited(_teardown());
        _setState(LinkState.disabled, why);
      };
      // SCAN FIRST, THEN THE BOX (Brett's pick 2026-09-25): every
      // companion heard is listed, and HIS tap chooses the radio.
      final found = await transport.scan();
      if (!_wantRun) {
        await transport.close();
        return;
      }
      if (found.isEmpty) {
        throw const BleRefusal('no companion radio found nearby');
      }
      BleCandidate pick;
      if (devicePicker == null) {
        pick = found.first; // no box wired (tests): first-found
      } else {
        _setState(LinkState.connecting, 'choose a radio from the list');
        final id = await devicePicker!(found);
        if (id == null || !_wantRun) {
          _wantRun = false;
          await transport.close();
          _log('radio selection cancelled - nothing connected');
          _setState(LinkState.disabled, 'radio selection cancelled');
          return;
        }
        pick = found.firstWhere((c) => c.id == id,
            orElse: () => found.first);
      }
      // ROCK-SOLID CONNECT (Brett 2026-09-25): Android HOPS the BLE
      // link while the PIN box does its pairing (bench: two of three
      // fresh attempts died with 'Device is disconnected' when our
      // init write landed mid-bounce). The app rides it out itself:
      // connect + protocol init as ONE unit, retried up to 3 times -
      // no re-tapping for the human.
      const maxAttempts = 3;
      _retrying = true;
      Object? bounce;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        if (attempt > 1) {
          _setState(LinkState.connecting,
              'link bounced - retrying ($attempt/$maxAttempts)');
          _log('BLE link bounced (the pairing box hops the connection)'
              ' - retry $attempt of $maxAttempts');
          await Future<void>.delayed(retryPause);
          if (!_wantRun) {
            _retrying = false;
            await transport.close();
            return;
          }
        }
        try {
          await transport.connect(pick);
          _transport = transport;
          final proto = CompanionProtocol(
            transport: transport,
            // Reassembled scope plaintexts are FULL packets (envelope
            // intact) - straight into the shared feed.
            onPayload: (plaintext) => _feed.feed(plaintext),
            onLog: _log,
            pollInterval: pollInterval,
            slotProbeGap: slotProbeGap,
            probeSummaryDelay: probeSummaryDelay,
          );
          _proto = proto;
          await proto.start();
          bounce = null;
          break;
        } catch (err) {
          bounce = err;
          // A half-open attempt must be swept BEFORE retrying (its
          // timers/subscriptions would double-fire otherwise).
          final proto = _proto;
          _proto = null;
          await proto?.stop();
          if (attempt == maxAttempts) break;
        }
      }
      _retrying = false;
      if (bounce != null) throw bounce;
      if (!_wantRun) {
        await transport.close();
        return;
      }
      _setState(LinkState.connected, transport.name);
      _log('companion connected: ${transport.name} - receiving on the'
          ' air pipe');
    } catch (err) {
      _wantRun = false;
      _retrying = false;
      await _teardown();
      _setState(LinkState.disabled, 'no radio: $err');
      _log('companion: $err');
    }
  }

  @override
  void disconnect() {
    _wantRun = false;
    unawaited(_teardown());
    _setState(LinkState.disabled);
  }

  Future<void> _teardown() async {
    final proto = _proto;
    _proto = null;
    await proto?.stop();
    final transport = _transport;
    _transport = null;
    await transport?.close();
  }

  /// THE AIR ASK (DESIGN.md 2): the same vectored REFRESH_REQ the
  /// door ferries, wrapped for the #scope channel so hilltop can
  /// answer over the air. Same codec bytes, different pipe.
  Future<void> sendVectoredAsk(
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
    return _sendScope(encodeRefreshReq(req), 'ask-${req.seq}');
  }

  /// The tap-ask over the air (design section 10): a section ask,
  /// same bytes the door carries.
  Future<void> sendSectionAsk(
      {required int sectionId, required int origin}) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final req = RefreshReq(
      seq: nowMs & 0xFFFF,
      kind: refreshKindSection,
      target: sectionId,
      nonce: (nowMs >> 4) & 0xFFFF,
      origin: origin,
    );
    return _sendScope(
        encodeRefreshReq(req), 'sec-${req.seq}-$sectionId');
  }

  Future<void> _sendScope(Uint8List wire, String id) async {
    final proto = _proto;
    if (proto == null || _state != LinkState.connected) {
      _log('$id not sent - the companion link is down');
      return;
    }
    await proto.sendScope(wire);
  }
}
