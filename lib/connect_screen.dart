// The connect screen (DESIGN.md section 3): THE 4-WAY LINK SELECTOR
// (Brett 2026-09-25 - four chips: BLE / USB / WiFi / TCP) + the
// facts the chosen link needs + THE MAP SIZE - chosen BEFORE connect,
// saved with the rest.
//
// THE SELECTOR'S LAW: nothing ever connects on its own. The app
// waits on this screen; Connect only becomes pressable once a chip is
// chosen, and it acts for THAT chip alone. The hilltop address +
// data-door password belong to TCP only, so they wait behind the TCP
// chip. WiFi on this selector is a companion found over the network
// (NOT the TCP door - planned later, says so plainly today). The size
// selector here is the one the map obeys; changing it later redraws
// only (section 3, rule 2) - it never asks hilltop for anything.

import 'package:flutter/material.dart';

import 'link.dart' show LinkState;
import 'settings.dart';
import 'zip.dart';

// The four link chips (shared with the shell, which routes the press).
const String linkBle = 'ble';
const String linkUsb = 'usb';
const String linkWifi = 'wifi';
const String linkTcp = 'tcp';

class ConnectScreen extends StatefulWidget {
  final ConnectionSettings settings;
  // The TYPED facts go UP on connect (first-run lesson: the shell must
  // dial what is in the fields, not a stale saved copy). homeCenter is
  // the freshly-resolved ZIP center (null = keep the saved one). The
  // first arg is WHICH CHIP was selected - the shell connects that
  // link and no other.
  final Future<void> Function(String link, String host, String password,
      int mapSizeKm, String homeZip, (double, double)? homeCenter)
      onConnect;
  final VoidCallback onDisconnect;
  final LinkState linkState;
  final String linkDetail;

  /// THE RADIO STATUS LINE (Brett 2026-09-25): the companion link's
  /// state in plain words, always in the same spot - the bench reads
  /// it at a glance instead of through adb.
  final String radioStatus;
  final List<String> linkLog;

  const ConnectScreen({
    super.key,
    required this.settings,
    required this.onConnect,
    required this.onDisconnect,
    required this.linkState,
    this.linkDetail = '',
    this.radioStatus = '',
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
  String? _error; // the plain-words verdict of a Connect press

  /// The chosen chip: 'ble' | 'usb' | 'wifi' | 'tcp' - null until the
  /// user picks one. Connect stays unpressable while null (the
  /// selector's law: wait for the choice, never connect on its own).
  String? _target;

  /// The four chips, in the order Brett named them.
  static const _targets = [
    (linkBle, 'BLE'),
    (linkUsb, 'USB'),
    (linkWifi, 'WiFi'),
    (linkTcp, 'TCP'),
  ];

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.settings.host);
    _password = TextEditingController(text: widget.settings.password);
    _zip = TextEditingController(text: widget.settings.homeZip);
    _mapSizeKm = widget.settings.mapSizeKm;
  }

  /// THE FIELDS FILL WHEN THE SETTINGS ARRIVE (Brett 2026-09-25,
  /// Bug A): the first frame builds these controllers BEFORE the
  /// async load finishes, so they used to start EMPTY even with a
  /// saved address - and Connect then refused silently. When the
  /// settings land (new widget), any field the human hasn't touched
  /// (still empty) takes its saved value. Never overwrites typing.
  @override
  void didUpdateWidget(covariant ConnectScreen old) {
    super.didUpdateWidget(old);
    if (identical(old.settings, widget.settings)) return;
    if (_host.text.isEmpty && widget.settings.host.isNotEmpty) {
      _host.text = widget.settings.host;
    }
    if (_password.text.isEmpty && widget.settings.password.isNotEmpty) {
      _password.text = widget.settings.password;
    }
    if (_zip.text.isEmpty && widget.settings.homeZip.isNotEmpty) {
      _zip.text = widget.settings.homeZip;
    }
    if (_error != null && _host.text.isNotEmpty) _error = null;
  }

  @override
  void dispose() {
    _host.dispose();
    _password.dispose();
    _zip.dispose();
    super.dispose();
  }

  Future<void> _onConnect() async {
    final target = _target;
    // THE DEVICE LOG (Brett 2026-09-25): where a Connect press dies,
    // visible in adb.
    debugPrint('CONNECT TAP link=${target ?? "-"} host="${_host.text}"'
        ' pwd(${_password.text.length}) zip="${_zip.text}"');
    if (target == null) {
      // The button gates this too - belt and braces, never silent.
      setState(() => _error = 'pick a link type first');
      return;
    }
    final host = _host.text.trim();
    // NO SILENT REFUSAL (Brett, 2026-09-25): an empty address says
    // so on screen and in the device log - the button never again
    // appears dead. TCP is the only link that dials an address.
    if (target == linkTcp && host.isEmpty) {
      setState(() => _error = 'no address yet - type the hilltop address');
      debugPrint('CONNECT REFUSED: empty address');
      return;
    }
    if (_error != null) setState(() => _error = null);
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
    // link, and dials what is real (section 3) - for the ONE link the
    // selected chip names.
    await widget.onConnect(target, host, _password.text.trim(),
        _mapSizeKm, zip, center);
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
          // FOUR CHIPS (Brett 2026-09-25): one per link type. Nothing
          // connects on its own - the button below only becomes
          // pressable once a chip is chosen, and then it acts for THAT
          // chip alone.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (id, label) in _targets)
                ChoiceChip(
                  label: Text(label),
                  selected: _target == id,
                  onSelected: connected
                      ? null
                      : (sel) =>
                          setState(() => _target = sel ? id : null),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // The address + door password are TCP's facts only - they
          // wait behind the TCP chip (WiFi on the selector means a
          // companion over the network, not this door).
          if (_target == linkTcp) ...[
            TextField(
              controller: _host,
              onTap: () => debugPrint('FIELD-AT host'),
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
              onTap: () => debugPrint('FIELD-AT password'),
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Data-door password',
                border: OutlineInputBorder(),
              ),
              enabled: !connected,
            ),
            const SizedBox(height: 12),
          ],
          // THE HOME AREA (section 9): chosen once, saved as hard
          // data - the map's center comes from here.
          TextField(
            controller: _zip,
            onTap: () => debugPrint('FIELD-AT zip'),
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
          // THE RADIO STATUS LINE: one fixed spot, plain words,
          // always shown - scanning / connected + #scope slot / the
          // honest refusal. The bench's glance, not the log's scroll.
          if (widget.radioStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(widget.radioStatus,
                  key: const ValueKey('radio-status'),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          FilledButton(
            onPressed: connected
                ? widget.onDisconnect
                : (widget.linkState == LinkState.connecting ||
                        _zipBusy ||
                        // THE SELECTOR'S LAW: no chip = no press.
                        _target == null
                    ? null
                    : _onConnect),
            child: Text(switch (widget.linkState) {
              LinkState.connected => 'Disconnect',
              LinkState.connecting => 'Connecting...',
              LinkState.disabled => _zipBusy ? 'Looking up ZIP...' : 'Connect',
            }),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: Theme.of(context).textTheme.bodySmall),
            )
          else if (widget.linkDetail.isNotEmpty)
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
