// The native (Android/desktop) door socket: dart:io's WebSocket speaks
// the SAME wire the browser one does - same URL, same bearer.<token>
// subprotocol, same JSON frames. Without this the Android build ships
// only the honest stub (found on the bench 2026-09-24: the stub made
// Connect hang on "Connecting..." with nothing logged - also fixed;
// a missing socket now refuses in plain words).

import 'dart:async';
import 'dart:io';

import 'door_socket.dart';

class IoDoorSocket implements DoorSocket {
  @override
  void Function()? onOpen;
  @override
  void Function(String raw)? onMessage;
  @override
  void Function(int code, bool clean)? onClose;

  WebSocket? _ws;
  StreamSubscription<Object?>? _sub;

  @override
  void open(String url, List<String>? protocols) {
    _dial(url, protocols);
  }

  Future<void> _dial(String url, List<String>? protocols) async {
    try {
      final ws = await WebSocket.connect(url, protocols: protocols);
      _ws = ws;
      onOpen?.call();
      _sub = ws.listen(
        (Object? data) {
          if (data is String) onMessage?.call(data);
        },
        onDone: () {
          onClose?.call(ws.closeCode ?? 1006, false);
        },
        onError: (Object _) {
          onClose?.call(1006, false);
        },
      );
    } catch (_) {
      // Dial failed (unreachable host, refused, wrong port): the link
      // hears the close and reports it in plain words.
      onClose?.call(1006, false);
    }
  }

  @override
  void send(String data) {
    _ws?.add(data);
  }

  @override
  void close() {
    _sub?.cancel();
    _ws?.close();
    _ws = null;
  }
}
