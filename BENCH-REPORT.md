# BENCH-REPORT.md - meshtech-app

## 2026-09-28: Mesh Clinic v2 bench pass (app v00.000.032 release APK)

Setup: release APK built (81.7MB) + installed on the Pixel. Hilltop
updated 060 -> 062 FIRST - clinic facts are born on the box, so an
old node would have shown an empty map.

PASS - CLINIC MAP VIEWS: the five chips (All facts / Node health /
Route health / Trouble flags / Second-hand) each draw only their own
family. Counts are LIVE: they grow as hilltop's rotating batches
arrive (<= 7 facts per packet), so numbers move between taps - that
is the feed filling, not facts dying (verified: no "without a place"
tail, no dots lost, 2 -> 9 -> 14 climbing). Trouble 0 + Second-hand 0
is honest with one box on the air - second-hand needs a second box.

PASS - TAP CARDS: tapping a clinic ring opens the card naming the
fact and its provenance ("first-hand box 2f25" - hilltop's own
measurement, its boot-random origin this session).

NOT TESTED - USB COMPANION LEG: companion radios are flashed for one
connection type; the bench Heltec is not a USB companion. Skipped by
agreement (Brett, 2026-09-28). Needs a radio flashed as a USB
companion before this leg can run.

Notes for next time:
- The pale route lines draw in EVERY view by design (the map's route
  memory); the chips filter only the clinic layer drawn on top.
- Two small lines stack under the chips: "N node(s) with positions"
  (steady) above "K clinic fact(s) drawn" (the chip's count) - easy
  to grab the wrong one when reading fast.
- Build note: usb_serial 0.5.2's Android build code is dead on
  Gradle 9 (jcenter + AGP 4.1). Patched LOCALLY in this PC's pub
  cache only (Brett's choice) - a fresh PC needs the same patch
  until the library is vendored or replaced.
