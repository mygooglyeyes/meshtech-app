# meshtech-app - TODOS (order matters, top first)

## QUEUED (Brett, 2026-09-24, "one todo later"): STALE NODES PACKET
A packet telling the phone which nodes the SERVER has not heard from
in 14 days (the server's stale line) -> the phone turns those dots
YELLOW. Server knows (STALE_AFTER_S already exists); wire packet +
phone rendering to design when Brett pulls the queue item.

## DONE - VECTORED SYNC BUILT (2026-09-24, Brett said "correct"):
## BOTH SIDES, TESTS FIRST, SUITES GREEN - NOT COMMITTED (his OK
## needed per rule zero)
SERVER (meshtech-node, uncommitted): migration 2 (nodes.change_seq,
sync_state counter table, gone_pending) - counter monotonic across
restarts, backfill = first ask after upgrade is one full roster;
bump lives ONLY in _disk_node (real fact changes bump, re-heard
silence does not); supersede + prune queue gone; codec v1.6
PER-PACKET versioning (only REFRESH_REQ + new TYPE_GONE 0x5312
declare 0x06 - the old web app's decoder never sees an unknown
version; this DEVIATION from the doc's global bump is Brett's own
"old web app keeps working unchanged" law); vectored answer =
change-filtered INTRO + GONE packets (cleared only after the burst
sends); marker 0 = today's behavior byte-for-byte. Suite: 282
passed + 6 skipped (11 new vectored tests; golden refresh vector
regenerated - version 06, +2 bytes).
PHONE (meshtech-app, uncommitted): Dart codec speaks v1.6 (marker
encode/decode, GONE type, per-packet version) - golden vectors
re-pinned, byte-identical with the server's regenerated set. Suite:
14 all green. NEXT (step 2, awaiting his go): connect screen +
companion link; the marker rides the app's asks once it connects.
HONEST NOTE: design doc said "marker 0 = byte-identical old
behavior" - true on DECODE (old packets decode fine); ENCODE always
carries the current version. Tests state it that way.

## DONE - BUILD STEP 1 (2026-09-24, Brett said "correct"): DART WIRE
## CODEC PROVEN AGAINST THE GOLDEN VECTORS
lib/codec.dart: faithful port of the reference codec.py (via the
TypeScript sibling) - all 7 packet types, v1.2 1-based sections,
v1.3 span_km, v1.5 INTRO-carried span, strict loud rejections
(unknown version, section 0, truncation, unknown type), same
decode-BODY contract as the reference (encode* returns full
plaintext, decode* takes the stripped body - decodeAny strips).
test/codec_test.dart: the SAME SIX golden vectors as the node repo
(tests/golden_vectors.json), each decoded -> fields asserted ->
re-encoded -> BYTE-IDENTICAL pin, plus boundary tests. Suite: 13
codec tests + skeleton smoke = ALL GREEN. Honest port note: Dart
rounds halves away from zero, Python to-even - golden vectors never
hit a .5 and roundtrip is FP-stable; noted in code. NEXT (design
step 2, needs Brett's go): connect screen + companion/BLE link
shape; the vectored-sync server-side design doc still owes Brett a
line-by-line review before any server code.

## LIVE PACKET TRAILS (Brett, 2026-09-24): in DESIGN.md section 11
Every live packet drawn as a comet trail - a line dot-to-dot along
the path, leading end travels, tail slowly vanishes; dissolve speed
tuned at the bench. Drawn on ANY map size the user views (geography,
not grid). Sources: hilltop's feed AND the companion's own listening
(packets originating/ending at nodes the phone holds). BRETT ALSO
EDITED THE DOC HIMSELF (his save wins): TCP "never live" line
deleted (live TCP no longer forbidden forever), iPhone build "yet".
Re-applied only what his save was missing (v4 header).

## VECTORED SYNC (Brett's design, 2026-09-24): DECIDED + in DESIGN.md
## section 10 - server-side design doc comes BEFORE any server code
His pick with the caveat: routes ON-DEMAND over the air (tap = ask
= answer, day-one TX), and the INITIAL TCP download after map
location + size selection carries the database's route data with
everything else - phone starts full, the air carries only changes.
Marker = disk-saved change counter (never clock); "node gone"
events; phone persists its marker; version-gated wire so the old
web app keeps working. Review verdict delivered as asked (sound
logic, 3 flaws handled). NEXT when he says go: the small server-side
design (counter at the disk choke point, marker ask/answer packet
shape, gone-event shape) for his line-by-line OK before any code.

## WAITING ON BRETT (v3 design 2026-09-24):
1. Verify DESIGN.md (v3) line by line -> say "correct" -> step 1
   (Dart codec vs golden vectors) starts.
v3 additions: real maps under the dots - ENGINE VERIFIED FROM
waev:outpost SOURCE (Brett supplied C:\projects\waev-outpost-plugin-main):
MapLibre GL + CARTO basemaps (Dark Matter); our app uses the
maplibre_gl Flutter plugin (same native engine) + offline region
pack for the home area downloaded while online. FIRST-RUN FLOW
(Brett, final 2026-09-24): first run assumes internet (the app can
only be installed online anyway) - ZIP -> download home-area
basemap once -> saved as hard data on the phone. The offline
first-run branch and the bundled ZIP table are DELETED - invented
flows he never asked for. LESSON recorded: add NOTHING Brett did
not ask for; a silent spot in the design = ask him, never invent.
Build order locked: OTA-first, tested by TCP download
until Brett's TX go. CORRECTION (Brett, 2026-09-24): the companion
is the app's MAIN feature - established at app start, the phone's
eys AND voice; phone TX (update asks over the air) is day-one
behavior, NOT excluded; the "no TX from the phone" line is deleted.
First-run ZIP + server download = setup, never the center.
v2 in one breath: the app is OTA-first (companion radio -> BLE ->
phone); TCP is a DOWNLOAD of map + node database for offline use,
never a live link; map size is picked BEFORE connect, lives on the
connect screen; changing size redraws ONLY (never asks hilltop,
spends nothing); the app translates any held data to the chosen
size (wire packets carry their true span; the app re-cuts the grid
itself); the phone keeps its OWN store and new OTA data lands in it
- the map updates live from the store as packets arrive (Brett's
correction 2026-09-24). TWO MORE BRETT RULES (2026-09-24): an update
REPLACES the old facts - one node = one dot, a moved node never
draws twice; node NAMES show on the map in every screen - name +
first 1/2/3 pubkey bytes matching the node's path-hash width.

## DONE (2026-09-24): toolkit + skeleton
- Flutter 3.47.5 / Dart 3.13.4 / Android SDK 36 green (flutter doctor).
- Project created: android-only, org com.meshtech, name meshtech_app.
- Brett's calls: web app chapter closed; app home = this folder;
  PC web server 8616 already stopped; hilltop data door untouched.
- v1 design (WiFi-live like the web app) DEAD same day - Brett's
  redirect: OTA-first, TCP = download-only, size before connect.
