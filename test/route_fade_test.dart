// Route fade tests (Brett's law, 2026-09-24): the phone's route list
// colors and drops follow the same lines the server enforces -
// DIRECT silent 3 days = STALE (yellow), 7 days dead; MULTI-HOP 7/14.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshtech_app/codec.dart';
import 'package:meshtech_app/store.dart';

Route _route({required int routeId, required List<int> prefixes,
    required int lastHeardMin, int delayMedS = 12}) =>
    Route(
        seq: 1,
        sectionId: 5,
        routeId: routeId,
        packetCount: 4,
        delayMedS: delayMedS,
        lastHeardMin: lastHeardMin,
        prefixes: prefixes);

void main() {
  test('the dead lines drop exactly at 7 days (direct) / 14 (multi-hop)',
      () {
    final s = NodeStore();
    // direct, 7 days + 1 min: dead
    s.applyRoute(_route(routeId: 1, prefixes: [0x11],
        lastHeardMin: NodeStore.directDeadAfterMin + 1));
    // direct, exactly 7 days - 1 min: still under the line, kept
    s.applyRoute(_route(routeId: 2, prefixes: [0x12],
        lastHeardMin: NodeStore.directDeadAfterMin - 1));
    // multi-hop, exactly 14 days - 1 min: kept (14 = the line, > drops)
    s.applyRoute(_route(routeId: 3, prefixes: [0x13, 0x14],
        lastHeardMin: NodeStore.multihopDeadAfterMin - 1));
    expect(s.route(1), isNull);
    expect(s.route(2), isNotNull);
    expect(s.route(3), isNotNull);
  });

  test('routeIsDirect: one hop on the wire = the direct kind', () {
    expect(NodeStore.routeIsDirect(_route(routeId: 1, prefixes: [0x11],
        lastHeardMin: 1)), isTrue);
    expect(NodeStore.routeIsDirect(_route(routeId: 2, prefixes: [0x11, 0x22],
        lastHeardMin: 1)), isFalse);
  });
}
