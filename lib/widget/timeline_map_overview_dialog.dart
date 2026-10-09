import 'package:backend/config/design.dart';
import 'package:backend/config/app_colors.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:backend/widget/location_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:backend/widget/app_snackbar.dart';

/// Lets an admin see every timeline event's resolved location on a single
/// map and fix the ones that are missing or plain wrong (e.g. geocoded to
/// the wrong country), instead of having to open each event's edit dialog
/// one at a time to find and fix a bad pin.
///
/// An event's location can be set three ways: searching in its row,
/// searching in the box on the map, or selecting the event and clicking
/// the map. Pins can be dragged to fine-tune them.
class TimelineMapOverviewDialog extends StatefulWidget {
  final GroupInformation groupInformation;
  final GroupInformationRepository repository;

  const TimelineMapOverviewDialog({
    super.key,
    required this.groupInformation,
    required this.repository,
  });

  @override
  State<TimelineMapOverviewDialog> createState() =>
      _TimelineMapOverviewDialogState();
}

class _TimelineMapOverviewDialogState extends State<TimelineMapOverviewDialog> {
  final MapController _mapController = MapController();
  final TextEditingController _mapSearchController = TextEditingController();
  late List<TimelineEvent> _events;
  String? _selectedEventId;
  bool _saving = false;
  // The last place picked in the map's search box, highlighted on the map
  // until another search or the label's close button.
  PlaceSuggestion? _searchHighlight;

  @override
  void initState() {
    super.initState();
    _events = List.of(widget.groupInformation.timelineEvents)
      ..sort((a, b) => a.startDate.compareTo(b.startDate));
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitToMarkers());
  }

  @override
  void dispose() {
    _mapSearchController.dispose();
    super.dispose();
  }

  List<TimelineEvent> get _locatedEvents =>
      _events.where((e) => e.latitude != null && e.longitude != null).toList();

  /// Event id → the same 1-based number shown on its pin on the map, so the
  /// list can display a matching badge next to each event.
  Map<String, int> get _markerNumbers => {
        for (final entry in _locatedEvents.asMap().entries)
          entry.value.id: entry.key + 1,
      };

  TimelineEvent? get _selectedEvent {
    for (final e in _events) {
      if (e.id == _selectedEventId) return e;
    }
    return null;
  }

  void _fitToMarkers() {
    final points =
        _locatedEvents.map((e) => LatLng(e.latitude!, e.longitude!)).toList();
    if (points.isEmpty) return;
    if (points.length == 1) {
      _mapController.move(points.first, 11);
    } else {
      _mapController.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(48),
      ));
    }
  }

  void _replaceEvent(TimelineEvent updated) {
    final index = _events.indexWhere((e) => e.id == updated.id);
    if (index != -1) _events[index] = updated;
  }

  void _selectEvent(TimelineEvent event) {
    setState(() => _selectedEventId = event.id);
    if (event.latitude != null && event.longitude != null) {
      final zoom = _mapController.camera.zoom;
      _mapController.move(
          LatLng(event.latitude!, event.longitude!), zoom < 12 ? 12 : zoom);
    }
  }

  /// Sets [eventId]'s location. With no [address] (a click or a drag on the
  /// map), the coordinates are shown until a reverse lookup fills in the
  /// address at that spot.
  void _setLocation(String eventId, LatLng point,
      {String? address, PlaceSuggestion? focus}) {
    final event = _events.firstWhere((e) => e.id == eventId);
    setState(() {
      _replaceEvent(_withLocation(event,
          address: address ?? formatLatLng(point),
          latitude: point.latitude,
          longitude: point.longitude));
      _selectedEventId = eventId;
    });
    if (focus != null) focusMapOn(_mapController, focus);
    if (address == null) _fillAddressFromMap(eventId, point);
  }

  Future<void> _fillAddressFromMap(String eventId, LatLng point) async {
    final address = await Geocoder.reverse(point);
    if (!mounted || address == null) return;
    final event = _events.firstWhere((e) => e.id == eventId);
    // The pin was moved again (or cleared) while the lookup ran.
    if (event.latitude != point.latitude ||
        event.longitude != point.longitude) {
      return;
    }
    setState(() => _replaceEvent(_withLocation(event,
        address: address,
        latitude: point.latitude,
        longitude: point.longitude)));
  }

  /// Events with no point yet whose location can be guessed from their
  /// "Land, By eller Område" field. Ones the admin gave a specific address
  /// are left alone — a guess from the country would be less precise.
  List<TimelineEvent> get _autoLocatable => _events.where((e) {
        final country = e.country.trim();
        final address = (e.address ?? '').trim();
        return (e.latitude == null || e.longitude == null) &&
            country.isNotEmpty &&
            (address.isEmpty || address == country);
      }).toList();

  /// Looks up each auto-locatable event's country/city, one per ~second
  /// (Nominatim's usage policy). Results only change this dialog's copy —
  /// nothing is written until "Gem ændringer".
  Future<void> _autoLocate() async {
    final targets = _autoLocatable;
    if (targets.isEmpty) {
      final unplaced = _events
          .where((e) => e.latitude == null || e.longitude == null)
          .length;
      showInfoSnackbar(
          context,
          unplaced == 0
              ? 'Alle begivenheder har allerede en placering.'
              : '$unplaced begivenhed${unplaced == 1 ? '' : 'er'} uden placering har en specifik adresse eller intet land, så de kan ikke findes automatisk. Placér dem ved at søge eller klikke på kortet.');
      return;
    }
    // Unplaced events the auto-lookup will skip because the admin typed a
    // specific address for them — mentioned in the dialog so nobody wonders
    // why those stayed empty.
    final skipped =
        _events.where((e) => e.latitude == null || e.longitude == null).length -
            targets.length;

    final found = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AutoLocateDialog(
        targets: targets,
        skippedCount: skipped,
        locate: _locateFromCountry,
      ),
    );
    if (found == null || !mounted) return;

    _fitToMarkers();
    showAppSnackbar(
      context,
      'Fandt placering for $found af ${targets.length} begivenheder · kontrollér nålene og tryk "Gem ændringer"',
      type: found == targets.length ? SnackType.success : SnackType.warning,
      duration: const Duration(seconds: 6),
    );
  }

  /// Places [target] from its "Land, By eller Område" text. Returns whether
  /// a location was found. Leaves it alone if the admin placed it by hand
  /// while the lookup ran.
  Future<bool> _locateFromCountry(TimelineEvent target) async {
    final country = target.country.trim();
    final List<PlaceSuggestion> results;
    try {
      results = await Geocoder.search(country, limit: 1);
    } catch (_) {
      return false;
    }
    if (!mounted || results.isEmpty) return false;
    final current = _events.firstWhere((e) => e.id == target.id);
    if (current.latitude != null) return false;
    final point = results.first.point;
    setState(() => _replaceEvent(_withLocation(current,
        address: country,
        latitude: point.latitude,
        longitude: point.longitude)));
    return true;
  }

  void _onMapTap(LatLng point) {
    final selected = _selectedEvent;
    if (selected == null) {
      showInfoSnackbar(context, 'Vælg først en begivenhed i listen til højre');
      return;
    }
    _setLocation(selected.id, point);
  }

  /// Shows the searched place — events are put there from its "+" button
  /// rather than automatically, so a search never moves a pin by surprise.
  void _onMapSearchSelected(PlaceSuggestion suggestion) {
    setState(() => _searchHighlight = suggestion);
    focusMapOn(_mapController, suggestion);
    _mapSearchController.clear();
  }

  /// Puts [event] at the highlighted search result — after a warning if
  /// that would move a location it already has.
  Future<void> _placeAtHighlight(TimelineEvent event) async {
    final place = _searchHighlight;
    if (place == null) return;
    if (event.latitude != null && event.longitude != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _MoveLocationDialog(event: event, place: place),
      );
      if (confirmed != true || !mounted) return;
    }
    _setLocation(event.id, place.point, address: place.displayName);
    setState(() => _searchHighlight = null);
  }

  Widget _buildHighlightMenu() {
    final numbers = _markerNumbers;
    return PopupMenuButton<TimelineEvent>(
      tooltip: 'Placér en begivenhed her',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 360),
      shape: RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
      color: Colors.white,
      onSelected: _placeAtHighlight,
      itemBuilder: (_) => [
        PopupMenuItem<TimelineEvent>(
          enabled: false,
          height: 36,
          child: Text('Placér begivenhed her',
              style: GoogleFonts.kanit(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[600])),
        ),
        for (final event in _events)
          PopupMenuItem<TimelineEvent>(
            value: event,
            child: Row(
              children: [
                if (numbers[event.id] != null)
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text('${numbers[event.id]}',
                        style: GoogleFonts.kanit(
                            color: AppColors.onPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 11)),
                  )
                else
                  const SizedBox(
                    width: 22,
                    child: Icon(Icons.error_outline,
                        color: Colors.orange, size: 18),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${event.type}${event.country.isNotEmpty ? ' · ${event.country}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.kanit(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        numbers[event.id] != null
                            ? 'Har allerede en placering'
                            : 'Mangler placering',
                        style: GoogleFonts.kanit(
                            fontSize: 11,
                            color: numbers[event.id] != null
                                ? Colors.grey[600]
                                : Colors.orange[800]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
      child: const HighlightPlusButton(),
    );
  }

  void _clearLocation(TimelineEvent event) {
    setState(() => _replaceEvent(
        _withLocation(event, address: null, latitude: null, longitude: null)));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final groupDocRef = widget.repository.firestore
          .collection('groups')
          .doc(widget.groupInformation.groupId);
      final snapshot = await groupDocRef.get();
      final eventsList = List<dynamic>.from(
          (snapshot.data()?['timelineEvents'] as List?) ?? []);
      for (final event in _events) {
        final index = eventsList.indexWhere((e) => e['id'] == event.id);
        if (index != -1) eventsList[index] = event.toMap();
      }
      await groupDocRef.update({'timelineEvents': eventsList});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      print('Error saving timeline locations: $e');
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackbar(context, 'Kunne ikke gemme ændringer');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final located = _locatedEvents;
    final numbers = _markerNumbers;
    final selected = _selectedEvent;

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(AppSpacing.xxl),
      shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
      child: SizedBox(
        width: 1100,
        height: 720,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.map_outlined, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Verificer lokationer på kort',
                        style: AppTextStyles.headingBold()),
                  ),
                  Tooltip(
                    message:
                        'Placér begivenheder uden placering ud fra "Land, By eller Område"',
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : _autoLocate,
                      icon: const Icon(Icons.my_location, size: 16),
                      label: Text(
                          _autoLocatable.isEmpty
                              ? 'Opdater pinpoints automatisk'
                              : 'Opdater pinpoints automatisk (${_autoLocatable.length})',
                          style:
                              GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey[800],
                        side: BorderSide(color: Colors.grey.shade400),
                        shape: RoundedRectangleBorder(
                            borderRadius: AppRadii.smRadius),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(20)),
                      child: PinMap(
                        controller: _mapController,
                        initialCenter: located.isNotEmpty
                            ? LatLng(located.first.latitude!,
                                located.first.longitude!)
                            : defaultMapCenter,
                        initialZoom: located.isNotEmpty ? 11 : 4,
                        drawRoute: true,
                        pins: [
                          for (final e in located)
                            MapPin(
                              id: e.id,
                              point: LatLng(e.latitude!, e.longitude!),
                              label: '${numbers[e.id]}',
                              selected: e.id == _selectedEventId,
                            ),
                        ],
                        onTapMap: _onMapTap,
                        highlight: _searchHighlight,
                        highlightAction:
                            _events.isEmpty ? null : _buildHighlightMenu(),
                        onClearHighlight: () =>
                            setState(() => _searchHighlight = null),
                        onTapPin: (id) => setState(() => _selectedEventId = id),
                        onPinMoved: (id, point) => _setLocation(id, point),
                        overlays: [
                          Positioned(
                            top: 12,
                            left: 12,
                            right: 12,
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 420),
                                child: Material(
                                  color: Colors.transparent,
                                  child: PlaceSearchField(
                                    controller: _mapSearchController,
                                    onSelected: _onMapSearchSelected,
                                    decoration: InputDecoration(
                                      isDense: true,
                                      filled: true,
                                      fillColor: Colors.white,
                                      prefixIcon:
                                          const Icon(Icons.search, size: 18),
                                      hintText: 'Søg adresse eller sted',
                                      hintStyle: AppTextStyles.body(
                                          color: Colors.grey[500]),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 12),
                                      border: OutlineInputBorder(
                                        borderRadius: AppRadii.smRadius,
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 12,
                            bottom: 12,
                            right: 12,
                            child: Align(
                              alignment: Alignment.bottomLeft,
                              child: MapHint(_searchHighlight != null
                                  ? 'Tryk på + for at placere en begivenhed på det søgte sted'
                                  : selected != null
                                      ? 'Klik på kortet for at placere "${selected.type}" · træk i en nål for at flytte den'
                                      : 'Vælg en begivenhed i listen, og klik på kortet for at placere den · træk i en nål for at flytte den'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(width: 1, color: Colors.grey.shade300),
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Vælg en begivenhed, og søg adressen eller klik på kortet.',
                              style: GoogleFonts.kanit(
                                  fontSize: 12, color: Colors.grey[600]),
                            ),
                          ),
                        ),
                        Expanded(
                          child: _events.isEmpty
                              ? Center(
                                  child: Text(
                                    'Ingen begivenheder i rejseforløbet endnu',
                                    style: GoogleFonts.kanit(
                                        color: Colors.grey[600]),
                                  ),
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.all(14),
                                  itemCount: _events.length,
                                  itemBuilder: (context, index) {
                                    final event = _events[index];
                                    return _EventLocationRow(
                                      key: ValueKey(event.id),
                                      event: event,
                                      markerNumber: numbers[event.id],
                                      isSelected: event.id == _selectedEventId,
                                      onSelect: () => _selectEvent(event),
                                      onSuggestionSelected: (s) => _setLocation(
                                          event.id, s.point,
                                          address: s.displayName, focus: s),
                                      onCleared: () => _clearLocation(event),
                                    );
                                  },
                                ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: _saving
                                      ? null
                                      : () => Navigator.pop(context),
                                  child: Text('Annuller',
                                      style: GoogleFonts.kanit()),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primary,
                                    foregroundColor: AppColors.onPrimary,
                                  ),
                                  onPressed: _saving ? null : _save,
                                  child: _saving
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white),
                                        )
                                      : Text('Gem ændringer',
                                          style: GoogleFonts.kanit(
                                              fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

TimelineEvent _withLocation(
  TimelineEvent event, {
  required String? address,
  required double? latitude,
  required double? longitude,
}) {
  return TimelineEvent(
    id: event.id,
    type: event.type,
    country: event.country,
    startDate: event.startDate,
    endDate: event.endDate,
    dayNumber: event.dayNumber,
    isDestination: event.isDestination,
    imageURL: event.imageURL,
    description: event.description,
    bureauOffers: event.bureauOffers,
    accommodation: event.accommodation,
    transport: event.transport,
    transportIcon: event.transportIcon,
    meals: event.meals,
    activities: event.activities,
    address: address,
    latitude: latitude,
    longitude: longitude,
  );
}

class _EventLocationRow extends StatefulWidget {
  final TimelineEvent event;
  // The same 1-based number shown on this event's pin on the map, if it has
  // a resolved location — null when it doesn't have one yet.
  final int? markerNumber;
  final bool isSelected;
  final VoidCallback onSelect;
  final ValueChanged<PlaceSuggestion> onSuggestionSelected;
  final VoidCallback onCleared;

  const _EventLocationRow({
    super.key,
    required this.event,
    required this.markerNumber,
    required this.isSelected,
    required this.onSelect,
    required this.onSuggestionSelected,
    required this.onCleared,
  });

  @override
  State<_EventLocationRow> createState() => _EventLocationRowState();
}

class _EventLocationRowState extends State<_EventLocationRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.event.address ?? '');
  }

  @override
  void didUpdateWidget(covariant _EventLocationRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final address = widget.event.address ?? '';
    if (oldWidget.event.address != widget.event.address &&
        _controller.text != address) {
      _controller.text = address;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasLocation =
        widget.event.latitude != null && widget.event.longitude != null;

    return GestureDetector(
      onTap: widget.onSelect,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: widget.isSelected
              ? AppColors.primary.withValues(alpha: 0.08)
              : Colors.grey.withValues(alpha: 0.05),
          borderRadius: AppRadii.mdRadius,
          border: Border.all(
            color: widget.isSelected ? AppColors.primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (hasLocation && widget.markerNumber != null)
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: widget.isSelected ? Colors.red : AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${widget.markerNumber}',
                      style: GoogleFonts.kanit(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  )
                else
                  const Icon(Icons.error_outline,
                      color: Colors.orange, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${widget.event.type}${widget.event.country.isNotEmpty ? ' · ${widget.event.country}' : ''}',
                    style: GoogleFonts.kanit(
                        fontWeight: FontWeight.w600, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            PlaceSearchField(
              controller: _controller,
              onSelected: widget.onSuggestionSelected,
              onCleared: widget.onCleared,
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                hintText: 'Søg adresse eller by',
                hintStyle: AppTextStyles.body(),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            if (hasLocation)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${widget.event.latitude!.toStringAsFixed(4)}, ${widget.event.longitude!.toStringAsFixed(4)}',
                  style:
                      GoogleFonts.kanit(fontSize: 10, color: Colors.grey[600]),
                ),
              )
            else if (widget.isSelected)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Klik på kortet for at placere denne begivenhed',
                  style: GoogleFonts.kanit(
                      fontSize: 10.5, color: AppColors.primary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Explains that automatic pinpoints are guessed from each event's
/// "Land, By eller Område" text and must be checked afterwards, then — on
/// "Fortsæt" — runs the lookups with progress shown in the same dialog.
/// Pops with the number of events placed, or null if cancelled.
class _AutoLocateDialog extends StatefulWidget {
  final List<TimelineEvent> targets;
  final int skippedCount;
  final Future<bool> Function(TimelineEvent event) locate;

  const _AutoLocateDialog({
    required this.targets,
    required this.skippedCount,
    required this.locate,
  });

  @override
  State<_AutoLocateDialog> createState() => _AutoLocateDialogState();
}

class _AutoLocateDialogState extends State<_AutoLocateDialog> {
  bool _running = false;
  int _done = 0;
  int _found = 0;

  Future<void> _run() async {
    setState(() => _running = true);
    for (final target in widget.targets) {
      if (_done > 0) {
        // Nominatim's free usage policy caps requests at 1 per second.
        await Future.delayed(const Duration(milliseconds: 1100));
      }
      if (!mounted) return;
      if (await widget.locate(target)) _found++;
      if (!mounted) return;
      setState(() => _done++);
    }
    if (mounted) Navigator.pop(context, _found);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.targets.length;
    final current = _running && _done < total ? widget.targets[_done] : null;

    return PopScope(
      canPop: !_running,
      child: Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor:
                            AppColors.primary.withValues(alpha: 0.15),
                        child: Icon(Icons.my_location,
                            color: AppColors.primary.computeLuminance() > 0.6
                                ? Colors.black87
                                : AppColors.primary),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text('Opdater pinpoints automatisk',
                            style: AppTextStyles.headingBold()),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  if (!_running)
                    ..._buildIntro(total)
                  else
                    ..._buildProgress(total, current),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildIntro(int total) {
    return [
      Text(
        '$total begivenhed${total == 1 ? '' : 'er'} uden placering bliver sat på kortet ud fra det, der står i "Land, By eller Område".',
        style: GoogleFonts.kanit(fontSize: 14, color: Colors.black87),
      ),
      const SizedBox(height: AppSpacing.lg),
      Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.1),
          borderRadius: AppRadii.mdRadius,
          border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Colors.orange[800], size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Kontrollér nålene bagefter',
                      style: GoogleFonts.kanit(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.orange[900])),
                  const SizedBox(height: 2),
                  Text(
                    'Placeringen er et gæt ud fra den indtastede by, land eller område — fx midt i byen eller midt i landet. Et navn kan også findes flere steder i verden. Gennemgå derfor hver nål, og flyt den, hvis den ligger forkert.',
                    style: AppTextStyles.body(color: Colors.grey[800]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      if (widget.skippedCount > 0) ...[
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 18, color: Colors.grey[600]),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${widget.skippedCount} begivenhed${widget.skippedCount == 1 ? '' : 'er'} med en specifik adresse eller uden land røres ikke.',
                style: AppTextStyles.body(color: Colors.grey[700]),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: AppSpacing.xs),
      Text(
        'Intet gemmes, før du trykker "Gem ændringer".',
        style: AppTextStyles.caption(),
      ),
      const SizedBox(height: AppSpacing.xxl),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Annuller',
                style: GoogleFonts.kanit(color: Colors.grey[600])),
          ),
          const SizedBox(width: AppSpacing.md),
          ElevatedButton.icon(
            onPressed: _run,
            icon: const Icon(Icons.my_location, size: 18),
            label: Text('Fortsæt',
                style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.onPrimary,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: AppRadii.smRadius),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _buildProgress(int total, TimelineEvent? current) {
    final spinnerColor = AppColors.primary.computeLuminance() > 0.6
        ? Colors.grey[800]!
        : AppColors.primary;
    return [
      const SizedBox(height: AppSpacing.sm),
      Center(
        child: SizedBox(
          width: 44,
          height: 44,
          child: CircularProgressIndicator(
            strokeWidth: 3.5,
            color: spinnerColor,
          ),
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      Text(
        'Finder placering ${(_done + 1).clamp(1, total)} af $total',
        textAlign: TextAlign.center,
        style: GoogleFonts.kanit(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      if (current != null)
        Text(
          '${current.type} · ${current.country.trim()}',
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.body(color: Colors.grey[600]),
        ),
      const SizedBox(height: AppSpacing.lg),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: total == 0 ? null : _done / total,
          minHeight: 6,
          color: spinnerColor,
          backgroundColor: Colors.grey.withValues(alpha: 0.15),
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      Text(
        'Det tager ca. et sekund pr. begivenhed.',
        textAlign: TextAlign.center,
        style: AppTextStyles.caption(),
      ),
      const SizedBox(height: AppSpacing.sm),
    ];
  }
}

/// Warns before putting an already-placed event at a searched spot, which
/// would move its pin away from where it is now.
class _MoveLocationDialog extends StatelessWidget {
  final TimelineEvent event;
  final PlaceSuggestion place;

  const _MoveLocationDialog({required this.event, required this.place});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: Colors.orange.withValues(alpha: 0.15),
                    child: Icon(Icons.warning_amber_rounded,
                        color: Colors.orange[800]),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text('Flyt placering?',
                        style: AppTextStyles.headingBold()),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                '"${event.type}" har allerede en placering. Vil du flytte den hertil?',
                style: GoogleFonts.kanit(fontSize: 14, color: Colors.black87),
              ),
              const SizedBox(height: AppSpacing.lg),
              _row(
                  Icons.place_outlined,
                  'Nu',
                  event.address?.isNotEmpty == true
                      ? event.address!
                      : '${event.latitude!.toStringAsFixed(4)}, ${event.longitude!.toStringAsFixed(4)}',
                  Colors.grey[600]!),
              const SizedBox(height: AppSpacing.sm),
              _row(Icons.arrow_forward, 'Ny', place.displayName,
                  const Color(0xFFE5484D)),
              const SizedBox(height: AppSpacing.xxl),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text('Annuller',
                        style: GoogleFonts.kanit(color: Colors.grey[600])),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange[800],
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: AppRadii.smRadius),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 22, vertical: 12),
                    ),
                    child: Text('Flyt hertil',
                        style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(IconData icon, String label, String text, Color color) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.06),
        borderRadius: AppRadii.mdRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          SizedBox(
            width: 28,
            child: Text(label,
                style: GoogleFonts.kanit(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700])),
          ),
          Expanded(
            child: Text(text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body()),
          ),
        ],
      ),
    );
  }
}
