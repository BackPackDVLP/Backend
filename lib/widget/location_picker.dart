import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Shared building blocks for placing timeline events on a map: address
/// search, reverse lookup, and a map whose pins can be placed by clicking
/// and moved by dragging. Used by both the map overview dialog and the
/// single-event edit dialog so the two behave the same way.

// Roughly centered on Denmark — a reasonable starting point when nothing
// has a resolved location yet.
const LatLng defaultMapCenter = LatLng(56.0, 10.0);

class PlaceSuggestion {
  final String displayName;
  final LatLng point;
  // The place's extent as reported by the geocoder — tiny for a street
  // address, city-sized for a city — so the map can zoom to fit it.
  final LatLngBounds? bounds;

  const PlaceSuggestion(
      {required this.displayName, required this.point, this.bounds});

  /// The first part of [displayName] (e.g. "Via Roma 12" or "Firenze"),
  /// for labels where the full "street, city, region, country" is too long.
  String get shortName {
    final parts = displayName.split(',').map((p) => p.trim()).toList();
    // Nominatim puts a lone house number first ("12, Via Roma, ...") —
    // join it with the street so the label still reads as an address.
    if (parts.length > 1 && RegExp(r'^\d+[a-zA-Z]?$').hasMatch(parts[0])) {
      return '${parts[1]} ${parts[0]}';
    }
    return parts.first;
  }
}

/// Moves [controller] to show [place]: fitted to its extent when known, so
/// an exact address ends up zoomed in close and a city shows the whole city,
/// but never closer than street level.
void focusMapOn(MapController controller, PlaceSuggestion place) {
  final bounds = place.bounds;
  if (bounds == null ||
      (bounds.north - bounds.south).abs() < 1e-6 ||
      (bounds.east - bounds.west).abs() < 1e-6) {
    controller.move(place.point, 17);
    return;
  }
  controller.fitCamera(CameraFit.bounds(
    bounds: bounds,
    padding: const EdgeInsets.all(60),
    maxZoom: 18,
  ));
}

LatLngBounds? _parseBoundingBox(Object? raw) {
  // Nominatim: ["south", "north", "west", "east"] as strings.
  if (raw is! List || raw.length != 4) return null;
  final v = raw.map((e) => double.tryParse('$e')).toList();
  if (v.any((e) => e == null)) return null;
  return LatLngBounds(LatLng(v[0]!, v[2]!), LatLng(v[1]!, v[3]!));
}

/// OpenStreetMap's free Nominatim geocoder — no paid API involved. Its usage
/// policy allows ~1 request per second, which interactive use stays under.
class Geocoder {
  static const _headers = {
    'User-Agent': 'BackpackControlpanel/1.0 (kontakt@backpack-app.dk)'
  };

  static Future<List<PlaceSuggestion>> search(String query,
      {int limit = 5}) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': query,
      'format': 'json',
      'limit': '$limit',
    });
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Nominatim ${response.statusCode}');
    }
    return (jsonDecode(response.body) as List)
        .cast<Map<String, dynamic>>()
        .map((r) => PlaceSuggestion(
              displayName: r['display_name'] as String,
              point: LatLng(double.parse(r['lat'] as String),
                  double.parse(r['lon'] as String)),
              bounds: _parseBoundingBox(r['boundingbox']),
            ))
        .toList();
  }

  /// The address at [point], or null if there is none (e.g. open sea) or
  /// the lookup failed — callers fall back to showing the coordinates.
  static Future<String?> reverse(LatLng point) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'lat': '${point.latitude}',
        'lon': '${point.longitude}',
        'format': 'json',
      });
      final response = await http.get(uri, headers: _headers);
      if (response.statusCode != 200) return null;
      return (jsonDecode(response.body) as Map<String, dynamic>)['display_name']
          as String?;
    } catch (_) {
      return null;
    }
  }
}

String formatLatLng(LatLng p) =>
    '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

/// A text field that suggests matching places as you type and reports the
/// one picked. Programmatic changes to [controller] don't trigger a search —
/// only typing does.
class PlaceSearchField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<PlaceSuggestion> onSelected;
  final VoidCallback? onCleared;
  final InputDecoration decoration;
  final TextStyle? style;

  const PlaceSearchField({
    super.key,
    required this.controller,
    required this.onSelected,
    this.onCleared,
    this.decoration = const InputDecoration(),
    this.style,
  });

  @override
  State<PlaceSearchField> createState() => _PlaceSearchFieldState();
}

class _PlaceSearchFieldState extends State<PlaceSearchField> {
  Timer? _debounce;
  bool _loading = false;
  String? _error;
  List<PlaceSuggestion> _suggestions = [];

  @override
  void dispose() {
    _debounce?.cancel();
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
    setState(() => _loading = true);
    try {
      final results = await Geocoder.search(query);
      if (!mounted || widget.controller.text != query) return;
      setState(() {
        _loading = false;
        _suggestions = results;
        _error = results.isEmpty
            ? 'Ingen resultater. Prøv en mere præcis adresse.'
            : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Fejl ved opslag.';
      });
    }
  }

  void _select(PlaceSuggestion suggestion) {
    widget.controller.text = suggestion.displayName;
    setState(() => _suggestions = []);
    widget.onSelected(suggestion);
  }

  void _clear() {
    widget.controller.clear();
    setState(() {
      _suggestions = [];
      _error = null;
    });
    widget.onCleared?.call();
  }

  @override
  Widget build(BuildContext context) {
    Widget? suffix;
    if (_loading) {
      suffix = const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (widget.onCleared != null && widget.controller.text.isNotEmpty) {
      suffix = IconButton(
        icon: const Icon(Icons.clear, size: 16),
        tooltip: 'Ryd',
        onPressed: _clear,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: widget.controller,
          onChanged: _onChanged,
          style: widget.style ?? AppTextStyles.body(),
          decoration: widget.decoration.copyWith(
            suffixIcon: suffix ?? widget.decoration.suffixIcon,
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
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
              boxShadow: AppShadows.card,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in _suggestions)
                  InkWell(
                    onTap: () => _select(s),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.place_outlined,
                              size: 16, color: Colors.grey[500]),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(s.displayName,
                                style: GoogleFonts.kanit(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class MapPin {
  final String id;
  final LatLng point;
  // Shown inside the pin (e.g. the event's number); an icon when null.
  final String? label;
  final bool selected;

  const MapPin({
    required this.id,
    required this.point,
    this.label,
    this.selected = false,
  });
}

/// An OpenStreetMap view whose pins can be dragged to a new position, and
/// where a click on empty map reports the clicked point (for placing a pin).
/// [overlays] are stacked on top of the map, e.g. a search box or a hint.
class PinMap extends StatefulWidget {
  final MapController controller;
  final List<MapPin> pins;
  final LatLng initialCenter;
  final double initialZoom;
  // Connects the pins in order, for showing a trip's route.
  final bool drawRoute;
  final ValueChanged<LatLng>? onTapMap;
  final ValueChanged<String>? onTapPin;
  final void Function(String id, LatLng point)? onPinMoved;
  final List<Widget> overlays;
  // A searched-for place to call attention to: drawn as a pulsing ring with
  // its name above it, beneath any event pins at the same spot.
  final PlaceSuggestion? highlight;
  final VoidCallback? onClearHighlight;
  // Shown at the center of [highlight] in place of its dot, e.g. a button
  // for putting something at the searched spot.
  final Widget? highlightAction;

  const PinMap({
    super.key,
    required this.controller,
    required this.pins,
    this.initialCenter = defaultMapCenter,
    this.initialZoom = 4,
    this.drawRoute = false,
    this.onTapMap,
    this.onTapPin,
    this.onPinMoved,
    this.overlays = const [],
    this.highlight,
    this.onClearHighlight,
    this.highlightAction,
  });

  @override
  State<PinMap> createState() => _PinMapState();
}

class _PinMapState extends State<PinMap> {
  final GlobalKey _mapKey = GlobalKey();
  // Reused across rebuilds (rather than created inline in the TileLayer) so
  // repeated setState calls don't spin up a fresh Dio client each time.
  final CancellableNetworkTileProvider _tileProvider =
      CancellableNetworkTileProvider();

  String? _draggingId;
  LatLng? _dragPoint;
  // Distance from the cursor to the pin's center when the drag started, so
  // the pin doesn't jump to sit centered under the cursor.
  Point<double> _grabOffset = const Point(0, 0);

  Point<double>? _localPoint(Offset globalPosition) {
    final box = _mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(globalPosition);
    return Point(local.dx, local.dy);
  }

  void _onDragStart(MapPin pin, DragStartDetails details) {
    final local = _localPoint(details.globalPosition);
    if (local == null) return;
    final pinPoint = widget.controller.camera.latLngToScreenPoint(pin.point);
    setState(() {
      _draggingId = pin.id;
      _dragPoint = pin.point;
      _grabOffset = pinPoint - local;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final local = _localPoint(details.globalPosition);
    if (local == null || _draggingId == null) return;
    setState(() => _dragPoint =
        widget.controller.camera.pointToLatLng(local + _grabOffset));
  }

  void _onDragEnd() {
    final id = _draggingId;
    final point = _dragPoint;
    setState(() {
      _draggingId = null;
      _dragPoint = null;
    });
    if (id != null && point != null) widget.onPinMoved?.call(id, point);
  }

  LatLng _pointOf(MapPin pin) =>
      pin.id == _draggingId && _dragPoint != null ? _dragPoint! : pin.point;

  @override
  Widget build(BuildContext context) {
    final draggable = widget.onPinMoved != null;
    final routePoints = widget.pins.map(_pointOf).toList();

    return Stack(
      children: [
        MouseRegion(
          cursor: widget.onTapMap != null
              ? SystemMouseCursors.precise
              : MouseCursor.defer,
          child: FlutterMap(
            key: _mapKey,
            mapController: widget.controller,
            options: MapOptions(
              initialCenter: widget.initialCenter,
              initialZoom: widget.initialZoom,
              onTap: widget.onTapMap == null
                  ? null
                  : (_, point) => widget.onTapMap!(point),
            ),
            children: [
              TileLayer(
                urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                userAgentPackageName: 'dk.backpack-app.controlpanel',
                tileProvider: _tileProvider,
              ),
              if (widget.drawRoute && routePoints.length > 1)
                PolylineLayer(polylines: [
                  Polyline(
                    points: routePoints,
                    color: AppColors.primary,
                    strokeWidth: 3,
                  ),
                ]),
              if (widget.highlight != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: widget.highlight!.point,
                      width: 72,
                      height: 72,
                      child: IgnorePointer(
                          child: _PulsingRing(
                              showDot: widget.highlightAction == null)),
                    ),
                    if (widget.highlightAction != null)
                      Marker(
                        point: widget.highlight!.point,
                        width: 34,
                        height: 34,
                        child: widget.highlightAction!,
                      ),
                    Marker(
                      point: widget.highlight!.point,
                      width: 260,
                      height: 64,
                      alignment: Alignment.topCenter,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: _HighlightLabel(
                          name: widget.highlight!.shortName,
                          onClose: widget.onClearHighlight,
                        ),
                      ),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  for (final pin in widget.pins)
                    Marker(
                      point: _pointOf(pin),
                      width: 36,
                      height: 36,
                      child: MouseRegion(
                        cursor: draggable
                            ? (pin.id == _draggingId
                                ? SystemMouseCursors.grabbing
                                : SystemMouseCursors.grab)
                            : SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: widget.onTapPin == null
                              ? null
                              : () => widget.onTapPin!(pin.id),
                          onPanStart:
                              draggable ? (d) => _onDragStart(pin, d) : null,
                          onPanUpdate: draggable ? _onDragUpdate : null,
                          onPanEnd: draggable ? (_) => _onDragEnd() : null,
                          onPanCancel: draggable ? _onDragEnd : null,
                          child: _PinBadge(
                            pin: pin,
                            dragging: pin.id == _draggingId,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        ...widget.overlays,
      ],
    );
  }
}

/// An expanding, fading ring that marks a searched-for place.
class _PulsingRing extends StatefulWidget {
  final bool showDot;

  const _PulsingRing({this.showDot = true});

  @override
  State<_PulsingRing> createState() => _PulsingRingState();
}

class _PulsingRingState extends State<_PulsingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFE5484D);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 24 + 48 * t,
              height: 24 + 48 * t,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.25 * (1 - t)),
                border: Border.all(
                    color: color.withValues(alpha: 0.8 * (1 - t)), width: 2),
              ),
            ),
            if (widget.showDot)
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 4),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The name bubble shown above a highlighted search result.
class _HighlightLabel extends StatelessWidget {
  final String name;
  final VoidCallback? onClose;

  const _HighlightLabel({required this.name, this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(10, 5, onClose != null ? 4 : 10, 5),
      decoration: BoxDecoration(
        color: const Color(0xFF263238),
        borderRadius: AppRadii.smRadius,
        boxShadow: AppShadows.elevated,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search, size: 14, color: Colors.white70),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.kanit(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
            ),
          ),
          if (onClose != null)
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(10),
              child: const Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.close, size: 14, color: Colors.white70),
              ),
            ),
        ],
      ),
    );
  }
}

class _PinBadge extends StatelessWidget {
  final MapPin pin;
  final bool dragging;

  const _PinBadge({required this.pin, required this.dragging});

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: dragging ? 1.2 : 1,
      duration: const Duration(milliseconds: 120),
      child: Container(
        decoration: BoxDecoration(
          color: pin.selected ? Colors.red : AppColors.primary,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dragging ? 0.4 : 0.25),
              blurRadius: dragging ? 8 : 4,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: pin.label != null
            ? Text(
                pin.label!,
                style: GoogleFonts.kanit(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              )
            : const Icon(Icons.place, color: Colors.white, size: 18),
      ),
    );
  }
}

/// A small translucent hint card for the corner of a [PinMap].
class MapHint extends StatelessWidget {
  final String text;
  final IconData icon;

  const MapHint(this.text, {super.key, this.icon = Icons.touch_app_outlined});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: AppRadii.smRadius,
        boxShadow: AppShadows.card,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.grey[700]),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                style:
                    GoogleFonts.kanit(fontSize: 11.5, color: Colors.grey[800])),
          ),
        ],
      ),
    );
  }
}

/// The red "+" button for the center of a highlighted search result.
class HighlightPlusButton extends StatelessWidget {
  const HighlightPlusButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFE5484D),
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6),
        ],
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.add, color: Colors.white, size: 20),
    );
  }
}
