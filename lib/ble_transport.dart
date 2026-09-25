// The BLE transport seam: whatever CompanionLink talks through. Split
// from the plugin implementation so the companion protocol compiles
// (and is TESTED) on the VM - the same lesson as DoorSocket, applied
// to Bluetooth instead of the WebSocket. The real entrypoint supplies
// the flutter_blue_plus transport; tests supply a fake.

import 'dart:typed_data';

/// One BLE link to a companion radio (Nordic UART service).
abstract class BleTransport {
  /// Raw notifications from the radio (one notification = one call;
  /// the protocol layer reassembles).
  Stream<Uint8List> get incoming;

  /// Called when the radio drops the link (plain-words reason).
  set onDisconnect(void Function(String why) f);

  /// The radio's advertised name ("" until connected).
  String get name;

  /// Scan for the companion, connect, discover, subscribe.
  /// Throws plain words on failure ("no companion radio found").
  Future<void> connect();

  /// One command frame to the radio (the companion protocol's bare
  /// [type][data] shape - NO length prefix, per the live-link lesson).
  Future<void> write(Uint8List data);

  Future<void> close();
}

/// A plain-words refusal: the transport could not bring up a link and
/// says why without stack noise ("Bluetooth is off", "no radio found").
/// The link surfaces `why` verbatim in the state detail and the log.
class BleRefusal implements Exception {
  final String why;
  const BleRefusal(this.why);
  @override
  String toString() => why;
}

/// Creates the platform transport (wired in main.dart).
typedef BleTransportFactory = BleTransport Function();
