// The native (Android/desktop) entrypoint: the app shell with a REAL
// dart:io door socket - the bench transport that talks to hilltop's
// data door exactly like the web app did (same URL shape, same
// bearer.<password> subprotocol). The BLE companion link (the MAIN
// feature) is the inert honest slot until Brett's hardware go.

import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'io_door_socket.dart';

void main() {
  runApp(const MeshtechApp(socketFactory: IoDoorSocket.new));
}
