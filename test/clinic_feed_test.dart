// The clinic through the ONE intake path (WireFeed): both pipes
// feed it, the receipt log names it in plain words, and it lands as
// a Clinic object for the store to fold - the same decode path every
// other packet takes (zero-dots law included, untouched here).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/wire_feed.dart';

// The node repo's golden clinic vector (tests/golden_vectors.json) -
// byte-parity is codec_test's job; here it is just real wire.
const _clinicHex =
    '14534f0513017eb10401147eb12103000500070080022514240410a6b09c0a02127eb102112238000002000400090011000200030c7eb1022102001e000500f401040fefbe0100000400d204040028000900';

Uint8List _bytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

void main() {
  test('a heard CLINIC packet is named in the receipt log and lands '
      'as a Clinic for the store', () {
    final packets = <Object>[];
    final log = <String>[];
    final feed = WireFeed(
        pipe: 'air',
        onPacket: (packet, {heardMs}) => packets.add(packet),
        onLog: log.add);

    feed.feed(_bytes(_clinicHex));

    expect(packets, hasLength(1));
    final clinic = packets.single as Clinic;
    expect(clinic.origin, 0xb17e);
    expect(clinic.records, hasLength(4));
    // The receipt speaks plain words (Brett's honest-receipt law).
    expect(log, ['air <- clinic (4 fact(s))']);
  });
}
