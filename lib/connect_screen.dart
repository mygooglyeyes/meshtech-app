// The connect screen (DESIGN.md section 3): hilltop address + data-door
// password + THE MAP SIZE - chosen BEFORE connect, saved with the rest.
// The size selector here is the one the map obeys; changing it later
// redraws only (section 3, rule 2) - it never asks hilltop for anything.

import 'package:flutter/material.dart';

import 'link.dart' show LinkState;
import 'settings.dart';

class ConnectScreen extends StatefulWidget {
  final ConnectionSettings settings;
  final SettingsStore settingsStore;
  final Future<void> Function() onConnect;
  final VoidCallback onDisconnect;
  final LinkState linkState;
  final String linkDetail;
  final List<String> linkLog;

  const ConnectScreen({
    super.key,
    required this.settings,
    required this.settingsStore,
    required this.onConnect,
    required this.onDisconnect,
    required this.linkState,
    this.linkDetail = '',
    this.linkLog = const [],
  });

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _host;
  late final TextEditingController _password;
  late int _mapSizeKm;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.settings.host);
    _password = TextEditingController(text: widget.settings.password);
    _mapSizeKm = widget.settings.mapSizeKm;
  }

  @override
  void dispose() {
    _host.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _onConnect() async {
    final host = _host.text.trim();
    if (host.isEmpty) return; // the log line says what's missing
    // Save FIRST (address + password + size live together, section 3).
    await widget.settingsStore.save(widget.settings.copyWith(
      host: host,
      password: _password.text.trim(),
      mapSizeKm: _mapSizeKm,
    ));
    await widget.onConnect();
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.linkState == LinkState.connected;
    final log = widget.linkLog.isEmpty
        ? const <String>[]
        : widget.linkLog;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Connect',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'Hilltop address',
              hintText: '192.168.12.145 (or host:port)',
              border: OutlineInputBorder(),
            ),
            enabled: !connected,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Data-door password',
              border: OutlineInputBorder(),
            ),
            enabled: !connected,
          ),
          const SizedBox(height: 12),
          // THE SIZE LIVES HERE, BEFORE CONNECT (section 3, rule 1).
          DropdownButtonFormField<int>(
            initialValue: _mapSizeKm,
            decoration: const InputDecoration(
              labelText: 'Map size (picked before connect)',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final km in ConnectionSettings.allowedSizes)
                DropdownMenuItem(
                    value: km,
                    child: Text(ConnectionSettings.sizeLabels[km]!)),
            ],
            onChanged: connected
                ? null // live link: size changes are a map-screen redraw
                : (v) => setState(() => _mapSizeKm = v ?? 40),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: connected
                ? widget.onDisconnect
                : (widget.linkState == LinkState.connecting
                    ? null
                    : _onConnect),
            child: Text(switch (widget.linkState) {
              LinkState.connected => 'Disconnect',
              LinkState.connecting => 'Connecting...',
              LinkState.disabled => 'Connect',
            }),
          ),
          if (widget.linkDetail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(widget.linkDetail,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: ListView.builder(
                itemCount: log.length,
                itemBuilder: (_, i) => Text(log[i],
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
