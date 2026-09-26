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
import 'codec.dart';
import 'companion_protocol.dart'
    show channelSecretHex, scopeChannelName;
import 'connect_screen.dart';
import 'door_socket.dart';
import 'grid.dart';
import 'link.dart';
import 'main_page.dart';
import 'map_model.dart';
import 'settings.dart';
import 'store.dart';

class MeshtechApp extends StatefulWidget {
  final DoorSocketFactory socketFactory;
  final BleTransportFactory bleFactory;

  /// Test seam (the same one MainPage offers): a widget test stands a
  /// plain body in for the map, so no live map engine is needed in the
  /// test harness. Null in the real app.
  final WidgetBuilder? mapBuilder;
  const MeshtechApp(
      {super.key,
      this.socketFactory = _noSocket,
      this.bleFactory = _noBle,
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

class _MeshtechAppState extends State<MeshtechApp> {
  ConnectionSettings _settings = const ConnectionSettings();
  late final NodeStore _store;
  late final LinkEvents _tcpEvents;
  late final LinkEvents _airEvents;
  late TcpLink _tcpLink;
  late CompanionLink _airLink;
  // TWO PIPES: each link reports its own state; the map is up when
  // EITHER is live (Brett's answer 2026-09-25: the radio takes him to
  // the map even with no TCP at all).
  LinkState _tcpState = LinkState.disabled;
  LinkState _airState = LinkState.disabled;
  String _linkDetail = '';
  final List<String> _log = [];
  String? _frameName;
  (double, double)? _frameCenter;
  Pulse? _pulse; // the feed-health box's food (rides whole-area answers)
  List<int> _sectionRoutes = const []; // route stubs of the last tapped section
  int _tappedPrefix = 0; // the node whose section was last asked (0 = none)
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
    _tcpEvents = LinkEvents(
      onState: (s, d) => _safeSetState(() {
        _tcpState = s;
        _linkDetail = d;
      }),
      onPacket: (packet, {heardMs}) => _onPacket(packet, heardMs),
      onLog: _logLine,
      onReset: () => _store.resetAll(),
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
        transportFactory: widget.bleFactory,
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
      loaded = loaded.copyWith(syncMarker: 0);
      await SettingsStore().save(loaded);
      // Wipe complete: the store is empty on flash too. Open the
      // gate - packets received from HERE ON are the only thing
      // that can persist (memory can never resurface).
      _wipeGate = false;
    } else {
      _store.noteSyncMarker(loaded.syncMarker);
      await _store.load();
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
        }
      case final Pulse pl:
        _pulse = pl; // feed-health box (section: the web app's furniture)
      case final SectSum ss:
        _safeSetState(() => _sectionRoutes = ss.routeStubs);
        if (ss.routeStubs.isNotEmpty) {
          _logLine('section ${ss.sectionId}: '
              '${ss.routeStubs.length} route(s) listed');
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
      default:
        break;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      // The wipe gate: no packet may re-persist pre-wipe memory.
      if (_wipeGate) return;
      _store.save().then((_) => SettingsStore()
          .save(_settings.copyWith(syncMarker: _store.syncMarker)));
    });
    _safeSetState(() {});
  }

  /// The TYPED facts lead (first-run lesson, found on the bench
  /// emulator 2026-09-24): save what the fields hold, rebuild the
  /// link from the saved settings, THEN dial - never a stale copy
  /// from app start. The ZIP's center arrives already resolved by
  /// the screen (it shows the lookup's honest error if it failed).
  /// THE SELECTED CHIP DIALS (Brett 2026-09-25): `link` names which
  /// chip was pressed - ONLY that link connects. USB and WiFi are in
  /// the 4-way selector but not built yet: said plainly, never faked.
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
    });
    switch (link) {
      case linkTcp:
        await _tcpLink.connect();
      case linkBle:
        await _airLink.connect();
      default:
        // USB / WiFi: selectable, and honest about being un-built.
        final name = link == linkUsb ? 'USB' : 'WiFi';
        _logLine('$name link: not built yet - pick BLE or TCP');
        _safeSetState(() => _linkDetail = '$name link: not built yet');
    }
  }

  void _disconnect() {
    _tcpLink.disconnect();
    _airLink.disconnect();
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

  /// THE TAP-ASK (design section 10): tapping a node asks the server
  /// section it sits in - the answer's routes draw dot-to-dot. The
  /// section is computed from the node's REAL position on the
  /// server's frame (the wire's 3x3 - section ids are the server's
  /// language), not the phone's 3x4 view grid. Same pipe choice as
  /// the Update ask: air when the radio is live, door otherwise.
  void _onDotTap(DotVM dot) {
    final section = _serverSectionOf(dot);
    if (section == 0) return; // outside every server section: honest no-op
    setState(() => _tappedPrefix = dot.prefix);
    if (_airState == LinkState.connected) {
      _airLink.sendSectionAsk(
          sectionId: section, origin: _settings.origin);
    } else {
      _tcpLink.sendSectionAsk(
          sectionId: section, origin: _settings.origin);
    }
  }

  /// Which server 3x3 section a position falls in - computed against
  /// the heard LAYOUT (whichever pipe heard it - the frame the wire
  /// uses for section ids is the same on both).
  int _serverSectionOf(DotVM dot) {
    final l = _airLink.layout ?? _tcpLink.layout;
    if (l == null) return 0;
    final frame = MapFrame(
        grid: l.grid,
        centerLat: l.centerLat,
        centerLon: l.centerLon,
        spanM: l.spanM.toDouble());
    return frame.sectionOf(dot.lat, dot.lon);
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
          ? MainPage(
              store: _store,
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
              onDotTap: _onDotTap,
              tappedPrefix: _tappedPrefix,
              sectionRouteIds: _sectionRoutes,
              mapBuilder: widget.mapBuilder,
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
