// Persisted connection settings (DESIGN.md section 3: the map size is
// picked BEFORE connect and lives with the address and password).

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class ConnectionSettings {
  final String host; // "192.168.12.145" or "host:port"
  final String password; // the data-door token
  final int mapSizeKm; // 20 / 40 / 60 - chosen BEFORE connect
  final int origin; // this client's 2-byte id on the wire
  final int syncMarker; // vectored-sync marker (what the phone has)

  const ConnectionSettings({
    this.host = '',
    this.password = '',
    this.mapSizeKm = 40,
    this.origin = 0,
    this.syncMarker = 0,
  });

  ConnectionSettings copyWith({
    String? host,
    String? password,
    int? mapSizeKm,
    int? origin,
    int? syncMarker,
  }) =>
      ConnectionSettings(
        host: host ?? this.host,
        password: password ?? this.password,
        mapSizeKm: mapSizeKm ?? this.mapSizeKm,
        origin: origin ?? this.origin,
        syncMarker: syncMarker ?? this.syncMarker,
      );

  /// The sizes the design allows, with their honest budget labels.
  static const List<int> allowedSizes = [20, 40, 60];
  static const Map<int, String> sizeLabels = {
    20: '20 km (3/hour)',
    40: '40 km (2/hour)',
    60: '60 km (1/hour)',
  };
}

class SettingsStore {
  static const _key = 'connection';

  Future<ConnectionSettings> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null) {
      // First run: mint this client's 2-byte wire origin once, forever.
      final origin = Random().nextInt(0xFFFF) + 1;
      final fresh = ConnectionSettings(origin: origin);
      await save(fresh);
      return fresh;
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return ConnectionSettings(
      host: m['host'] as String? ?? '',
      password: m['password'] as String? ?? '',
      mapSizeKm: m['mapSizeKm'] as int? ?? 40,
      origin: m['origin'] as int? ?? 1,
      syncMarker: m['syncMarker'] as int? ?? 0,
    );
  }

  Future<void> save(ConnectionSettings s) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode({
      'host': s.host,
      'password': s.password,
      'mapSizeKm': s.mapSizeKm,
      'origin': s.origin,
      'syncMarker': s.syncMarker,
    }));
  }
}
