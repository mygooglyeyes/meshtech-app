// The app shell (moved out of main.dart so VM tests can pump it):
// ConnectScreen (4-way link chips + the facts the pick needs + MAP
// SIZE) -> the SELECTED link connects (nothing ever starts on its
// own) -> the store fills -> MapScreen draws the store over MapLibre.
// TWO PIPES, ONE STORE: the companion link (BLE, the MAIN feature)
// takes Brett straight to the map with no TCP at all; TcpLink is the
// door (off-wire download + today's testable path). USB and WiFi chips
// are named now and honest about not being built yet.
//
// The DoorSocketFactory is INJECTED (constructor param, defaulting to
// the stub): the real entrypoint supplies the platform socket; tests
// supply fakes. This keeps dart:js_interop out of the VM test build
// (the same stub-the-WebSocket lesson, applied at the shell). The
// BleTransportFactory is injected the same way - web/tests get the
// honest refusing stub, the native build passes FbpBleTransport.new.

import 'dart:async';

// 'Route' hidden: the WIRE's Route (codec.dart) is the one this file
// means - Flutter's Navigator Route is never used here.
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart' hide Route;

import 'ble_transport.dart';
import 'clinic_screen.dart';
import 'clinic_store.dart';
import 'codec.dart';
import 'companion_protocol.dart'
    show channelSecretHex, scopeChannelName;
import 'connect_screen.dart';
import 'detail_screen.dart';
import 'door_socket.dart';
import 'link.dart';
import 'main_page.dart';
import 'map_model.dart';
import 'section_screen.dart';
import 'settings.dart';
import 'store.dart';

class MeshtechApp extends StatefulWidget {
  final DoorSocketFactory socketFactory;
  final BleTransportFactory bleFactory;
  final BleTransportFactory usbFactory;
  final NetworkTransportFactory wifiFactory;

  /// Test seam (the same one MainPage offers): a widget test stands a
  /// plain body in for the map, so no live map engine is needed in the
  /// test harness. Null in the real app.
  final WidgetBuilder? mapBuilder;
  const MeshtechApp(
      {super.key,
      this.socketFactory = _noSocket,
      this.bleFactory = _noBle,
      this.usbFactory = _noUsb,
      this.wifiFactory = _noWifi,
      this.mapBuilder});

  @override
  State<MeshtechApp> createState() => _MeshtechAppState();
}

/// The honest default: no platform socket wired. A link built with it
/// refuses to dial with a plain-words detail - never a silent hang.
DoorSocket _noSocket() => throw UnsupportedError(
    'no door socket wired for this entrypoint');

/// The honest default: no BLE wired (web build, VM tests). The
/// companion link reports it in plain words - never a fake scan.
BleTransport _noBle() => throw UnsupportedError(
    'no BLE transport wired for this entrypoint');

/// The honest default: no USB wired (web build, VM tests).
BleTransport _noUsb() => throw UnsupportedError(
    'no USB transport wired for this entrypoint');

/// The honest default: no network companion wired (web build, VM
/// tests) - a plain-words refusal, never a fake dial.
BleTransport _noWifi(String address) => throw UnsupportedError(
    'no network companion transport wired for this entrypoint');

class _MeshtechAppState extends State<MeshtechApp> {
  ConnectionSettings _settings = const ConnectionSettings();
  late final NodeStore _store;
  // THE CLINIC (Mesh Clinic v2): the clinic's facts live beside the
  // nodes in their own store - provenance tagged, removal laws from
  // CLINIC-WIRE.md, saved with the same debounced save.
  late final ClinicStore _clinic;
  late final LinkEvents _tcpEvents;
  late final LinkEvents _airEvents;
  late TcpLink _tcpLink;
  late CompanionLink _airLink;
  // TWO PIPES: each link reports its own state; the map is up when
  // EITHER is live (Brett's answer 2026-09-25: the radio takes him to
  // the map even with no TCP at all).
  LinkState _tcpState = LinkState.disabled;
  LinkState _airState = LinkState.disabled;

  /// WHICH CARRIER THE AIR LINK DIALS (Brett's four chips): the
  /// companion link is EQUAL on BLE / USB / WiFi - the same protocol
  /// engine over three transports (the plan's law). The chip pressed
  /// decides; the factory reads it at dial time.
  String _airKind = linkBle;

  BleTransport _makeAirTransport() => switch (_airKind) {
        linkUsb => widget.usbFactory(),
        linkWifi => widget.wifiFactory(_settings.host),
        _ => widget.bleFactory(),
      };
  String _linkDetail = '';
  final List<String> _log = [];
  String? _frameName;
  (double, double)? _frameCenter;
  Pulse? _pulse; // the feed-health box's food (rides whole-area answers)
  // THE SECTION DETAIL PAGE (Brett, 2026-09-25): which section's
  // page is up (0 = none), the square it was tapped from (the
  // page's camera), and the ONLY things a summary may drive - the
  // page's warm route lines and its stats line. A background
  // summary for any other section is ignored entirely (no map
  // change, no state).
  int _openSection = 0;
  SectionCell? _openCell;
  List<int> _sectionHot = const []; // the open section's route stubs
  SectSum? _sectionSum; // the open section's latest summary
  Timer? _saveTimer;
  // THE WIPE GATE (bench law): true from launch until the debug wipe
  // has finished - the debounced store save (which would re-persist
  // whatever the store held) is blocked until then.
  bool _wipeGate = true;

  /// The app's navigator (the picker dialog needs a context BELOW
  /// the MaterialApp - this state sits above it).
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  bool _mounted = true; // link callbacks can outlive the widget tree

  /// Either pipe live = the map is up (and the ConnectScreen steps
  /// aside); connecting = at least one pipe is dialing.
  LinkState get _linkState {
    if (_tcpState == LinkState.connected ||
        _airState == LinkState.connected) {
      return LinkState.connected;
    }
    if (_tcpState == LinkState.connecting ||
        _airState == LinkState.connecting) {
      return LinkState.connecting;
    }
    return LinkState.disabled;
  }

  /// The log lives in state; packets arriving from link callbacks
  /// append here (the map's log box reads it). THE DEVICE LOG
  /// (Brett, 2026-09-25 - "device"): every line also goes to the
  /// Android log so adb can read the phone's truth off-screen.
  void _logLine(String line) {
    debugPrint(line);
    _log.insert(0, line);
    if (_log.length > 50) _log.removeLast();
    _safeSetState(() {});
  }

  @override
  void initState() {
    super.initState();
    _store = NodeStore();
    _clinic = ClinicStore();
    _tcpEvents = LinkEvents(
      onState: (s, d) => _safeSetState(() {
        _tcpState = s;
        _linkDetail = d;
      }),
      onPacket: (packet, {heardMs}) => _onPacket(packet, heardMs),
      onLog: _logLine,
      onReset: () {
        // NODE RESTART IS NOT DEATH (Brett's law, 2026-09-27): the
        // server persists its map on disk, so the phone keeps every
        // dot, line and the frame. Full re-sync instead: the marker
        // drops (marker 0 = the whole roster re-sent) and the fresh
        // LAYOUT replaces the frame like-for-like. The store saves
        // immediately - a crash here must not resurrect the old
        // marker with stale data.
        _store.prepareResync();
        _store.save().then((_) => SettingsStore()
            .save(_settings.copyWith(syncMarker: _store.syncMarker)));
        _logLine('node restarted - the map stays, a full re-sync begins');
      },
    );
    _airEvents = LinkEvents(
      onState: (s, d) {
        _safeSetState(() {
          _airState = s;
          _linkDetail = d;
        });
        if (s == LinkState.connected) {
          // THE AUTO CHANNEL CHECK (v022, Brett's flow 2026-09-25):
          // connect -> the app checks/provisions the channel itself ->
          // map. No human in the middle, no Connect screen in the way.
          unawaited(_checkAirChannel());
        } else if (_airChecking) {
          // The pipe went away: no check can finish on it, and no gate
          // may wait on one that never will.
          _safeSetState(() => _airChecking = false);
        }
      },
      onPacket: (packet, {heardMs}) => _onPacket(packet, heardMs),
      onLog: _logLine,
    );
    _tcpLink = _buildLink();
    _airLink = CompanionLink(_airEvents,
        transportFactory: _makeAirTransport,
        devicePicker: _pickRadio);
    _bootstrap();
  }

  /// Link callbacks (and the debounced persist) can fire after the
  /// widget tree is torn down - setState on a defunct state is a
  /// framework assertion, not a style question.
  void _safeSetState(VoidCallback fn) {
    if (!_mounted) return;
    setState(fn);
  }

  /// THE PICKER BOX (Brett 2026-09-25): the scan's finds listed by
  /// name - his tap picks the radio. Dismissing or Cancel = no pick,
  /// which the link reports honestly (nothing connects). The dialog
  /// rides the NAVIGATOR (this state sits above the MaterialApp, so
  /// its own context has no Navigator to look up).
  Future<String?> _pickRadio(List<BleCandidate> found) {
    // The Navigator's own context works here (Navigator.of handles
    // a context that IS the navigator).
    final navContext = _navKey.currentContext;
    if (navContext == null) return Future<String?>.value(null);
    return showDialog<String>(
      context: navContext,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose the radio'),
        children: [
          for (final c in found)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c.id),
              child: Text(c.name),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  /// THE CHANNEL GATE (v022): true from the moment the radio pipe
  /// links up until the channel check has PROVED #$scopeChannelName is
  /// in the radio. While it is true the map stays down and the connect
  /// screen carries the log - a failed check keeps it there, where the
  /// Provision channel button is the honest retry.
  bool _airChecking = false;

  /// The check the air link's connect runs for itself: probe, compare
  /// against THE shared key, write what is missing, read it back. The
  /// verdict lands in the log either way - the honesty rule applied to
  /// an unattended write.
  Future<void> _checkAirChannel() async {
    if (!_mounted || _airChecking) return;
    _safeSetState(() => _airChecking = true);
    String verdict;
    try {
      verdict = await _airLink.ensureChannel(
          secretHex: channelSecretHex, stage: _logLine);
    } catch (err) {
      verdict = 'channel check failed: $err';
    }
    _logLine(verdict);
    if (!_mounted) return;
    if (_airLink.scopeSlot == null) {
      _logLine('#$scopeChannelName is not in the radio - the map stays '
          'down until it is (Provision channel retries it)');
      return; // gate held: the honest refusal stays on screen
    }
    if (_airState == LinkState.connected) {
      _safeSetState(() => _airChecking = false);
    }
  }

  /// THE PROVISION DIALOG (v020, Brett's check-first rule): shows the
  /// probe's slot table as current truth, collects slot/name/key, and
  /// runs the read -> confirm -> write -> read-back conversation.
  /// Every stage line and the final verdict land in the log - the
  /// honesty rule applied to provisioning.
  Future<void> _provisionChannel() async {
    final navContext = _navKey.currentContext;
    if (navContext == null) return;
    final currentSlot = _airLink.scopeSlot ?? 0;
    final currentName =
        _airLink.slotNames[_airLink.scopeSlot] ??
        _airLink.slotNames[currentSlot] ??
        '';
    final slotCtrl = TextEditingController(text: '$currentSlot');
    final nameCtrl = TextEditingController(text: currentName);
    final keyCtrl = TextEditingController();
    final slots = _airLink.slotNames.isEmpty
        ? '(the probe has not heard the slots yet)'
        : _airLink.slotNames.entries
            .map((e) => "${e.key}: '${e.value}'")
            .join('   ');
    final picked = await showDialog<(int, String, String)>(
      context: navContext,
      builder: (ctx) => AlertDialog(
        title: const Text('Provision radio channel'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('radio holds: $slots',
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
              TextField(
                controller: slotCtrl,
                key: const ValueKey('prov-slot'),
                decoration: const InputDecoration(labelText: 'slot (0-7)'),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: nameCtrl,
                key: const ValueKey('prov-name'),
                decoration:
                    const InputDecoration(labelText: 'channel name'),
              ),
              TextField(
                controller: keyCtrl,
                key: const ValueKey('prov-key'),
                decoration: const InputDecoration(
                    labelText: 'key - 32 hex chars (16 bytes)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('prov-write'),
            onPressed: () {
              final slot = int.tryParse(slotCtrl.text.trim()) ?? -1;
              if (slot < 0 || slot > 7) return;
              Navigator.pop(
                  ctx, (slot, nameCtrl.text.trim(), keyCtrl.text));
            },
            child: const Text('Write'),
          ),
        ],
      ),
    );
    if (picked == null) return;
    final result = await _airLink.provisionChannel(
      picked.$1,
      picked.$2,
      picked.$3,
      confirm: (situation) async {
        if (!navContext.mounted) return false;
        return await showDialog<bool>(
              context: navContext,
              builder: (ctx) => AlertDialog(
                title: const Text('Overwrite this slot?'),
                content: Text(situation),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Overwrite')),
                ],
              ),
            ) ??
            false;
      },
      stage: _logLine,
    );
    _logLine(result);
    // A manual retry that WORKED releases the same gate the automatic
    // check holds: the map opens the moment the channel is proved.
    if (_airChecking && _airLink.scopeSlot != null) {
      _safeSetState(() => _airChecking = false);
    }
  }

  TcpLink _buildLink() => TcpLink(
        _tcpEvents,
        host: _settings.host,
        password: _settings.password,
        socketFactory: widget.socketFactory,
        // The vectored ask rides the link: marker = what the phone
        // holds (0 = first run = full roster), span = the chosen map
        // size. Origin 0 would be an un-minted client - skip it.
        askMarker: _settings.syncMarker,
        askSpanKm: _settings.origin == 0 ? 0 : _settings.mapSizeKm,
        askOrigin: _settings.origin,
      );

  Future<void> _bootstrap() async {
    var loaded = await SettingsStore().load();
    if (kDebugMode) {
      // BRETT'S BENCH LAW (2026-09-24, his pick): a debug build acts
      // freshly installed EVERY launch - data/routes/marker wiped
      // (flash included), the first-connect ask goes out with
      // marker 0 = the full roster. Release builds remember (the
      // offline-trail design, section 4).
      await _store.wipe();
      await _clinic.wipe();
      loaded = loaded.copyWith(syncMarker: 0);
      await SettingsStore().save(loaded);
      // Wipe complete: the store is empty on flash too. Open the
      // gate - packets received from HERE ON are the only thing
      // that can persist (memory can never resurface).
      _wipeGate = false;
    } else {
      _store.noteSyncMarker(loaded.syncMarker);
      await _store.load();
      // The clinic's facts come back too - and anything that died
      // while the app was shut is gone the moment it reopens.
      await _clinic.load(
          nowMs: DateTime.now().millisecondsSinceEpoch);
      // THE LINES SURVIVE A RESTART (Brett, 2026-09-27): the saved map
      // frame comes back with the dots - the map draws its grid
      // immediately, no TCP trip needed. A node restart still clears
      // it (resetAll) and a fresh install has none: the app then
      // waits for a real LAYOUT, never draws stale lines.
      final f = _store.frame;
      if (f != null) {
        _frameName = f.name;
        _frameCenter = (f.centerLat, f.centerLon);
      }
      // RELEASE MUST SAVE TOO (the lines bug, Brett's phone test
        // 2026-09-27): the wipe gate existed only for the DEBUG wipe -
        // in release it NEVER opened, so no release install has
        // persisted anything since the gate was born. Open it here:
        // loading is done, the flash holds what the store loaded.
      _wipeGate = false;
    }
    setState(() {
      _settings = loaded;
      _tcpLink = _buildLink();
    });
    // NOTHING CONNECTS HERE (Brett 2026-09-25 - the selector's law):
    // the app waits on the connect screen; only a pressed Connect
    // (for the chosen chip) dials anything.
  }

  /// The store's law in action: packets land the moment they arrive;
  /// the map is the store's live window. INTRO entries merge (unknown
  /// never overwrites known); LAYOUT names the frame; GONE removes
  /// dots. A persist is debounced - flash storage is kind, not free.
  void _onPacket(Object packet, int? heardMs) {
    final now = heardMs ?? DateTime.now().millisecondsSinceEpoch;
    switch (packet) {
      case final Layout l:
        // The layout is RECEIVED DATA: into the store's frame so the
        // debounced save persists it with the dots (the lines survive
        // the app closing - Brett's fix, 2026-09-27).
        _store.noteFrame(l);
        _safeSetState(() {
          _frameName = l.name;
          _frameCenter = (l.centerLat, l.centerLon);
        });
      case final Intro i:
        for (final e in i.entries) {
          _store.applyIntroEntry(e, heardMs: now);
        }
        debugPrint('INTRO ${i.entries.length} entr(ies) -> '
            '${_store.nodes.length} node(s) in store');
      case final Gone g:
        for (final p in g.prefixes) {
          _store.removeGone(p);
          // THE FACTS FOLLOW THE NODE (CLINIC-WIRE's forget law):
          // its chart, its flags and its peer INTRO reports die with
          // it - peer ROUTE reports survive (they are the route's).
          _clinic.forgetNode(p);
          // THE LINE FOLLOWS THE DOT (Brett, 2026-09-27): a GONE
          // update removes the node's route lines too - they are
          // lines TO it, fiction without the dot.
          _store.removeGoneRoutes(p);
        }
      case final Pulse pl:
        _pulse = pl; // feed-health box (section: the web app's furniture)
      case final SectSum ss:
        // THE SUMMARY GATE (Brett, 2026-09-25): a summary speaks
        // only when ITS section's detail page is open - anything
        // else the rotating background brings is ignored entirely.
        // Route packets still land in the store as always, so the
        // maps' data never stops; only this page's display is gated.
        if (_openSection != 0 && ss.sectionId == _openSection) {
          _safeSetState(() {
            _sectionSum = ss;
            _sectionHot = ss.routeStubs;
          });
          if (ss.routeStubs.isNotEmpty) {
            _logLine('section ${ss.sectionId}: '
                '${ss.routeStubs.length} route(s) listed');
          }
        }
      case final Route r:
        _store.applyRoute(r); // the tap-ask's answer lands in the store
        // HONEST TAP DIAGNOSIS: the answer says what it brought -
        // hops total, hops drawable (a known node WITH a position),
        // hops the honest gap must skip. No more silent no-lines.
        final known =
            r.prefixes.where((p) => _store.nodes[p] != null).length;
        final placeable = r.prefixes
            .where((p) =>
                _store.nodes[p]?.lat != null &&
                _store.nodes[p]?.lon != null)
            .length;
        _logLine('route ${r.routeId}: ${r.prefixes.length} hop(s), '
            '$placeable drawn, ${r.prefixes.length - placeable} '
            'no-place${known < r.prefixes.length
                ? ', ${r.prefixes.length - known} unknown node(s)'
                : ''}');
      case final Clinic c:
        // THE CLINIC (Mesh Clinic v2): the clinic's facts land the
        // moment they are heard - provenance tagged, one row per
        // measuring box, never merged (CLINIC-WIRE's rule).
        _clinic.fold(c, heardMs: now);
        final head = c.origin.toRadixString(16).padLeft(4, '0');
        _logLine('clinic: ${c.records.length} fact(s) folded '
            '(box $head sent)');
      default:
        break;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      // The wipe gate: no packet may re-persist pre-wipe memory.
      if (_wipeGate) return;
      // THE CLINIC'S REMOVAL AGES (CLINIC-WIRE.md) run while the app
      // is up - facts die when their evidence stops being fresh.
      _clinic.prune(nowMs: DateTime.now().millisecondsSinceEpoch);
      _store.save().then((_) => SettingsStore()
          .save(_settings.copyWith(syncMarker: _store.syncMarker)));
      _clinic.save();
    });
    _safeSetState(() {});
  }

  /// The TYPED facts lead (first-run lesson, found on the bench
  /// emulator 2026-09-24): save what the fields hold, rebuild the
  /// link from the saved settings, THEN dial - never a stale copy
  /// from app start. The ZIP's center arrives already resolved by
  /// the screen (it shows the lookup's honest error if it failed).
  /// THE SELECTED CHIP DIALS (Brett 2026-09-25): `link` names which
  /// chip was pressed - ONLY that link connects. THE COMPANION LINK
  /// IS EQUAL ON BLE / USB / WiFi (Mesh Clinic v2): the same
  /// protocol engine over the carrier the chip stands for.
  Future<void> _connect(String link, String host, String password,
      int mapSizeKm, String homeZip, (double, double)? homeCenter) async {
    debugPrint('SHELL CONNECT link="$link" host="$host"');
    final next = _settings.copyWith(
      host: host,
      password: password,
      mapSizeKm: mapSizeKm,
      homeZip: homeZip,
      homeLat: homeCenter?.$1 ?? _settings.homeLat,
      homeLon: homeCenter?.$2 ?? _settings.homeLon,
    );
    await SettingsStore().save(next);
    debugPrint('SETTINGS SAVED');
    if (!mounted) return;
    setState(() {
      _settings = next;
      _tcpLink = _buildLink();
      // The companion carrier the chosen chip stands for (BLE, USB
      // or WiFi - one link, three equal carriers).
      _airKind = link;
    });
    switch (link) {
      case linkTcp:
        await _tcpLink.connect();
      case linkBle:
      case linkUsb:
      case linkWifi:
        await _airLink.connect();
    }
  }

  void _disconnect() {
    _tcpLink.disconnect();
    _airLink.disconnect();
    // The pipes are gone: the detail page's ask can no longer be
    // answered, so it closes with them (it returns on the map's
    // next tap after a reconnect, never as a stale overlay).
    _closeSection();
    _closeDetail();
    _closeClinic();
  }

  /// THE SIZE BUTTONS: stepping 20/40/60 redraws the SAME held data
  /// at the new window (rule 2) and persists the choice. It never
  /// asks hilltop for anything.
  Future<void> _changeMapSize(int km) async {
    if (km == _settings.mapSizeKm) return;
    final next = _settings.copyWith(mapSizeKm: km);
    setState(() => _settings = next);
    await SettingsStore().save(next);
  }

  /// THE UPDATE BUTTON: ask hilltop for the area data now - the same
  /// vectored ask the link sends by itself on connect (marker = what
  /// the phone holds; the server's limiter decides, honestly). When
  /// the radio is live the ask rides the AIR (DESIGN 2); otherwise
  /// the door ferries it.
  void _ask() {
    if (_airState == LinkState.connected) {
      _airLink.sendVectoredAsk(
          syncMarker: _settings.syncMarker,
          spanKm: _settings.mapSizeKm,
          origin: _settings.origin);
    } else {
      _tcpLink.sendVectoredAsk(
          syncMarker: _settings.syncMarker,
          spanKm: _settings.mapSizeKm,
          origin: _settings.origin);
    }
  }

  /// TAP A SQUARE, OPEN THAT SECTION (Brett, 2026-09-25): the
  /// square's NUMBER is the section id the wire speaks (1 upper
  /// left .. 12 lower right), so the page he opens is the number he
  /// saw. The page's camera parks on the tapped square's own
  /// geography; the ask goes out for the section's data.
  void _onSectionTap(SectionCell cell) {
    setState(() {
      _openSection = cell.id;
      _openCell = cell;
      // Fresh page: this section's own ask-answer brings its warm
      // lines and stats a moment later (the gate above accepts only
      // its summaries from there on).
      _sectionHot = const [];
      _sectionSum = null;
      _sectionClinicView = null; // the plain section page (long press)
      _sectionClinicWindow = 0;
    });
    _askSection(cell.id);
  }

  /// Close the detail page - the page's back arrow, the system back
  /// button, and disconnect all end here, so nothing can stay open
  /// over a map it no longer belongs to.
  void _closeSection() {
    if (_openSection == 0) return;
    setState(() {
      _openSection = 0;
      _openCell = null;
      _sectionHot = const [];
      _sectionSum = null;
      _sectionClinicView = null;
      _sectionClinicWindow = 0;
    });
  }

  /// THE NODE / ROUTE DETAIL PAGE (Brett, 2026-09-30): the lists'
  /// rows used to do nothing - now a tap rides THIS page over
  /// everything (its back button returns to the list he came
  /// from). One detail at a time, like everything on the stack.
  int _detailPrefix = 0;
  Route? _detailRoute;

  void _openNodeDetail(int prefix) {
    setState(() {
      _detailPrefix = prefix;
      _detailRoute = null;
    });
  }

  void _openRouteDetail(Route route) {
    setState(() {
      _detailRoute = route;
      _detailPrefix = 0;
    });
  }

  void _closeDetail() {
    if (_detailPrefix == 0 && _detailRoute == null) return;
    setState(() {
      _detailPrefix = 0;
      _detailRoute = null;
    });
  }

  /// THE CLINIC PAGE (Brett, 2026-09-30): "+clinic" on the map
  /// opens it - the clinic chips, the time window and the section
  /// list live there now, off the map. Its choices live HERE so
  /// they survive the section-map round trip (the chips are still
  /// lit when the back button returns to the page).
  bool _clinicOpen = false;
  ClinicView _clinicView = ClinicView.nodes;
  int _clinicWindowMin = 1440;

  /// The map's own view grid (lifted by MapScreen): the Clinic
  /// page's section numbers are THESE squares - the number Brett
  /// saw on the map is the number he taps in the list.
  ViewGrid? _mapGrid;

  /// The family the OPEN section page draws (null = the plain
  /// section page from the map's long press).
  ClinicView? _sectionClinicView;
  int _sectionClinicWindow = 0;

  void _openClinic() => setState(() => _clinicOpen = true);

  void _closeClinic() {
    if (!_clinicOpen) return;
    setState(() => _clinicOpen = false);
  }

  /// THE CLINIC FLOW (Brett, 2026-09-30: "tapping on a clinic
  /// option, then a section number opens that section map with the
  /// clinic option details ... then a back button to go back to the
  /// clinic page"): the chosen family draws on that section's map,
  /// and the section's back button lands back on the Clinic page.
  void _onClinicSection(int id) {
    final g = _mapGrid;
    if (g == null || id < 1 || id > g.cols * g.rows) return;
    final cell = g.cell(id - 1);
    setState(() {
      _openSection = cell.id;
      _openCell = cell;
      _sectionHot = const [];
      _sectionSum = null;
      _sectionClinicView = _clinicView;
      _sectionClinicWindow = _clinicWindowMin;
    });
    _askSection(cell.id);
  }

  /// The SECTION ASK - same pipe choice as the Update: air when the
  /// radio is live, the door otherwise. The answer is a summary of
  /// THIS section (the gate displays it) plus the section's top
  /// routes, which land in the store like any Route packet.
  void _askSection(int section) {
    if (_airState == LinkState.connected) {
      _airLink.sendSectionAsk(
          sectionId: section, origin: _settings.origin);
    } else {
      _tcpLink.sendSectionAsk(
          sectionId: section, origin: _settings.origin);
    }
  }

  @override
  void dispose() {
    _mounted = false;
    _saveTimer?.cancel();
    _tcpLink.disconnect();
    _airLink.disconnect();
    // A debug build leaves nothing behind on the way out: whatever
    // this session heard is wiped on flash too (fresh next launch).
    if (kDebugMode) {
      _store.wipe();
      _clinic.wipe();
    }
    super.dispose();
  }  /// THE BLUELINE PALETTE (Brett, 2026-09-25): the logo's drafting
  /// print - #0f3a72 blue paper, white lines and text. Section
  /// plates lift one shade; white edges draw the lines. Shades are
  /// bench-tunable later (his call), the two colors are the law.
  ThemeData _bluelineTheme() {
    const blue = Color(0xFF0F3A72);
    const plate = Color(0xFF123F73);
    final scheme = ColorScheme.fromSeed(
      seedColor: blue,
      brightness: Brightness.dark,
    ).copyWith(
      surface: blue,
      surfaceContainer: plate,
      surfaceContainerHigh: const Color(0xFF164A85),
      surfaceContainerHighest: const Color(0xFF164A85),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: blue,
      dividerColor: Colors.white24,
      textTheme: ThemeData.dark()
          .textTheme
          .apply(bodyColor: Colors.white, displayColor: Colors.white),
      appBarTheme: const AppBarTheme(
        backgroundColor: blue,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Which pipe is live, named on the connection pill (one glance):
    // both can be up at once (radio + door).
    final airUp = _airState == LinkState.connected;
    final tcpUp = _tcpState == LinkState.connected;
    final linkLabel = airUp && tcpUp
        ? 'Radio + TCP'
        : airUp
            ? 'Radio active'
            : 'TCP active';
    // THE RADIO STATUS LINE (Brett 2026-09-25): the companion link's
    // truth in one fixed spot on the connect screen.
    final radioStatus = switch (_airState) {
      LinkState.connecting => 'Radio: ${_airLink.detail.isEmpty
          ? 'scanning...'
          : _airLink.detail}',
      LinkState.connected => _airChecking
          ? 'Radio: connected (${_airLink.detail}) - checking '
              '#$scopeChannelName now'
          : _airLink.scopeSlot == null
              ? 'Radio: connected (${_airLink.detail}) - waiting for '
                  '#$scopeChannelName'
              : 'Radio: connected (${_airLink.detail})'
                  ' - #$scopeChannelName slot ${_airLink.scopeSlot}',
      LinkState.disabled => switch (_airLink.detail
          .replaceFirst('no radio: ', '')) {
          '' => 'Radio: not connected',
          final d => 'Radio: $d',
        },
    };
    return MaterialApp(
      navigatorKey: _navKey,
      title: 'meshtech',
      theme: _bluelineTheme(),
      home: (_linkState == LinkState.connected && !_airChecking)
          ? PopScope(
              // THE SYSTEM BACK (Brett, 2026-09-25): while a page
              // is up, back closes IT - the TOP page first - never
              // the app underneath a page still open over the map.
              canPop: _openSection == 0 &&
                  _detailPrefix == 0 &&
                  _detailRoute == null &&
                  !_clinicOpen,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) return;
                // THE TOP PAGE FIRST (Brett, 2026-09-25): detail,
                // then the section map, then the Clinic page -
                // never the app under a page still open.
                if (_detailPrefix != 0 || _detailRoute != null) {
                  _closeDetail();
                } else if (_openSection != 0) {
                  _closeSection();
                } else {
                  _closeClinic();
                }
              },
              child: Stack(
                children: [
                  MainPage(
                    store: _store,
                    clinic: _clinic,
                    settings: _settings,
                    frameName: _frameName,
                    frameCenter: _frameCenter,
                    pulse: _pulse,
                    log: _log,
                    linkDetail: _linkDetail,
                    linkLabel: linkLabel,
                    onDisconnect: _disconnect,
                    onAsk: _ask,
                    onMapSizeChange: _changeMapSize,
                    onSectionTap: _onSectionTap,
                    onNodeTap: _openNodeDetail,
                    onRouteTap: _openRouteDetail,
                    onClinicTap: _openClinic,
                    onGrid: (g) => _mapGrid = g,
                    mapBuilder: widget.mapBuilder,
                  ),
                  // THE CLINIC PAGE (Brett, 2026-09-30): the
                  // +clinic button opens it - chips, time window,
                  // sections. It rides between the map and whatever
                  // page it opens.
                  if (_clinicOpen)
                    ClinicScreen(
                      clinic: _clinic,
                      store: _store,
                      view: _clinicView,
                      windowMin: _clinicWindowMin,
                      onView: (v) => setState(() => _clinicView = v),
                      onWindow: (m) =>
                          setState(() => _clinicWindowMin = m),
                      onPick: _onClinicSection,
                      onClose: _closeClinic,
                    ),
                  // THE SECTION DETAIL PAGE (Brett, 2026-09-25):
                  // rides OVER the main page - the map below stays
                  // mounted (its pan survives the round trip) and
                  // every packet rebuilds this page straight from
                  // the shell's setState. Its orange lines and
                  // stats come only from summaries of this exact
                  // section (the gate in _onPacket).
                  if (_openSection != 0 && _openCell != null)
                    SectionScreen(
                      store: _store,
                      clinic: _clinic,
                      cell: _openCell!,
                      hotRouteIds: _sectionHot,
                      summary: _sectionSum,
                      clinicView: _sectionClinicView,
                      clinicWindowMin: _sectionClinicWindow,
                      onClose: _closeSection,
                      onNodeTap: _openNodeDetail,
                      onRouteTap: _openRouteDetail,
                      mapBuilder: widget.mapBuilder,
                    ),
                  // THE NODE / ROUTE DETAIL PAGE (Brett, 2026-09-30):
                  // rides OVER everything, opened from the lists -
                  // its back button returns to the list he came from.
                  if (_detailRoute != null)
                    RouteDetailScreen(
                      store: _store,
                      clinic: _clinic,
                      route: _detailRoute!,
                      onClose: _closeDetail,
                    )
                  else if (_detailPrefix != 0)
                    NodeDetailScreen(
                      store: _store,
                      clinic: _clinic,
                      prefix: _detailPrefix,
                      onClose: _closeDetail,
                    ),
                ],
              ),
            )
          : Scaffold(
              // ConnectScreen draws TextFields: it needs a Material
              // ancestor (the map screen builds its own Scaffold).
              body: ConnectScreen(
                settings: _settings,
                linkState: _linkState,
                linkDetail: _linkDetail,
                radioStatus: radioStatus,
                linkLog: _log,
                onConnect: _connect,
                onDisconnect: _disconnect,
                onProvision: _provisionChannel,
              ),
            ),
    );
  }
}
