// The browser implementation of DoorSocket (Flutter web / any JS
// engine). Isolated here so nothing else in the app imports package:web
// and the protocol code stays testable on the VM.
//
// NOTE (honest build status): the package:web interop below targets
// dart2js/dart2wasm (dart:js_interop). `flutter analyze` on this
// machine runs the VM-side analysis and flags the JS interop getters;
// a web build compiles them. The Android app does NOT use this file
// (Android rides the BLE companion, not the door) - it is kept for
// the bench-testable web build. If Android-only builds ever complain,
// this file is excluded by the build, not by edits here.

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'door_socket.dart';

class WebDoorSocket implements DoorSocket {
  web.WebSocket? _ws;
  void Function()? _onOpen;
  void Function(String raw)? _onMessage;
  void Function(int code, bool clean)? _onClose;

  @override
  set onOpen(void Function() f) => _onOpen = f;

  @override
  set onMessage(void Function(String raw) f) => _onMessage = f;

  @override
  set onClose(void Function(int code, bool clean) f) => _onClose = f;

  @override
  void open(String url, List<String>? protocols) {
    _ws = web.WebSocket(url,
        (protocols ?? []).map((p) => p.toJS).toList().toJS);
    _ws!.onopen = ((web.Event _) => _onOpen?.call()).toJS;
    _ws!.onmessage = ((web.MessageEvent e) =>
        _onMessage?.call((e.data as JSString).toDart)).toJS;
    _ws!.onclose = ((web.CloseEvent e) =>
        _onClose?.call(e.code, e.wasClean)).toJS;
    _ws!.onerror = ((web.Event _) {}).toJS;
  }

  @override
  void send(String data) => _ws?.send(data.toJS);

  @override
  void close() {
    try {
      _ws?.close();
    } catch (_) {}
  }
}
