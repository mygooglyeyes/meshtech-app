// The REAL BleTransport for the native build: flutter_blue_plus over
// the Nordic UART service - the same service/characteristics the
// VERIFIED web client used (meshtech-phone meshclient.ts: service
// 6e400001, notify 6e400003 radio->phone, write 6e400002 phone->radio).
//
// This file holds ONLY transport mechanics (scan/connect/notify/
// write). The companion protocol itself lives in
// companion_protocol.dart and is tested on the VM through the
// BleTransport seam - the DoorSocket lesson applied to Bluetooth.
// No BLE at all (wrong platform, emulator, permission refused) is a
// BleRefusal in plain words, never a hang.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_transport.dart';

class FbpBleTransport implements BleTransport {
  // Nordic UART service (verified against the MeshCore BLE SDK).
  // Guid's constructor is not const - these are final.
  static final _uartService =
      Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  static final _uartTx =
      Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e'); // radio -> phone
  static final _uartRx =
      Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e'); // phone -> radio

  final _incoming = StreamController<Uint8List>.broadcast();
  void Function(String why)? _onDisconnect;
  BluetoothDevice? _device;
  final Map<String, BluetoothDevice> _nearby = {}; // scan results by id
  BluetoothCharacteristic? _rxChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
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
      if (!await FlutterBluePlus.isSupported) {
        throw const BleRefusal('this device has no Bluetooth');
      }
      final adapter = await FlutterBluePlus.adapterState.first;
      if (adapter != BluetoothAdapterState.on) {
        throw const BleRefusal('Bluetooth is off - turn it on first');
      }
      // Scan the Nordic-UART service only. The first scan also pops
      // Android's Nearby-devices permission box (once per install) -
      // so wait for scanning to actually START (the grant) before
      // counting the collection window; a never-started scan means
      // the permission was not granted, and says so.
      final found = <String, BleCandidate>{};
      _nearby.clear();
      final sub = FlutterBluePlus.scanResults.listen((batch) {
        for (final r in batch) {
          final id = r.device.remoteId.str;
          final name = r.device.platformName.isEmpty
              ? 'unnamed radio'
              : r.device.platformName;
          found[id] = BleCandidate(id, name);
          _nearby[id] = r.device;
        }
      });
      try {
        FlutterBluePlus.startScan(
                withServices: [_uartService], timeout: timeout)
            .catchError((_) {}); // failure shows up as an empty list
        try {
          await FlutterBluePlus.isScanning
              .where((s) => s)
              .first
              .timeout(timeout);
        } on TimeoutException {
          throw const BleRefusal(
              'Bluetooth permission not granted - allow Nearby devices, then Connect again');
        }
        await Future<void>.delayed(timeout);
      } finally {
        await FlutterBluePlus.stopScan();
        await sub.cancel();
      }
      return found.values.toList(growable: false);
    } catch (err) {
      if (err is BleRefusal) rethrow;
      throw BleRefusal('scan failed: $err');
    }
  }

  @override
  Future<void> connect(BleCandidate pick) async {
    try {
      // IDEMPOTENT (the pairing-bounce retry): a retry can arrive
      // while listeners from a half-open attempt are still wired -
      // cancel them first or notifications double-fire.
      await _notifySub?.cancel();
      _notifySub = null;
      await _connSub?.cancel();
      _connSub = null;
      final device = _nearby[pick.id];
      if (device == null) {
        throw const BleRefusal('that radio is no longer nearby - scan again');
      }
      // The library demands a license declaration at connect
      // (flutter_blue_plus 2.3.x). Brett's pick 2026-09-25:
      // nonprofit (the free tier - personal/nonprofit/education).
      // connect also negotiates a 512-byte MTU by itself (frames run
      // up to ~172 B; the default 23 truncates writes).
      //
      // PATIENT THROUGH THE PAIRING BOX (Brett's bench 2026-09-25):
      // a brand-new association pops Android's PIN dialog, which
      // waits for a HUMAN to type - our old 10 s timeout aborted
      // mid-entry ("seemed to fail"). A minute gives the PIN box
      // room; the retry helper below does the same for the steps
      // that follow, which block while the pairing runs.
      await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 60));
      _device = device;
      _name = pick.name;
      final services = await _patient(() => device.discoverServices());
      BluetoothService? uart;
      for (final s in services) {
        if (s.uuid == _uartService) uart = s;
      }
      if (uart == null) {
        throw const BleRefusal('found a radio without the UART service');
      }
      BluetoothCharacteristic? tx, rx;
      for (final c in uart.characteristics) {
        if (c.uuid == _uartTx) tx = c;
        if (c.uuid == _uartRx) rx = c;
      }
      if (tx == null || rx == null) {
        throw const BleRefusal('UART service is missing its channels');
      }
      final notifier = tx; // final for the closure (tx is nullable)
      _rxChar = rx;
      await _patient(() => notifier.setNotifyValue(true));
      _notifySub = tx.onValueReceived.listen(
        (data) => _incoming.add(Uint8List.fromList(data)),
        onError: (_) => _notifySub?.cancel(),
      );
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _handleGone('radio disconnected');
        }
      });
    } catch (err) {
      await close();
      if (err is BleRefusal) rethrow;
      // A plugin exception is jargon - name it in plain words.
      throw BleRefusal('radio connect failed: $err');
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    final rx = _rxChar;
    if (rx == null) {
      throw const BleRefusal('not connected to the radio');
    }
    // With response - the companion's proven command path (the web
    // client's characteristic.writeValue).
    await rx.write(data);
  }

  /// Patient through the pairing box: steps that follow a connect
  /// can block or refuse while Android's PIN dialog waits for a
  /// human (bench 2026-09-25). Retry until [window] runs out instead
  /// of failing on the first refusal - then say so in plain words,
  /// naming the PIN box as the likely suspect.
  Future<T> _patient<T>(
    Future<T> Function() op, {
    Duration window = const Duration(seconds: 60),
    Duration pause = const Duration(milliseconds: 500),
  }) async {
    final deadline = DateTime.now().add(window);
    while (true) {
      try {
        return await op();
      } catch (err) {
        if (err is BleRefusal || DateTime.now().isAfter(deadline)) {
          if (err is BleRefusal) rethrow;
          throw BleRefusal(
              'radio did not finish coming up: $err - if a PIN box'
              ' appeared, enter the PIN and press Connect again');
        }
        await Future<void>.delayed(pause);
      }
    }
  }

  @override
  Future<void> close() async {
    final device = _device;
    _device = null; // set FIRST: our own disconnect must not read as
    _rxChar = null; // the radio dropping us
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    try {
      await device?.disconnect();
    } catch (_) {
      /* already gone */
    }
  }

  /// The radio dropped the link (not our own close()).
  void _handleGone(String why) {
    if (_device == null) return; // we caused it - stay quiet
    _device = null;
    _rxChar = null;
    _notifySub?.cancel();
    _notifySub = null;
    _connSub?.cancel();
    _connSub = null;
    _onDisconnect?.call(why);
  }
}
