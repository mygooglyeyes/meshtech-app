// The REAL transport for the network carrier (the WiFi chip): a
// companion radio found over the network - the SAME companion
// protocol as BLE and USB, wrapped in the stream framing (the
// MeshCore SDK tcp_cx.py rules, companion_framing.dart).
//
// This is the shape the bench already runs: the plugin's own client
// dials the repeater's companion frame server over TCP
// (meshtech-plugin core/client.py: "Connects to the repeater's
// companion frame server over TCP" via MeshCore.create_tcp). The
// address is what the human typed ('host' or 'host:port'); the port
// defaults to 5000 - the frame server's own default AND the bench's
// 'repeater's tcp_port' (hilltop-config.yaml connection.port).
//
// A network companion is found by ADDRESS, not by sniffing: scan()
// honestly offers the one address configured - no fake discovery.
// Mechanics only - the protocol lives in companion_protocol.dart and
// is tested on the VM through the seam.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'ble_transport.dart';
import 'companion_framing.dart';

class IoWifiTransport implements BleTransport {
  /// The repeater's companion frame server port (frame_server.py
  /// default; hilltop-config.yaml connection.port on the bench).
  static const defaultPort = 5000;

  final String address; // 'host' or 'host:port'
  final Duration connectTimeout;

  IoWifiTransport(this.address,
      {this.connectTimeout = const Duration(seconds: 8)});

  final _incoming = StreamController<Uint8List>.broadcast();
  final _framer = CompanionStreamFramer();
  void Function(String why)? _onDisconnect;
  Socket? _socket;
  String _name = '';

  (String, int) get _dial {
    final parts = address.split(':');
    final host = parts[0].trim();
    final port = parts.length > 1
        ? (int.tryParse(parts[1].trim()) ?? defaultPort)
        : defaultPort;
    return (host, port);
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  set onDisconnect(void Function(String why) f) => _onDisconnect = f;

  @override
  String get name => _name;

  @override
  Future<List<BleCandidate>> scan(
      {Duration timeout = const Duration(seconds: 5)}) async {
    final (host, port) = _dial;
    if (host.isEmpty) {
      throw const BleRefusal('no companion address to dial');
    }
    // Honest: ONE candidate - the address the human typed. Whether
    // anything answers is connect()'s truth to tell, never scan's.
    return [BleCandidate('$host:$port', 'companion at $host:$port')];
  }

  @override
  Future<void> connect(BleCandidate pick) async {
    try {
      final (host, port) = _dial;
      final socket =
          await Socket.connect(host, port, timeout: connectTimeout);
      socket.listen(
        _onBytes,
        onError: (_) => _handleGone('companion link lost'),
        onDone: () => _handleGone('companion closed the link'),
      );
      _socket = socket;
      _name = pick.name;
    } catch (err) {
      await close();
      throw BleRefusal('no companion at ${pick.name}: $err');
    }
  }

  void _onBytes(Uint8List chunk) {
    for (final payload in _framer.add(chunk)) {
      _incoming.add(payload);
    }
  }

  @override
  Future<String> ensurePaired() async =>
      ''; // network needs no pairing - the symbol is a Bluetooth thing

  @override
  Future<void> write(Uint8List data) async {
    final socket = _socket;
    if (socket == null) {
      throw const BleRefusal('not connected to the radio');
    }
    socket.add(companionFrameToRadio(data));
    await socket.flush(); // a write error surfaces here, never silently
  }

  @override
  Future<void> close() async {
    final socket = _socket;
    _socket = null; // set FIRST: our own close must not read as a drop
    try {
      socket?.destroy();
    } catch (_) {
      /* already gone */
    }
  }

  /// The radio dropped the link (not our own close()).
  void _handleGone(String why) {
    if (_socket == null) return; // we caused it - stay quiet
    _socket = null;
    _onDisconnect?.call(why);
  }
}
