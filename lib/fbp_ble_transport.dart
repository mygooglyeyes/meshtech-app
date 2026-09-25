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
  Future<void> connect() async {
    try {
      if (!await FlutterBluePlus.isSupported) {
        throw const BleRefusal('this device has no Bluetooth');
      }
      final adapter = await FlutterBluePlus.adapterState.first;
      if (adapter != BluetoothAdapterState.on) {
        throw const BleRefusal('Bluetooth is off - turn it on first');
      }
      // Scan for the companion (filtered to the Nordic UART service
      // it advertises). Nothing found in 10 s = plain words.
      FlutterBluePlus.startScan(
          withServices: [_uartService],
          timeout: const Duration(seconds: 10));
      BluetoothDevice device;
      try {
        final batch = await FlutterBluePlus.scanResults
            .firstWhere((results) => results.isNotEmpty)
            .timeout(const Duration(seconds: 10));
        device = batch.first.device;
      } on TimeoutException {
        throw const BleRefusal('no companion radio found nearby');
      } finally {
        await FlutterBluePlus.stopScan();
      }
      // The library demands a license declaration at connect
      // (flutter_blue_plus 2.3.x). Brett's pick 2026-09-25:
      // nonprofit (the free tier - personal/nonprofit/education).
      // connect also negotiates a 512-byte MTU by itself (frames run
      // up to ~172 B; the default 23 truncates writes).
      await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 10));
      _device = device;
      _name = device.platformName.isEmpty
          ? 'companion radio'
          : device.platformName;
      final services = await device.discoverServices();
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
      _rxChar = rx;
      await tx.setNotifyValue(true);
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
