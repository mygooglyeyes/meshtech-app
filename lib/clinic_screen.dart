// THE CLINIC PAGE (Brett, 2026-09-30): "+clinic" on the map opens
// THIS page - "instead of the data changing on the map when tapping
// on a clinic chip, I want there to be a main +clinic button that
// when you tap it, it takes you to a new 'clinic' page." The clinic
// chips, the time window and the section list live HERE now, off the
// map (the map drew every route at once and drowned the labels).
//
// THE FLOW (his words): tap a clinic option, then a section number
// -> that section's map with the chosen family drawn on it (routes /
// nodes / trouble flags / whatever was chosen), then a back button
// to come back to THIS page. The choices live in the shell, so they
// survive the round trip and the chips are still lit on return.

import 'package:flutter/material.dart' hide Route;

import 'clinic_store.dart';
import 'map_model.dart';
import 'store.dart';

class ClinicScreen extends StatelessWidget {
  /// The clinic facts - what the chips, the strip and the loose
  /// list read from (never from anywhere else).
  final ClinicStore clinic;

  /// The node store: where a fact's place comes from (the same read
  /// the section maps do when they draw the family).
  final NodeStore store;

  /// The chosen family and time window (the shell keeps them - they
  /// survive the section-map round trip).
  final ClinicView view;
  final int windowMin;
  final ValueChanged<ClinicView> onView;
  final ValueChanged<int> onWindow;

  /// A section number tapped: the shell opens that section's map
  /// with the CHOSEN family drawn on it. The numbers are the ones
  /// the map's squares wear (the shell holds the map's own grid).
  final ValueChanged<int> onPick;

  final VoidCallback onClose;

  const ClinicScreen({
    super.key,
    required this.clinic,
    required this.store,
    required this.view,
    required this.windowMin,
    required this.onView,
    required this.onWindow,
    required this.onPick,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // The same layer the section maps draw - counted here so the
    // honest strip speaks BEFORE any map opens.
    final layer = ClinicLayerVM.build(clinic, store, view,
        nowMs: nowMs, windowMin: windowMin);
    final sectionCount = ViewGrid.viewCols * ViewGrid.viewRows;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('clinic-back'),
          tooltip: 'Back to the map',
          icon: const Icon(Icons.arrow_back),
          onPressed: onClose,
        ),
        title: const Text('Clinic'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // THE CHIPS + THE TIME WINDOW (they left the map): the
          // fact family draws per the chip, the window keeps only
          // what was heard inside it.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (v, name) in const [
                          (ClinicView.nodes, 'Node health'),
                          (ClinicView.routes, 'Route health'),
                          (ClinicView.trouble, 'Trouble flags'),
                          (ClinicView.secondHand, 'Second-hand'),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: ChoiceChip(
                              label: Text(name,
                                  style: const TextStyle(fontSize: 14)),
                              selected: view == v,
                              onSelected: (_) => onView(v),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                DropdownButton<int>(
                  key: const ValueKey('clinic-window'),
                  value: windowMin,
                  isDense: true,
                  style: const TextStyle(fontSize: 14, color: Colors.white),
                  dropdownColor: const Color(0xFF123B63),
                  items: const [
                    DropdownMenuItem(value: 60, child: Text('1 hr')),
                    DropdownMenuItem(value: 240, child: Text('4 hrs')),
                    DropdownMenuItem(value: 720, child: Text('12 hrs')),
                    DropdownMenuItem(value: 1440, child: Text('1 day')),
                    DropdownMenuItem(value: 10080, child: Text('7 days')),
                    DropdownMenuItem(value: 20160, child: Text('14 days')),
                  ],
                  onChanged: (v) {
                    if (v != null) onWindow(v);
                  },
                ),
              ],
            ),
          ),
          // THE CLINIC STRIP (moved here from the map): what the
          // chosen family holds and what has no place - the honest
          // gap, said out loud (never invented).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '${layer.markers.length + layer.lines.length} clinic fact(s) '
              'in this view - ${layer.secondHandDrawn} reported'
              '${layer.unpositioned > 0 ? ' - ${layer.unpositioned} without a place' : ''}',
              key: const ValueKey('clinic-strip'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (layer.unpositioned > 0)
            TextButton(
              key: const ValueKey('clinic-loose'),
              onPressed: () => _openLooseSheet(context),
              child: Text(
                'read the ${layer.unpositioned} fact(s) without a place',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          // THE SECTION LIST (Brett: "a list of sections bigger
          // font"): tap the chosen family's chip first, then a
          // section number - that section's map opens with the
          // family drawn on it, and its back button returns here.
          Expanded(
            child: ListView(
              children: [
                for (var id = 1; id <= sectionCount; id++)
                  ListTile(
                    key: ValueKey('clinic-section-$id'),
                    title: Text(
                      'Section $id',
                      style: const TextStyle(fontSize: 20),
                    ),
                    onTap: () => onPick(id),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The loose list: one line per fact that has no place - the same
  /// honest card the map used to open from its strip.
  void _openLooseSheet(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lines = ClinicCards.looseCard(clinic, nowMs: nowMs);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            Text(lines.first, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final line in lines.skip(1))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(line, style: Theme.of(ctx).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}
