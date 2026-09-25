// The native (Android/desktop) entrypoint: the app shell with a REAL
// dart:io door socket (the bench transport that talks to hilltop's
// data door exactly like the web app did - same URL shape, same
// bearer.<password> subprotocol) and a REAL BLE transport (the
// companion radio link, the MAIN feature: scan -> connect -> protocol
// init -> 1s RX polling over the Nordic UART service).

import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'fbp_ble_transport.dart';
import 'io_door_socket.dart';

void main() {
  runApp(const MeshtechApp(
      socketFactory: IoDoorSocket.new, bleFactory: FbpBleTransport.new));
}
