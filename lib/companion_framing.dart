// The stream carriers' framing (USB serial + network WiFi): the
// MeshCore companion protocol's own frame delimiters, verified
// against the reference - meshcore SDK serial_cx.py / tcp_cx.py and
// openhop_core companion/constants.py - never re-derived from
// memory:
//
//   app   -> radio: '<' (0x3C) + 2-byte LE length + data
//   radio -> app : '>' (0x3E) + 2-byte LE length + data
//
// BLE stays BARE (Nordic UART notifications bound the frames - the
// proven live path). These two carriers are byte STREAMS, so they
// wrap. Some radios interleave console/debug text on the same UART,
// so the reader SKIPS junk to the next frame marker (the SDK
// reader's own rule) and refuses absurd sizes instead of trusting
// them - then resyncs, never guesses.

import 'dart:typed_data';

const int frameInboundPrefix = 0x3C; // '<' - app -> radio
const int frameOutboundPrefix = 0x3E; // '>' - radio -> app

// writeFrame() refuses to send past MAX_FRAME_SIZE (172) and a frame
// is prefix(1) + len(2) + payload - so a command payload is at most
// 169 bytes (openhop_core companion/constants.py MAX_PAYLOAD_SIZE).
const int maxFramePayload = 169;

// The SDK reader's invalid-size line (serial_cx.py): a length past
// this is junk on the wire, not a frame - drop the marker and resync.
const int frameSizeSanity = 300;

/// Wrap one command for the radio: '<' + 2-byte LE length + data.
/// Refuses to mint a frame the wire could not carry - loudly.
Uint8List companionFrameToRadio(List<int> data) {
  if (data.length > maxFramePayload) {
    throw ArgumentError(
        'companion frame too long: ${data.length} B > $maxFramePayload B');
  }
  final out = Uint8List(3 + data.length);
  out[0] = frameInboundPrefix;
  out[1] = data.length & 0xff;
  out[2] = (data.length >> 8) & 0xff;
  out.setRange(3, out.length, data);
  return out;
}

/// Reassembles '>'-framed payloads out of a byte stream - the SDK
/// reader's exact behavior: junk before a marker is console noise and
/// is dropped, split frames wait for their tail, absurd sizes resync.
class CompanionStreamFramer {
  Uint8List _buf = Uint8List(0);

  /// Feed one received chunk; get back every COMPLETE payload it
  /// finished. (Zero-length frames carry no response code and would
  /// break the protocol reader downstream - skipped, loudly not
  /// needed.)
  List<Uint8List> add(Uint8List chunk) {
    final merged = Uint8List(_buf.length + chunk.length);
    merged.setAll(0, _buf);
    merged.setAll(_buf.length, chunk);
    _buf = merged;
    final out = <Uint8List>[];
    while (true) {
      // Find the start of frame; junk before it is not ours.
      var start = -1;
      for (var i = 0; i < _buf.length; i++) {
        if (_buf[i] == frameOutboundPrefix) {
          start = i;
          break;
        }
      }
      if (start < 0) {
        _buf = Uint8List(0); // nothing but junk: drop it
        return out;
      }
      if (start > 0) {
        _buf = Uint8List.sublistView(_buf, start);
      }
      if (_buf.length < 3) return out; // header split - wait
      final size = _buf[1] | (_buf[2] << 8);
      if (size > frameSizeSanity) {
        // Invalid size: this marker was junk. Drop just the marker
        // and rescan the rest (the SDK reader's resync).
        _buf = Uint8List.sublistView(_buf, 1);
        continue;
      }
      if (_buf.length < 3 + size) return out; // body split - wait
      final payload = Uint8List.fromList(_buf.sublist(3, 3 + size));
      _buf = Uint8List.sublistView(_buf, 3 + size);
      if (payload.isNotEmpty) out.add(payload);
    }
  }
}
