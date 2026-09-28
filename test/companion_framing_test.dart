// The stream carriers' framing (USB serial + network WiFi): pinned
// to the MeshCore SDK's own bytes (serial_cx.py send() = '<' + 2-byte
// LE length + data; handle_rx = '>'-marker search, junk skip, size
// sanity). A byte that disagrees with the SDK never ships.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/companion_framing.dart';

void main() {
  group('companionFrameToRadio (app -> radio)', () {
    test("wraps '<' + 2-byte LE length + data - the SDK's send shape", () {
      expect(companionFrameToRadio([0x01, 0x02, 0x03]),
          [0x3C, 0x03, 0x00, 0x01, 0x02, 0x03]);
    });

    test('the length is little-endian at the 169-byte payload cap', () {
      final wire = companionFrameToRadio(List.filled(169, 7));
      expect(wire.length, 3 + 169);
      expect(wire[0], 0x3C);
      expect((wire[1], wire[2]), (169, 0)); // 0x00A9 LE
    });

    test('refuses to mint a frame the wire could not carry', () {
      // writeFrame() refuses past MAX_FRAME_SIZE (172) and a frame is
      // prefix(1) + len(2) + payload - so 170 B of payload is out.
      expect(() => companionFrameToRadio(List.filled(170, 0)),
          throwsArgumentError);
    });
  });

  group('CompanionStreamFramer (radio -> app)', () {
    test('one frame in one chunk comes out bare', () {
      final f = CompanionStreamFramer();
      expect(f.add(Uint8List.fromList([0x3E, 0x02, 0x00, 0xAA, 0xBB])), [
        [0xAA, 0xBB]
      ]);
    });

    test('a frame split across chunks waits for its tail', () {
      final f = CompanionStreamFramer();
      expect(f.add(Uint8List.fromList([0x3E, 0x02])), isEmpty);
      expect(f.add(Uint8List.fromList([0x00, 0xAA])), isEmpty);
      expect(f.add(Uint8List.fromList([0xBB])), [
        [0xAA, 0xBB]
      ]);
    });

    test('two frames in one chunk come out in order', () {
      final f = CompanionStreamFramer();
      expect(
          f.add(Uint8List.fromList(
              [0x3E, 0x01, 0x00, 0x11, 0x3E, 0x02, 0x00, 0x22, 0x33])), [
        [0x11],
        [0x22, 0x33]
      ]);
    });

    test('console noise before a marker is dropped (the SDK rule)', () {
      final f = CompanionStreamFramer();
      // 'Hel' = radio console text, then a real frame.
      expect(f.add(Uint8List.fromList([0x48, 0x65, 0x6C, 0x3E, 0x01, 0x00, 0x99])), [
        [0x99]
      ]);
    });

    test('an absurd size resyncs at the next marker, never guesses', () {
      final f = CompanionStreamFramer();
      // First marker claims 500 bytes (past the sanity line): junk.
      // The NEXT marker is a real 1-byte frame.
      expect(
          f.add(Uint8List.fromList(
              [0x3E, 0xF4, 0x01, 0x3E, 0x01, 0x00, 0x77])), [
        [0x77]
      ]);
    });

    test('a zero-length frame carries no code and is skipped', () {
      final f = CompanionStreamFramer();
      expect(f.add(Uint8List.fromList([0x3E, 0x00, 0x00, 0x3E, 0x01, 0x00, 0x42])), [
        [0x42]
      ]);
    });

    test('a bare partial header keeps waiting', () {
      final f = CompanionStreamFramer();
      expect(f.add(Uint8List.fromList([0x3E])), isEmpty);
      expect(f.add(Uint8List(0)), isEmpty);
      expect(f.add(Uint8List.fromList([0x04, 0x00, 1, 2, 3, 4])), [
        [1, 2, 3, 4]
      ]);
    });
  });
}
