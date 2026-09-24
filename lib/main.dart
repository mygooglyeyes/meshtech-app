// The default entrypoint (mobile/desktop): the app shell with the
// honest no-socket default - the Android app rides the BLE companion
// link (the MAIN feature), not the TCP door. The TCP link becomes
// available on Android when its entrypoint wires a dart:io socket
// implementation of DoorSocket.

import 'package:flutter/material.dart';

import 'app_shell.dart';

void main() {
  runApp(const MeshtechApp());
}
