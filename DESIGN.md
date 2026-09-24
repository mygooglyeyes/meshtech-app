# MESHITECH-APP - DESIGN v4 (2026-09-24, Brett's changes applied;
# Brett's own edits preserved: TCP "never live" line deleted by his
# hand, iPhone build "yet", section 10 vectored sync)

The rulebook for the Flutter phone app. Nothing is built until Brett
says "correct". v1 (WiFi-live, like the web app) is DEAD - Brett
redirected the design the same day. The web app stays untouched.

---

## 1. What this app is (one sentence)

A phone app that draws the mesh map from packets heard OVER THE AIR
through a companion radio. WiFi/TCP is only a way to download the map
+ node database for use OFF the wire.

## 2. The main feature: the companion radio link (Brett, 2026-09-24)

The app is BUILT around the companion radio - it IS the phone's
radio, its ears AND its voice, and the link is established at the
start of the app:

```
phone <--BLE--> companion radio <--LoRa--> the air <-- hilltop
```

- DOWN (hearing): hilltop broadcasts the map on its schedule; the
  companion's receiver hears it; BLE carries it to the phone.
- UP (asking): the phone asks for updates OVER THE AIR from day
  one - the ask travels BLE to the companion, the companion
  TRANSMITS it, hilltop hears it and answers with the asked-for
  data.
- The first-run ZIP choice and the one-time server download are
  setup, NOT the app's center of gravity. The companion link is
  the main feature, never secondary.
- TCP is the helper, not the link: one-time download of the map +
  node database for off-wire use. (deleted the never part - BPS 9/24/26)

## 3. Map size - Brett's rules (2026-09-24, verbatim intent)

1. Size is picked BEFORE connect - it lives on the connect screen,
   saved with the address and password.
2. Changing the size changes the DRAWING ONLY. It never asks hilltop
   for anything: no auto refresh, no download, no budget spent.
3. The app translates whatever it holds to the size chosen: data
   heard or downloaded at 60 km can be drawn at 20 km. It can do this
   because the wire already carries each packet's true span (LAYOUT
   and INTRO both do), and the app re-cuts the grid itself from the
   data it holds. It never assumes the data matches the selector.

## 4. Where data lives: the phone's own store

- The phone keeps its own copy: nodes (name, position, class), the
  map frame, and honest ages for everything.
- OTA packets update the store live (the app's normal heartbeat).
- A TCP download fills/refreshes the store in bulk.
- LIVE MEANS LIVE (Brett's correction, 2026-09-24): new OTA data is
  added to the store the moment it is heard, and the map updates
  from it - new dots, fresh ages, routes appear as they arrive.
  The store is the one place data lives; the map is its live
  window, redrawn as packets land.
- AN UPDATE REPLACES THE OLD (Brett, 2026-09-24): new data removes
  the old - one node is ONE dot. If a node moves, its old position
  is gone the moment the new one lands; no node ever shows twice.

## 5. Honest data rules (law, carried over unchanged)

- A missing number shows as missing - never a placeholder that looks
  real.
- The size selector never lies: the title states the size DRAWN, and
  the app states the size the data was heard at when they differ.
- Bad adverts never become dots - the server already refuses them.

## 6. What hilltop needs (each waits for Brett's explicit go)

- OTA: TX ON (one toggle - Brett's decision, made at the bench, not
  before) + the #scope broadcast schedule (what hilltop puts on the
  air and how often - its own small design doc; PHONE-CONNECT.md's
  ledger math is the starting point) + a companion radio flashed
  MeshCore-companion (Brett's Heltec).
- TCP download: the data door may need ONE small bulk-download
  addition (map + node database in one fetch). Designed and approved
  before any server code changes.

## 7. Build order - DECIDED (Brett, 2026-09-24)

OTA-first, tested by download: the app is OTA-shaped from day one;
until Brett's TX go, the TCP download feeds it real hilltop data so
every screen is testable. BLE plugs in when the hardware says go.

## 8. Real maps under the dots (Brett's ask, 2026-09-24) - ANSWERED

The dots, sections, and routes draw OVER a real geographic map.
- Brett named waev:outpost as the reference AND supplied its source
  (C:\projects\waev-outpost-plugin-main). VERIFIED FROM THE SOURCE,
  not guessed: waev:outpost draws with **MapLibre GL** (maplibre-gl
  + react-map-gl in its package.json; README: "MapLibre GL rendering
  with CARTO basemaps and 3D terrain from elevation tiles") - the
  dark look is CARTO's **Dark Matter** style.
- SO OUR APP USES THE SAME ENGINE: the Flutter plugin **maplibre_gl**
  wraps the SAME MapLibre engine waev uses - on Android it is the
  same native renderer, driven from Dart instead of React.
- THE LOOK IS BRETT'S CALL (2026-09-24): NOT waev's dark style -
  "hard to see detail". Default = the standard colorful daylight
  map, the "real map" look (CARTO Voyager - same free CARTO tile
  family we verified, colorful streets/parks/water).
- NAMES ON THE MAP, EVERY SCREEN (Brett, 2026-09-24): wherever a
  node is drawn, its label shows: the node's name, then the first
  1, 2, or 3 bytes of its pubkey - matching the width that node
  uses in path hashes (1, 2, or 3 bytes). Shapes: "Hilltop a1",
  "Hilltop a1b2", "Hilltop a1b2c3".
- Filters (dark mode, contrast, glare) are a LATER chapter - Brett:
  "look at filters later". Nothing styled now beyond the daylight
  default. Note recorded for that later day: an offline pack is
  tied to one style's tiles, so adding a dark option then means
  its own pack - decided when we get there.
- OFFLINE IS THE POINT (fits Brett's TCP rule): MapLibre Native has
  a built-in offline pack - while the phone has internet (at home,
  with the TCP sync), the app downloads the home region's map data
  once (60x60 km + margin) and it lives on the phone. On the trail:
  ZERO internet, ZERO radio for the basemap - tiles from the pack,
  dots from the mesh.
- Same law as the mesh data: an area with no basemap shows an
  honest blank under the dots, never a fake placeholder.
- Escape hatch recorded: if maplibre_gl misbehaves on Brett's
  phone, the fallback is flutter_map + raster tiles (simpler, less
  pretty) - decided at the bench, not now.

## 9. Home area: chosen once, saved as HARD DATA (Brett, 2026-09-24)

- FIRST RUN (the phone has internet - that is how the app got
  installed): the user chooses their home area by ZIP code. The app
  downloads the basemap for that area (the 60x60 km home box +
  margin) once and saves it as HARD DATA on the phone.
- From then on the basemap is ON the phone - the trail needs
  nothing but the radio.
- LATER (moved home area, refreshed maps): re-downloading is a
  menu action for when the phone has internet.

(LESSON RECORDED, Brett 2026-09-24: stop planning for cases he did
not ask about, and stop adding flows he did not ask for. If the
design doc does not answer a question, ASK - do not invent.)

## 10. Vectored sync: changes vs new (Brett's design, 2026-09-24)

Goal: keep the air load down. The server tracks WHEN each node's
information last changed (new key, position, name, ...), and the
app's ask carries a marker for what it already has. The answer sends
FULL records only for nodes changed after that marker - everything
else travels as changes, routes on demand, packets as they come.

- BRETT'S DESIGN, REVIEWED (he asked for flaws, not a yes-OK): the
  logic is sound and pays exactly where airtime is dearest - most
  nodes never move, so re-sending the whole roster is the waste
  this kills. Three flaws found and handled: (1) the marker is a
  change COUNTER saved on disk, never clock time - hilltop
  restarts often and clock jumps would silently skip changes
  forever; a counter that only goes up is immune. (2) the stream
  carries a "node is gone" event, or retired/superseded nodes
  would sit on the map forever. (3) routes are the bulky cargo -
  they stay ON-DEMAND (below). The phone must persist its marker
  across restarts, and the server change is version-gated so the
  old web app keeps working unchanged (INTRO-span precedent).
- ROUTES: ON-DEMAND OVER THE AIR (Brett's pick). A tap = the ask
  (day-one TX through the companion) = the route detail comes
  back. Node-deltas ride the broadcast schedule.
- THE CAVEAT (Brett, 2026-09-24): on app start - after map
  location and size are chosen - the INITIAL TCP download carries
  the route data from the database along with everything else. So
  the phone starts full, and the air only ever carries what
  changed since.
- Server side changes (designed + approved before any code): the
  node store records a change-counter per node (bumped at the disk
  choke point every writer passes through), remembers "gone"
  events, and answers marker-based asks. The app is BUILT
  expecting this wire.

## 11. Live packet trails on the map (Brett, 2026-09-24)

Every live packet is SHOWN, on any version of the map the user may
be looking at - the trail is plain geography (the dots' real
coordinates), so the same trail draws the same way at 20, 40 or
60 km, or any size the selector is set to.

- THE LOOK: a line extending from one dot to the next along the
  packet's path, with a leading end that travels and a tail that
  SLOWLY VANISHES BEHIND IT (a comet trail). The dissolve speed is
  a tunable constant - experimented at the bench until Brett likes
  the feel of it.
- TWO SOURCES for live packets: hilltop's heard-traffic feed, AND
  the companion radio's own ability to listen - packets that
  originate or end at nodes the phone holds get drawn even when
  hilltop's schedule did not carry them.
- Honest gaps apply: a hop is drawn only as far as its known ends
  (section 5 law) - an unknown repeater in the path never gets an
  invented position.

## 12. Deliberately NOT in this app

- No iPhone build yet (Android first; iOS later is Flutter's promise,
  not day-one work).
- (The old "no TX from the phone" line is DELETED - Brett was
  right: asking for updates over the air is day-one behavior, sent
  through the companion. See section 2.)
