import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:backend/models/agencyInformation.dart';
import 'package:backend/models/coupon_model.dart';
import 'package:backend/widget/backgroundVideo.dart';
import 'package:backend/widget/bureauLogoHeader.dart';
import 'package:backend/widget/saved_snackbar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui';

/// Sidebar "App" screen: a big, phone-framed live preview of how the app
/// looks for this bureau, with a small editor for the controls that drive
/// it (logo, video, color, map default) next to it. Emergency phone and the
/// welcome message live only in BureauSettingsScreen (Indstillinger) now —
/// not shown here at all, so nothing is ever editable from both places.
/// Logo/video themselves are rendered only inside the phone mockup, never a
/// second time in the editor, so there's exactly one place to see "how it
/// actually looks."
class AppScreen extends StatelessWidget {
  final AgencyInformation agencyInfo;
  final String? logoUrl;
  final bool isNested;

  const AppScreen({
    super.key,
    required this.agencyInfo,
    this.logoUrl,
    this.isNested = false,
  });

  @override
  Widget build(BuildContext context) {
    final themeColor = AppColors.fromHex(agencyInfo.mainColor);

    return Scaffold(
      backgroundColor: AppColors.scaffoldGradientStart,
      appBar: isNested
          ? null
          : AppBar(
              title: Text('App',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              backgroundColor: themeColor,
              foregroundColor: Colors.white,
              elevation: 0,
              centerTitle: true,
            ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 900;
            final editor = _AppSettingsEditor(agencyInfo: agencyInfo);
            // Bigger and on the right, per explicit request — this is the
            // whole point of the screen, so it gets the visual weight.
            final preview = Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _MockupLabel(themeColor: themeColor),
                const SizedBox(height: 14),
                _PhoneMockup(agencyInfo: agencyInfo),
              ],
            );

            if (isWide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: editor),
                  const SizedBox(width: AppSpacing.xxl),
                  preview,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: preview),
                const SizedBox(height: AppSpacing.xl),
                editor,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A clear, unmissable label above the phone frame — this is explicitly a
/// mockup/preview, not the real running app, even though the colors/logo/
/// video are live.
class _MockupLabel extends StatelessWidget {
  const _MockupLabel({required this.themeColor});

  final Color themeColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: themeColor.withValues(alpha: 0.12),
            borderRadius: AppRadii.lgRadius,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.visibility_outlined, size: 14, color: themeColor),
              const SizedBox(width: 6),
              Text('EKSEMPEL-VISNING',
                  style: GoogleFonts.kanit(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: themeColor,
                      letterSpacing: 0.6)),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text('Sådan ser appen ud for jeres rejsende',
            style: GoogleFonts.kanit(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.black87)),
        Text(
            'Farver, logo og video er live — rejseplanen herunder er eksempeldata',
            textAlign: TextAlign.center,
            style: AppTextStyles.caption()),
      ],
    );
  }
}

/// The editable, traveler-visible controls behind the mockup: logo, video,
/// color, and the map-enabled default. Moved here wholesale from
/// BureauSettingsScreen (not duplicated) — see AppScreen's doc comment for
/// why the split exists. Logo/video aren't previewed here at all — only in
/// the phone mockup next to this — so there's no double rendering of "how
/// it looks."
class _AppSettingsEditor extends StatefulWidget {
  const _AppSettingsEditor({required this.agencyInfo});

  final AgencyInformation agencyInfo;

  @override
  State<_AppSettingsEditor> createState() => _AppSettingsEditorState();
}

class _AppSettingsEditorState extends State<_AppSettingsEditor> {
  late TextEditingController _colorController;
  String? _logoUrl;
  String? _videoUrl;
  bool _isUploadingLogo = false;
  bool _isUploadingVideo = false;
  bool _isLoadingInitialLogo = true;
  // For bureaus whose primary logo is white/low-contrast — an optional
  // second variant the traveler app uses everywhere except the Home
  // screen's hero (see backpack/lib/widget/agencyLogo.dart).
  String? _contrastLogoUrl;
  bool _isUploadingContrastLogo = false;
  bool _isLoadingInitialContrastLogo = true;
  late bool _mapEnabledDefault;
  late bool _whatsappConfirmEnabled;
  late bool _packingListScreenEnabled;
  late bool _groupScreenEnabled;
  late bool _documentsScreenEnabled;
  late bool _travelersCanMessage;
  late bool _introTourEnabled;
  late bool _marketingConsentEnabled;
  late List<Coupon> _coupons;

  Timer? _colorDebounce;

  @override
  void initState() {
    super.initState();
    _mapEnabledDefault = widget.agencyInfo.mapEnabledDefault;
    _whatsappConfirmEnabled = widget.agencyInfo.whatsappConfirmEnabled;
    _packingListScreenEnabled = widget.agencyInfo.packingListScreenEnabled;
    _groupScreenEnabled = widget.agencyInfo.groupScreenEnabled;
    _documentsScreenEnabled = widget.agencyInfo.documentsScreenEnabled;
    _travelersCanMessage = widget.agencyInfo.travelersCanMessage;
    _introTourEnabled = widget.agencyInfo.introTourEnabled;
    _marketingConsentEnabled = widget.agencyInfo.marketingConsentEnabled;
    _coupons = List.of(widget.agencyInfo.coupons);
    _colorController = TextEditingController(text: widget.agencyInfo.mainColor);
    _videoUrl = widget.agencyInfo.videoUrl;
    _loadInitialLogo();
    _loadInitialContrastLogo();
  }

  @override
  void dispose() {
    _colorDebounce?.cancel();
    _colorController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialLogo() async {
    try {
      final ref = FirebaseStorage.instance
          .ref('config/AgencyLogos/${widget.agencyInfo.agencyCode}.png');
      final url = await ref.getDownloadURL();
      if (mounted) setState(() => _logoUrl = url);
    } catch (e) {
      // This is expected if no logo has been uploaded yet.
      debugPrint('No initial logo found: $e');
    } finally {
      if (mounted) setState(() => _isLoadingInitialLogo = false);
    }
  }

  Future<void> _loadInitialContrastLogo() async {
    try {
      final ref = FirebaseStorage.instance.ref(
          'config/AgencyLogos/${widget.agencyInfo.agencyCode}_contrast.png');
      final url = await ref.getDownloadURL();
      if (mounted) setState(() => _contrastLogoUrl = url);
    } catch (e) {
      // This is expected if no contrast logo has been uploaded yet.
      debugPrint('No initial contrast logo found: $e');
    } finally {
      if (mounted) setState(() => _isLoadingInitialContrastLogo = false);
    }
  }

  Color _getColorFromHex(String hexColor) {
    try {
      return AppColors.fromHex(hexColor);
    } catch (e) {
      return Colors.black;
    }
  }

  void _showColorPicker() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vælg farve'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: _getColorFromHex(_colorController.text),
            onColorChanged: (color) {
              setState(() {
                _colorController.text =
                    '#${color.value.toRadixString(16).substring(2).toUpperCase()}';
              });
            },
            enableAlpha: false,
            displayThumbColor: true,
            paletteType: PaletteType.hsvWithHue,
          ),
        ),
        actions: [
          ElevatedButton(
            child: const Text('Vælg'),
            onPressed: () {
              // Confirming the picker commits immediately — no debounce
              // needed since this is a single discrete action, not typing.
              _colorDebounce?.cancel();
              Navigator.of(context).pop();
              _saveField({'mainColor': _colorController.text});
            },
          ),
        ],
      ),
    );
  }

  // agency/{agencyCode} is function-only in firestore.rules — this goes
  // through updateAppSettings. Deliberately field-scoped (only ever sends
  // the field(s) that specific control owns) rather than resending this
  // whole screen's local state: emergencyPhone/standardMessage are also
  // editable from BureauSettingsScreen (Indstillinger) now, a *separate*
  // mounted widget with its own local copy — if this screen resent its own
  // (possibly stale) copy of those on every save, it could silently revert
  // an edit made over there. updateAppSettings only writes whichever keys
  // are present in `fields`, so this is safe regardless of which screen is
  // open or how stale the others' local state is.
  Future<void> _saveField(Map<String, dynamic> fields) async {
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('updateAppSettings')
          .call({'agencyCode': widget.agencyInfo.agencyCode, ...fields});
      if (mounted) {
        showSavedSnackbar(context, _getColorFromHex(_colorController.text));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Fejl: $e')));
      }
    }
  }

  Future<void> _saveCoupons() =>
      _saveField({'coupons': _coupons.map((c) => c.toMap()).toList()});

  void _addOrEditCoupon(Color themeColor, {Coupon? existingCoupon}) {
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
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
            title: Row(
              children: [
                Icon(existingCoupon == null ? Icons.add_circle : Icons.edit,
                    color: themeColor),
                const SizedBox(width: AppSpacing.md),
                Text(
                  existingCoupon == null
                      ? 'Tilføj affiliate link'
                      : 'Rediger affiliate link',
                  style: AppTextStyles.headingBold(),
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
                  _buildCouponDialogField(
                    controller: nameController,
                    label: 'Navn',
                    hint: 'F.eks. 20% rabat på rejseforsikring',
                    icon: Icons.label_outline,
                    themeColor: themeColor,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildCouponDialogField(
                    controller: descriptionController,
                    label: 'Beskrivelse',
                    hint: 'F.eks. Gælder alle bookinger i 2026',
                    icon: Icons.description_outlined,
                    maxLines: 2,
                    themeColor: themeColor,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildCouponDialogField(
                    controller: imageUrlController,
                    label: 'Billed-URL',
                    hint: 'Link til logo eller billede',
                    icon: Icons.image_outlined,
                    themeColor: themeColor,
                    onChanged: (val) => setDialogState(() {}),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildCouponDialogField(
                    controller: linkController,
                    label: 'Affiliate link',
                    hint: 'Hvor skal linket føre hen?',
                    icon: Icons.link,
                    themeColor: themeColor,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text('Annuller',
                    style: GoogleFonts.kanit(color: Colors.grey[600])),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: themeColor,
                  foregroundColor: Colors.white,
                  shape:
                      RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                onPressed: () {
                  if (nameController.text.isEmpty) return;

                  final newCoupon = Coupon(
                    couponName: nameController.text,
                    description: descriptionController.text,
                    imageURL: imageUrlController.text,
                    link: linkController.text,
                  );

                  setState(() {
                    if (existingCoupon != null) {
                      _coupons.removeWhere(
                          (c) => c.couponName == existingCoupon.couponName);
                    }
                    _coupons.add(newCoupon);
                  });
                  _saveCoupons();

                  Navigator.pop(dialogContext);
                },
                child: Text(existingCoupon == null ? 'Tilføj' : 'Gem',
                    style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCouponDialogField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required Color themeColor,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(label, style: AppTextStyles.label()),
        ),
        TextFormField(
          controller: controller,
          maxLines: maxLines,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, size: 20, color: themeColor),
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
              borderSide: BorderSide(color: themeColor, width: 2),
            ),
          ),
          style: GoogleFonts.kanit(fontSize: 15),
        ),
      ],
    );
  }

  void _deleteCoupon(Coupon coupon) {
    setState(() {
      _coupons.removeWhere((c) => c.couponName == coupon.couponName);
    });
    _saveCoupons();
  }

  // Rendered as a plain row inside the shared bordered panel (see
  // _panelDecoration/_rowDivider in build()) — no card-per-item chrome of
  // its own, consistent with the settings rows above it.
  Widget _buildCouponTile(Coupon coupon, Color themeColor) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              themeColor.withValues(alpha: 0.24),
              themeColor.withValues(alpha: 0.08),
            ],
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: coupon.imageURL.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: coupon.imageURL,
                  fit: BoxFit.contain,
                  errorWidget: (context, url, error) =>
                      Icon(Icons.local_offer, color: themeColor),
                )
              : Icon(Icons.local_offer, color: themeColor),
        ),
      ),
      title: Text(coupon.couponName,
          style: GoogleFonts.kanit(
              fontWeight: FontWeight.w600, color: Colors.black87)),
      subtitle: Text(
        coupon.description.isNotEmpty ? coupon.description : coupon.link,
        style: GoogleFonts.kanit(fontSize: 12, color: Colors.grey[600]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        icon: Icon(Icons.more_vert, color: Colors.grey[600], size: 20),
        onSelected: (value) {
          if (value == 'edit') {
            _addOrEditCoupon(themeColor, existingCoupon: coupon);
          } else if (value == 'delete') {
            _deleteCoupon(coupon);
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'edit',
            child: ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text('Rediger'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red),
              title: Text('Slet', style: TextStyle(color: Colors.red)),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndUploadLogo() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png'],
        withData: true,
      );

      if (result != null) {
        setState(() => _isUploadingLogo = true);
        PlatformFile file = result.files.single;
        String agencyCode = widget.agencyInfo.agencyCode;
        Reference storageRef =
            FirebaseStorage.instance.ref('config/AgencyLogos/$agencyCode.png');

        SettableMetadata metadata = SettableMetadata(contentType: 'image/png');

        if (file.bytes != null) {
          UploadTask uploadTask = storageRef.putData(file.bytes!, metadata);
          await uploadTask;
          String downloadUrl = await storageRef.getDownloadURL();

          setState(() {
            _logoUrl = downloadUrl;
            _isUploadingLogo = false;
          });
          _saveField({'logoUrl': _logoUrl});
        }
      }
    } catch (e) {
      setState(() => _isUploadingLogo = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Fejl ved upload: $e')));
      }
    }
  }

  Future<void> _pickAndUploadContrastLogo() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png'],
        withData: true,
      );

      if (result != null) {
        setState(() => _isUploadingContrastLogo = true);
        PlatformFile file = result.files.single;
        String agencyCode = widget.agencyInfo.agencyCode;
        Reference storageRef = FirebaseStorage.instance
            .ref('config/AgencyLogos/${agencyCode}_contrast.png');

        SettableMetadata metadata = SettableMetadata(contentType: 'image/png');

        if (file.bytes != null) {
          UploadTask uploadTask = storageRef.putData(file.bytes!, metadata);
          await uploadTask;
          String downloadUrl = await storageRef.getDownloadURL();

          setState(() {
            _contrastLogoUrl = downloadUrl;
            _isUploadingContrastLogo = false;
          });
          _saveField({'contrastLogoUrl': _contrastLogoUrl});
        }
      }
    } catch (e) {
      setState(() => _isUploadingContrastLogo = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Fejl ved upload: $e')));
      }
    }
  }

  Future<void> _pickAndUploadVideo() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        withData: kIsWeb ? true : false,
      );

      if (result != null) {
        setState(() => _isUploadingVideo = true);

        if (_videoUrl != null && _videoUrl!.isNotEmpty) {
          try {
            Reference oldRef = FirebaseStorage.instance.refFromURL(_videoUrl!);
            await oldRef.delete();
          } catch (e) {
            debugPrint('Error deleting old video: $e');
          }
        }

        PlatformFile file = result.files.single;
        String agencyCode = widget.agencyInfo.agencyCode;
        String fileName =
            'video_${DateTime.now().millisecondsSinceEpoch}.${file.extension ?? 'mp4'}';
        Reference storageRef =
            FirebaseStorage.instance.ref('agencies/$agencyCode/$fileName');

        SettableMetadata metadata =
            SettableMetadata(contentType: 'video/${file.extension ?? 'mp4'}');

        UploadTask uploadTask;
        if (kIsWeb && file.bytes != null) {
          uploadTask = storageRef.putData(file.bytes!, metadata);
        } else if (file.path != null) {
          uploadTask = storageRef.putFile(File(file.path!), metadata);
        } else {
          throw Exception("Ingen data fundet til upload af video");
        }

        await uploadTask;
        String downloadUrl = await storageRef.getDownloadURL();

        setState(() {
          _videoUrl = downloadUrl;
          _isUploadingVideo = false;
        });
        _saveField({'videoUrl': _videoUrl});
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUploadingVideo = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Fejl ved upload af video: $e')));
      }
    }
  }

  Future<void> _deleteVideo() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Slet video?'),
        content: const Text(
            'Er du sikker på, at du vil slette baggrundsvideoen? Appen vil gå tilbage til standardvideoen.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuller'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Slet', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        if (_videoUrl != null && _videoUrl!.isNotEmpty) {
          setState(() => _isUploadingVideo = true);
          Reference storageRef =
              FirebaseStorage.instance.refFromURL(_videoUrl!);
          await storageRef.delete();
        }

        setState(() {
          _videoUrl = null;
          _isUploadingVideo = false;
        });

        await _saveField({'videoUrl': null});
      } catch (e) {
        if (mounted) {
          setState(() => _isUploadingVideo = false);
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Kunne ikke slette video: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = _getColorFromHex(_colorController.text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(themeColor),
        const SizedBox(height: AppSpacing.xxl),
        _buildSectionTitle('Branding', Icons.auto_awesome_outlined, themeColor),
        _buildBrandingCard(themeColor),
        const SizedBox(height: AppSpacing.xxl),
        _buildSectionTitle('Indstillinger', Icons.tune_rounded, themeColor),
        _buildSettingsCard(themeColor),
        const SizedBox(height: AppSpacing.xxl),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
                child: _buildSectionTitle(
                    'Affiliate links', Icons.local_offer_outlined, themeColor)),
            _buildAddCouponButton(themeColor),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (_coupons.isEmpty)
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: _panelDecoration(themeColor),
            child: Text(
              'Ingen affiliate links endnu. Tilføjede links vises på alle bureauets rejser i appen.',
              style: AppTextStyles.body(color: Colors.grey[600]),
            ),
          )
        else
          Container(
            decoration: _panelDecoration(themeColor),
            child: Column(
              children: [
                for (var i = 0; i < _coupons.length; i++) ...[
                  _buildCouponTile(_coupons[i], themeColor),
                  if (i != _coupons.length - 1) _rowDivider(themeColor),
                ],
              ],
            ),
          ),
      ],
    );
  }

  // A bold gradient identity header for the editor — an immediate visual
  // "this is your bureau's control panel," in the bureau's own brand color,
  // rather than opening straight into a plain settings list.
  Widget _buildHeader(Color themeColor) {
    final name = widget.agencyInfo.agencyName;
    final darker = Color.lerp(themeColor, Colors.black, 0.28)!;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [themeColor, darker],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: themeColor.withValues(alpha: 0.35),
            blurRadius: 32,
            offset: const Offset(0, 16),
            spreadRadius: -10,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('APP-KONFIGURATION',
              textAlign: TextAlign.center,
              style: GoogleFonts.kanit(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: Colors.white.withValues(alpha: 0.75))),
          const SizedBox(height: 12),
          // The logo already carries the bureau's name — no separate name
          // text alongside it, that would just repeat what the logo says.
          // Falls back to the plain name only when there's no logo yet.
          SizedBox(
            height: 56,
            child: Align(
              alignment: Alignment.center,
              child: _logoUrl != null
                  ? CachedNetworkImage(
                      imageUrl: _logoUrl!,
                      height: 56,
                      fit: BoxFit.contain,
                      alignment: Alignment.center,
                      placeholder: (context, url) => _headerNameFallback(name),
                      errorWidget: (context, url, error) =>
                          _headerNameFallback(name),
                    )
                  : _headerNameFallback(name),
            ),
          ),
          const SizedBox(height: 10),
          Text('Ændringer herunder er live for jeres rejsende med det samme.',
              textAlign: TextAlign.center,
              style: GoogleFonts.kanit(
                  fontSize: 12.5, color: Colors.white.withValues(alpha: 0.85))),
        ],
      ),
    );
  }

  Widget _headerNameFallback(String name) {
    return Text(name.isNotEmpty ? name : 'Jeres bureau',
        style: GoogleFonts.kanit(
            fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white));
  }

  // Soft gradient-tinted panel with a colored glow shadow instead of a flat
  // gray card — every panel takes on the bureau's own brand color at a low
  // alpha, so the whole editor visually belongs to this one bureau.
  BoxDecoration _panelDecoration(Color themeColor) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white,
          Color.alphaBlend(themeColor.withValues(alpha: 0.035), Colors.white),
        ],
      ),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: themeColor.withValues(alpha: 0.10)),
      boxShadow: [
        BoxShadow(
          color: themeColor.withValues(alpha: 0.12),
          blurRadius: 28,
          offset: const Offset(0, 14),
          spreadRadius: -10,
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.03),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  Widget _rowDivider(Color themeColor) => Divider(
      height: 1, thickness: 1, color: themeColor.withValues(alpha: 0.08));

  // A pill badge (icon + label) instead of plain caps text — echoes the
  // "EKSEMPEL-VISNING" pill on the preview side, so the two halves of this
  // screen read as one designed system rather than two different UIs stuck
  // together.
  Widget _buildSectionTitle(String title, IconData icon, Color themeColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14, left: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              themeColor.withValues(alpha: 0.16),
              themeColor.withValues(alpha: 0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: themeColor),
            const SizedBox(width: 6),
            Text(title.toUpperCase(),
                style: GoogleFonts.kanit(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: themeColor)),
          ],
        ),
      ),
    );
  }

  Widget _buildAddCouponButton(Color themeColor) {
    final darker = Color.lerp(themeColor, Colors.black, 0.15)!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => _addOrEditCoupon(themeColor),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [themeColor, darker]),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                  color: themeColor.withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 5)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add, size: 15, color: Colors.white),
              const SizedBox(width: 6),
              Text('Tilføj',
                  style: GoogleFonts.kanit(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }

  // A soft pill button for a media row's action ("Tilføj"/"Skift") — a
  // tinted-fill pill instead of a bare TextButton, disabled state rendered
  // in flat gray so it reads as unavailable rather than just dimmer.
  Widget _pillActionButton(
      String label, Color themeColor, VoidCallback? onTap) {
    final disabled = onTap == null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: disabled
                ? Colors.grey[200]
                : themeColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label,
              style: GoogleFonts.kanit(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: disabled ? Colors.grey[500] : themeColor)),
        ),
      ),
    );
  }

  // Deliberately no logo/video preview here — that only ever renders inside
  // the phone mockup next to this editor, so there's exactly one place
  // showing "how it looks," not a second copy on this side of the screen.
  // Just upload controls + a small status line for each.
  Widget _buildBrandingCard(Color themeColor) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: _panelDecoration(themeColor),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildMediaRow(
            themeColor: themeColor,
            icon: Icons.image_outlined,
            label: 'Logo',
            statusText: _isUploadingLogo
                ? 'Uploader...'
                : _isLoadingInitialLogo
                    ? 'Indlæser...'
                    : (_logoUrl != null ? 'Logo uploadet' : 'Intet logo endnu'),
            actionLabel: _logoUrl != null ? 'Skift' : 'Tilføj',
            onAction: (_isUploadingLogo || _isLoadingInitialLogo)
                ? null
                : _pickAndUploadLogo,
          ),
          const SizedBox(height: 10),
          _buildMediaRow(
            themeColor: themeColor,
            icon: Icons.contrast,
            label: 'Kontrastlogo',
            statusText: _isUploadingContrastLogo
                ? 'Uploader...'
                : _isLoadingInitialContrastLogo
                    ? 'Indlæser...'
                    : (_contrastLogoUrl != null
                        ? 'Kontrastlogo uploadet'
                        : 'Til hvidt logo — bruges alle steder undtagen forsiden'),
            actionLabel: _contrastLogoUrl != null ? 'Skift' : 'Tilføj',
            onAction:
                (_isUploadingContrastLogo || _isLoadingInitialContrastLogo)
                    ? null
                    : _pickAndUploadContrastLogo,
          ),
          const SizedBox(height: 10),
          _buildMediaRow(
            themeColor: themeColor,
            icon: Icons.video_library_outlined,
            label: 'Baggrundsvideo',
            statusText: _isUploadingVideo
                ? 'Uploader...'
                : ((_videoUrl != null && _videoUrl!.isNotEmpty)
                    ? 'Brugerdefineret video'
                    : 'Standardvideo'),
            actionLabel: (_videoUrl != null && _videoUrl!.isNotEmpty)
                ? 'Skift'
                : 'Tilføj',
            onAction: _isUploadingVideo ? null : _pickAndUploadVideo,
            onDelete: (_videoUrl != null &&
                    _videoUrl!.isNotEmpty &&
                    !_isUploadingVideo)
                ? _deleteVideo
                : null,
          ),
          const SizedBox(height: AppSpacing.lg),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  themeColor.withValues(alpha: 0.10),
                  themeColor.withValues(alpha: 0.02),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: themeColor.withValues(alpha: 0.15)),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _showColorPicker,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _getColorFromHex(_colorController.text),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [
                        BoxShadow(
                            color: themeColor.withValues(alpha: 0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 4)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(
                    controller: _colorController,
                    decoration: InputDecoration(
                      labelText: 'Primær brandfarve',
                      labelStyle: GoogleFonts.kanit(
                          fontSize: 12, color: Colors.grey[600]),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: GoogleFonts.kanit(
                        fontSize: 14, fontWeight: FontWeight.w600),
                    onChanged: (value) {
                      setState(() {});
                      _colorDebounce?.cancel();
                      _colorDebounce = Timer(const Duration(milliseconds: 700),
                          () => _saveField({'mainColor': value}));
                    },
                  ),
                ),
                IconButton(
                  icon:
                      Icon(Icons.palette_outlined, color: themeColor, size: 20),
                  onPressed: _showColorPicker,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // One row per media control (Logo/Video) — icon, label, a status line
  // (no visual preview — see _buildBrandingCard's comment), an action
  // button, and an optional trailing delete action.
  Widget _buildMediaRow({
    required Color themeColor,
    required IconData icon,
    required String label,
    required String statusText,
    required String actionLabel,
    required VoidCallback? onAction,
    VoidCallback? onDelete,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color:
            Color.alphaBlend(themeColor.withValues(alpha: 0.035), Colors.white),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: themeColor.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  themeColor.withValues(alpha: 0.22),
                  themeColor.withValues(alpha: 0.08),
                ],
              ),
            ),
            child: Icon(icon, color: themeColor, size: 18),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTextStyles.label()),
                Text(statusText, style: AppTextStyles.caption()),
              ],
            ),
          ),
          if (onDelete != null) ...[
            IconButton(
              icon:
                  const Icon(Icons.delete_outline, color: Colors.red, size: 19),
              onPressed: onDelete,
              tooltip: 'Slet baggrundsvideo',
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          _pillActionButton(actionLabel, themeColor, onAction),
        ],
      ),
    );
  }

  // One bordered panel holding every bureau-wide behavior toggle as list
  // rows with dividers, rather than a separate floating card per switch —
  // reads as a single settings list instead of six bouncing tiles.
  Widget _buildSettingsCard(Color themeColor) {
    final rows = <Widget>[
      _buildToggleRow(
        themeColor: themeColor,
        icon: Icons.map_outlined,
        title: 'Kort som standard',
        subtitle:
            'Nye rejser får kortet slået til fra start. Kan altid ændres for en enkelt rejse under dens egne detaljer.',
        value: _mapEnabledDefault,
        onChanged: (v) {
          setState(() => _mapEnabledDefault = v);
          _saveField({'mapEnabledDefault': v});
        },
      ),
      _buildToggleRow(
        themeColor: themeColor,
        icon: Icons.chat_outlined,
        title: 'Spørg om WhatsApp-nummer ved login',
        subtitle:
            'Efter login bliver rejsende spurgt om de har WhatsApp, og skal bekræfte deres nummer, før de ser velkomstoplevelsen.',
        value: _whatsappConfirmEnabled,
        onChanged: (v) {
          setState(() => _whatsappConfirmEnabled = v);
          _saveField({'whatsappConfirmEnabled': v});
        },
      ),
      _buildToggleRow(
        themeColor: themeColor,
        icon: Icons.explore_outlined,
        title: 'Velkomstoplevelse (rundvisning)',
        subtitle:
            'Førstegangsrejsende får en guidet rundvisning af appen efter login. Slået fra springer direkte til forsiden.',
        value: _introTourEnabled,
        onChanged: (v) {
          setState(() => _introTourEnabled = v);
          _saveField({'introTourEnabled': v});
        },
      ),
      _buildToggleRow(
        themeColor: themeColor,
        icon: Icons.mark_email_read_outlined,
        title: 'Spørg om email markedsføring',
        subtitle:
            'Rejsende, der ikke har svaret endnu, bliver spurgt om de vil modtage tilbud og nyheder på email. Svarer de ikke, eller er dette slået fra, tælles de som "nej".',
        value: _marketingConsentEnabled,
        onChanged: (v) {
          setState(() => _marketingConsentEnabled = v);
          _saveField({'marketingConsentEnabled': v});
        },
      ),
      _buildToggleRow(
        themeColor: themeColor,
        icon: Icons.forum_outlined,
        title: 'Rejsende kan skrive og svare',
        subtitle: _travelersCanMessage
            ? 'Rejsende kan oprette nye beskeder og svare på jeres beskeder.'
            : 'Kun bureauet kan sende beskeder — rejsende kan læse, men ikke skrive eller svare.',
        value: _travelersCanMessage,
        onChanged: (v) {
          setState(() => _travelersCanMessage = v);
          _saveField({'travelersCanMessage': v});
        },
      ),
      _buildToggleRow(
        themeColor: themeColor,
        icon: Icons.checklist_outlined,
        title: 'Huskeliste',
        subtitle: 'Pakkelisten og evt. tilbud/kuponer.',
        value: _packingListScreenEnabled,
        onChanged: (v) {
          setState(() => _packingListScreenEnabled = v);
          _saveField({'packingListScreenEnabled': v});
        },
      ),
      _buildToggleRow(
        themeColor: themeColor,
        icon: Icons.group_outlined,
        title: 'Gruppe',
        subtitle: 'Rejsegruppe, medlemmer og guide.',
        value: _groupScreenEnabled,
        onChanged: (v) {
          setState(() => _groupScreenEnabled = v);
          _saveField({'groupScreenEnabled': v});
        },
      ),
      _buildToggleRow(
        themeColor: themeColor,
        icon: Icons.file_copy_outlined,
        title: 'Dokumenter',
        subtitle: 'Rejsedokumenter til download.',
        value: _documentsScreenEnabled,
        onChanged: (v) {
          setState(() => _documentsScreenEnabled = v);
          _saveField({'documentsScreenEnabled': v});
        },
      ),
    ];

    return Container(
      decoration: _panelDecoration(themeColor),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            rows[i],
            if (i != rows.length - 1) _rowDivider(themeColor),
          ],
        ],
      ),
    );
  }

  // A single settings-list row: a soft gradient icon badge tinted with the
  // bureau's own brand color, title/subtitle, and a hand-built glow switch
  // — hoverable, so the row itself reacts before you even reach the switch.
  Widget _buildToggleRow({
    required Color themeColor,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _HoverableRow(
      themeColor: themeColor,
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    themeColor.withValues(alpha: value ? 0.24 : 0.10),
                    themeColor.withValues(alpha: value ? 0.10 : 0.03),
                  ],
                ),
              ),
              child: Icon(icon, color: themeColor, size: 19),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.label()),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppTextStyles.caption()),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            _GlowSwitch(
              value: value,
              color: themeColor,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

// Subtle brand-tinted hover highlight for a settings row — only visible on
// web/desktop pointer input; a no-op tap target everywhere else.
class _HoverableRow extends StatefulWidget {
  const _HoverableRow({required this.child, required this.themeColor});

  final Widget child;
  final Color themeColor;

  @override
  State<_HoverableRow> createState() => _HoverableRowState();
}

class _HoverableRowState extends State<_HoverableRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        color: _hovering
            ? widget.themeColor.withValues(alpha: 0.035)
            : Colors.transparent,
        child: widget.child,
      ),
    );
  }
}

// A hand-built pill toggle (not the stock Material Switch) — a colored glow
// halo appears behind the track when ON, and the thumb slides with a short
// animation, for a more deliberately "designed" feel on this one screen.
class _GlowSwitch extends StatelessWidget {
  const _GlowSwitch({
    required this.value,
    required this.color,
    required this.onChanged,
  });

  final bool value;
  final Color color;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final darker = Color.lerp(color, Colors.black, 0.15)!;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: 46,
        height: 27,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: value ? null : Colors.grey[300],
          gradient: value ? LinearGradient(colors: [color, darker]) : null,
          boxShadow: value
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.45),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : const [],
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 21,
            height: 21,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Read-only, phone-framed preview. Bound to a live Firestore stream of
/// agency/{agencyCode} rather than the adjacent editor's in-progress text
/// fields, so it always reflects the last *saved* state — refreshing the
/// moment _AppSettingsEditor's "Gem" succeeds, with no state-lifting needed
/// between the two sibling widgets.
///
/// Mirrors the real traveler app's structure end to end (see
/// backpack/lib/screens/home/homescreen.dart, home_hero_header.dart,
/// trip_stat_card.dart, itinerary_day_card.dart, and the bottom nav bar in
/// backpack/lib/rootscreen/rootscreen.dart): hero → floating stat card
/// (messages badge, map button, "FØR AFREJSE" checklist) → itinerary photo
/// cards → the app's own floating 4-tab bottom nav. Labels/checklist/
/// itinerary are static example content, not a real trip's data.
class _PhoneMockup extends StatelessWidget {
  const _PhoneMockup({required this.agencyInfo});

  final AgencyInformation agencyInfo;

  // A real iPhone's screen ratio is ~19.5:9 (e.g. 390x844 logical points on
  // an iPhone 14). Bigger than before, per explicit request — this is the
  // whole point of the screen.
  static const double _phoneWidth = 360;
  static const double _phoneHeight = _phoneWidth * 19.5 / 9;
  // Matches HomeHeroHeader's crop in the traveler app: full device width x
  // a fixed 250 height at a 390-wide reference frame.
  static const double _heroAspectRatio = 390 / 250;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('agency')
          .doc(agencyInfo.agencyCode)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() as Map<String, dynamic>?;
        final mainColorHex =
            data?['mainColor'] as String? ?? agencyInfo.mainColor;
        final themeColor = AppColors.fromHex(mainColorHex);
        final videoUrl = data?['videoUrl'] as String?;
        final mapEnabled =
            data?['mapEnabledDefault'] as bool? ?? agencyInfo.mapEnabledDefault;

        return Container(
          width: _phoneWidth,
          height: _phoneHeight,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(36),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: Container(
                  color: AppColors.scaffoldGradientStart,
                  // The nav bar floats *over* the content as a translucent
                  // glass pill (see RootScreen in the backpack app), rather
                  // than docking as an opaque bottom bar — content scrolls
                  // beneath it, with bottom padding so the itinerary's last
                  // card doesn't end up hidden behind it.
                  child: Stack(
                    children: [
                      SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _HeroSection(
                              agencyInfo: agencyInfo,
                              videoUrl: videoUrl,
                            ),
                            Transform.translate(
                              offset: const Offset(0, -14),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 14),
                                child: _StatCard(
                                  themeColor: themeColor,
                                  mapEnabled: mapEnabled,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 76),
                              child: _ItinerarySection(themeColor: themeColor),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: 14,
                        child: _MockBottomNavBar(themeColor: themeColor),
                      ),
                    ],
                  ),
                ),
              ),
              // Dynamic-island-style notch, floating over the hero video —
              // purely cosmetic, just so the frame reads as a phone.
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    width: 90,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The video/logo hero plus its overlaid help/SOS/switch-trip pills —
/// matches HomeHeroHeader's layout (help+switch top-left, SOS top-right).
class _HeroSection extends StatelessWidget {
  const _HeroSection({required this.agencyInfo, required this.videoUrl});

  final AgencyInformation agencyInfo;
  final String? videoUrl;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: _PhoneMockup._heroAspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video + a legibility scrim, then a *separate* opaque overlay
          // that ramps into the exact page background color at the very
          // bottom. HomeHeroHeader itself uses a ShaderMask(dstIn) to fade
          // the video's own alpha — that doesn't reliably work here because
          // BackgroundVideo renders through a platform-view-backed video
          // texture (notably on Flutter Web), and platform views generally
          // don't composite correctly under ShaderMask/BackdropFilter/
          // Opacity. Painting a normal opaque gradient *on top* of the
          // video sidesteps that entirely — it's an ordinary Flutter-drawn
          // shape, not dependent on the video's own alpha — while still
          // producing the same "dissolves into the page" look.
          BackgroundVideo(videoUrl: videoUrl),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.35),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.5],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  AppColors.scaffoldGradientStart,
                ],
                stops: const [0.55, 1.0],
              ),
            ),
          ),
          Center(
            child: BureauLogoHeader(
              agencyCode: agencyInfo.agencyCode,
              fallbackText: agencyInfo.agencyName,
              height: 110,
              width: 260,
            ),
          ),
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: const [
                    _GlassPillIcon(icon: Icons.swap_horiz, size: 13),
                    SizedBox(width: 6),
                    _GlassPillIcon(icon: Icons.question_mark, size: 12),
                  ],
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: AppRadii.smRadius,
                  ),
                  child: const Icon(Icons.sos, color: Colors.white, size: 16),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassPillIcon extends StatelessWidget {
  const _GlassPillIcon({required this.icon, required this.size});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.25),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
      ),
      child: Icon(icon, color: Colors.white, size: size),
    );
  }
}

/// The floating white stat card: title/subtitle + messages (with unread
/// badge) + map button, a divider, and an example "FØR AFREJSE" checklist —
/// matches trip_stat_card.dart's upcoming-trip layout.
class _StatCard extends StatelessWidget {
  const _StatCard({required this.themeColor, required this.mapEnabled});

  final Color themeColor;
  final bool mapEnabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('12 dage til afrejse',
                        style: GoogleFonts.kanit(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.black87)),
                    Text('Fra København · 15. jun.',
                        style: GoogleFonts.kanit(
                            fontSize: 10.5, color: Colors.grey[600])),
                  ],
                ),
              ),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _MockStatButton(
                      icon: Icons.chat_bubble_outline_rounded,
                      color: themeColor),
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Colors.redAccent,
                        shape: BoxShape.circle,
                      ),
                      constraints:
                          const BoxConstraints(minWidth: 14, minHeight: 14),
                      child: Text('3',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.kanit(
                              fontSize: 8,
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
              if (mapEnabled) ...[
                const SizedBox(width: 6),
                _MockStatButton(icon: Icons.map_outlined, color: themeColor),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Divider(color: Colors.grey[200], height: 1),
          const SizedBox(height: AppSpacing.sm),
          Text('FØR AFREJSE',
              style: GoogleFonts.kanit(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey[500],
                  letterSpacing: 0.5)),
          const SizedBox(height: 6),
          const _ChecklistRow(label: 'Pak kufferten', checked: true),
          const _ChecklistRow(label: 'Tjek rejseforsikring', checked: false),
          const _ChecklistRow(label: 'Print boardingpas', checked: false),
        ],
      ),
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({required this.label, required this.checked});

  final String label;
  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            checked ? Icons.check_circle : Icons.circle_outlined,
            size: 14,
            color: checked ? Colors.green : Colors.grey[400],
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            label,
            style: GoogleFonts.kanit(
              fontSize: 10.5,
              color: checked ? Colors.grey[400] : Colors.black87,
              decoration: checked ? TextDecoration.lineThrough : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _MockStatButton extends StatelessWidget {
  const _MockStatButton({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 15, color: color),
    );
  }
}

/// "DIN REJSEPLAN" — the numbered-rail itinerary, each day a full-bleed
/// photo card (mirrors ItineraryDayCard: photo, "DAG X · LAND" chip,
/// title + dates). Example content, not a real trip's days.
class _ItinerarySection extends StatelessWidget {
  const _ItinerarySection({required this.themeColor});

  final Color themeColor;

  // Example content only, not a real trip — real photos (not a flat color)
  // so the mockup actually reads as a photo-card itinerary like the real
  // app's ItineraryDayCard.
  static const _days = [
    (
      day: '1',
      country: 'DANMARK',
      title: 'Ankomst & velkomstmiddag',
      imageUrl:
          'https://images.unsplash.com/photo-1513622470522-26c3c8a854bc?w=400&auto=format&fit=crop&q=60',
    ),
    (
      day: '2',
      country: 'VIETNAM',
      title: 'Byrundtur i Hoi An',
      imageUrl:
          'https://images.unsplash.com/photo-1528127269322-539801943592?w=400&auto=format&fit=crop&q=60',
    ),
    (
      day: '3',
      country: 'VIETNAM',
      title: 'Fritid ved stranden',
      imageUrl:
          'https://images.unsplash.com/photo-1507525428034-b723cf961d3e?w=400&auto=format&fit=crop&q=60',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DIN REJSEPLAN',
            style: GoogleFonts.kanit(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Colors.grey[500],
                letterSpacing: 0.5)),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < _days.length; i++)
          _ItineraryDayRow(
            dayLabel: _days[i].day,
            country: _days[i].country,
            title: _days[i].title,
            imageUrl: _days[i].imageUrl,
            themeColor: themeColor,
            showConnector: i != _days.length - 1,
          ),
      ],
    );
  }
}

class _ItineraryDayRow extends StatelessWidget {
  const _ItineraryDayRow({
    required this.dayLabel,
    required this.country,
    required this.title,
    required this.imageUrl,
    required this.themeColor,
    required this.showConnector,
  });

  final String dayLabel;
  final String country;
  final String title;
  final String imageUrl;
  final Color themeColor;
  final bool showConnector;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              child: Column(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: themeColor.withValues(alpha: 0.85),
                    ),
                    child: Text(dayLabel,
                        style: GoogleFonts.kanit(
                            fontSize: 8,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ),
                  if (showConnector)
                    Expanded(
                      child: Container(
                        width: 1,
                        color: themeColor.withValues(alpha: 0.25),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: ClipRRect(
                borderRadius: AppRadii.mdRadius,
                // Real ItineraryDayCard is ~176px tall against a 390-wide
                // reference frame (much more prominent than a thumbnail) —
                // 150 here is the proportionally-scaled equivalent for this
                // mockup's actual card width, not an arbitrary thumbnail size.
                child: SizedBox(
                  height: 150,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Real example photo, not a flat placeholder — falls
                      // back to a themeColor gradient if it fails to load
                      // (e.g. offline), same defensive spirit as other
                      // network-image fallbacks in this app.
                      Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        loadingBuilder: (context, child, progress) =>
                            progress == null
                                ? child
                                : Container(
                                    color: themeColor.withValues(alpha: 0.3)),
                        errorBuilder: (context, error, stackTrace) => Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                themeColor.withValues(alpha: 0.55),
                                themeColor.withValues(alpha: 0.85),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Scrim so the chip/title stay legible over any photo.
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.15),
                              Colors.black.withValues(alpha: 0.55),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('DAG $dayLabel · $country',
                              style: GoogleFonts.kanit(
                                  fontSize: 7.5,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                      Positioned(
                        bottom: 6,
                        left: 8,
                        right: 8,
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.kanit(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The app's floating 4-tab bottom nav (see RootScreen in the backpack app):
/// Hjem / Huskeliste / Gruppe / Dokumenter. Static — "Hjem" shown active,
/// since this mockup only illustrates the Home tab's content above.
class _MockBottomNavBar extends StatelessWidget {
  const _MockBottomNavBar({required this.themeColor});

  final Color themeColor;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _NavBarItem(
                  icon: Icons.home,
                  label: 'Hjem',
                  color: themeColor,
                  active: true),
              _NavBarItem(
                  icon: Icons.summarize,
                  label: 'Huskeliste',
                  color: themeColor,
                  active: false),
              _NavBarItem(
                  icon: Icons.group,
                  label: 'Gruppe',
                  color: themeColor,
                  active: false),
              _NavBarItem(
                  icon: Icons.file_copy,
                  label: 'Dokumenter',
                  color: themeColor,
                  active: false),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavBarItem extends StatelessWidget {
  const _NavBarItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.active,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    // grey[400] read as almost invisible against the translucent glass bar
    // — black54 keeps a clear active/inactive distinction without
    // disappearing depending on what's behind the blur.
    final tint = active ? color : Colors.black54;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: tint),
        const SizedBox(height: 2),
        Text(label,
            style: GoogleFonts.kanit(
                fontSize: 7, color: tint, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
