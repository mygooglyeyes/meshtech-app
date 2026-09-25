# meshtech-app - TODOS (order matters, top first)

## BUILT, UNCOMMITTED (2026-09-24, Brett's "correct" + additions): ROUTE
## FADE + NODE RED + ROUTE TIMING on the phone - 49 tests green, analyzer
## clean (same 5 map-leftover warnings as before). SERVER half (meshtech-
## node, version 00.000.046, 300 tests green): routes-on-disk (routes
## table in the same SQLite as nodes, written through at every hearing,
## refilled at boot), DIRECT routes now FORM (a packet heard with no
## repeaters = a one-hop route - the old code threw them away), the fade
## runs on the layout cadence: DIRECT silent 3d = stale, 7d = deleted;
## MULTI-HOP 7d/14d. A route row carries path, sender, is_direct,
## section heard in, count, median delay (honest origin stamps, 0 =
## unknown), last-heard. A route's death NEVER touches the node table.
PHONE SIDE: a node unheard 3 DAYS turns RED (heard again = regular
instantly, derived from age); a route silent past its stale line
(direct 3d / multi-hop 7d) lists YELLOW with a STALE tag in the
Routes tab; the route's MEASURED start-to-end time shows in the list
("time start-to-end: N s", "unknown" when the wire carried no honest
stamps); the store REFUSES a past-dead route answer (direct > 7d,
multi-hop > 14d). Analyzer note: browser_screen.dart now hides
Flutter's Navigator Route (same name clash app_shell already solved).
NEXT: bench-verify against hilltop after Brett's deploy word; queued
open-sequence chapter still waits for his go.

## PREVIOUSLY BUILT, UNCOMMITTED (2026-09-24, Brett's "routes next"): ROUTE
## LAYER + 3x4 VIEW GRID + SIZE BUTTONS - 44 tests green, analyzer clean
ROUTES (design section 10, tap = ask = answer): tapping a node's
label asks the SERVER section that node sits in (the wire's 3x3
frame, real geography); the answer (SECT_SUM + its top ROUTEs)
lands in the store and draws dot-to-dot in travel order.
Highlighted = the tapped section's routes (thick orange); faint =
the rest. HONEST GAPS: a route hop with an unknown/position-less
node SPLITS the line - drawn only between known ends, never
invented. Store: routes keyed by route_id, UPSERT-REPLACE (the
newest answer IS the route), RAM-only (bulk route history rides
the future TCP download). Flutter's Navigator Route hidden in
app_shell.dart - the wire's Route is the one that file means.
VIEW GRID: 3 wide x 4 tall (Brett's pick) cut on the VISIBLE
region (getVisibleRegion, rebuilt on camera events, epsilon ==),
count badges per cell, north-up flip verified by test (caught the
missing flip in counts).
SIZE BUTTONS: + = closer (60->40->20), - = farther, re-center on
home, REDRAW ONLY (rule 2), persisted.
STYLUS OFF in all three fields (Brett's call after the Gboard
fight).
NEXT: the queued open-sequence chapter (settings dialog + connect
box) waits for Brett's go; so does the map-center exploration.


## QUEUED (Brett, 2026-09-24, AFTER grid/routes): APP OPEN SEQUENCE
- FIRST RUN opens a "settings" dialog: TCP address (if available or
  known), ZIP code, map size, and the BLE/companion information -
  the COMPANION TYPE: BLE, WiFi, or USB.
- Save closes settings into a "connect" box holding the choices:
  a BIG 'companion' button (already highlighted), a TCP button, a
  "settings" button to edit, and a "Connect" button that uses the
  choices made in the connect box.
- Build order: grid/routes FIRST, then this - Brett said so. Not
  started.

## QUEUED (Brett, 2026-09-24): EXPLORE - WHAT CENTERS THE MAP
- Viability + necessity of the person's CURRENT LOCATION (phone
  position) as the map center vs centering on the SERVER NODE's
  location. Also open: coordinates instead of ZIP for the home
  area? Brett is unsure - needs a real explore + his decision
  (DESIGN.md section 9 says ZIP today; any change is HIS call).
- Nothing built until he picks.

## LESSON (2026-09-24, bench emulator): ADD NOTHING UNASKED - HE MEANS IT
Buffy flipped the virtual phone's hw.keyboard=yes (a PC-keyboard
convenience NOBODY asked for) - it made Gboard collapse to a
floating tab and wrecked the on-screen keyboard. Brett: "remove that
feature I never asked for". Undone (hw.keyboard=no, factory wipe);
the bench phone is stock. The rule is not just about app code - it
covers the whole toolchain. Also: Brett's approved logo lives in
C:\projects\visuals (logo-draft-2.svg) - read that folder's
CONTEXT before claiming anything about the logo.

## DONE - STEP 3 (2026-09-24, committed d2e9242 + pushed origin/dev):
## MAP SCREEN - analyzer clean, 34 tests green, DEBUG APK BUILDS
lib/map_model.dart: the map's view-model - one dot per positioned
node (no fix = no dot), stale = the 14-day line (fresh #4A90D9 /
stale #F5C518), section counts counted ON THE VIEW, labels = name
+ pubkey head (section 8).
lib/map_screen.dart: MapLibre 0.3.6 declarative layers, CARTO
Voyager daylight style, fresh + stale circle layers, text-label
markers, "N node(s) with positions - M stale" strip.
lib/app_shell.dart: shell lifted out of main.dart, injectable
socket factory (package:web stays quarantined in
web_door_socket.dart); lib/main.dart = Android entry,
lib/main_web.dart = web entry.
tests: map_model laws + shell smoke rewrite. Suite 34 all green.
BUILD FACTS: NDK 28.2.13676358 installed (android.exe sdk
install); gradle auto-added platform 35 + CMake 3.22.1; maplibre
0.3.6 applies ktlint UNVERSIONED (upstream bug #565, fix ships in
0.3.7 - not on pub.dev yet) -> pinned ktlint 14.2.0 in
android/settings.gradle.kts, drop the pin when 0.3.7 lands.
flutter build apk --debug = BUILT
(build\app\outputs\flutter-apk\app-debug.apk).
NEXT when Brett says go: routes/sections/health, or a first TCP
connect at the bench (APK is at
build\app\outputs\flutter-apk\app-debug.apk).

## DONE - STEP 2 (2026-09-24, committed 5b7d483 + pushed): CONNECT
## SCREEN + LINK LAYER - flutter test 29 ALL GREEN
lib/settings.dart: persisted settings (address, password, MAP SIZE
chosen before connect, client origin minted once, sync marker).
lib/store.dart: the phone's own store - upsert REPLACES (one node =
one dot, moved node never twins), unknown-never-overwrites-known on
INTRO merge, GONE removal, honest lastHeardMs ages, name + pubkey-
head labels (section 8), persisted across restarts.
lib/grid.dart: the re-cut - data heard at any span projects onto the
chosen size (zoom = same real place, bigger fraction); sections are
a property of the VIEW (a node can be section 2 at 60 km and outside
the window at 20 km).
lib/link.dart + lib/door_socket.dart + lib/web_door_socket.dart:
TcpLink speaks the web app's EXACT door protocol (ws://host:8710/feed,
bearer.<password> subprotocol, wire-hex packets through the SAME
codec, resume-after-hello, seq-regression reset, plain-words refusal
acks, NO auto-reconnect, silent-drop watchdog with injectable tick);
CompanionLink = the inert honest slot ("no radio paired" until the
hardware go).
lib/connect_screen.dart: address + password + size picked BEFORE
connect, saved first, state-driven button, log view.
tests: 15 new (store laws, re-cut math incl. the 3x-zoom truth, door
protocol through a fake socket incl. watchdog). Suite 29 green.

## WORKFLOW (Brett, 2026-09-24): ALL FUTURE DEV WORK ON THE dev BRANCH
The app repo now works on `dev` (Brett created it on GitHub; local
checked out, tracking origin/dev). main = the stable line; work
lands on dev, merges up to main only with Brett's explicit OK.

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
