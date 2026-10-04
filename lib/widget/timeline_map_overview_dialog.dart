import 'dart:async';
import 'package:backend/config/design.dart';
import 'dart:convert';

import 'package:backend/config/app_colors.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:backend/widget/app_snackbar.dart';

/// Lets an admin see every timeline event's resolved location on a single
/// map and fix the ones that are missing or plain wrong (e.g. geocoded to
/// the wrong country), instead of having to open each event's edit dialog
/// one at a time to find and fix a bad pin.
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

class _TimelineMapOverviewDialogState
    extends State<TimelineMapOverviewDialog> {
  // Roughly centered on Denmark — just a reasonable starting point when no
  // event has a resolved location yet.
  static const LatLng _defaultCenter = LatLng(56.0, 10.0);

  final MapController _mapController = MapController();
  // Reused across rebuilds (rather than created inline in the TileLayer) so
  // repeated setState calls don't spin up a fresh Dio client each time.
  final CancellableNetworkTileProvider _tileProvider =
      CancellableNetworkTileProvider();
  late List<TimelineEvent> _events;
  String? _selectedEventId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _events = List.of(widget.groupInformation.timelineEvents)
      ..sort((a, b) => a.startDate.compareTo(b.startDate));
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitToMarkers());
  }

  List<TimelineEvent> get _locatedEvents => _events
      .where((e) => e.latitude != null && e.longitude != null)
      .toList();

  /// Event id → the same 1-based number shown on its pin on the map, so the
  /// list can display a matching badge next to each event.
  Map<String, int> get _markerNumbers => {
        for (final entry in _locatedEvents.asMap().entries)
          entry.value.id: entry.key + 1,
      };

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

  void _onLocationSelected(TimelineEvent updated) {
    setState(() {
      final index = _events.indexWhere((e) => e.id == updated.id);
      if (index != -1) _events[index] = updated;
      _selectedEventId = updated.id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitToMarkers());
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
    final points =
        _locatedEvents.map((e) => LatLng(e.latitude!, e.longitude!)).toList();

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
                      borderRadius:
                          const BorderRadius.only(bottomLeft: Radius.circular(20)),
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter:
                              points.isNotEmpty ? points.first : _defaultCenter,
                          initialZoom: points.isNotEmpty ? 11 : 4,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                            userAgentPackageName:
                                'dk.backpack-app.controlpanel',
                            tileProvider: _tileProvider,
                          ),
                          if (points.length > 1)
                            PolylineLayer(polylines: [
                              Polyline(
                                points: points,
                                color: AppColors.primary,
                                strokeWidth: 3,
                              ),
                            ]),
                          MarkerLayer(
                            markers: _locatedEvents.asMap().entries.map((entry) {
                              final index = entry.key;
                              final event = entry.value;
                              final isSelected = event.id == _selectedEventId;
                              return Marker(
                                point: LatLng(event.latitude!, event.longitude!),
                                width: 36,
                                height: 36,
                                child: GestureDetector(
                                  onTap: () =>
                                      setState(() => _selectedEventId = event.id),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? Colors.red
                                          : AppColors.primary,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: Colors.white, width: 2),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.25),
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${index + 1}',
                                      style: GoogleFonts.kanit(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
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
                              'Søg og vælg den rigtige adresse for hver begivenhed.',
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
                                      markerNumber: _markerNumbers[event.id],
                                      isSelected: event.id == _selectedEventId,
                                      onTapMarker: () {
                                        setState(
                                            () => _selectedEventId = event.id);
                                        _mapController.move(
                                          LatLng(
                                              event.latitude!, event.longitude!),
                                          14,
                                        );
                                      },
                                      onLocationSelected: _onLocationSelected,
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

class _AddressSuggestion {
  final String displayName;
  final double lat;
  final double lon;

  const _AddressSuggestion(
      {required this.displayName, required this.lat, required this.lon});
}

class _EventLocationRow extends StatefulWidget {
  final TimelineEvent event;
  // The same 1-based number shown on this event's pin on the map, if it has
  // a resolved location — null when it doesn't have one yet.
  final int? markerNumber;
  final bool isSelected;
  final VoidCallback onTapMarker;
  final ValueChanged<TimelineEvent> onLocationSelected;

  const _EventLocationRow({
    super.key,
    required this.event,
    required this.markerNumber,
    required this.isSelected,
    required this.onTapMarker,
    required this.onLocationSelected,
  });

  @override
  State<_EventLocationRow> createState() => _EventLocationRowState();
}

class _EventLocationRowState extends State<_EventLocationRow> {
  late final TextEditingController _controller;
  Timer? _debounce;
  bool _loading = false;
  String? _error;
  List<_AddressSuggestion> _suggestions = [];

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
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    setState(() {
      _suggestions = [];
      _error = null;
    });
    if (value.trim().length < 3) return;
    _debounce = Timer(const Duration(milliseconds: 500), () => _search(value));
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'json',
        'limit': '5',
      });
      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'BackpackControlpanel/1.0 (contact@backpack-app.dk)'
        },
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final results = (jsonDecode(response.body) as List)
            .cast<Map<String, dynamic>>();
        setState(() {
          _loading = false;
          _suggestions = results
              .map((r) => _AddressSuggestion(
                    displayName: r['display_name'] as String,
                    lat: double.parse(r['lat'] as String),
                    lon: double.parse(r['lon'] as String),
                  ))
              .toList();
          if (_suggestions.isEmpty) {
            _error = 'Ingen resultater. Prøv en mere præcis adresse.';
          }
        });
      } else {
        setState(() {
          _loading = false;
          _error = 'Fejl ved opslag.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Fejl ved opslag.';
      });
    }
  }

  void _select(_AddressSuggestion suggestion) {
    setState(() {
      _controller.text = suggestion.displayName;
      _suggestions = [];
    });
    widget.onLocationSelected(_withLocation(
      widget.event,
      address: suggestion.displayName,
      latitude: suggestion.lat,
      longitude: suggestion.lon,
    ));
  }

  void _clear() {
    setState(() {
      _controller.clear();
      _suggestions = [];
      _error = null;
    });
    widget.onLocationSelected(
      _withLocation(widget.event, address: null, latitude: null, longitude: null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasLocation =
        widget.event.latitude != null && widget.event.longitude != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: widget.isSelected
            ? AppColors.primary.withOpacity(0.08)
            : Colors.grey.withOpacity(0.05),
        borderRadius: AppRadii.mdRadius,
        border: Border.all(
          color: widget.isSelected ? AppColors.primary : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: hasLocation ? widget.onTapMarker : null,
            child: Row(
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
                    style:
                        GoogleFonts.kanit(fontWeight: FontWeight.w600, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _controller,
            onChanged: _onChanged,
            style: AppTextStyles.body(),
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              hintText: 'Søg adresse eller by',
              hintStyle: AppTextStyles.body(),
              suffixIcon: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : (_controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: _clear,
                        )
                      : null),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error!,
                  style: GoogleFonts.kanit(color: Colors.red, fontSize: 11)),
            ),
          if (_suggestions.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _suggestions
                    .map((s) => InkWell(
                          onTap: () => _select(s),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            child: Text(s.displayName,
                                style: GoogleFonts.kanit(fontSize: 12)),
                          ),
                        ))
                    .toList(),
              ),
            ),
          if (hasLocation)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${widget.event.latitude!.toStringAsFixed(4)}, ${widget.event.longitude!.toStringAsFixed(4)}',
                style: GoogleFonts.kanit(fontSize: 10, color: Colors.grey[600]),
              ),
            ),
        ],
      ),
    );
  }
}
