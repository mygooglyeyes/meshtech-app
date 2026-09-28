# meshtech-app

The phone half of the meshtech mesh — one map that shows what the
mesh knows, honestly.

- ONE MAP: nodes and routes heard over the air, drawn where the
  packets place them. Gaps show as gaps — a place is never invented.
- MESH CLINIC (v00.000.032): a simple health layer on top — every
  fact colored by its state (fresh blue / aging yellow / trouble red
  / second-hand teal) and labeled FIRST-HAND or SECOND-HAND by who
  measured it (never merged — disagreement preserved). Five views on
  the one map: All facts / Node health / Route health / Trouble
  flags / Second-hand. Tap any clinic ring or line for its card.
- MEMORY: the map survives closing the app. Facts and routes are
  removed only by age (7/14 days) or a "gone" report.
- LINKS: the companion link is equal on BLE, USB and WiFi; the
  network door (TCP) is the classic path. Clinic facts ride any of
  them.

## Building and testing

    flutter test            # the law suite (165 tests)
    flutter analyze
    flutter build apk --release

## The shelf

- DESIGN.md — the design
- TODOS.md — chapter history (what shipped, in order)
- BENCH-REPORT.md — the bench passes and their honest gaps
- APK.md — getting the APK onto a phone

Version law: every push that changes code raises the version in
pubspec.yaml (00.000.0NN) — the web chip and updater tell the
truth through it.
