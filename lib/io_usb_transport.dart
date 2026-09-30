// The REAL transport for the USB carrier: the companion radio on a
// USB cable (phone OTG -> radio serial), speaking the SAME companion
// protocol as BLE - wrapped in the stream framing (the MeshCore SDK
// serial_cx.py rules, companion_framing.dart).
//
// This file holds ONLY transport mechanics (list/open/params/read/
// write). The companion protocol itself lives in
// companion_protocol.dart and is tested on the VM through the
// BleTransport seam - the DoorSocket lesson, applied to USB.
//
// Constants verified against the reference, never guessed:
//   - 115200 8N1: the meshcore SDK's own create_serial default
//     (meshcore.py: baudrate: int = 115200).
//   - DTR asserted / RTS deasserted: the SDK SerialConnection's
//     defaults (serial_cx.py - and its note: deassert DTR on
//     heltec_v2; that is a bench knob if a radio ever needs it).
// No USB at all (nothing plugged, permission refused) is a plain-
// words BleRefusal, never a hang.

import 'dart:async';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';

import 'ble_transport.dart';
import 'companion_framing.dart';

class IoUsbTransport implements BleTransport {
  static const _baud = 115200; // meshcore SDK create_serial default

  final _incoming = StreamController<Uint8List>.broadcast();
  final _framer = CompanionStreamFramer();
  void Function(String why)? _onDisconnect;
  final Map<String, UsbDevice> _attached = {}; // scan results by id
  UsbPort? _port;
  StreamSubscription<Uint8List>? _sub;
  String _name = '';

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  set onDisconnect(void Function(String why) f) => _onDisconnect = f;

  @override
  String get name => _name;

  @override
  Future<List<BleCandidate>> scan(
      {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final devices = await UsbSerial.listDevices();
      _attached.clear();
      final out = <BleCandidate>[];
      for (final d in devices) {
        // deviceName is the plugin's own identity key (UsbDevice ==
        // compares it) - stable across scans, honest to dial.
        final id = d.deviceName;
        final name = (d.productName == null || d.productName!.isEmpty)
            ? 'USB serial device'
            : d.productName!;
        _attached[id] = d;
        out.add(BleCandidate(id, name));
      }
      return out; // empty = nothing plugged in - said in plain words
    } catch (err) {
      throw BleRefusal('USB scan failed: $err');
    }
  }

  @override
  Future<void> connect(BleCandidate pick) async {
    try {
      // IDEMPOTENT (a retry can arrive after a half-open attempt).
      await _sub?.cancel();
      _sub = null;
      final device = _attached[pick.id];
      if (device == null) {
        throw const BleRefusal('that USB device is gone - scan again');
      }
      final port = await device.create();
      if (port == null) {
        throw const BleRefusal('that USB device exposes no serial port');
      }
      final ok = await port.open();
      if (!ok) {
        await port.close();
        throw const BleRefusal('the USB port would not open');
      }
      await port.setPortParameters(
          _baud, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
      // The SDK SerialConnection's own line defaults (see header).
      await port.setDTR(true);
      await port.setRTS(false);
      _port = port;
      _name = pick.name;
      final stream = port.inputStream;
      if (stream != null) {
        _sub = stream.listen(
          _onBytes,
          onError: (_) => _handleGone('USB link dropped'),
          onDone: () => _handleGone('USB radio unplugged'),
        );
      }
    } catch (err) {
      await close();
      if (err is BleRefusal) rethrow;
      throw BleRefusal('USB connect failed: $err');
    }
  }

  void _onBytes(Uint8List chunk) {
    for (final payload in _framer.add(chunk)) {
      _incoming.add(payload);
    }
  }

  @override
  Future<String> ensurePaired() async =>
      ''; // USB needs no pairing - the symbol is a Bluetooth thing

  @override
  Future<void> write(Uint8List data) async {
    final port = _port;
    if (port == null) {
      throw const BleRefusal('not connected to the radio');
    }
    await port.write(companionFrameToRadio(data));
  }

  @override
  Future<void> close() async {
    final port = _port;
    _port = null; // set FIRST: our own close must not read as a drop
    await _sub?.cancel();
    _sub = null;
    try {
      await port?.close();
    } catch (_) {
      /* already gone */
    }
  }

  /// The radio dropped the link (not our own close()).
  void _handleGone(String why) {
    if (_port == null) return; // we caused it - stay quiet
    _port = null;
    _sub?.cancel();
    _sub = null;
    _onDisconnect?.call(why);
  }
}
