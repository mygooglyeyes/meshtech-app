// The BLE transport seam: whatever CompanionLink talks through. Split
// from the plugin implementation so the companion protocol compiles
// (and is TESTED) on the VM - the same lesson as DoorSocket, applied
// to Bluetooth instead of the WebSocket. The real entrypoint supplies
// the flutter_blue_plus transport; tests supply a fake.

import 'dart:typed_data';

/// One radio found by a scan: what the human sees (name) and what
/// the link needs to dial it (id - the platform's remote id).
class BleCandidate {
  final String id;
  final String name;
  const BleCandidate(this.id, this.name);
}

/// One BLE link to a companion radio (Nordic UART service).
abstract class BleTransport {
  /// Raw notifications from the radio (one notification = one call;
  /// the protocol layer reassembles).
  Stream<Uint8List> get incoming;

  /// Called when the radio drops the link (plain-words reason).
  set onDisconnect(void Function(String why) f);

  /// The radio's advertised name ("" until connected).
  String get name;

  /// Scan for companions advertising the UART service. Returns every
  /// candidate heard within [timeout] (empty list = none nearby - the
  /// caller reports it in plain words, never a fake connect).
  Future<List<BleCandidate>> scan(
      {Duration timeout = const Duration(seconds: 5)});

  /// Connect to ONE candidate the caller chose from scan() - the
  /// picker's pick (Brett 2026-09-25: a box lists them, he selects).
  /// Throws plain words (BleRefusal) on failure.
  Future<void> connect(BleCandidate pick);

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
