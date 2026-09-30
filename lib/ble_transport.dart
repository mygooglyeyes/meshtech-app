// The companion transport seam: whatever CompanionLink talks
// through - and the companion link is EQUAL on BLE, USB serial and
// network WiFi (Mesh Clinic v2's law): the SAME protocol engine over
// three carriers, each a transport behind this seam. Split from the
// platform implementations so the companion protocol compiles (and
// is TESTED) on the VM - the same lesson as DoorSocket, applied to
// every carrier. The real entrypoint supplies the platform
// transports (fbp_ble_transport / io_usb_transport /
// io_wifi_transport); tests supply fakes.
//
// (The type keeps its BLE-era name so the seam stays one seam - the
// docs say carriers; the name is naming debt, not a wire fact.)

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

  /// Make sure the phone is PAIRED with the radio - the phone shows
  /// its own Bluetooth symbol only for a paired device (Brett,
  /// 2026-09-29). Returns a plain-words note ('' = nothing to
  /// report - pairing fine, or this carrier has no pairing). Never
  /// fatal: an unpaired link still works, the symbol just stays
  /// hidden.
  Future<String> ensurePaired();

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

/// Creates a NETWORK companion transport (the WiFi chip): it needs
/// the dial address the human typed ('host' or 'host:port').
typedef NetworkTransportFactory = BleTransport Function(String address);
