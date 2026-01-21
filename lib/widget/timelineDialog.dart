import 'dart:io';
import 'package:backend/config/app_colors.dart';
import 'package:backend/models/bureau_offer.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'unsplash_image_picker.dart'; // <-- Import the picker

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
  late TextEditingController dayNumberController;
  late bool isDestination;
  late bool isEditing;
  late DateTime startDate;
  late DateTime endDate;

  List<BureauOffer> offers = [];
  final List<String> _sessionUploadedImages = [];

  @override
  void initState() {
    super.initState();
    isEditing = widget.event != null;

    typeController = TextEditingController(text: widget.event?.type ?? '');
    countryController = TextEditingController(text: widget.event?.country ?? '');
    descriptionController = TextEditingController(text: widget.event?.description ?? '');
    imageUrlController = TextEditingController(text: widget.event?.imageURL ?? '');
    imageUrlController.addListener(() {
      if (mounted) setState(() {});
    });
    dayNumberController = TextEditingController(text: widget.event?.dayNumber.toString() ?? '');
    isDestination = widget.event?.isDestination ?? false;
    startDate = widget.event?.startDate ?? DateTime.now();
    endDate = widget.event?.endDate ?? DateTime.now().add(const Duration(days: 1));
    offers = widget.event?.bureauOffers != null ? List.from(widget.event!.bureauOffers!) : [];
  }

  @override
  void dispose() {
    typeController.dispose();
    countryController.dispose();
    descriptionController.dispose();
    imageUrlController.dispose();
    dayNumberController.dispose();
    super.dispose();
  }

  Future<void> _saveChanges() async {
    try {
      final eventId = widget.event?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
      final savedEvent = TimelineEvent(
        id: eventId,
        type: typeController.text,
        country: countryController.text,
        startDate: startDate,
        endDate: endDate,
        dayNumber: int.tryParse(dayNumberController.text) ?? 0,
        isDestination: isDestination,
        imageURL: imageUrlController.text.trim().replaceAll(' ', '%20').replaceAll(RegExp(r'[\r\n]'), ''),
        description: descriptionController.text,
        bureauOffers: offers,
      );

      final groupDocRef = widget.repository.firestore.collection('groups').doc(widget.groupInformation.groupId);
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
        'bureauOffers': savedEvent.bureauOffers
                ?.map((o) => {
                      'offerName': o.offerName,
                      'teaser': o.teaser,
                      'imageURL': o.imageURL,
                      'description': o.description,
                    })
                .toList() ?? [],
      };

      if (isEditing) {
        int eventIndex = eventsList.indexWhere((event) => event['id'] == widget.event!.id);
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
      final groupDocRef = widget.repository.firestore.collection('groups').doc(widget.groupInformation.groupId);
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
        return AlertDialog(
          title: const Text('Bekræft sletning'),
          content: const Text('Er du sikker på, at du vil slette denne begivenhed? Handlingen kan ikke fortrydes.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Annuller'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Slet'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
            ),
          ],
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
    final detailsController = TextEditingController(text: offer?.description ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(offer == null ? 'Add Offer' : 'Edit Offer'),
        content: SingleChildScrollView(
          child: Column(
            children: [
              TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Offer Name')),
              TextField(controller: teaserController, decoration: const InputDecoration(labelText: 'Teaser')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.navActive),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => UnsplashImagePicker(
                      onImageSelected: (url) {
                        setState(() => imageController.text = url);
                      },
                    ),
                  );
                },
                child: Text(imageController.text.isEmpty ? 'Vælg billede' : 'Billede valgt', selectionColor: Colors.white,),
              ),
              TextField(controller: detailsController, decoration: const InputDecoration(labelText: 'Details'), maxLines: null),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
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
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _deleteOffer(int index) {
    setState(() => offers.removeAt(index));
  }

  Future<void> _pickAndUploadImage() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
      );

      if (result != null) {
        PlatformFile file = result.files.single;
        // Sanitize filename to remove spaces and special characters that might cause URL issues
        String fileName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        String uniqueFileName = '${DateTime.now().millisecondsSinceEpoch}_$fileName';
        // Use agencyCode instead of groupId for shared image storage
        String agencyCode = widget.groupInformation.agencyCode;
        Reference storageRef = FirebaseStorage.instance.ref('agencies/$agencyCode/timeline_images/$uniqueFileName');

        // Set content type metadata to ensure correct handling by image loaders
        String? mimeType;
        if (fileName.toLowerCase().endsWith('.png')) mimeType = 'image/png';
        else if (fileName.toLowerCase().endsWith('.jpg') || fileName.toLowerCase().endsWith('.jpeg')) mimeType = 'image/jpeg';
        SettableMetadata metadata = SettableMetadata(contentType: mimeType);

        UploadTask uploadTask;
        if (kIsWeb) {
          uploadTask = storageRef.putData(file.bytes!, metadata);
        } else {
          uploadTask = storageRef.putFile(File(file.path!), metadata);
        }

        await uploadTask;

        String downloadUrl = await storageRef.getDownloadURL();
        _sessionUploadedImages.add(downloadUrl);
        setState(() {
          imageUrlController.text = downloadUrl;
        });
      }
    } catch (e) {
      print('Fejl ved upload af billede: $e');
      if (mounted) {
        String errorMessage = 'Fejl ved upload: $e';
        if (e.toString().contains('unauthorized')) {
          errorMessage = 'Manglende rettigheder (Unauthorized). Kontakt en administrator.';
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
      backgroundColor: AppColors.panelBackground,
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
                if (imageUrlController.text.trim().isNotEmpty)
                  ClipRRect(
                    key: ValueKey(imageUrlController.text),
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      children: [
                        CachedNetworkImage(
                          imageUrl: imageUrlController.text.trim().replaceAll(' ', '%20').replaceAll(RegExp(r'[\r\n]'), ''),
                          height: 180,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
                          errorWidget: (context, url, error) => const Center(child: Icon(Icons.broken_image, size: 50, color: Colors.grey)),
                        ),
                        Container(
                          height: 180,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.black.withOpacity(0.25), Colors.transparent],
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                _buildTextField(typeController, 'Titel'),
                _buildTextField(countryController, 'Land, By eller Område'),
                _buildTextField(descriptionController, 'Beskrivelse', maxLines: 3),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.panelBackground,
                      elevation: 5,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
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
                                          setState(() => imageUrlController.text = url);
                                        },
                                      ),
                                    );
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
                    child: Text(imageUrlController.text.isEmpty ? 'Vælg billede' : 'Vælg nyt billede', style: const TextStyle(fontSize: 16)),
                  ),
                ),
                _buildTextField(dayNumberController, 'Dag (Fx. Dag 4)', keyboardType: TextInputType.number),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: _pickStartDate,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                          margin: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
                          decoration: BoxDecoration(color: AppColors.chipBackground, borderRadius: BorderRadius.circular(12)),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Startdato', style: TextStyle(fontWeight: FontWeight.bold)),
                              Text(DateFormat('dd/MM/yyyy').format(startDate)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: _pickEndDate,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                          margin: const EdgeInsets.only(left: 8, top: 8, bottom: 8),
                          decoration: BoxDecoration(color: AppColors.chipBackground, borderRadius: BorderRadius.circular(12)),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Slutdato', style: TextStyle(fontWeight: FontWeight.bold)),
                              Text(DateFormat('dd/MM/yyyy').format(endDate)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(color: AppColors.chipBackground, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Tilbud fra rejsebureauet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => _addOrEditOffer(),
                        child: const Text('Opret tilbud', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w300, color: Colors.white)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ...offers.asMap().entries.map((entry) {
                  int idx = entry.key;
                  BureauOffer offer = entry.value;
                  return Card(
                    color: AppColors.chipBackground,
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: ListTile(
                      title: Text(offer.offerName.isNotEmpty ? offer.offerName : 'Unnamed Offer'),
                      subtitle: Text(offer.teaser),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(icon: const Icon(Icons.edit), onPressed: () => _addOrEditOffer(offer: offer, index: idx)),
                          IconButton(icon: const Icon(Icons.delete), onPressed: () => _deleteOffer(idx)),
                        ],
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
                        child: const Text('Slet begivenhed', style: TextStyle(color: Colors.red, fontSize: 16)),
                      ),
                    const Spacer(),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _saveChanges,
                        child: Text(isEditing ? 'Gem ændringer' : 'Opret begivenhed', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w300, color: Colors.white)),
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

  Widget _buildTextField(TextEditingController controller, String label, {int maxLines = 1, TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: AppColors.homeGradientStart,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}
