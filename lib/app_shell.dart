// The app shell (moved out of main.dart so VM tests can pump it):
// ConnectScreen (address + password + MAP SIZE before connect) ->
// live link -> the store fills -> MapScreen draws the store over
// MapLibre. The companion link (BLE, the MAIN feature) is the inert
// honest slot until the hardware go; TcpLink is today's testable
// transport (and the off-wire download later).
//
// The DoorSocketFactory is INJECTED (constructor param, defaulting to
// the stub): the real entrypoint supplies the platform socket; tests
// supply fakes. This keeps dart:js_interop out of the VM test build
// (the same stub-the-WebSocket lesson, applied at the shell).

import 'dart:async';

// 'Route' hidden: the WIRE's Route (codec.dart) is the one this file
// means - Flutter's Navigator Route is never used here.
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart' hide Route;

import 'codec.dart';
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
  const MeshtechApp({super.key, this.socketFactory = _noSocket});

  @override
  State<MeshtechApp> createState() => _MeshtechAppState();
}

/// The honest default: no platform socket wired. A link built with it
/// refuses to dial with a plain-words detail - never a silent hang.
DoorSocket _noSocket() => throw UnsupportedError(
    'no door socket wired for this entrypoint');

class _MeshtechAppState extends State<MeshtechApp> {
  ConnectionSettings _settings = const ConnectionSettings();
  late final NodeStore _store;
  late final LinkEvents _events;
  late TcpLink _tcpLink;
  LinkState _linkState = LinkState.disabled;
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

  bool _mounted = true; // link callbacks can outlive the widget tree

  /// The log lives in state; packets arriving from link callbacks
  /// append here (the map's log box reads it).
  void _logLine(String line) {
    _log.insert(0, line);
    if (_log.length > 50) _log.removeLast();
    _safeSetState(() {});
  }

  @override
  void initState() {
    super.initState();
    _store = NodeStore();
    _events = LinkEvents(
      onState: (s, d) => _safeSetState(() {
        _linkState = s;
        _linkDetail = d;
      }),
      onPacket: (packet, {heardMs}) => _onPacket(packet, heardMs),
      onLog: (line) => _safeSetState(() {
        _log.insert(0, line);
        if (_log.length > 50) _log.removeLast();
      }),
      onReset: () => _store.resetAll(),
    );
    _tcpLink = _buildLink();
    _bootstrap();
  }

  /// Link callbacks (and the debounced persist) can fire after the
  /// widget tree is torn down - setState on a defunct state is a
  /// framework assertion, not a style question.
  void _safeSetState(VoidCallback fn) {
    if (!_mounted) return;
    setState(fn);
  }

  TcpLink _buildLink() => TcpLink(
        _events,
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
  Future<void> _connect(String host, String password, int mapSizeKm,
      String homeZip, (double, double)? homeCenter) async {
    final next = _settings.copyWith(
      host: host,
      password: password,
      mapSizeKm: mapSizeKm,
      homeZip: homeZip,
      homeLat: homeCenter?.$1 ?? _settings.homeLat,
      homeLon: homeCenter?.$2 ?? _settings.homeLon,
    );
    await SettingsStore().save(next);
    if (!mounted) return;
    setState(() {
      _settings = next;
      _tcpLink = _buildLink();
    });
    await _tcpLink.connect();
  }

  void _disconnect() => _tcpLink.disconnect();

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
  /// the phone holds; the server's limiter decides, honestly).
  void _ask() => _tcpLink.sendVectoredAsk(
      syncMarker: _settings.syncMarker,
      spanKm: _settings.mapSizeKm,
      origin: _settings.origin);

  /// THE TAP-ASK (design section 10): tapping a node asks the server
  /// section it sits in - the answer's routes draw dot-to-dot. The
  /// section is computed from the node's REAL position on the
  /// server's frame (the wire's 3x3 - section ids are the server's
  /// language), not the phone's 3x4 view grid.
  void _onDotTap(DotVM dot) {
    final section = _serverSectionOf(dot);
    if (section == 0) return; // outside every server section: honest no-op
    setState(() => _tappedPrefix = dot.prefix);
    _tcpLink.sendSectionAsk(
        sectionId: section, origin: _settings.origin);
  }

  /// Which server 3x3 section a position falls in - computed against
  /// the heard LAYOUT (the same frame the wire uses for section ids).
  int _serverSectionOf(DotVM dot) {
    final l = _tcpLink.layout;
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
    return MaterialApp(
      title: 'meshtech',
      theme: _bluelineTheme(),
      home: _linkState == LinkState.connected
          ? MainPage(
              store: _store,
              settings: _settings,
              frameName: _frameName,
              frameCenter: _frameCenter,
              pulse: _pulse,
              log: _log,
              linkDetail: _linkDetail,
              onDisconnect: _disconnect,
              onAsk: _ask,
              onMapSizeChange: _changeMapSize,
              onDotTap: _onDotTap,
              tappedPrefix: _tappedPrefix,
              sectionRouteIds: _sectionRoutes,
            )
          : Scaffold(
              // ConnectScreen draws TextFields: it needs a Material
              // ancestor (the map screen builds its own Scaffold).
              body: ConnectScreen(
                settings: _settings,
                linkState: _linkState,
                linkDetail: _linkDetail,
                linkLog: _log,
                onConnect: _connect,
                onDisconnect: _disconnect,
              ),
            ),
    );
  }
}
