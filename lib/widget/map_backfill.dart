import 'package:backend/widget/location_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Bulk-resolves map points for a trip's timeline events from their
/// "Land, By eller Område" field — run when the map is switched on, or on
/// demand, so events don't stay unplaced until each is opened by hand.
class MapBackfillPlan {
  final List<Map<String, dynamic>> events;
  final List<int> toGeocode;
  final int customCount;

  MapBackfillPlan(
      {required this.events, required this.toGeocode, required this.customCount});
}

/// Splits a group's timeline events into ones safe to auto-geocode from
/// the "country" field and ones the admin already gave a specific
/// address (address text differs from country) — those are always left
/// alone, whether or not they've been resolved to a point yet.
MapBackfillPlan planMapBackfill(Map<String, dynamic> data) {
  final events = List<Map<String, dynamic>>.from(
    (data['timelineEvents'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map)),
  );

  final toGeocode = <int>[];
  var customCount = 0;

  for (var i = 0; i < events.length; i++) {
    final country = (events[i]['country'] as String?)?.trim() ?? '';
    final address = (events[i]['address'] as String?)?.trim() ?? '';
    final hasCoords =
        events[i]['latitude'] != null && events[i]['longitude'] != null;
    final isCustomAddress = address.isNotEmpty && address != country;

    if (isCustomAddress) {
      customCount++;
      continue;
    }
    if (country.isNotEmpty && !hasCoords) {
      toGeocode.add(i);
    }
  }

  return MapBackfillPlan(
      events: events, toGeocode: toGeocode, customCount: customCount);
}

/// Geocodes the planned events' "country" field and writes the result
/// back, returning how many were resolved. Runs sequentially with a delay
/// between lookups to respect Nominatim's 1-request-per-second usage policy.
Future<int> runMapBackfill(
    DocumentReference<Map<String, dynamic>> groupRef,
    MapBackfillPlan plan) async {
  var resolvedCount = 0;
  for (final index in plan.toGeocode) {
    final country = (plan.events[index]['country'] as String).trim();
    try {
      final results = await Geocoder.search(country, limit: 1);
      if (results.isNotEmpty) {
        plan.events[index]['address'] = country;
        plan.events[index]['latitude'] = results.first.point.latitude;
        plan.events[index]['longitude'] = results.first.point.longitude;
        resolvedCount++;
      }
    } catch (e) {
      print('Error geocoding "$country" during map backfill: $e');
    }

    // Nominatim's free usage policy caps requests at 1 per second.
    await Future.delayed(const Duration(milliseconds: 1100));
  }

  await groupRef.update({'timelineEvents': plan.events});
  return resolvedCount;
}
