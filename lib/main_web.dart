// The web entrypoint: the app shell + the browser door socket.
// (Android's entrypoint passes its own factory or none - Android
// rides the BLE companion, not the door.)

import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'web_door_socket.dart';

void main() {
  runApp(const MeshtechApp(socketFactory: WebDoorSocket.new));
}
