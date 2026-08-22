import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:backend/models/agencyInformation.dart';
import 'package:backend/widget/backgroundVideo.dart';
import 'package:backend/widget/bureauLogoHeader.dart';
import 'package:backend/widget/saved_snackbar.dart';
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
                fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black87)),
        Text('Farver, logo og video er live — rejseplanen herunder er eksempeldata',
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
  late bool _mapEnabledDefault;

  Timer? _colorDebounce;

  @override
  void initState() {
    super.initState();
    _mapEnabledDefault = widget.agencyInfo.mapEnabledDefault;
    _colorController =
        TextEditingController(text: widget.agencyInfo.mainColor);
    _videoUrl = widget.agencyInfo.videoUrl;
    _loadInitialLogo();
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

        SettableMetadata metadata =
            SettableMetadata(contentType: 'image/png');

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
          Reference storageRef = FirebaseStorage.instance.refFromURL(_videoUrl!);
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
        _buildBrandingCard(themeColor),
        const SizedBox(height: AppSpacing.lg),
        _buildSectionTitle('Kort'),
        _buildMapDefaultCard(themeColor),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4, top: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(title,
            style: AppTextStyles.heading()),
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
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: AppRadii.lgRadius,
        boxShadow: AppShadows.card,
      ),
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
            icon: Icons.video_library_outlined,
            label: 'Baggrundsvideo',
            statusText: _isUploadingVideo
                ? 'Uploader...'
                : ((_videoUrl != null && _videoUrl!.isNotEmpty)
                    ? 'Brugerdefineret video'
                    : 'Standardvideo'),
            actionLabel:
                (_videoUrl != null && _videoUrl!.isNotEmpty) ? 'Skift' : 'Tilføj',
            onAction: _isUploadingVideo ? null : _pickAndUploadVideo,
            onDelete: (_videoUrl != null &&
                    _videoUrl!.isNotEmpty &&
                    !_isUploadingVideo)
                ? _deleteVideo
                : null,
          ),
          const SizedBox(height: AppSpacing.lg),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey[300]!),
              borderRadius: AppRadii.mdRadius,
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _showColorPicker,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _getColorFromHex(_colorController.text),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(
                    controller: _colorController,
                    decoration: InputDecoration(
                      labelText: 'Primær farve',
                      labelStyle:
                          GoogleFonts.kanit(fontSize: 12, color: Colors.grey[600]),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: GoogleFonts.kanit(fontSize: 14),
                    onChanged: (value) {
                      setState(() {});
                      _colorDebounce?.cancel();
                      _colorDebounce = Timer(
                          const Duration(milliseconds: 700),
                          () => _saveField({'mainColor': value}));
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.palette, color: Colors.grey, size: 20),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: AppRadii.mdRadius,
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: themeColor.withValues(alpha: 0.1),
              borderRadius: AppRadii.smRadius,
            ),
            child: Icon(icon, color: themeColor, size: 18),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: GoogleFonts.kanit(
                        fontWeight: FontWeight.w600, color: Colors.black87)),
                Text(statusText,
                    style:
                        AppTextStyles.caption()),
              ],
            ),
          ),
          if (onDelete != null) ...[
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
              onPressed: onDelete,
              tooltip: 'Slet baggrundsvideo',
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          TextButton(
            onPressed: onAction,
            child: Text(actionLabel,
                style: GoogleFonts.kanit(
                    fontWeight: FontWeight.w600, color: themeColor)),
          ),
        ],
      ),
    );
  }

  Widget _buildMapDefaultCard(Color themeColor) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: AppRadii.lgRadius,
        boxShadow: AppShadows.card,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: themeColor.withValues(alpha: 0.1),
              borderRadius: AppRadii.mdRadius,
            ),
            child: Icon(Icons.map_outlined, color: themeColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Kort som standard',
                    style: GoogleFonts.kanit(
                        fontWeight: FontWeight.w600, color: Colors.black87)),
                Text(
                    'Nye rejser får kortet slået til fra start. Kan altid ændres for en enkelt rejse under dens egne detaljer.',
                    style:
                        GoogleFonts.kanit(fontSize: 12, color: Colors.grey[600])),
              ],
            ),
          ),
          Switch(
            value: _mapEnabledDefault,
            activeThumbColor: themeColor,
            onChanged: (v) {
              setState(() => _mapEnabledDefault = v);
              _saveField({'mapEnabledDefault': v});
            },
          ),
        ],
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
                              padding:
                                  const EdgeInsets.fromLTRB(16, 8, 16, 76),
                              child:
                                  _ItinerarySection(themeColor: themeColor),
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
                                : Container(color: themeColor.withValues(alpha: 0.3)),
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
              _NavBarItem(icon: Icons.home, label: 'Hjem', color: themeColor, active: true),
              _NavBarItem(icon: Icons.summarize, label: 'Huskeliste', color: themeColor, active: false),
              _NavBarItem(icon: Icons.group, label: 'Gruppe', color: themeColor, active: false),
              _NavBarItem(icon: Icons.file_copy, label: 'Dokumenter', color: themeColor, active: false),
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
