import 'dart:async';
import 'dart:convert';

import 'package:backend/config/app_colors.dart';
import 'package:backend/models/bureau_offer.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import 'unsplash_image_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';

class TimelineDialog extends StatefulWidget {
  final TimelineEvent? event;
  final dynamic groupInformation;
  final GroupInformationRepository repository;

  const TimelineDialog({
    super.key,
    this.event,
    required this.groupInformation,
    required this.repository,
  });

  @override
  State<TimelineDialog> createState() => _TimelineDialogState();
}

class _TimelineDialogState extends State<TimelineDialog> {
  late TextEditingController typeController;
  late TextEditingController countryController;
  late TextEditingController descriptionController;
  late TextEditingController imageUrlController;
  late TextEditingController accommodationController;
  late TextEditingController transportController;
  late TextEditingController mealsController;
  late TextEditingController activitiesController;
  late TextEditingController addressController;

  late bool isDestination;
  late bool isEditing;
  late DateTime startDate;
  late DateTime endDate;

  List<BureauOffer> offers = [];

  bool _showAccommodationField = false;
  bool _showTransportField = false;
  bool _showMealsField = false;
  bool _showActivitiesField = false;

  String? selectedTransportIcon;

  final List<String> _sessionUploadedImages = [];

  // Map location. Only editable when the group has map enabled — resolved
  // via OpenStreetMap's free Nominatim geocoder, no paid API involved.
  double? _latitude;
  double? _longitude;
  bool _geocoding = false;
  String? _geocodeError;
  bool get _mapEnabled => widget.groupInformation.mapEnabled == true;

  // Keeps the address field mirroring "Land, By eller Område" until the
  // admin edits the address directly — at that point their edit wins and
  // the two fields stop tracking each other.
  bool _addressAutoSynced = false;
  bool _syncingAddressFromCountry = false;
  Timer? _geocodeDebounce;

  @override
  void initState() {
    super.initState();
    isEditing = widget.event != null;

    typeController = TextEditingController(text: widget.event?.type ?? '');
    countryController =
        TextEditingController(text: widget.event?.country ?? '');
    descriptionController =
        TextEditingController(text: widget.event?.description ?? '');
    imageUrlController =
        TextEditingController(text: widget.event?.imageURL ?? '');
    imageUrlController.addListener(() {
      if (mounted) setState(() {});
    });
    accommodationController =
        TextEditingController(text: widget.event?.accommodation ?? '');
    transportController =
        TextEditingController(text: widget.event?.transport ?? '');
    mealsController = TextEditingController(text: widget.event?.meals ?? '');
    activitiesController =
        TextEditingController(text: widget.event?.activities ?? '');
    // No saved address yet (or it still matches the country field from a
    // prior auto-sync) — keep tracking "Land, By eller Område" until the
    // admin types their own address.
    final savedAddress = widget.event?.address;
    _addressAutoSynced = _mapEnabled &&
        (savedAddress == null ||
            savedAddress.isEmpty ||
            savedAddress == widget.event?.country);
    addressController = TextEditingController(
      text: (savedAddress?.isNotEmpty ?? false)
          ? savedAddress!
          : (_mapEnabled ? countryController.text : ''),
    );

    _latitude = widget.event?.latitude;
    _longitude = widget.event?.longitude;

    addressController.addListener(_onAddressFieldChanged);
    countryController.addListener(_onCountryFieldChanged);

    // Resolve immediately if we already have an address (auto-filled or
    // saved) but no coordinates for it yet.
    if (_mapEnabled &&
        _latitude == null &&
        addressController.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _geocodeAddress();
      });
    }

    selectedTransportIcon = widget.event?.transportIcon;
    isDestination = widget.event?.isDestination ?? false;
    startDate = widget.event?.startDate ?? DateTime.now();
    endDate =
        widget.event?.endDate ?? DateTime.now().add(const Duration(days: 1));
    offers = widget.event?.bureauOffers != null
        ? List.from(widget.event!.bureauOffers!)
        : [];

    _showAccommodationField = widget.event?.accommodation?.isNotEmpty ?? false;
    _showTransportField = widget.event?.transport?.isNotEmpty ?? false;
    _showMealsField = widget.event?.meals?.isNotEmpty ?? false;
    _showActivitiesField = widget.event?.activities?.isNotEmpty ?? false;
  }

  @override
  void dispose() {
    _geocodeDebounce?.cancel();
    typeController.dispose();
    countryController.dispose();
    descriptionController.dispose();
    imageUrlController.dispose();
    accommodationController.dispose();
    transportController.dispose();
    mealsController.dispose();
    activitiesController.dispose();
    addressController.dispose();
    super.dispose();
  }

  /// Mirrors "Land, By eller Område" into the address field while it's
  /// still auto-synced, and re-resolves the point after a short pause in
  /// typing.
  void _onCountryFieldChanged() {
    if (!_mapEnabled || !_addressAutoSynced) return;
    _syncingAddressFromCountry = true;
    addressController.text = countryController.text;
    _syncingAddressFromCountry = false;
    _scheduleGeocode();
  }

  /// Clears any stale resolved point whenever the address text changes. A
  /// change that didn't come from the country-sync above is the admin
  /// taking manual control, so auto-sync stops from here on.
  void _onAddressFieldChanged() {
    final manualEdit = !_syncingAddressFromCountry;
    final hadCoordinates = _latitude != null || _longitude != null;
    if (manualEdit && _addressAutoSynced) {
      setState(() {
        _addressAutoSynced = false;
        if (hadCoordinates) {
          _latitude = null;
          _longitude = null;
          _geocodeError = null;
        }
      });
    } else if (hadCoordinates) {
      setState(() {
        _latitude = null;
        _longitude = null;
        _geocodeError = null;
      });
    }
  }

  void _scheduleGeocode() {
    _geocodeDebounce?.cancel();
    _geocodeDebounce = Timer(const Duration(milliseconds: 900), () {
      if (mounted) _geocodeAddress();
    });
  }

  /// Resolves the free-text address/city into coordinates via OpenStreetMap's
  /// free Nominatim geocoder. Clears any previously resolved point first, so
  /// stale coordinates never get saved alongside an edited/unresolved address.
  Future<void> _geocodeAddress() async {
    final query = addressController.text.trim();
    setState(() {
      _geocoding = true;
      _geocodeError = null;
      _latitude = null;
      _longitude = null;
    });

    if (query.isEmpty) {
      setState(() {
        _geocoding = false;
        _geocodeError = 'Indtast en adresse eller by først';
      });
      return;
    }

    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'json',
        'limit': '1',
      });
      final response = await http.get(
        uri,
        headers: {'User-Agent': 'BackpackControlpanel/1.0 (contact@backpack-app.dk)'},
      );

      if (response.statusCode == 200) {
        final results = jsonDecode(response.body) as List;
        if (results.isNotEmpty) {
          final first = results.first as Map<String, dynamic>;
          setState(() {
            _latitude = double.tryParse(first['lat'] as String);
            _longitude = double.tryParse(first['lon'] as String);
            _geocoding = false;
          });
          return;
        }
      }

      setState(() {
        _geocoding = false;
        _geocodeError = 'Kunne ikke finde stedet. Prøv en mere præcis adresse.';
      });
    } catch (e) {
      print('Error geocoding address: $e');
      setState(() {
        _geocoding = false;
        _geocodeError = 'Fejl ved opslag. Prøv igen.';
      });
    }
  }

  Future<void> _saveChanges() async {
    try {
      final eventId =
          widget.event?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
      final savedEvent = TimelineEvent(
        id: eventId,
        type: typeController.text,
        country: countryController.text,
        startDate: startDate,
        endDate: endDate,
        dayNumber: 1,
        isDestination: isDestination,
        imageURL: imageUrlController.text
            .trim()
            .replaceAll(' ', '%20')
            .replaceAll(RegExp(r'[\r\n]'), ''),
        description: descriptionController.text,
        bureauOffers: offers,
        accommodation: accommodationController.text,
        transport: transportController.text,
        transportIcon: selectedTransportIcon,
        meals: mealsController.text,
        activities: activitiesController.text,
        address: _mapEnabled ? addressController.text : null,
        latitude: _mapEnabled ? _latitude : null,
        longitude: _mapEnabled ? _longitude : null,
      );

      final groupDocRef = widget.repository.firestore
          .collection('groups')
          .doc(widget.groupInformation.groupId);
      final groupSnapshot = await groupDocRef.get();
      final groupData = groupSnapshot.data();

      List<dynamic> eventsList = [];
      if (groupData != null && groupData['timelineEvents'] is List) {
        eventsList = List.from(groupData['timelineEvents']);
      }

      final eventMap = {
        'id': savedEvent.id,
        'type': savedEvent.type,
        'country': savedEvent.country,
        'startDate': savedEvent.startDate,
        'endDate': savedEvent.endDate,
        'dayNumber': savedEvent.dayNumber,
        'isDestination': savedEvent.isDestination,
        'imageURL': savedEvent.imageURL,
        'description': savedEvent.description,
        'accommodation': savedEvent.accommodation,
        'transport': savedEvent.transport,
        'transportIcon': savedEvent.transportIcon,
        'meals': savedEvent.meals,
        'activities': savedEvent.activities,
        'address': savedEvent.address,
        'latitude': savedEvent.latitude,
        'longitude': savedEvent.longitude,
        'bureauOffers': savedEvent.bureauOffers
                ?.map((o) => {
                      'offerName': o.offerName,
                      'teaser': o.teaser,
                      'imageURL': o.imageURL,
                      'description': o.description,
                    })
                .toList() ??
            [],
      };

      if (isEditing) {
        int eventIndex =
            eventsList.indexWhere((event) => event['id'] == widget.event!.id);
        if (eventIndex != -1) {
          eventsList[eventIndex] = eventMap;
        } else {
          eventsList.add(eventMap);
        }
      } else {
        eventsList.add(eventMap);
      }

      await groupDocRef.update({'timelineEvents': eventsList});

      // Delete old image if it was replaced - DISABLED for shared agency images
      if (isEditing && widget.event != null) {
        final oldUrl = widget.event!.imageURL;
        if (oldUrl.isNotEmpty && oldUrl != savedEvent.imageURL) {
          // await _deleteImageFromStorage(oldUrl);
        }
      }

      // Delete unused session images (e.g. if user uploaded multiple times before saving)
      for (final url in _sessionUploadedImages) {
        if (url != savedEvent.imageURL) {
          await _deleteImageFromStorage(url);
        }
      }

      if (mounted) Navigator.pop(context, savedEvent);
    } catch (e) {
      print('Error saving event: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save changes')),
        );
      }
    }
  }

  Future<void> _deleteEvent() async {
    try {
      final groupDocRef = widget.repository.firestore
          .collection('groups')
          .doc(widget.groupInformation.groupId);
      final groupSnapshot = await groupDocRef.get();
      final groupData = groupSnapshot.data();

      if (groupData != null && groupData['timelineEvents'] is List) {
        List<dynamic> eventsList = List.from(groupData['timelineEvents']);
        eventsList.removeWhere((event) => event['id'] == widget.event!.id);
        await groupDocRef.update({'timelineEvents': eventsList});
      }

      if (widget.event?.imageURL.isNotEmpty == true) {
        // Disabled deletion to prevent breaking links in other groups sharing this image
        // await _deleteImageFromStorage(widget.event!.imageURL);
      }

      if (mounted) Navigator.of(context).pop(null);
    } catch (e) {
      print('Error deleting event: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete event')),
        );
      }
    }
  }

  void _showDeleteConfirmationDialog() {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.delete_outline_rounded,
                        size: 22, color: Colors.red),
                  ),
                ),
                const SizedBox(height: 14),
                Text('Slet begivenhed?',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.kanit(
                        fontSize: 18, fontWeight: FontWeight.w600, color: Colors.black87)),
                const SizedBox(height: 6),
                Text(
                    'Er du sikker på, at du vil slette denne begivenhed? Handlingen kan ikke fortrydes.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.kanit(
                        fontSize: 13, fontWeight: FontWeight.w500, color: Colors.black54)),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: Text('Annuller',
                            style: GoogleFonts.kanit(
                                color: Colors.grey[600], fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        child: Text('Slet',
                            style: GoogleFonts.kanit(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ).then((confirmed) {
      if (confirmed == true) {
        _deleteEvent();
      }
    });
  }

  Future<void> _pickStartDate() async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => startDate = picked);
  }

  Future<void> _pickEndDate() async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: endDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => endDate = picked);
  }

  void _addOrEditOffer({BureauOffer? offer, int? index}) {
    final nameController = TextEditingController(text: offer?.offerName ?? '');
    final teaserController = TextEditingController(text: offer?.teaser ?? '');
    final imageController = TextEditingController(text: offer?.imageURL ?? '');
    final detailsController =
        TextEditingController(text: offer?.description ?? '');

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
                Icon(offer == null ? Icons.add_circle : Icons.edit,
                    color: AppColors.darkGreen),
                const SizedBox(width: 12),
                Text(
                  offer == null ? 'Opret Tilbud' : 'Rediger Tilbud',
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
                  if (imageController.text.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        height: 120,
                        width: double.infinity,
                        color: Colors.white,
                        child: CachedNetworkImage(
                          imageUrl: imageController.text,
                          fit: BoxFit.cover,
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
                    const SizedBox(height: 16),
                  ],
                  _buildOfferDialogField(
                    controller: nameController,
                    label: 'Overskrift',
                    hint: 'F.eks. Besøg en lokal skole',
                    icon: Icons.title,
                  ),
                  const SizedBox(height: 12),
                  _buildOfferDialogField(
                    controller: teaserController,
                    label: 'Teaser',
                    hint: 'En kort fængende tekst',
                    icon: Icons.short_text,
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text('Billede',
                        style: GoogleFonts.kanit(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: Colors.black87)),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _buildOfferDialogField(
                          controller: imageController,
                          label: '', // Label handled by outer Text
                          hint: 'Link til billede',
                          icon: Icons.image_outlined,
                          onChanged: (val) => setDialogState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.navActive,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (context) => UnsplashImagePicker(
                                onImageSelected: (url) {
                                  setDialogState(
                                      () => imageController.text = url);
                                },
                              ),
                            );
                          },
                          child: const Icon(Icons.search),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildOfferDialogField(
                    controller: detailsController,
                    label: 'Detaljer',
                    hint: 'Uddyb beskrivelsen her...',
                    icon: Icons.notes,
                    maxLines: 4,
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
                      borderRadius: BorderRadius.circular(12)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                onPressed: () {
                  if (nameController.text.isEmpty) return;

                  final newOffer = BureauOffer(
                    offerName: nameController.text,
                    teaser: teaserController.text,
                    imageURL: imageController.text,
                    description: detailsController.text,
                  );
                  setState(() {
                    if (offer != null && index != null) {
                      offers[index] = newOffer;
                    } else {
                      offers.add(newOffer);
                    }
                  });
                  Navigator.pop(context);
                },
                child: Text(offer == null ? 'Opret' : 'Gem',
                    style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              )
            ],
          );
        },
      ),
    );
  }

  Widget _buildOfferDialogField({
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
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(label,
                style: GoogleFonts.kanit(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Colors.black87)),
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
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey[350]!),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey[300]!),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.darkGreen, width: 2),
            ),
          ),
          style: GoogleFonts.kanit(fontSize: 15),
        ),
      ],
    );
  }

  void _deleteOffer(int index) {
    setState(() => offers.removeAt(index));
  }

  Future<void> _pickAndUploadImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);

      if (image != null) {
        final CroppedFile? croppedFile = await ImageCropper().cropImage(
          sourcePath: image.path,
          aspectRatio: const CropAspectRatio(ratioX: 2.5, ratioY: 1),
          uiSettings: [
            AndroidUiSettings(
              toolbarTitle: 'Beskær billede',
              toolbarColor: AppColors.primary,
              toolbarWidgetColor: AppColors.onPrimary,
              initAspectRatio: CropAspectRatioPreset.ratio4x3,
              lockAspectRatio: true,
            ),
            IOSUiSettings(
              title: 'Beskær billede',
              aspectRatioLockEnabled: true,
            ),
            WebUiSettings(
              context: context,
              presentStyle: WebPresentStyle.dialog,
              size: const CropperSize(
                width: 480,
                height: 480,
              ),
              customDialogBuilder: (cropper, init, crop, rotate, scale) {
                return StatefulBuilder(builder: (context, setState) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    init();
                  });

                  return Dialog(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.5,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Beskær & Zoom',
                                    style: GoogleFonts.kanit(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold)),
                                IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: () =>
                                        Navigator.of(context).pop()),
                              ],
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: 450,
                              height: 250,
                              child: ClipRect(child: cropper),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.zoom_out,
                                    size: 20, color: Colors.grey),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10),
                                  child: Text('Zoom ud/ind herover',
                                      style: GoogleFonts.kanit(
                                          color: Colors.grey, fontSize: 13)),
                                ),
                                const Icon(Icons.zoom_in,
                                    size: 20, color: Colors.grey),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    child: Text('Annuller',
                                        style: GoogleFonts.kanit(
                                            color: Colors.red))),
                                const SizedBox(width: 10),
                                ElevatedButton(
                                  onPressed: () async {
                                    final result = await crop();
                                    if (context.mounted) {
                                      Navigator.of(context).pop(result);
                                    }
                                  },
                                  style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.primary),
                                  child: Text('Beskær',
                                      style: GoogleFonts.kanit(
                                          color: AppColors.onPrimary)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                });
              },
            ),
          ],
        );

        if (croppedFile != null) {
          String fileName =
              image.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
          String uniqueFileName =
              '${DateTime.now().millisecondsSinceEpoch}_$fileName';
          String agencyCode = widget.groupInformation.agencyCode;
          Reference storageRef = FirebaseStorage.instance
              .ref('agencies/$agencyCode/timeline_images/$uniqueFileName');

          final bytes = await croppedFile.readAsBytes();

          String? mimeType;
          if (fileName.toLowerCase().endsWith('.png'))
            mimeType = 'image/png';
          else if (fileName.toLowerCase().endsWith('.jpg') ||
              fileName.toLowerCase().endsWith('.jpeg')) mimeType = 'image/jpeg';

          SettableMetadata metadata =
              SettableMetadata(contentType: mimeType ?? 'image/jpeg');

          await storageRef.putData(bytes, metadata);

          String downloadUrl = await storageRef.getDownloadURL();
          _sessionUploadedImages.add(downloadUrl);
          setState(() {
            imageUrlController.text = downloadUrl;
          });
        }
      }
    } catch (e) {
      print('Fejl ved upload af billede: $e');
      if (mounted) {
        String errorMessage = 'Fejl ved upload: $e';
        if (e.toString().contains('unauthorized')) {
          errorMessage =
              'Manglende rettigheder (Unauthorized). Kontakt en administrator.';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      }
    }
  }

  Future<void> _deleteImageFromStorage(String url) async {
    if (url.isEmpty) return;
    try {
      if (url.contains('firebasestorage.googleapis.com')) {
        await FirebaseStorage.instance.refFromURL(url).delete();
      }
    } catch (e) {
      print('Error deleting image from storage: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20.0)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
          maxWidth: MediaQuery.of(context).size.width * 0.5,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                          isEditing
                              ? Icons.edit_calendar_outlined
                              : Icons.add_location_alt_outlined,
                          color: AppColors.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                          isEditing ? 'Rediger begivenhed' : 'Ny begivenhed',
                          style: GoogleFonts.kanit(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (imageUrlController.text.trim().isNotEmpty)
                  ClipRRect(
                    key: ValueKey(imageUrlController.text),
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      children: [
                        CachedNetworkImage(
                          imageUrl: imageUrlController.text
                              .trim()
                              .replaceAll(' ', '%20')
                              .replaceAll(RegExp(r'[\r\n]'), ''),
                          height: 180,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          placeholder: (context, url) =>
                              const Center(child: CircularProgressIndicator()),
                          errorWidget: (context, url, error) => const Center(
                              child: Icon(Icons.broken_image,
                                  size: 50, color: Colors.grey)),
                        ),
                        Container(
                          height: 180,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.black.withValues(alpha: 0.25),
                                Colors.transparent
                              ],
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    height: 110,
                    decoration: BoxDecoration(
                      color: AppColors.cardBackground,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.image_outlined, size: 28, color: Colors.grey[400]),
                        const SizedBox(height: 6),
                        Text('Intet billede valgt',
                            style: GoogleFonts.kanit(
                                fontSize: 12.5, color: Colors.grey[500])),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                _buildTextField(typeController, 'Titel', maxLength: 40),
                _buildTextField(countryController, 'Land, By eller Område'),
                if (_mapEnabled) _buildLocationField(),
                _buildTextField(descriptionController, 'Beskrivelse',
                    maxLines: 3),
                const SizedBox(height: 16),
                _buildOptionalDetailField(
                  controller: accommodationController,
                  label: 'Overnatning',
                  buttonText: 'Tilføj Overnatning',
                  isVisible: _showAccommodationField,
                  onToggle: () => setState(
                      () => _showAccommodationField = !_showAccommodationField),
                ),
                _buildOptionalDetailField(
                  controller: transportController,
                  label: 'Transport',
                  buttonText: 'Tilføj Transport',
                  isVisible: _showTransportField,
                  extraContent: _buildTransportIconSelector(),
                  onToggle: () => setState(() {
                    _showTransportField = !_showTransportField;
                    if (!_showTransportField) selectedTransportIcon = null;
                  }),
                ),
                _buildOptionalDetailField(
                  controller: mealsController,
                  label: 'Måltider',
                  buttonText: 'Tilføj Måltider',
                  isVisible: _showMealsField,
                  onToggle: () =>
                      setState(() => _showMealsField = !_showMealsField),
                ),
                _buildOptionalDetailField(
                  controller: activitiesController,
                  label: 'Aktiviteter',
                  buttonText: 'Tilføj Aktiviteter',
                  isVisible: _showActivitiesField,
                  onToggle: () => setState(
                      () => _showActivitiesField = !_showActivitiesField),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: Material(
                    color: AppColors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      showModalBottomSheet(
                        context: context,
                        builder: (BuildContext context) {
                          return SafeArea(
                            child: Wrap(
                              children: <Widget>[
                                ListTile(
                                  leading: const Icon(Icons.photo_library),
                                  title: const Text('Vælg fra Unsplash'),
                                  onTap: () {
                                    Navigator.pop(context);
                                    showDialog(
                                      context: context,
                                      builder: (context) => UnsplashImagePicker(
                                        onImageSelected: (url) {
                                          setState(() =>
                                              imageUrlController.text = url);
                                        },
                                      ),
                                    );
                                  },
                                ),
                                ListTile(
                                  leading: const Icon(Icons.folder_special),
                                  title: const Text('Vælg fra fotobibliotek'),
                                  onTap: () async {
                                    Navigator.pop(context);
                                    final selectedUrl =
                                        await showDialog<String>(
                                      context: context,
                                      builder: (context) =>
                                          _AgencyImagePickerDialog(
                                        agencyCode:
                                            widget.groupInformation.agencyCode,
                                      ),
                                    );
                                    if (selectedUrl != null) {
                                      setState(() => imageUrlController.text =
                                          selectedUrl);
                                    }
                                  },
                                ),
                                ListTile(
                                  leading: const Icon(Icons.upload_file),
                                  title: const Text('Upload eget billede'),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _pickAndUploadImage();
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.image_outlined, color: AppColors.primary, size: 20),
                          const SizedBox(width: 8),
                          Text(
                              imageUrlController.text.isEmpty
                                  ? 'Vælg billede'
                                  : 'Vælg nyt billede',
                              style: GoogleFonts.kanit(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15)),
                        ],
                      ),
                    ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Material(
                        color: AppColors.cardBackground,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: _pickStartDate,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                vertical: 12, horizontal: 12),
                            margin: const EdgeInsets.only(
                                right: 8, top: 8, bottom: 8),
                            child: Row(
                              children: [
                                Icon(Icons.calendar_today_outlined,
                                    size: 16, color: AppColors.primary),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text('Startdato',
                                          style: GoogleFonts.kanit(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.grey[600])),
                                      Text(
                                          DateFormat('dd/MM/yyyy')
                                              .format(startDate),
                                          style: GoogleFonts.kanit(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.black87)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Material(
                        color: AppColors.cardBackground,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: _pickEndDate,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                vertical: 12, horizontal: 12),
                            margin: const EdgeInsets.only(
                                left: 8, top: 8, bottom: 8),
                            child: Row(
                              children: [
                                Icon(Icons.event_outlined,
                                    size: 16, color: AppColors.primary),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text('Slutdato',
                                          style: GoogleFonts.kanit(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.grey[600])),
                                      Text(
                                          DateFormat('dd/MM/yyyy')
                                              .format(endDate),
                                          style: GoogleFonts.kanit(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.black87)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('TILBUD FRA REJSEBUREAUET',
                          style: GoogleFonts.kanit(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                              color: Colors.grey[600])),
                      Material(
                        color: AppColors.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () => _addOrEditOffer(),
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add, size: 15, color: AppColors.primary),
                                const SizedBox(width: 4),
                                Text('Opret tilbud',
                                    style: GoogleFonts.kanit(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.primary)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ...offers.asMap().entries.map((entry) {
                  int idx = entry.key;
                  BureauOffer offer = entry.value;
                  return Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(12),
                      leading: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: offer.imageURL.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: offer.imageURL,
                                  fit: BoxFit.cover,
                                  errorWidget: (context, url, error) => Icon(
                                      Icons.local_offer,
                                      color: AppColors.primary),
                                )
                              : Icon(Icons.local_offer, color: AppColors.primary),
                        ),
                      ),
                      title: Text(
                        offer.offerName.isNotEmpty
                            ? offer.offerName
                            : 'Unavngivet tilbud',
                        style: GoogleFonts.kanit(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.black87,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          offer.teaser,
                          style: GoogleFonts.kanit(
                            fontSize: 14,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                      trailing: Container(
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert,
                              color: Colors.black54),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          onSelected: (value) {
                            if (value == 'edit') {
                              _addOrEditOffer(offer: offer, index: idx);
                            } else if (value == 'delete') {
                              _deleteOffer(idx);
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'edit',
                              child: Row(
                                children: [
                                  Icon(Icons.edit,
                                      size: 20, color: AppColors.primary),
                                  const SizedBox(width: 12),
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
                                  const SizedBox(width: 12),
                                  Text('Slet', style: GoogleFonts.kanit()),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
                const SizedBox(height: 20),
                Row(
                  children: [
                    if (isEditing)
                      TextButton(
                        onPressed: _showDeleteConfirmationDialog,
                        child: Text('Slet begivenhed',
                            style: GoogleFonts.kanit(
                                color: Colors.red,
                                fontWeight: FontWeight.w600,
                                fontSize: 14)),
                      ),
                    const Spacer(),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.onPrimary,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _saveChanges,
                        child: Text(
                            isEditing ? 'Gem ændringer' : 'Opret begivenhed',
                            style: GoogleFonts.kanit(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppColors.onPrimary)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTransportIconSelector() {
    final icons = {
      'car': Icons.directions_car,
      'bus': Icons.directions_bus,
      'train': Icons.train,
      'flight': Icons.flight,
      'ferry': Icons.directions_boat,
      'walk': Icons.directions_walk,
      'motorcycle': Icons.motorcycle_outlined,
    };

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: icons.entries.map((entry) {
        final isSelected = selectedTransportIcon == entry.key;
        return InkWell(
          onTap: () => setState(() => selectedTransportIcon = entry.key),
          borderRadius: BorderRadius.circular(30),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primary : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(
                  color: isSelected ? AppColors.primary : Colors.grey.shade400),
            ),
            child: Icon(
              entry.value,
              color: isSelected ? AppColors.onPrimary : Colors.grey.shade600,
              size: 20,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildOptionalDetailField({
    required TextEditingController controller,
    required String label,
    required String buttonText,
    required bool isVisible,
    required VoidCallback onToggle,
    Widget? extraContent,
  }) {
    if (isVisible) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6.0),
        child: Column(
          children: [
            if (extraContent != null) ...[
              extraContent,
              const SizedBox(height: 8)
            ],
            TextField(
              controller: controller,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: GoogleFonts.kanit(fontSize: 14),
              decoration: InputDecoration(
                labelText: label,
                labelStyle: GoogleFonts.kanit(fontSize: 13, color: Colors.grey[600]),
                filled: true,
                fillColor: AppColors.cardBackground,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.primary, width: 1.5),
                ),
                suffixIcon: IconButton(
                  icon: Icon(Icons.close, size: 18, color: Colors.grey[500]),
                  onPressed: () {
                    controller.clear();
                    onToggle();
                  },
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Material(
          color: AppColors.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
              child: Row(
                children: [
                  Icon(Icons.add, color: AppColors.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(buttonText,
                      style: GoogleFonts.kanit(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                ],
              ),
            ),
          ),
        ),
      );
    }
  }

  Widget _buildTextField(TextEditingController controller, String label,
      {int maxLines = 1, TextInputType? keyboardType, int? maxLength}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        maxLength: maxLength,
        style: GoogleFonts.kanit(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: GoogleFonts.kanit(fontSize: 13, color: Colors.grey[600]),
          filled: true,
          fillColor: AppColors.cardBackground,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5),
          ),
          helperText: maxLength != null
              ? 'Holdes kort, så det passer på rejsekortet i appen'
              : null,
          helperStyle: GoogleFonts.kanit(fontSize: 11, color: Colors.grey[500]),
        ),
      ),
    );
  }

  Widget _buildLocationField() {
    final resolved = _latitude != null && _longitude != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: addressController,
                  style: GoogleFonts.kanit(fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Adresse eller by (til kort)',
                    labelStyle:
                        GoogleFonts.kanit(fontSize: 13, color: Colors.grey[600]),
                    filled: true,
                    fillColor: AppColors.cardBackground,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppColors.primary, width: 1.5),
                    ),
                    suffixIcon: resolved
                        ? Icon(Icons.check_circle,
                            color: Colors.green[600], size: 20)
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _geocoding ? null : _geocodeAddress,
                  child: _geocoding
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.my_location, size: 18),
                ),
              ),
            ],
          ),
          if (_geocodeError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(_geocodeError!,
                  style: GoogleFonts.kanit(fontSize: 12, color: Colors.red)),
            )
          else if (resolved)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                  'Fundet på kort (${_latitude!.toStringAsFixed(3)}, ${_longitude!.toStringAsFixed(3)})',
                  style: GoogleFonts.kanit(fontSize: 12, color: Colors.green[700])),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                  _geocoding
                      ? 'Finder stedet...'
                      : _addressAutoSynced
                          ? 'Følger automatisk "Land, By eller Område" — rediger for at bruge en anden adresse'
                          : 'Tryk på knappen for at finde stedet på kortet',
                  style: GoogleFonts.kanit(fontSize: 12, color: Colors.grey[500])),
            ),
        ],
      ),
    );
  }
}

class _AgencyImagePickerDialog extends StatefulWidget {
  final String agencyCode;

  const _AgencyImagePickerDialog({required this.agencyCode});

  @override
  State<_AgencyImagePickerDialog> createState() =>
      _AgencyImagePickerDialogState();
}

class _AgencyImagePickerDialogState extends State<_AgencyImagePickerDialog> {
  String _currentPath = '';
  List<Reference> _folders = [];
  List<Reference> _images = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  String get _storageBasePath {
    if (_currentPath.isEmpty) {
      return 'agencies/${widget.agencyCode}/timeline_images';
    } else {
      return 'agencies/${widget.agencyCode}/timeline_images/$_currentPath';
    }
  }

  Future<void> _loadImages() async {
    try {
      final result =
          await FirebaseStorage.instance.ref(_storageBasePath).listAll();

      if (mounted) {
        setState(() {
          _folders = result.prefixes;
          _images = result.items.where((ref) => ref.name != '.keep').toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.panelBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
          maxWidth: 600,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(children: [
                if (_currentPath.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      setState(() {
                        _currentPath = '';
                        _isLoading = true;
                      });
                      _loadImages();
                    },
                  ),
                Expanded(
                  child: Text(
                    _currentPath.isEmpty ? 'Vælg fra billedbank' : _currentPath,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ]),
              const SizedBox(height: 20),
              Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : (_folders.isEmpty && _images.isEmpty)
                          ? const Center(child: Text('Ingen billeder fundet'))
                          : CustomScrollView(slivers: [
                              if (_folders.isNotEmpty)
                                SliverGrid(
                                    gridDelegate:
                                        const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 150,
                                      crossAxisSpacing: 10,
                                      mainAxisSpacing: 10,
                                      mainAxisExtent: 50,
                                    ),
                                    delegate: SliverChildBuilderDelegate(
                                        (context, index) {
                                      final folder = _folders[index];
                                      return InkWell(
                                          onTap: () {
                                            setState(() {
                                              _currentPath = folder.name;
                                              _isLoading = true;
                                            });
                                            _loadImages();
                                          },
                                          child: Container(
                                              decoration: BoxDecoration(
                                                  color: AppColors.primary
                                                      .withOpacity(0.1),
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  border: Border.all(
                                                      color: AppColors.primary
                                                          .withOpacity(0.3))),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8),
                                              child: Row(children: [
                                                Icon(Icons.folder,
                                                    color: AppColors.darkGreen,
                                                    size: 20),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                    child: Text(folder.name,
                                                        overflow: TextOverflow
                                                            .ellipsis)),
                                              ])));
                                    }, childCount: _folders.length)),
                              if (_folders.isNotEmpty && _images.isNotEmpty)
                                const SliverToBoxAdapter(
                                    child: SizedBox(height: 20)),
                              if (_images.isNotEmpty)
                                SliverGrid(
                                    gridDelegate:
                                        const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 150,
                                      crossAxisSpacing: 10,
                                      mainAxisSpacing: 10,
                                    ),
                                    delegate: SliverChildBuilderDelegate(
                                        (context, index) {
                                      final ref = _images[index];
                                      return FutureBuilder<String>(
                                        future: ref.getDownloadURL(),
                                        builder: (context, snapshot) {
                                          if (!snapshot.hasData) {
                                            return Container(
                                              color: Colors.grey[200],
                                              child: const Center(
                                                  child:
                                                      CircularProgressIndicator()),
                                            );
                                          }
                                          return InkWell(
                                            onTap: () => Navigator.pop(
                                                context, snapshot.data),
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  CachedNetworkImage(
                                                    imageUrl: snapshot.data!,
                                                    fit: BoxFit.cover,
                                                    placeholder:
                                                        (context, url) =>
                                                            Container(
                                                                color: Colors
                                                                    .grey[200]),
                                                    errorWidget: (context, url,
                                                            error) =>
                                                        const Icon(Icons.error),
                                                  ),
                                                  Positioned(
                                                    bottom: 0,
                                                    left: 0,
                                                    right: 0,
                                                    child: Container(
                                                      color: Colors.black54,
                                                      padding:
                                                          const EdgeInsets.all(
                                                              2),
                                                      child: Text(
                                                        ref.name,
                                                        style: const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 10),
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        textAlign:
                                                            TextAlign.center,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      );
                                    }, childCount: _images.length)),
                            ])),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Annuller'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
