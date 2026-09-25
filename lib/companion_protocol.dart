// The MeshCore companion protocol engine: the bytes between the phone
// and Brett's Heltec companion radio. Ported from the VERIFIED web
// client (meshtech-phone/app/src/lib/meshclient.ts, proven live
// 2026-09-17/18) - never re-derived from memory. The rules it carries:
//
//   - BARE command writes: [type][data] on the RX characteristic, NO
//     0xFF length prefix (the 2026-09-18 live-link bug: the radio
//     silently ignored every wrapped command).
//   - INIT order: CMD_APP_START first after connect, then a device
//     query, then the 8-slot channel probe that finds #scope.
//   - POLLING RX: the firmware QUEUES received datagrams - a passive
//     notification listener sees nothing. The host fetches each one
//     with CMD_SYNC_NEXT_MESSAGE every second (the 2026-09-18 lesson:
//     TX worked, RX was silent).
//   - scope plaintext arrives inside CHANNEL_DATA_RECV (0x1B) frames;
//     the full data_type+len+body is reassembled for the codec.
//   - No BLE PIN ever enters the log (device info logs fw + build
//     only) - and a steady link is SILENT: heartbeats and empty acks
//     never print, only real packets and real uplink verdicts.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'ble_transport.dart';
import 'codec.dart';

// Companion-protocol constants (docs.meshcore.io/companion_protocol,
// cross-checked against openhop_core frame_server.py constants.py +
// the plugin's client.py - never guess wire constants).
const int cmdAppStart = 0x01; // first after connect
const int cmdSyncNextMessage = 0x0a; // poll: next queued packet
const int cmdDeviceQuery = 0x16; // arg 0x03 -> PACKET_DEVICE_INFO
const int cmdGetChannel = 0x1f; // arg: slot 0..7
const int cmdSendChannelData = 62; // [62][slot][0xFF]+type+payload
const int rspChannelInfo = 0x12; // 50 B: idx,name(32),secret(16)
const int rspChannelDataRecv = 0x1b; // scope datagrams arrive here
const int rspDeviceInfo = 0x0d;
const int rspOk = 0x00; // TX verdict: accepted
const int rspErr = 0x01; // TX verdict: rejected (code follows)
const String scopeChannelName = 'scope';

/// Companion CHANNEL_DATA_RECV frame: code(1)+snr(1)+rsv(2)+chan(1)+
/// path_len(1)+data_type(2)+data_len(1)+payload. The 9-byte header is
/// located by the scope magic (0x53xx) rather than trusting stream
/// sync. Each hit reassembles the FULL plaintext (data_type+data_len+
/// body - what decodeAny expects): slicing from byte 9 yields a
/// headless body that fails type dispatch silently (the proven
/// 2026-09-18 16:13-16:19 bug). SNR is signed-8/4 (companion
/// convention). VERIFIED LIVE 2026-09-18 16:26:55.
List<({Uint8List payload, double? snr})> extractScopePayloads(Uint8List frame) {
  final out = <({Uint8List payload, double? snr})>[];
  for (var off = 0; off + 9 <= frame.length; off++) {
    final dataType = frame[off + 6] | (frame[off + 7] << 8);
    if ((dataType & 0xff00) != 0x5300) continue;
    final dataLen = frame[off + 8];
    if (off + 9 + dataLen > frame.length) continue;
    final snrRaw = frame[off + 1];
    final snr = (snrRaw >= 128 ? snrRaw - 256 : snrRaw) / 4;
    out.add((
      payload: Uint8List.sublistView(frame, off + 6, off + 9 + dataLen),
      snr: snr,
    ));
    off += 9 + dataLen - 1;
  }
  // Bare scope plaintext (bench captures): also accept directly.
  if (out.isEmpty && frame.length >= 3 && frame[1] == 0x53) {
    out.add((payload: Uint8List.sublistView(frame), snr: null));
  }
  return out;
}

/// The protocol engine over ONE connected transport. `start()` runs the
/// init sequence + RX polling; scope payloads come out through
/// `onPayload` as full plaintexts (the WireFeed feeds on them).
class CompanionProtocol {
  final BleTransport transport;

  /// One reassembled scope plaintext (the codec's exact input shape).
  final void Function(Uint8List plaintext) onPayload;
  final void Function(String line) onLog;

  /// The name announced in CMD_APP_START.
  final String appName;

  /// Timing knobs (the proven defaults; tests shorten them).
  final Duration pollInterval;
  final Duration slotProbeGap;
  final Duration probeSummaryDelay;

  CompanionProtocol({
    required this.transport,
    required this.onPayload,
    required this.onLog,
    this.appName = 'meshtech-app',
    this.pollInterval = const Duration(seconds: 1),
    this.slotProbeGap = const Duration(milliseconds: 120),
    this.probeSummaryDelay = const Duration(milliseconds: 1400),
  });

  Uint8List _rx = Uint8List(0); // response reassembly buffer
  StreamSubscription<Uint8List>? _sub;
  Timer? _poll;
  final List<Timer> _probeTimers = [];
  int? _scopeSlot; // #scope's slot in the radio's channel table
  int _awaitingTxAckMs = 0; // an uplink waiting for the radio verdict
  bool _running = false;
  bool _firstPacketSeen = false;
  final Map<int, String> _probeNames = {};

  /// #scope's slot (found by the probe), or null when not found yet.
  int? get scopeSlot => _scopeSlot;

  /// The expected #scope secret: sha256('#scope')[:16] - the hashtag
  /// rule (docs.meshcore.io Channel Management; same rule the node
  /// uses with an empty secret_hex, client.py).
  static final List<int> expectedSecret =
      sha256.convert(utf8.encode('#scope')).bytes.sublist(0, 16);

  /// Init + RX polling. Throws plain words (BleRefusal) when the
  /// init cannot be written - the caller reports it, never hangs.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _sub = transport.incoming.listen(_onChunk);
    try {
      // CMD_APP_START: [0x01][7 reserved zeros][name] - must come
      // first after connecting (companion_protocol doc).
      final name = utf8.encode(appName);
      final appStart = Uint8List(8 + name.length);
      appStart[0] = cmdAppStart;
      appStart.setRange(8, 8 + name.length, name);
      await transport.write(appStart);
      // Device query (byte0 0x16, byte1 0x03): firmware version gates
      // channel-datagram (0x1B) support - logged, never a guess.
      await transport.write(Uint8List.fromList([cmdDeviceQuery, 0x03]));
    } catch (err) {
      await stop();
      throw BleRefusal('companion init write failed: $err');
    }
    // The probe: ask the radio for all 8 channel slots, 120 ms apart;
    // the responses build _scopeSlot and log a one-line sweep summary
    // after the last slot's response window.
    for (var slot = 0; slot < 8; slot++) {
      _probeTimers.add(Timer(slotProbeGap * slot, () {
        _writeQuiet([cmdGetChannel, slot]);
      }));
    }
    _probeTimers.add(Timer(probeSummaryDelay, _probeSummary));
    onLog('channel probe sent (slots 0-7) - looking for #scope');
    // One poll per second: each response is one queued packet or an
    // empty ack - both drain through _onChunk, where scope payloads
    // are extracted and everything else drops quietly.
    _poll = Timer.periodic(pollInterval, (_) => _pollTick());
    final every = pollInterval.inSeconds >= 1
        ? '${pollInterval.inSeconds}s'
        : '${pollInterval.inMilliseconds}ms';
    onLog('companion init sent - RX polling every $every');
  }

  Future<void> stop() async {
    _running = false;
    _poll?.cancel();
    _poll = null;
    for (final t in _probeTimers) {
      t.cancel();
    }
    _probeTimers.clear();
    await _sub?.cancel();
    _sub = null;
    _rx = Uint8List(0);
    _awaitingTxAckMs = 0;
  }

  /// Send a FULL scope plaintext (3-byte envelope + body) over the
  /// #scope channel: wrapped in CMD_SEND_CHANNEL_DATA with the slot
  /// the probe found. The frame is exactly what the reference parser
  /// reads (frame_server._cmd_send_channel_data):
  ///
  ///   [62][slot][0xFF path_len][data_type 2 LE][body]
  ///
  /// The radio then builds the on-air plaintext as
  /// `type(2) + len(1) + body` itself, so the body travels WITHOUT
  /// its 3-byte envelope (carrying the full plaintext double-wraps
  /// the packet and the host drops it - the 2026-09-18 bug). But the
  /// data_type is its own frame field: v017 omitted it, the radio
  /// read its "type" from the body's first two bytes (0x06 version +
  /// seq -> 0x8d06), wrapped THOSE, and hilltop honestly refused every
  /// air ask as not-scope traffic (2026-09-25, the silent-uplink
  /// trace - the node's v0.0.050 DEBUG named the gate).
  Future<bool> sendScope(Uint8List plaintext) async {
    int dataType;
    try {
      dataType = peekDataType(plaintext);
    } catch (_) {
      dataType = 0;
    }
    if ((dataType & 0xff00) != 0x5300) {
      // Not a scope packet: the companion takes it as a raw command.
      return _writeRaw(plaintext, 'raw uplink');
    }
    final slot = _scopeSlot;
    if (slot == null) {
      onLog('#scope slot not found yet - uplink NOT sent');
      return false;
    }
    final bodyLen = plaintext.length > 2 ? plaintext[2] : 0;
    final body = 3 + bodyLen <= plaintext.length
        ? Uint8List.sublistView(plaintext, 3, 3 + bodyLen)
        : Uint8List.sublistView(plaintext, 3);
    final frame = Uint8List(5 + body.length);
    frame[0] = cmdSendChannelData;
    frame[1] = slot;
    frame[2] = 0xff; // flood
    frame[3] = dataType & 0xff; // data_type - its own field (v018)
    frame[4] = (dataType >> 8) & 0xff;
    frame.setAll(5, body);
    final hex = dataType.toRadixString(16).padLeft(4, '0');
    return _writeRaw(frame,
        'scope uplink sent (type 0x$hex, ${body.length}B body, slot $slot)'
        ' - awaiting radio verdict',
        verdict: true);
  }

  // ------------------------------------------------------------------
  // Response handling
  // ------------------------------------------------------------------

  void _onChunk(Uint8List chunk) {
    final merged = Uint8List(_rx.length + chunk.length);
    merged.setAll(0, _rx);
    merged.setAll(_rx.length, chunk);
    _rx = merged;
    _drain();
  }

  /// One complete response at a time; a response SPLIT across
  /// notifications waits for its tail (long frames do split).
  void _drain() {
    while (_rx.isNotEmpty) {
      final t = _rx[0];
      if (t == rspChannelDataRecv) {
        if (_rx.length < 9) return; // header split - wait
        final dataLen = _rx[8];
        if (_rx.length < 9 + dataLen) return; // body split - wait
        final frame = Uint8List.sublistView(_rx, 0, 9 + dataLen);
        _rx = Uint8List.sublistView(_rx, 9 + dataLen);
        _handleFrame(frame);
        continue;
      }
      if (t == rspChannelInfo) {
        if (_rx.length < 50) return; // split - wait
        final frame = Uint8List.sublistView(_rx, 0, 50);
        _rx = Uint8List.sublistView(_rx, 50);
        _onChannelInfo(frame);
        continue;
      }
      if (t == rspDeviceInfo) {
        // PACKET_DEVICE_INFO: fw_ver(1) ... build_date @8..19. Log
        // version + build ONLY - NEVER the BLE PIN (bytes 4..7).
        if (_rx.length < 20) return; // split - wait
        var build = utf8.decode(_rx.sublist(8, 20), allowMalformed: true)
            .replaceAll('\x00', '')
            .trim();
        if (build.isEmpty) build = 'unknown build';
        onLog('radio firmware v${_rx[1]} ($build) - datagram support'
            ' needs v1.12+');
        _rx = Uint8List(0); // device info is self-contained
        continue;
      }
      // One complete short frame (ack / no-more / waiting / verdict).
      final frame = _rx;
      _rx = Uint8List(0);
      _onShortFrame(frame);
    }
  }

  void _handleFrame(Uint8List frame) {
    final hits = extractScopePayloads(frame);
    if (hits.isEmpty) return;
    if (!_firstPacketSeen) {
      _firstPacketSeen = true;
      final snr = hits.first.snr;
      onLog(snr == null
          ? 'first OTA packet heard - feeding the store'
          : 'first OTA packet heard (snr ${snr.toStringAsFixed(1)} dB)'
              ' - feeding the store');
    }
    for (final hit in hits) {
      try {
        onPayload(hit.payload);
      } catch (err) {
        // An app-side throw must name itself, never vanish.
        onLog('app handler failed on scope packet: $err');
      }
    }
  }

  /// PACKET_CHANNEL_INFO (0x12): idx(1) name(32) secret(16).
  void _onChannelInfo(Uint8List frame) {
    final idx = frame[1];
    var end = 2;
    while (end < 34 && frame[end] != 0) {
      end++;
    }
    final name =
        utf8.decode(frame.sublist(2, end), allowMalformed: true).trim();
    _probeNames[idx] = name.isEmpty ? '(empty)' : name;
    // Match like the plugin does (client.py _ensure_scope_channel):
    // strip the leading '#', case-insensitive - the radio may store
    // the channel as '#scope' or 'scope'.
    final bare =
        name.replaceFirst(RegExp(r'^#'), '').toLowerCase();
    if (bare != scopeChannelName) return;
    if (_scopeSlot == idx) return; // already reported
    _scopeSlot = idx;
    final secret = frame.sublist(34, 50);
    final match = _bytesEqual(secret, expectedSecret)
        ? 'secret MATCHES #scope'
        : 'secret MISMATCHES #scope - wrong key on the radio';
    onLog('#scope found in radio slot $idx - $match');
  }

  /// One compact line per probe sweep listing every slot heard (only
  /// when no #scope turned up - a found slot already logged itself).
  void _probeSummary() {
    if (!_running || _scopeSlot != null) return;
    final parts = <String>[];
    for (var i = 0; i < 8; i++) {
      final n = _probeNames[i];
      if (n != null) parts.add("$i:'$n'");
    }
    onLog(parts.isNotEmpty
        ? 'probe heard slots: ${parts.join(' ')} - no #scope among them'
        : 'probe heard no channel info responses at all');
  }

  void _pollTick() {
    // Stale TX verdict: the radio never answered within 6 s - stop
    // waiting, loudly (an invisible uplink fate is the bug class the
    // 2026-09-18 hunt named).
    if (_awaitingTxAckMs != 0 &&
        DateTime.now().millisecondsSinceEpoch - _awaitingTxAckMs > 6000) {
      _awaitingTxAckMs = 0;
      onLog('uplink verdict MISSING - radio never answered the send');
    }
    _writeQuiet([cmdSyncNextMessage]);
  }

  /// A response that is neither a scope frame nor channel info: usually
  /// an empty poll ack (quiet - a steady link is silent) or the TX
  /// verdict of a pending uplink (never invisible).
  void _onShortFrame(Uint8List frame) {
    final t = frame[0];
    if (t != rspOk && t != rspErr) return;
    if (_awaitingTxAckMs == 0) return;
    _awaitingTxAckMs = 0;
    if (t == rspOk) {
      onLog('uplink ACCEPTED by radio (OK)');
    } else {
      onLog('uplink REJECTED by radio (error code '
          '${frame.length > 1 ? frame[1] : '?'})');
    }
  }

  // ------------------------------------------------------------------
  // Writes
  // ------------------------------------------------------------------

  /// A poll/probe write: a dropped one is not news (a dead link names
  /// itself through the transport's onDisconnect).
  Future<void> _writeQuiet(List<int> bytes) async {
    try {
      await transport.write(Uint8List.fromList(bytes));
    } catch (_) {
      /* quiet by design */
    }
  }

  Future<bool> _writeRaw(Uint8List frame, String receipt,
      {bool verdict = false}) async {
    // v019 (the 2026-09-25 16:19 bench race): arm the verdict flag
    // BEFORE the write - the radio's OK can land while the BLE write
    // future is still settling (hilltop heard the packet 278 ms
    // before our own write returned), and an OK arriving with the
    // flag down was discarded as unsolicited - printing "verdict
    // MISSING" for a send that had worked perfectly.
    if (verdict) {
      _awaitingTxAckMs = DateTime.now().millisecondsSinceEpoch;
    }
    try {
      await transport.write(frame);
      onLog(receipt);
      return true;
    } catch (err) {
      if (verdict) {
        _awaitingTxAckMs = 0;
      }
      onLog('TX failed: $err');
      return false;
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
