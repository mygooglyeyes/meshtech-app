// The door socket interface: whatever TcpLink dials through. Split
// from the browser implementation so the protocol logic compiles (and
// is TESTED) on the VM - the same stub-the-WebSocket lesson the web
// app's directclient.test.ts learned.

/// One WebSocket-like channel. Implementations: WebDoorSocket (the
/// browser/Flutter-web build) and test fakes.
abstract class DoorSocket {
  /// Called by TcpLink to assign its handlers BEFORE open().
  set onOpen(void Function() f);
  set onMessage(void Function(String raw) f);
  set onClose(void Function(int code, bool clean) f);

  void open(String url, List<String>? protocols);
  void send(String data);
  void close();
}

/// Creates the platform socket (wired in main.dart: WebDoorSocket.new).
typedef DoorSocketFactory = DoorSocket Function();
