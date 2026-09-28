// The network companion carrier (the WiFi chip) against a real
// loopback socket: the framing goes out as the SDK's '<' bytes, the
// radio's '>' frames come back bare to the protocol, a dropped link
// says so in plain words - and a dead address refuses, never hangs.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/ble_transport.dart';
import 'package:meshtech_app/io_wifi_transport.dart';

void main() {
  group('the network companion carrier (WiFi chip)', () {
    test('scan offers the typed address; the link speaks the SDK '
        'framing both ways and reports a drop', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = <int>[];
      Socket? peer;
      server.listen((s) {
        peer = s;
        s.listen(received.addAll);
      });

      final t = IoWifiTransport('127.0.0.1:${server.port}');
      final dropped = Completer<String>();
      t.onDisconnect = dropped.complete;

      // Honest scan: ONE candidate - the address the human typed.
      final found = await t.scan();
      expect(found.length, 1);
      expect(found.single.name, 'companion at 127.0.0.1:${server.port}');

      await t.connect(found.single);
      expect(t.name, 'companion at 127.0.0.1:${server.port}');

      // Out: bare command in, framed bytes on the wire ('<' + LE len).
      await t.write(Uint8List.fromList([0x01, 0x02]));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, [0x3C, 0x02, 0x00, 0x01, 0x02]);

      // In: the radio's '>'-framed answer arrives BARE at the seam.
      final payload = Completer<Uint8List>();
      final sub = t.incoming.listen(payload.complete);
      peer!.add([0x3E, 0x02, 0x00, 0xAA, 0xBB]);
      expect(await payload.future.timeout(const Duration(seconds: 2)),
          [0xAA, 0xBB]);

      // The radio drops the link: said in plain words, never silent.
      peer!.destroy();
      final why = await dropped.future.timeout(const Duration(seconds: 2));
      expect(why, isNotEmpty);

      await sub.cancel();
      await t.close();
      await server.close();
    });

    test('a dead address refuses in plain words - never a hang', () async {
      final t = IoWifiTransport('127.0.0.1:1',
          connectTimeout: const Duration(seconds: 2));
      final found = await t.scan();
      await expectLater(t.connect(found.single), throwsA(isA<BleRefusal>()));
    });

    test('no address is an honest refusal', () async {
      final t = IoWifiTransport('');
      await expectLater(t.scan(), throwsA(isA<BleRefusal>()));
    });

    test('the port default is the frame server\'s own (5000)', () {
      expect(IoWifiTransport.defaultPort, 5000);
    });
  });
}
