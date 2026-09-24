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

import 'package:flutter/material.dart';

import 'codec.dart';
import 'connect_screen.dart';
import 'door_socket.dart';
import 'link.dart';
import 'map_screen.dart';
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
  Timer? _saveTimer;

  bool _mounted = true; // link callbacks can outlive the widget tree

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
      );

  Future<void> _bootstrap() async {
    final loaded = await SettingsStore().load();
    _store.noteSyncMarker(loaded.syncMarker);
    await _store.load();
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
        setState(() {
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
      default:
        break; // PULSE/SECT_SUM/ROUTE detail screens come later
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      _store.save().then((_) => SettingsStore()
          .save(_settings.copyWith(syncMarker: _store.syncMarker)));
    });
    _safeSetState(() {});
  }

  Future<void> _connect() async {
    _tcpLink = _buildLink();
    await _tcpLink.connect();
  }

  void _disconnect() => _tcpLink.disconnect();

  @override
  void dispose() {
    _mounted = false;
    _saveTimer?.cancel();
    _tcpLink.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'meshtech',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF4A90D9)),
      home: _linkState == LinkState.connected
          ? MapScreen(
              store: _store,
              settings: _settings,
              frameName: _frameName,
              frameCenter: _frameCenter,
              onDisconnect: _disconnect,
            )
          : Scaffold(
              // ConnectScreen draws TextFields: it needs a Material
              // ancestor (the map screen builds its own Scaffold).
              body: ConnectScreen(
                settings: _settings,
                settingsStore: SettingsStore(),
                linkState: _linkState,
                linkDetail: _linkDetail,
                linkLog: _log,
                onConnect: () async => _connect(),
                onDisconnect: _disconnect,
              ),
            ),
    );
  }
}
