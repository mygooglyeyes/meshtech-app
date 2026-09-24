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
// (DoorSocket): the browser build passes WebDoorSocket.new, tests
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
  const LinkEvents({this.onState, this.onPacket, this.onLog, this.onReset});
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
  DoorSocket? _socket;
  LinkState _state = LinkState.disabled;
  int _lastSeq = 0;
  bool _wantRun = false;
  int _lastAliveMs = 0;
  Timer? _watchdog;

  TcpLink(this.events,
      {required this.host,
      required this.password,
      required this.socketFactory,
      this.watchdogMs = watchdogTimeoutMs,
      this.watchdogTickMs = _watchdogTickMs});

  @override
  LinkState get state => _state;

  void _setState(LinkState s, [String detail = '']) {
    _state = s;
    events.onState?.call(s, detail);
  }

  void _log(String line) => events.onLog?.call(line);

  /// The door URL - the web app's exact shape (App.ts onConnect):
  /// ws://<host>:<port>/feed, bare host = the node's web port 8710.
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
    try {
      socket.open(doorUrl(host),
          password.isEmpty ? null : ['bearer.$password']);
    } catch (err) {
      _wantRun = false;
      _setState(LinkState.disabled, 'bad address: $err');
      return;
    }
    _socket = socket;
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
      _lastAliveMs = DateTime.now().millisecondsSinceEpoch;
      _startWatchdog();
      final lastSeq = (msg['last_seq'] as num?)?.toInt() ?? 0;
      if (lastSeq < _lastSeq) {
        _lastSeq = 0;
        events.onReset?.call();
      }
      _send({'type': 'resume', 'after_seq': _lastSeq});
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
        final packet = decodeAny(Uint8List.fromList(bytes));
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
    _send({
      'type': 'refresh',
      'req_id': reqId,
      'kind': kind,
      'target': target,
      'origin': origin,
      'span_km': spanKm,
      'wire': [for (final b in payload)
        b.toRadixString(16).padLeft(2, '0')].join(),
    });
    _log('refresh sent (kind=$kind target=$target'
        '${spanKm > 0 ? ', $spanKm km window' : ''})');
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
