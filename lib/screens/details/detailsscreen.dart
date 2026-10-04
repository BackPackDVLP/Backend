import 'dart:convert';
import 'package:backend/config/design.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:backend/config/app_colors.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/coupon_model.dart';
import 'package:backend/models/agencyInformation.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:backend/widget/app_snackbar.dart';

class _MapBackfillPlan {
  final List<Map<String, dynamic>> events;
  final List<int> toGeocode;
  final int customCount;

  _MapBackfillPlan(
      {required this.events, required this.toGeocode, required this.customCount});
}

class GroupDetailsScreen extends StatefulWidget {
  final String groupId;
  final GroupInformationRepository repository;
  // Needed only to read the bureau-wide affiliate links (agencyInfo.coupons)
  // so this screen can show them alongside the trip's own — they're managed
  // from the App-settings screen, not editable here.
  final AgencyInformation agencyInfo;
  // Whether the signed-in staff member's role grants `trips.edit`. Unlike
  // homescreen.dart's per-row edit icons, this whole screen is a single
  // form with one save action — rather than gating ~15 individual fields,
  // the form body is made inert via AbsorbPointer and the save FAB hidden
  // when this is false.
  final bool canEditTrips;

  const GroupDetailsScreen({
    super.key,
    required this.groupId,
    required this.repository,
    required this.agencyInfo,
    this.canEditTrips = true,
  });

  @override
  State<GroupDetailsScreen> createState() => _GroupDetailsScreenState();
}

class _GroupDetailsScreenState extends State<GroupDetailsScreen> {
  GroupInformation? _group;
  bool _loading = true;
  final _formKey = GlobalKey<FormState>();

  // Controllers
  final _departureDateController = TextEditingController();
  final _returnDateController = TextEditingController();
  final _departureFromController = TextEditingController();
  final _returnToController = TextEditingController();
  final _emergencyPhoneController = TextEditingController();
  bool _flightAway = false;
  bool _flightHome = false;
  bool _mapEnabled = false;
  bool _mapEnabledAtLoad = false;
  bool _backfillingMapLocations = false;
  List<String> _beforeDepartureItems = [];
  final _newPreDepartureController = TextEditingController();
  final _newPreDepartureFocus = FocusNode();
  final _editPreDepartureController = TextEditingController();
  int? _editingPreDepartureIndex;

  @override
  void initState() {
    super.initState();
    _loadGroup();
  }

  @override
  void dispose() {
    _departureDateController.dispose();
    _returnDateController.dispose();
    _departureFromController.dispose();
    _returnToController.dispose();
    _emergencyPhoneController.dispose();
    _newPreDepartureController.dispose();
    _newPreDepartureFocus.dispose();
    _editPreDepartureController.dispose();
    super.dispose();
  }

  Future<void> _loadGroup() async {
    // Read straight from Firestore, not repository.getGroupInformation():
    // that stream yields the Hive-cached copy first, which can be stale or
    // lossy — and since this screen writes whole fields back (the "Før
    // afrejse" list, mapEnabled, coupons), editing on top of a stale copy
    // silently overwrote what was actually saved.
    final GroupInformation group;
    try {
      final snapshot = await widget.repository.firestore
          .collection('groups')
          .doc(widget.groupId)
          .get();
      group = GroupInformation.fromSnapshot(snapshot);
    } catch (e) {
      if (mounted) {
        showErrorSnackbar(
            context, 'Kunne ikke hente rejsen: ${describeError(e)}');
      }
      return;
    }
    if (!mounted) return;

    setState(() {
      _group = group;
      _departureDateController.text =
          DateFormat('dd. MMMM yyyy', 'da_DK').format(group.departureDate);
      _returnDateController.text =
          DateFormat('dd. MMMM yyyy', 'da_DK').format(group.returnDate);
      _departureFromController.text = group.departureFrom;
      _returnToController.text = group.returnTo;
      _emergencyPhoneController.text = group.emergencyPhone ?? '';
      _flightAway = group.flightAway;
      _flightHome = group.flightHome;
      _mapEnabled = group.mapEnabled;
      _mapEnabledAtLoad = group.mapEnabled;
      _beforeDepartureItems = List.from(group.beforeDepartureItems ?? []);
      _loading = false;
    });
  }

  Future<void> _pickDate(
      TextEditingController controller, DateTime initialDate) async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        controller.text = DateFormat('dd. MMMM yyyy', 'da_DK').format(picked);
      });
    }
  }

  Future<void> _saveGroupDetails() async {
    if (_group == null || !_formKey.currentState!.validate()) return;

    final justEnabledMap = _mapEnabled && !_mapEnabledAtLoad;

    try {
      final groupRef =
          widget.repository.firestore.collection('groups').doc(_group!.groupId);

      // Use a locale-aware parser to handle the Danish date format
      final dateFormat = DateFormat('dd. MMMM yyyy', 'da_DK');

      await groupRef.update({
        'departureDate': dateFormat.parse(_departureDateController.text),
        'returnDate': dateFormat.parse(_returnDateController.text),
        'departureFrom': _departureFromController.text,
        'returnTo': _returnToController.text,
        'emergencyPhone': _emergencyPhoneController.text,
        'flightAway': _flightAway,
        'flightHome': _flightHome,
        'mapEnabled': _mapEnabled,
      });

      // Optionally, reload the main group info in the BLoC
      // context.read<GroupInformationBloc>().add(LoadGroupInformationById(groupId: _group!.groupId));

      _mapEnabledAtLoad = _mapEnabled;

      if (mounted) {
        showAppSnackbar(context, 'Details saved');
      }

      // The map was just switched on — backfill coordinates for every
      // existing timeline event that has a location but no point yet,
      // instead of leaving them unresolved until each is opened by hand.
      if (justEnabledMap) {
        final snapshot = await groupRef.get();
        final data = snapshot.data();
        if (data != null) {
          await _runMapBackfill(groupRef, _planMapBackfill(data));
        }
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackbar(context, 'Error saving details: ${describeError(e)}');
      }
    }
  }

  /// Splits a group's timeline events into ones safe to auto-geocode from
  /// the "country" field and ones the admin already gave a specific
  /// address (address text differs from country) — those are always left
  /// alone, whether or not they've been resolved to a point yet.
  _MapBackfillPlan _planMapBackfill(Map<String, dynamic> data) {
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

    return _MapBackfillPlan(
        events: events, toGeocode: toGeocode, customCount: customCount);
  }

  /// Geocodes the planned events' "country" field via OpenStreetMap's free
  /// Nominatim geocoder and writes the result back. Runs sequentially with
  /// a delay between lookups to respect Nominatim's 1-request-per-second
  /// usage policy.
  Future<void> _runMapBackfill(dynamic groupRef, _MapBackfillPlan plan) async {
    if (_backfillingMapLocations || plan.toGeocode.isEmpty) return;

    setState(() => _backfillingMapLocations = true);
    if (mounted) {
      showInfoSnackbar(context, 'Finder placeringer for ${plan.toGeocode.length} begivenheder...', duration: const Duration(seconds: 3));
    }

    var resolvedCount = 0;
    for (final index in plan.toGeocode) {
      final country = (plan.events[index]['country'] as String).trim();
      try {
        final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
          'q': country,
          'format': 'json',
          'limit': '1',
        });
        final response = await http.get(uri, headers: {
          'User-Agent': 'BackpackControlpanel/1.0 (kontakt@backpack-app.dk)',
        });

        if (response.statusCode == 200) {
          final results = jsonDecode(response.body) as List;
          if (results.isNotEmpty) {
            final first = results.first as Map<String, dynamic>;
            final lat = double.tryParse(first['lat'] as String);
            final lng = double.tryParse(first['lon'] as String);
            if (lat != null && lng != null) {
              plan.events[index]['address'] = country;
              plan.events[index]['latitude'] = lat;
              plan.events[index]['longitude'] = lng;
              resolvedCount++;
            }
          }
        }
      } catch (e) {
        print('Error geocoding "$country" during map backfill: $e');
      }

      // Nominatim's free usage policy caps requests at 1 per second.
      await Future.delayed(const Duration(milliseconds: 1100));
    }

    await groupRef.update({'timelineEvents': plan.events});

    if (mounted) {
      setState(() => _backfillingMapLocations = false);
      showInfoSnackbar(context, 'Kort: fandt placering for $resolvedCount af ${plan.toGeocode.length} begivenheder');
    } else {
      _backfillingMapLocations = false;
    }
  }

  /// Manual, always-available trigger for the map pinpoint backfill —
  /// covers groups made before this feature existed, or ones where the
  /// map switch was already on so the save-time auto-trigger never fires.
  Future<void> _manualUpdateMapPinpoints() async {
    if (_group == null || _backfillingMapLocations) return;

    final groupRef =
        widget.repository.firestore.collection('groups').doc(_group!.groupId);
    final snapshot = await groupRef.get();
    final data = snapshot.data();
    if (data == null) return;

    final plan = _planMapBackfill(data);

    if (plan.toGeocode.isEmpty) {
      if (mounted) {
        showInfoSnackbar(context, plan.customCount > 0
              ? 'Alle begivenheder har allerede en placering (${plan.customCount} har en specifik adresse og røres ikke).'
              : 'Alle begivenheder har allerede en placering.');
      }
      return;
    }

    if (!mounted) return;
    final confirmed = await _showMapBackfillConfirmDialog(plan);
    if (confirmed != true) return;

    await _runMapBackfill(groupRef, plan);
  }

  Future<bool?> _showMapBackfillConfirmDialog(_MapBackfillPlan plan) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.beige,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Icon(Icons.map_outlined, color: AppColors.darkGreen),
            const SizedBox(width: AppSpacing.md),
            Text('Opdater pinpoints',
                style:
                    GoogleFonts.kanit(fontWeight: FontWeight.bold, fontSize: 20)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Finder placering for ${plan.toGeocode.length} begivenhed${plan.toGeocode.length == 1 ? '' : 'er'} ud fra landefeltet.',
                style: GoogleFonts.kanit(fontSize: 14)),
            if (plan.customCount > 0) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.12),
                  borderRadius: AppRadii.mdRadius,
                  border: Border.all(color: Colors.orange.withOpacity(0.4)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.orange, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                          '${plan.customCount} begivenhed${plan.customCount == 1 ? '' : 'er'} har en specifik adresse indtastet manuelt. De røres ikke af denne handling.',
                          style: AppTextStyles.body()),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Annuller',
                style: GoogleFonts.kanit(color: Colors.grey[600])),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.onPrimary,
              shape:
                  RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Fortsæt',
                style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _addOrEditCoupon({Coupon? existingCoupon}) {
    final nameController =
        TextEditingController(text: existingCoupon?.couponName ?? '');
    final descriptionController =
        TextEditingController(text: existingCoupon?.description ?? '');
    final imageUrlController =
        TextEditingController(text: existingCoupon?.imageURL ?? '');
    final linkController =
        TextEditingController(text: existingCoupon?.link ?? '');

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.beige,
            surfaceTintColor: Colors.transparent,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(
              children: [
                Icon(existingCoupon == null ? Icons.add_circle : Icons.edit,
                    color: AppColors.darkGreen),
                const SizedBox(width: AppSpacing.md),
                Text(
                  existingCoupon == null
                      ? 'Tilføj affiliate link'
                      : 'Rediger affiliate link',
                  style: GoogleFonts.kanit(
                      fontWeight: FontWeight.bold, fontSize: 22),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (imageUrlController.text.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: AppRadii.mdRadius,
                      child: Container(
                        height: 120,
                        width: double.infinity,
                        color: Colors.white,
                        child: CachedNetworkImage(
                          imageUrl: imageUrlController.text,
                          fit: BoxFit.contain,
                          placeholder: (context, url) =>
                              const Center(child: CircularProgressIndicator()),
                          errorWidget: (context, url, error) => const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.broken_image,
                                  color: Colors.grey, size: 40),
                              Text('Ugyldig billed-URL',
                                  style: TextStyle(
                                      color: Colors.grey, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                  _buildDialogField(
                    controller: nameController,
                    label: 'Navn',
                    hint: 'F.eks. 20% rabat på Safari',
                    icon: Icons.label_outline,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildDialogField(
                    controller: descriptionController,
                    label: 'Beskrivelse',
                    hint: 'F.eks. Gælder alle bookinger i 2024',
                    icon: Icons.description_outlined,
                    maxLines: 2,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildDialogField(
                    controller: imageUrlController,
                    label: 'Billed-URL',
                    hint: 'Link til logo eller billede',
                    icon: Icons.image_outlined,
                    onChanged: (val) => setDialogState(() {}),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildDialogField(
                    controller: linkController,
                    label: 'Link',
                    hint: 'Hvor skal linket føre hen?',
                    icon: Icons.link,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Annuller',
                    style: GoogleFonts.kanit(color: Colors.grey[600])),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.onPrimary,
                  shape: RoundedRectangleBorder(
                      borderRadius: AppRadii.mdRadius),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                onPressed: () async {
                  if (nameController.text.isEmpty) return;

                  final newCoupon = Coupon(
                    couponName: nameController.text,
                    description: descriptionController.text,
                    imageURL: imageUrlController.text,
                    link: linkController.text,
                  );

                  final groupRef = widget.repository.firestore
                      .collection('groups')
                      .doc(_group!.groupId);

                  List<Coupon> updatedCoupons =
                      List.from(_group!.coupons ?? []);

                  if (existingCoupon != null) {
                    updatedCoupons.removeWhere(
                        (c) => c.couponName == existingCoupon.couponName);
                  }

                  updatedCoupons.add(newCoupon);

                  await groupRef.update({
                    'coupons': updatedCoupons
                        .map((c) => {
                              'couponName': c.couponName,
                              'description': c.description,
                              'imageURL': c.imageURL,
                              'link': c.link,
                            })
                        .toList(),
                  });

                  if (context.mounted) Navigator.pop(context);
                },
                child: Text(existingCoupon == null ? 'Tilføj' : 'Gem',
                    style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              )
            ],
          );
        },
      ),
    );
  }

  Widget _buildDialogField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    int maxLines = 1,
    Function(String)? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(label,
              style: AppTextStyles.label()),
        ),
        TextFormField(
          controller: controller,
          maxLines: maxLines,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, size: 20, color: AppColors.darkGreen),
            filled: true,
            fillColor: Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: AppRadii.mdRadius,
              borderSide: BorderSide(color: Colors.grey[350]!),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: AppRadii.mdRadius,
              borderSide: BorderSide(color: Colors.grey[300]!),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: AppRadii.mdRadius,
              borderSide: BorderSide(color: AppColors.darkGreen, width: 2),
            ),
          ),
          style: GoogleFonts.kanit(fontSize: 15),
        ),
      ],
    );
  }

  Future<void> _deleteCoupon(Coupon coupon) async {
    if (_group == null) return;

    final groupRef =
        widget.repository.firestore.collection('groups').doc(_group!.groupId);

    List<Coupon> updatedCoupons = List.from(_group!.coupons ?? []);
    updatedCoupons.removeWhere((c) => c.couponName == coupon.couponName);

    await groupRef.update({
      'coupons': updatedCoupons
          .map((c) => {
                'couponName': c.couponName,
                'description': c.description,
                'imageURL': c.imageURL,
                'link': c.link,
              })
          .toList(),
    });
  }

  // Common checklist points offered as one-tap suggestions — only the ones
  // not already on the list are shown.
  static const _preDepartureSuggestions = [
    'Husk pas',
    'Tjek at passet er gyldigt',
    'Husk sundhedskort',
    'Tjek rejseforsikring',
    'Check ind online',
    'Medbring opladere og adapter',
    'Veksl valuta',
    'Tjek vaccinationer',
  ];

  Future<void> _saveBeforeDepartureItems() async {
    if (_group == null) return;
    final groupRef =
        widget.repository.firestore.collection('groups').doc(_group!.groupId);
    try {
      await groupRef.update({'beforeDepartureItems': _beforeDepartureItems});
    } catch (e) {
      if (mounted) {
        showErrorSnackbar(
            context, 'Kunne ikke gemme "Før afrejse": ${describeError(e)}');
      }
    }
  }

  /// Adds from the inline field at the bottom of the list. Focus stays in
  /// the field so several points can be typed in a row, one per Enter.
  Future<void> _addPreDepartureItem([String? text]) async {
    final value = (text ?? _newPreDepartureController.text).trim();
    if (value.isEmpty) return;
    setState(() {
      _beforeDepartureItems.add(value);
      if (text == null) _newPreDepartureController.clear();
    });
    if (text == null) _newPreDepartureFocus.requestFocus();
    await _saveBeforeDepartureItems();
  }

  void _startEditingPreDepartureItem(int index) {
    setState(() {
      _editingPreDepartureIndex = index;
      _editPreDepartureController.text = _beforeDepartureItems[index];
    });
  }

  Future<void> _commitPreDepartureEdit() async {
    final index = _editingPreDepartureIndex;
    if (index == null) return;
    final value = _editPreDepartureController.text.trim();
    final changed = value.isNotEmpty && value != _beforeDepartureItems[index];
    setState(() {
      if (changed) _beforeDepartureItems[index] = value;
      _editingPreDepartureIndex = null;
    });
    if (changed) await _saveBeforeDepartureItems();
  }

  void _cancelPreDepartureEdit() =>
      setState(() => _editingPreDepartureIndex = null);

  Future<void> _deletePreDepartureItem(int index) async {
    final removed = _beforeDepartureItems[index];
    setState(() {
      _beforeDepartureItems.removeAt(index);
      _editingPreDepartureIndex = null;
    });
    await _saveBeforeDepartureItems();
    if (!mounted) return;
    showAppSnackbar(
      context,
      'Punkt slettet',
      actionLabel: 'Fortryd',
      onAction: () async {
        setState(() => _beforeDepartureItems.insert(
            index.clamp(0, _beforeDepartureItems.length), removed));
        await _saveBeforeDepartureItems();
      },
    );
  }

  Future<void> _reorderPreDepartureItems(int oldIndex, int newIndex) async {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _beforeDepartureItems.removeAt(oldIndex);
      _beforeDepartureItems.insert(newIndex, item);
      _editingPreDepartureIndex = null;
    });
    await _saveBeforeDepartureItems();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _group == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.scaffoldGradientStart,
              AppColors.scaffoldGradientEnd,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0.0, 0.5],
          ),
        ),
        child: SafeArea(
          child: AbsorbPointer(
            absorbing: !widget.canEditTrips,
            child: Form(
            key: _formKey,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 900;

                final travelSection = _buildSectionCard(
                  title: 'Rejseoplysninger',
                  icon: Icons.flight_takeoff,
                  children: [
                    _buildDateRow(),
                    const SizedBox(height: AppSpacing.md),
                    _buildTextFormField(
                        _departureFromController,
                        'Afrejse fra / Rejsen starter i',
                        Icons.location_on_outlined),
                    const SizedBox(height: AppSpacing.md),
                    _buildTextFormField(_returnToController,
                        'Hjemkomst til / Rejsen slutter i', Icons.location_on),
                    const SizedBox(height: AppSpacing.md),
                    _buildTextFormField(_emergencyPhoneController,
                        'Nødtelefon', Icons.phone,
                        keyboardType: TextInputType.phone, isRequired: false),
                  ],
                );

                final settingsSection = _buildSectionCard(
                  title: 'Indstillinger',
                  icon: Icons.tune,
                  children: [
                    _buildCompactSwitch(
                      icon: Icons.flight_takeoff,
                      label: 'Afrejse',
                      subtitle: _flightAway
                          ? 'Flyver samlet fra lufthavnen'
                          : 'Rejsen starter på destinationen',
                      value: _flightAway,
                      onChanged: (val) => setState(() => _flightAway = val),
                    ),
                    _buildCompactSwitch(
                      icon: Icons.flight_land,
                      label: 'Hjemrejse',
                      subtitle: _flightHome
                          ? 'Lander samlet i lufthavnen'
                          : 'Rejsen slutter på destinationen',
                      value: _flightHome,
                      onChanged: (val) => setState(() => _flightHome = val),
                    ),
                    _buildCompactSwitch(
                      icon: Icons.map_outlined,
                      label: '"Vis kort"-knap',
                      subtitle: _mapEnabled
                          ? 'Vises på rejsekortet i appen'
                          : 'Skjult i appen',
                      value: _mapEnabled,
                      onChanged: (val) => setState(() => _mapEnabled = val),
                    ),
                    if (_mapEnabled)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, left: 46),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _backfillingMapLocations
                                ? null
                                : _manualUpdateMapPinpoints,
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.primary,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 4),
                            ),
                            icon: _backfillingMapLocations
                                ? SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppColors.primary),
                                  )
                                : const Icon(Icons.my_location, size: 16),
                            label: Text(
                                'Opdater pinpoints automatisk',
                                style: GoogleFonts.kanit(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                  ],
                );

                final preDepartureSection = _buildSectionCard(
                  title: 'Før afrejse',
                  icon: Icons.checklist,
                  action: _beforeDepartureItems.isEmpty
                      ? null
                      : Text('${_beforeDepartureItems.length} punkter',
                          style: AppTextStyles.caption()),
                  children: [
                    Text(
                      'Tjekliste rejsende ser i appen inden afrejse.',
                      style: AppTextStyles.caption(),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (_beforeDepartureItems.isNotEmpty)
                      ReorderableListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        buildDefaultDragHandles: false,
                        itemCount: _beforeDepartureItems.length,
                        onReorder: _reorderPreDepartureItems,
                        itemBuilder: (context, index) =>
                            _buildPreDepartureItemTile(
                                _beforeDepartureItems[index], index),
                      ),
                    _buildPreDepartureAddField(),
                    _buildPreDepartureSuggestions(),
                  ],
                );

                final agencyCoupons = widget.agencyInfo.coupons;
                final groupCoupons = _group!.coupons ?? [];
                final couponsSection = _buildSectionCard(
                  title: 'Affiliate links',
                  icon: Icons.local_offer,
                  action: _buildAddChip(onTap: () => _addOrEditCoupon()),
                  children: [
                    if (agencyCoupons.isEmpty && groupCoupons.isEmpty)
                      _buildEmptyRow('Ingen affiliate links tilføjet endnu')
                    else ...[
                      if (agencyCoupons.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 2),
                          child: Text('Fra bureauet',
                              style: AppTextStyles.caption()),
                        ),
                        ...agencyCoupons.map(
                            (coupon) => _buildCouponTile(coupon, isEditable: false)),
                      ],
                      if (groupCoupons.isNotEmpty) ...[
                        Padding(
                          padding: EdgeInsets.only(
                              top: agencyCoupons.isNotEmpty ? 12 : 4,
                              bottom: 2),
                          child: Text('For denne rejse',
                              style: AppTextStyles.caption()),
                        ),
                        ...groupCoupons
                            .map((coupon) => _buildCouponTile(coupon)),
                      ],
                    ],
                  ],
                );

                final content = isWide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                travelSection,
                                const SizedBox(height: AppSpacing.lg),
                                settingsSection,
                              ],
                            ),
                          ),
                          const SizedBox(width: AppSpacing.lg),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                preDepartureSection,
                                const SizedBox(height: AppSpacing.lg),
                                couponsSection,
                              ],
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          travelSection,
                          const SizedBox(height: AppSpacing.lg),
                          settingsSection,
                          const SizedBox(height: AppSpacing.lg),
                          preDepartureSection,
                          const SizedBox(height: AppSpacing.lg),
                          couponsSection,
                        ],
                      );

                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTripHeader(),
                      const SizedBox(height: AppSpacing.lg),
                      content,
                    ],
                  ),
                );
              },
            ),
            ),
          ),
        ),
      ),
      floatingActionButton: widget.canEditTrips
          ? FloatingActionButton.extended(
              onPressed: _saveGroupDetails,
              backgroundColor: AppColors.primary,
              label: Text('Gem ændringer',
                  style: GoogleFonts.kanit(
                      fontWeight: FontWeight.bold,
                      color: AppColors.onPrimary)),
              icon: Icon(Icons.save, color: AppColors.onPrimary),
            )
          : null,
    );
  }

  Widget _buildCompactSwitch({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: AppRadii.smRadius,
            ),
            child: Icon(icon, size: 17, color: AppColors.primary),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: AppTextStyles.label()),
                Text(subtitle,
                    style: AppTextStyles.caption()),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildAddChip({required VoidCallback onTap}) {
    return Material(
      color: AppColors.primary.withOpacity(0.1),
      borderRadius: AppRadii.lgRadius,
      child: InkWell(
        borderRadius: AppRadii.lgRadius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 15, color: AppColors.primary),
              const SizedBox(width: AppSpacing.xs),
              Text('Tilføj',
                  style: GoogleFonts.kanit(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyRow(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(text, style: AppTextStyles.body(color: Colors.grey[500])),
    );
  }

  Widget _buildTripHeader() {
    final group = _group!;
    final now = DateTime.now();
    final daysUntil = group.departureDate.difference(now).inDays;
    final isActive =
        group.departureDate.isBefore(now) && group.returnDate.isAfter(now);
    final countdownText = isActive
        ? 'Rejsen er i gang'
        : daysUntil >= 0
            ? 'Afrejse om $daysUntil dage'
            : 'Rejse afsluttet';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(18),
        boxShadow: AppShadows.card,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.darkGreen.withValues(alpha: 0.1),
              borderRadius: AppRadii.mdRadius,
            ),
            child: Icon(Icons.info_outline, color: AppColors.darkGreen, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(group.groupName ?? group.groupId,
                    style: AppTextStyles.headingBold(),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 1),
                Text(group.groupId,
                    style: GoogleFonts.kanit(fontSize: 12, color: Colors.black45)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: (isActive ? Colors.orange : AppColors.darkGreen).withValues(alpha: 0.1),
              borderRadius: AppRadii.smRadius,
            ),
            child: Text(countdownText,
                style: GoogleFonts.kanit(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isActive ? Colors.orange[800] : AppColors.darkGreen)),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard(
      {required String title,
      required IconData icon,
      required List<Widget> children,
      Widget? action}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(18),
        boxShadow: AppShadows.card,
      ),
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: AppColors.darkGreen.withValues(alpha: 0.1),
                        borderRadius: AppRadii.smRadius,
                      ),
                      child: Icon(icon, color: AppColors.darkGreen, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Text(title,
                        style: GoogleFonts.kanit(
                            fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)),
                  ],
                ),
                if (action != null) action,
              ],
            ),
            Divider(height: 16, thickness: 1, color: Colors.grey.withValues(alpha: 0.15)),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildPreDepartureItemTile(String item, int index) {
    final isEditing = _editingPreDepartureIndex == index;
    return Container(
      key: ValueKey('predep-$index-$item'),
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: isEditing ? Colors.white : Colors.black.withValues(alpha: 0.02),
        borderRadius: AppRadii.mdRadius,
        border: Border.all(
          color: isEditing
              ? AppColors.darkGreen.withValues(alpha: 0.4)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Icon(Icons.drag_indicator,
                    size: 18, color: Colors.black26),
              ),
            ),
          ),
          Expanded(
            child: isEditing
                ? CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.escape):
                          _cancelPreDepartureEdit,
                    },
                    child: TextField(
                      controller: _editPreDepartureController,
                      autofocus: true,
                      style: GoogleFonts.kanit(fontSize: 14),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                      ),
                      onSubmitted: (_) => _commitPreDepartureEdit(),
                      onTapOutside: (_) => _commitPreDepartureEdit(),
                    ),
                  )
                : Tooltip(
                    message: 'Klik for at redigere',
                    waitDuration: const Duration(milliseconds: 600),
                    child: InkWell(
                      onTap: () => _startEditingPreDepartureItem(index),
                      borderRadius: AppRadii.smRadius,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(item, style: GoogleFonts.kanit(fontSize: 14)),
                      ),
                    ),
                  ),
          ),
          if (isEditing)
            IconButton(
              tooltip: 'Gem',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.check, size: 18, color: AppColors.darkGreen),
              onPressed: _commitPreDepartureEdit,
            )
          else
            IconButton(
              tooltip: 'Rediger',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined,
                  size: 17, color: Colors.black38),
              onPressed: () => _startEditingPreDepartureItem(index),
            ),
          IconButton(
            tooltip: 'Slet',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline,
                size: 18, color: Colors.redAccent),
            onPressed: () => _deletePreDepartureItem(index),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// Always-visible input at the bottom of the list — type and press Enter
  /// to add, instead of opening a dialog per point.
  Widget _buildPreDepartureAddField() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _newPreDepartureController,
        builder: (context, value, _) {
          final canAdd = value.text.trim().isNotEmpty;
          return TextField(
            controller: _newPreDepartureController,
            focusNode: _newPreDepartureFocus,
            style: GoogleFonts.kanit(fontSize: 14),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _addPreDepartureItem(),
            decoration: InputDecoration(
              hintText: 'Tilføj punkt, f.eks. "Husk pas" — tryk Enter',
              hintStyle: GoogleFonts.kanit(fontSize: 14, color: Colors.grey[500]),
              prefixIcon: Icon(Icons.add, color: AppColors.darkGreen),
              suffixIcon: canAdd
                  ? Padding(
                      padding: const EdgeInsets.all(6),
                      child: ElevatedButton(
                        onPressed: _addPreDepartureItem,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.onPrimary,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: AppRadii.smRadius),
                        ),
                        child: Text('Tilføj',
                            style: GoogleFonts.kanit(
                                fontWeight: FontWeight.w600)),
                      ),
                    )
                  : null,
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: AppRadii.mdRadius,
                borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: AppRadii.mdRadius,
                borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: AppRadii.mdRadius,
                borderSide: BorderSide(color: AppColors.darkGreen, width: 1.5),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPreDepartureSuggestions() {
    final remaining = _preDepartureSuggestions
        .where((s) => !_beforeDepartureItems
            .any((item) => item.toLowerCase() == s.toLowerCase()))
        .toList();
    if (remaining.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Forslag — klik for at tilføje', style: AppTextStyles.caption()),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final suggestion in remaining)
                ActionChip(
                  avatar: Icon(Icons.add, size: 14, color: AppColors.darkGreen),
                  label: Text(suggestion,
                      style: GoogleFonts.kanit(fontSize: 12.5)),
                  backgroundColor: Colors.white,
                  side: BorderSide(color: Colors.black.withValues(alpha: 0.1)),
                  shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _addPreDepartureItem(suggestion),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCouponTile(Coupon coupon, {bool isEditable = true}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppShadows.card,
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(AppSpacing.md),
        leading: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: AppColors.beige,
            borderRadius: AppRadii.mdRadius,
          ),
          child: ClipRRect(
            borderRadius: AppRadii.mdRadius,
            child: coupon.imageURL.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: coupon.imageURL,
                    fit: BoxFit.contain,
                    errorWidget: (context, url, error) =>
                        Icon(Icons.local_offer, color: AppColors.darkGreen),
                  )
                : Icon(Icons.local_offer, color: AppColors.darkGreen),
          ),
        ),
        title: Text(
          coupon.couponName,
          style: GoogleFonts.kanit(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Colors.black87,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            coupon.description,
            style: GoogleFonts.kanit(
              fontSize: 14,
              color: Colors.black54,
            ),
          ),
        ),
        trailing: isEditable
            ? Container(
                decoration: BoxDecoration(
                  color: AppColors.beige,
                  shape: BoxShape.circle,
                ),
                child: PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Colors.black54),
                  shape:
                      RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
                  onSelected: (value) {
                    if (value == 'edit') {
                      _addOrEditCoupon(existingCoupon: coupon);
                    } else if (value == 'delete') {
                      _deleteCoupon(coupon);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit, size: 20, color: AppColors.darkGreen),
                          const SizedBox(width: AppSpacing.md),
                          Text('Rediger', style: GoogleFonts.kanit()),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          const Icon(Icons.delete,
                              size: 20, color: Colors.redAccent),
                          const SizedBox(width: AppSpacing.md),
                          Text('Slet', style: GoogleFonts.kanit()),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            : Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.beige,
                  borderRadius: AppRadii.smRadius,
                ),
                child: Text('Bureau',
                    style: GoogleFonts.kanit(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.darkGreen)),
              ),
      ),
    );
  }

  Widget _buildTextFormField(
      TextEditingController controller, String label, IconData icon,
      {TextInputType? keyboardType, bool isRequired = true}) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      style: GoogleFonts.kanit(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: AppTextStyles.body(color: Colors.grey[600]),
        prefixIcon: Icon(icon, size: 19),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: AppRadii.mdRadius),
        filled: true,
        fillColor: Colors.white,
      ),
      validator: (value) => isRequired && (value == null || value.isEmpty)
          ? 'Dette felt er påkrævet'
          : null,
    );
  }

  Widget _buildDateRow() {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () =>
                _pickDate(_departureDateController, _group!.departureDate),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Afrejsedato',
                labelStyle: AppTextStyles.body(color: Colors.grey[600]),
                prefixIcon: const Icon(Icons.calendar_today, size: 18),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border:
                    OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                filled: true,
                fillColor: Colors.white,
              ),
              child: Text(_departureDateController.text,
                  style: GoogleFonts.kanit(fontSize: 14)),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: InkWell(
            onTap: () => _pickDate(_returnDateController, _group!.returnDate),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Hjemkomstdato',
                labelStyle: AppTextStyles.body(color: Colors.grey[600]),
                prefixIcon: const Icon(Icons.calendar_today, size: 18),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border:
                    OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                filled: true,
                fillColor: Colors.white,
              ),
              child: Text(_returnDateController.text,
                  style: GoogleFonts.kanit(fontSize: 14)),
            ),
          ),
        ),
      ],
    );
  }
}
