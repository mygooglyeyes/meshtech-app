// The connect screen (DESIGN.md section 3): hilltop address + data-door
// password + THE MAP SIZE - chosen BEFORE connect, saved with the rest.
// The size selector here is the one the map obeys; changing it later
// redraws only (section 3, rule 2) - it never asks hilltop for anything.

import 'package:flutter/material.dart';

import 'link.dart' show LinkState;
import 'settings.dart';
import 'zip.dart';

class ConnectScreen extends StatefulWidget {
  final ConnectionSettings settings;
  // The TYPED facts go UP on connect (first-run lesson: the shell must
  // dial what is in the fields, not a stale saved copy). homeCenter is
  // the freshly-resolved ZIP center (null = keep the saved one).
  final Future<void> Function(String host, String password, int mapSizeKm,
      String homeZip, (double, double)? homeCenter) onConnect;
  final VoidCallback onDisconnect;
  final LinkState linkState;
  final String linkDetail;
  final List<String> linkLog;

  const ConnectScreen({
    super.key,
    required this.settings,
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
  late final TextEditingController _zip;
  late int _mapSizeKm;
  bool _zipBusy = false;
  String? _zipError;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.settings.host);
    _password = TextEditingController(text: widget.settings.password);
    _zip = TextEditingController(text: widget.settings.homeZip);
    _mapSizeKm = widget.settings.mapSizeKm;
  }

  @override
  void dispose() {
    _host.dispose();
    _password.dispose();
    _zip.dispose();
    super.dispose();
  }

  Future<void> _onConnect() async {
    final host = _host.text.trim();
    if (host.isEmpty) return; // the log line says what's missing
    // THE HOME AREA (section 9): a 5-digit ZIP gets looked up ONLINE
    // (first run has internet), its center saved as hard data. An
    // empty box keeps what is already saved; a bad lookup shows its
    // honest error and STOPS - never a guessed center.
    final zip = _zip.text.trim();
    (double, double)? center;
    if (zip.isNotEmpty && zip != widget.settings.homeZip) {
      setState(() {
        _zipBusy = true;
        _zipError = null;
      });
      try {
        center = await lookupZip(zip);
      } on ZipLookupException catch (e) {
        setState(() {
          _zipBusy = false;
          _zipError = e.message;
        });
        return;
      }
      if (!mounted) return;
      setState(() => _zipBusy = false);
    }
    // Hand the TYPED facts up: the shell saves them, rebuilds the
    // link, and dials with what is real (section 3).
    await widget.onConnect(
        host, _password.text.trim(), _mapSizeKm, zip, center);
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
          // THE HOME AREA (section 9): chosen once, saved as hard
          // data - the map's center comes from here.
          TextField(
            controller: _zip,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Home ZIP code',
              hintText: '94945',
              border: const OutlineInputBorder(),
              errorText: _zipError,
              helperText: widget.settings.homeLon != 0
                  ? 'saved: ${widget.settings.homeZip}'
                  : null,
            ),
            enabled: !connected && !_zipBusy,
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
                : (widget.linkState == LinkState.connecting || _zipBusy
                    ? null
                    : _onConnect),
            child: Text(switch (widget.linkState) {
              LinkState.connected => 'Disconnect',
              LinkState.connecting => 'Connecting...',
              LinkState.disabled => _zipBusy ? 'Looking up ZIP...' : 'Connect',
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
