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

import 'ble_transport.dart';
import 'codec.dart';

// Companion-protocol constants (docs.meshcore.io/companion_protocol,
// cross-checked against openhop_core frame_server.py constants.py +
// the plugin's client.py - never guess wire constants).
const int cmdAppStart = 0x01; // first after connect
const int cmdSyncNextMessage = 0x0a; // poll: next queued packet
const int cmdDeviceQuery = 0x16; // arg 0x03 -> PACKET_DEVICE_INFO
const int cmdGetChannel = 0x1f; // arg: slot 0..7
const int cmdSetChannel = 0x20; // [slot][name 32 NUL-padded][secret]
//   openhop frame_server._cmd_set_channel: secret may ride as 16/32
//   raw bytes or 64 ASCII hex; we send our 16 raw bytes.
const int cmdSendChannelData = 62; // [62][slot][0xFF]+type+payload
const int rspChannelInfo = 0x12; // 50 B: idx,name(32),secret(16)
const int rspChannelDataRecv = 0x1b; // scope datagrams arrive here
const int rspDeviceInfo = 0x0d;
const int rspOk = 0x00; // TX verdict: accepted
const int rspErr = 0x01; // TX verdict: rejected (code follows)
const String scopeChannelName = 'meshtech';

/// THE SHARED CHANNEL KEY (Brett 2026-09-25 - his waiver of rule
/// zero, in his words: "this is open source, and the key is not
/// critical. just having it different than the default is
/// sufficient"). ONE key, shared by every phone and every node: each
/// node's config.json carries the same hex as channel.secret_hex, so
/// several nodes and several phones end up on ONE channel. The old
/// sha256('#scope') guess is gone for good - the name alone can no
/// longer hand anyone the key.
const String channelSecretHex = 'f5a660b67dcfdf6b1adea876443091d7';

/// One CHANNEL_INFO answer: what the radio ACTUALLY holds in a slot.
/// The provisioner speaks in these - pre-write check and read-back
/// both compare against a snapshot, never against hope.
class ChannelSnapshot {
  final int slot;
  final String name;
  final Uint8List secret;
  const ChannelSnapshot(this.slot, this.name, this.secret);
}

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
  final Duration channelWait;

  CompanionProtocol({
    required this.transport,
    required this.onPayload,
    required this.onLog,
    this.appName = 'meshtech-app',
    this.pollInterval = const Duration(seconds: 1),
    this.slotProbeGap = const Duration(milliseconds: 120),
    this.probeSummaryDelay = const Duration(milliseconds: 1400),
    this.channelWait = const Duration(milliseconds: 1500),
  });

  Uint8List _rx = Uint8List(0); // response reassembly buffer
  StreamSubscription<Uint8List>? _sub;
  Timer? _poll;
  final List<Timer> _probeTimers = [];
  int? _scopeSlot; // #scope's slot in the radio's channel table
  int _awaitingTxAckMs = 0; // a write waiting for the radio verdict
  String _awaitingLabel = 'uplink'; // what that verdict belongs to
  final Map<int, Completer<ChannelSnapshot?>> _chanWait = {};
  bool _running = false;
  bool _firstPacketSeen = false;
  final Map<int, String> _probeNames = {};
  Completer<void> _probeSettled = Completer<void>();

  /// #scope's slot (found by the probe), or null when not found yet.
  int? get scopeSlot => _scopeSlot;

  /// THE PROBE'S SETTLE POINT: completes as soon as the channel is
  /// found, or when the sweep's summary timer runs (all 8 slots asked
  /// + their answer windows), or when the protocol stops. The
  /// automatic channel check waits on THIS so it never reads a
  /// half-probed slot table and calls it truth.
  Future<void> get probeSettled => _probeSettled.future;

  void _settleProbe() {
    if (!_probeSettled.isCompleted) _probeSettled.complete();
  }

  /// Init + RX polling. Throws plain words (BleRefusal) when the
  /// init cannot be written - the caller reports it, never hangs.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _probeSettled = Completer<void>(); // fresh sweep, fresh settle point
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
    onLog('channel probe sent (slots 0-7) - looking for '
        '#$scopeChannelName');
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
    _settleProbe(); // no waiter may hang on a protocol that stopped
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
    for (final w in _chanWait.values) {
      if (!w.isCompleted) w.complete(null); // honest: no answer
    }
    _chanWait.clear();
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
      onLog('#$scopeChannelName slot not found yet - uplink NOT sent');
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
        verdictLabel: 'uplink');
  }

  // -------------------------------------------------- channel provisioning

  /// The probe's slot table (slot -> name as the radio stored it) -
  /// the provision dialog shows this as current truth before any
  /// write is even offered.
  Map<int, String> get probeNames => Map.unmodifiable(_probeNames);

  /// Fresh read of ONE slot. Null = the radio did not answer in time
  /// - reported as an honest gap, never guessed around.
  Future<ChannelSnapshot?> readChannel(int slot) {
    final wait = Completer<ChannelSnapshot?>();
    _chanWait[slot] = wait;
    _writeQuiet([cmdGetChannel, slot]);
    return wait.future.timeout(channelWait, onTimeout: () {
      _chanWait.remove(slot);
      return null;
    });
  }

  /// CMD_SET_CHANNEL (32): [slot][name 32, NUL-padded][secret]. The
  /// verdict arrives like any write's - but it is only the radio's
  /// opinion; the provisioner's READ-BACK is the proof.
  Future<bool> setChannel(int slot, String name, Uint8List secret) {
    final nb = utf8.encode(name);
    final take = nb.length > 31 ? 31 : nb.length;
    final frame = Uint8List(34 + secret.length);
    frame[0] = cmdSetChannel;
    frame[1] = slot;
    frame.setRange(2, 2 + take, nb.sublist(0, take));
    frame.setRange(34, 34 + secret.length, secret);
    return _writeRaw(
        frame,
        'channel write sent (slot $slot name=$name '
        '${secret.length}B key) - awaiting radio verdict',
        verdictLabel: 'channel write');
  }

  /// THE PROVISION CONVERSATION (Brett's check-first rule, 2026-09-25):
  /// read the slot FRESH, compare, ask before touching anything that
  /// is not already correct, write, then READ IT BACK. Returns the
  /// plain-words truth for the log; every stage line is said aloud.
  Future<String> provisionChannel(int slot, String name, String secretHex,
      {Future<bool> Function(String situation)? confirm,
      void Function(String stage)? stage}) async {
    final hex = secretHex.replaceAll(RegExp(r'\s'), '').toLowerCase();
    if (hex.length != 32 || !RegExp(r'^[0-9a-f]+$').hasMatch(hex)) {
      return 'key must be exactly 32 hex characters (16 bytes) - '
          'nothing written';
    }
    final secret = Uint8List.fromList([
      for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
    final bare = name.startsWith('#') ? name.substring(1) : name;
    if (bare.isEmpty) return 'channel name is empty - nothing written';
    String norm(String n) =>
        n.replaceFirst(RegExp(r'^#'), '').toLowerCase();
    bool sameSecret(List<int> a) {
      if (a.length != secret.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != secret[i]) return false;
      }
      return true;
    }

    stage?.call('reading slot $slot first');
    final before = await readChannel(slot);
    if (before != null &&
        norm(before.name) == norm(bare) &&
        sameSecret(before.secret)) {
      final msg = 'slot $slot already holds #$bare with this exact key - '
          'nothing written';
      stage?.call(msg);
      return msg;
    }
    String situation;
    if (before == null) {
      situation = 'slot $slot did not answer the read - write #$bare '
          'there anyway?';
    } else if (before.name.isEmpty) {
      situation = 'slot $slot is empty - write #$bare there?';
    } else if (norm(before.name) == norm(bare)) {
      situation = 'slot $slot holds #$bare with a DIFFERENT key - '
          'overwrite it?';
    } else {
      situation = 'slot $slot holds "${before.name}" - overwrite '
          'with #$bare?';
    }
    final go = await confirm?.call(situation) ?? true;
    if (!go) {
      final msg = 'cancelled - slot $slot left as it was '
          '(${before?.name ?? "no answer"})';
      stage?.call(msg);
      return msg;
    }
    stage?.call('writing slot $slot');
    final wrote = await setChannel(slot, bare, secret);
    stage?.call('reading slot $slot back');
    final after = await readChannel(slot);
    if (after != null &&
        norm(after.name) == norm(bare) &&
        sameSecret(after.secret)) {
      final msg = 'slot $slot now #$bare - read back MATCHES'
          '${wrote ? '' : ' (no verdict from the radio, but the read-back is proof)'}';
      stage?.call(msg);
      return msg;
    }
    final msg = 'write did NOT stick - slot $slot reads '
        '${after?.name ?? "(no answer)"}'
        '${wrote ? '' : ' and the radio refused the write'}';
    stage?.call(msg);
    return msg;
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
    // v020: the provisioner asked for THIS slot - hand it the truth
    // (name + secret) before any scope-name filtering can hide it.
    final waiter = _chanWait.remove(idx);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(ChannelSnapshot(
          idx, name, Uint8List.fromList(frame.sublist(34, 50))));
    }
    // Match like the plugin does (client.py _ensure_scope_channel):
    // strip the leading '#', case-insensitive - the radio may store
    // the channel as '#scope' or 'scope'.
    final bare =
        name.replaceFirst(RegExp(r'^#'), '').toLowerCase();
    if (bare != scopeChannelName) return;
    if (_scopeSlot == idx) return; // already reported
    _scopeSlot = idx;
    final secret = frame.sublist(34, 50);
    // v021 (the #meshtech cutover): the app cannot know the node's
    // key (it is not derivable from the name anymore), so the sha256
    // guess is GONE - the radio is the source of truth for the key,
    // and the log says exactly what was and was not verified.
    final emptyKey = secret.every((b) => b == 0);
    final match = emptyKey
        ? 'slot key is EMPTY (all zeros) - provision it'
        : 'key read from the radio (${secret.length}B) - the node '
            'must hold the same';
    onLog('#$scopeChannelName found in radio slot $idx - $match');
    // The channel is here: the auto check need not wait the sweep out.
    _settleProbe();
  }

  /// One compact line per probe sweep listing every slot heard (only
  /// when no #scope turned up - a found slot already logged itself).
  void _probeSummary() {
    _settleProbe(); // every slot's answer window has passed by now
    if (!_running || _scopeSlot != null) return;
    final parts = <String>[];
    for (var i = 0; i < 8; i++) {
      final n = _probeNames[i];
      if (n != null) parts.add("$i:'$n'");
    }
    onLog(parts.isNotEmpty
        ? 'probe heard slots: ${parts.join(' ')} - no '
            '#$scopeChannelName among them'
        : 'probe heard no channel info responses at all');
  }

  void _pollTick() {
    // Stale TX verdict: the radio never answered within 6 s - stop
    // waiting, loudly (an invisible uplink fate is the bug class the
    // 2026-09-18 hunt named).
    if (_awaitingTxAckMs != 0 &&
        DateTime.now().millisecondsSinceEpoch - _awaitingTxAckMs > 6000) {
      _awaitingTxAckMs = 0;
      onLog('$_awaitingLabel verdict MISSING - radio never answered'
          ' the send');
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
      onLog('$_awaitingLabel ACCEPTED by radio (OK)');
    } else {
      onLog('$_awaitingLabel REJECTED by radio (error code '
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
      {String? verdictLabel}) async {
    // v019 (the 2026-09-25 16:19 bench race): arm the verdict flag
    // BEFORE the write - the radio's OK can land while the BLE write
    // future is still settling (hilltop heard the packet 278 ms
    // before our own write returned), and an OK arriving with the
    // flag down was discarded as unsolicited - printing "verdict
    // MISSING" for a send that had worked perfectly.
    if (verdictLabel != null) {
      _awaitingLabel = verdictLabel;
      _awaitingTxAckMs = DateTime.now().millisecondsSinceEpoch;
    }
    try {
      await transport.write(frame);
      onLog(receipt);
      return true;
    } catch (err) {
      if (verdictLabel != null) {
        _awaitingTxAckMs = 0;
      }
      onLog('TX failed: $err');
      return false;
    }
  }
}
