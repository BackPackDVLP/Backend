import 'dart:math';
import 'package:backend/config/design.dart';

import 'package:backend/config/app_colors.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/group_members_model.dart';
import 'package:backend/models/guide_model.dart' show Guide;
import 'package:backend/models/message_model.dart';
import 'package:backend/models/packinglist_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:backend/widget/flightbox4.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:timeline_tile/timeline_tile.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:backend/widget/phone_number_field.dart';
import 'package:backend/widget/timelineeventbox.dart';
import '../../widget/timelineDialog.dart';
import '../../widget/timeline_map_overview_dialog.dart';
import '../../widget/departurebox2.dart';
import '../../widget/returnbox2.dart';
import '../../blocs/groupinformation/groupinformation_bloc.dart';
import 'package:backend/widget/app_snackbar.dart';
import 'package:backend/widget/message_composer_dialog.dart';

class HomeScreen extends StatefulWidget {
  static const String routeName = '/home';
  final ScrollController scrollController;
  // Whether the signed-in staff member's role grants `trips.edit`. Every
  // existing edit/delete affordance in this screen was already gated on
  // `emailVerified` alone — this ANDs the new permission onto that same
  // check everywhere, rather than adding a second parallel gate that could
  // drift out of sync with it.
  final bool canEditTrips;

  const HomeScreen({
    super.key,
    required this.scrollController,
    this.canEditTrips = true,
  });

  static Route route() {
    return MaterialPageRoute(
      builder: (_) => HomeScreen(scrollController: ScrollController()),
      settings: const RouteSettings(name: routeName),
    );
  }

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? groupId;
  List<Reference> _currentFiles = [];
  List<Reference> _currentFolders = [];
  Map<String, FullMetadata> _fileMetadata = {};
  Reference? _currentDocsRef;
  Box<List<String>>? _pdfCacheBox;
  Stream<List<Message>>? _messagesStream;

  // The documents panel is shown inside a dialog (see `_showPanelDialog`),
  // whose content is only rebuilt by its own local state or by
  // GroupInformationBloc — not by this State's setState(). Document
  // fetches/uploads mutate plain fields on this State via setState() here,
  // so without this hook the dialog would keep showing a stale file list
  // until closed and reopened. Bound to the dialog's own rebuild function
  // while it's open (null otherwise) so document changes show immediately.
  VoidCallback? _documentsDialogRefresh;

  @override
  void initState() {
    super.initState();
    _loadGroupIdAndFetchData();
  }

  Future<void> _loadGroupIdAndFetchData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      // Use context.mounted check for safety with async gaps
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    // Check if the widget is still in the tree after the await.
    if (!mounted) return;

    final savedGroupId = prefs.getString('groupId');

    if (savedGroupId != null) {
      setState(() {
        groupId = savedGroupId;
        _currentDocsRef = FirebaseStorage.instance.ref('$groupId/documents');
        _messagesStream =
            context.read<GroupInformationRepository>().getMessages(groupId!);
      });

      final currentState = context.read<GroupInformationBloc>().state;
      if (currentState is! GroupInformationLoaded ||
          currentState.groupInformation.groupId != groupId) {
        context
            .read<GroupInformationBloc>()
            .add(LoadGroupInformationById(groupId: groupId!));
      } else {
        _updateAgencyColor(currentState.groupInformation.agencyCode);
      }
      await _openPdfCacheBox();
      _fetchDocuments();
    } else {
      Navigator.pushReplacementNamed(context, '/groupIDscreen');
    }
  }

  Future<void> _updateAgencyColor(String agencyCode) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('agency')
          .doc(agencyCode)
          .get();
      if (doc.exists && mounted) {
        final data = doc.data();
        if (data != null && data['mainColor'] != null) {
          setState(() {
            final color = AppColors.fromHex(data['mainColor']);
            AppColors.navActive = color;
            AppColors.primary = color;
          });
        }
      }
    } catch (e) {
      print('Error fetching agency color: $e');
    }
  }

  Future<void> _openPdfCacheBox() async {
    // Hive.openBox() returns the existing instance if already open.
    _pdfCacheBox = await Hive.openBox<List<String>>('pdfFileCache');
  }

  Future<void> _fetchDocuments() async {
    if (groupId == null || _currentDocsRef == null) return;

    var connectivityResult = await (Connectivity().checkConnectivity());
    if (connectivityResult == ConnectivityResult.none) {
      // Offline
      final cachedUrls = _pdfCacheBox?.get(_currentDocsRef!.fullPath);
      if (cachedUrls != null && cachedUrls.isNotEmpty) {
        _setPdfFilesFromUrls(cachedUrls);
      }
    } else {
      // Online
      try {
        final listResult = await _currentDocsRef!.listAll();
        final pdfFiles =
            listResult.items.where((ref) => !ref.name.startsWith('.')).toList();
        final folders = listResult.prefixes;

        final metadataList = await Future.wait(
          pdfFiles.map((file) async {
            try {
              final meta = await file.getMetadata();
              return MapEntry(file.name, meta);
            } catch (e) {
              return null;
            }
          }),
        );
        final metadataMap = Map.fromEntries(
            metadataList.whereType<MapEntry<String, FullMetadata>>());

        final urlsToCache = <String>[];
        for (var pdfFile in pdfFiles) {
          urlsToCache.add(await pdfFile.getDownloadURL());
        }
        if (mounted) {
          setState(() {
            _currentFiles = pdfFiles;
            _currentFolders = folders;
            _fileMetadata = metadataMap;
          });
          _documentsDialogRefresh?.call();
        }
        await _pdfCacheBox?.put(_currentDocsRef!.fullPath, urlsToCache);
      } catch (e) {
        print('Error fetching PDF files from Firebase: $e');
        final cachedUrls = _pdfCacheBox?.get(_currentDocsRef!.fullPath);
        if (cachedUrls != null && cachedUrls.isNotEmpty) {
          _setPdfFilesFromUrls(cachedUrls);
        }
      }
    }
  }

  void _setPdfFilesFromUrls(List<String> urls) {
    if (mounted) {
      setState(() {
        _currentFiles = urls
            .map((url) {
              try {
                return FirebaseStorage.instance.refFromURL(url);
              } catch (e) {
                print('Invalid cached URL: $e');
                return null;
              }
            })
            .whereType<Reference>()
            .toList();
        _fileMetadata = {};
      });
      _documentsDialogRefresh?.call();
    }
  }

  Future<void> _pickAndUploadDocument(BuildContext context) async {
    final folder = _currentDocsRef;
    if (folder == null) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: true,
        withData: true,
      );
      final files =
          result?.files.where((f) => f.bytes != null).toList() ?? const [];
      if (files.isEmpty || !context.mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => _UploadConfirmDialog(files: files),
      );
      if (confirmed != true || !context.mounted) return;

      await _uploadDocuments(context, folder, files);
    } catch (e) {
      if (context.mounted) {
        showErrorSnackbar(context, 'Fejl ved upload: ${describeError(e)}');
      }
    }
  }

  /// Uploads every picked PDF into [folder] in parallel, then refreshes the
  /// list once. One failing file doesn't stop the rest — the snackbar says
  /// how many made it.
  Future<void> _uploadDocuments(
    BuildContext context,
    Reference folder,
    List<PlatformFile> files,
  ) async {
    if (files.length > 1) {
      showInfoSnackbar(context, 'Uploader ${files.length} dokumenter...');
    }
    final results = await Future.wait(files.map((file) async {
      try {
        await folder.child(file.name).putData(file.bytes!);
        return true;
      } catch (e) {
        print('Error uploading ${file.name}: $e');
        return false;
      }
    }));
    _fetchDocuments();

    if (!context.mounted) return;
    final failed = results.where((ok) => !ok).length;
    final uploaded = files.length - failed;
    if (failed == 0) {
      showAppSnackbar(
          context,
          uploaded == 1
              ? '${files.single.name} uploadet'
              : '$uploaded dokumenter uploadet');
    } else {
      showErrorSnackbar(context,
          '$failed af ${files.length} dokumenter kunne ikke uploades');
    }
  }

  Future<void> _createFolder(BuildContext context) async {
    if (_currentDocsRef == null) return;
    String folderName = '';
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogAltBackground,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
        title: const Text('Opret ny mappe',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.create_new_folder, size: 48, color: Colors.grey),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'For at oprette en mappe skal du uploade mindst én fil til den. Du kan vælge flere filer på én gang.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Mappenavn',
                border:
                    OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                filled: true,
                fillColor: Colors.white,
              ),
              onChanged: (value) => folderName = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuller'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.onPrimary,
              shape: RoundedRectangleBorder(
                  borderRadius: AppRadii.mdRadius),
            ),
            onPressed: () async {
              if (folderName.trim().isNotEmpty) {
                Navigator.pop(context);
                try {
                  final result = await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['pdf'],
                    allowMultiple: true,
                    withData: true,
                  );
                  final files = result?.files
                          .where((f) => f.bytes != null)
                          .toList() ??
                      const <PlatformFile>[];
                  if (files.isNotEmpty && mounted) {
                    await _uploadDocuments(this.context,
                        _currentDocsRef!.child(folderName.trim()), files);
                  }
                } catch (e) {
                  print('Error creating folder: $e');
                  if (mounted) {
                    showErrorSnackbar(context, 'Fejl ved oprettelse af mappe: ${describeError(e)}');
                  }
                }
              }
            },
            child: const Text('Vælg filer & opret'),
          ),
        ],
      ),
    );
  }

  void _navigateToFolder(Reference folder) {
    setState(() {
      _currentDocsRef = folder;
    });
    _documentsDialogRefresh?.call();
    _fetchDocuments();
  }

  void _navigateBack() {
    if (_currentDocsRef == null || groupId == null) return;
    // Check if we are at the root documents folder
    if (_currentDocsRef!.fullPath == '$groupId/documents') return;

    setState(() {
      _currentDocsRef = _currentDocsRef!.parent;
    });
    _documentsDialogRefresh?.call();
    _fetchDocuments();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<GroupInformationBloc, GroupInformationState>(
      listener: (context, state) {
        if (state is GroupInformationLoaded) {
          groupId = state.groupInformation.groupId;
          _updateAgencyColor(state.groupInformation.agencyCode);
        }
      },
      child: BlocBuilder<GroupInformationBloc, GroupInformationState>(
        builder: (context, state) {
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
              child: _buildBody(context, state),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeroHeader(GroupInformation groupInfo) {
    final now = DateTime.now();
    final daysUntil = groupInfo.departureDate.difference(now).inDays;
    final isActive = groupInfo.departureDate.isBefore(now) &&
        groupInfo.returnDate.isAfter(now);
    final countdownText = isActive
        ? 'Rejsen er i gang'
        : daysUntil >= 0
            ? 'Afrejse om $daysUntil dage'
            : 'Rejse afsluttet';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: AppRadii.lgRadius,
        boxShadow: AppShadows.card,
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.card_travel, color: AppColors.primary, size: 24),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  groupInfo.groupName ?? groupInfo.groupId,
                  style: GoogleFonts.kanit(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${DateFormat('dd. MMM yyyy', 'da_DK').format(groupInfo.departureDate)} '
                  '– ${DateFormat('dd. MMM yyyy', 'da_DK').format(groupInfo.returnDate)}',
                  style: GoogleFonts.kanit(fontSize: 13, color: Colors.black45),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          _buildHeroChip(Icons.people_outline, '${groupInfo.members.length}'),
          const SizedBox(width: AppSpacing.sm),
          _buildHeroChip(Icons.support_agent, '${groupInfo.guides.length}'),
          const SizedBox(width: AppSpacing.md),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: (isActive ? Colors.orange : AppColors.primary)
                  .withOpacity(0.1),
              borderRadius: AppRadii.smRadius,
            ),
            child: Text(
              countdownText,
              style: GoogleFonts.kanit(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isActive ? Colors.orange[800] : AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroChip(IconData icon, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.08),
        borderRadius: AppRadii.smRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.grey[700]),
          const SizedBox(width: 5),
          Text(value,
              style: GoogleFonts.kanit(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87)),
        ],
      ),
    );
  }

  /// Shared card chrome for the four dashboard-style panels below —
  /// white card, soft shadow, rounded corners, icon-in-circle header.
  BoxDecoration get _panelDecoration => BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: AppRadii.lgRadius,
        boxShadow: AppShadows.card,
      );

  Widget _buildPanelHeader(IconData icon, String title,
      {Widget? leading, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Row(
        children: [
          if (leading != null) leading,
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: AppRadii.smRadius,
            ),
            child: Icon(icon, color: AppColors.primary, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title,
                style: GoogleFonts.kanit(
                    fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                overflow: TextOverflow.ellipsis),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildDocRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.05),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.1),
            borderRadius: AppRadii.smRadius,
          ),
          child: Icon(icon, color: iconColor, size: 18),
        ),
        title: Text(title,
            style: AppTextStyles.label(),
            overflow: TextOverflow.ellipsis),
        subtitle: subtitle != null
            ? Text(subtitle,
                style: GoogleFonts.kanit(fontSize: 11, color: Colors.grey[500]))
            : null,
        onTap: onTap,
        trailing: trailing,
      ),
    );
  }

  Widget _buildBody(BuildContext context, GroupInformationState state) {
    if (state is GroupInformationLoading) {
      return const Center(child: CircularProgressIndicator());
    } else if (state is GroupInformationLoaded) {
      final groupInfo = state.groupInformation;

      // Merge events and flights into a single timeline list
      final List<dynamic> sortableEvents = [
        ...groupInfo.timelineEvents
            .map((e) => {'date': e.startDate, 'item': e, 'type': 'event'}),
        ...(groupInfo.flights ?? [])
            .map((f) => {'date': f.flightDate, 'item': f, 'type': 'flight'}),
      ]..sort((a, b) => a['date'].compareTo(b['date']));

      sortableEvents.insert(0, {
        'date': groupInfo.departureDate,
        'item': groupInfo,
        'type': 'departure'
      });
      sortableEvents.add(
          {'date': groupInfo.returnDate, 'item': groupInfo, 'type': 'return'});

      return LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 1000;

          if (!isNarrow) {
            return SafeArea(
              child: Column(
                children: [
                  _buildHeroHeader(groupInfo),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          flex: 3,
                          child: _buildTimeline(context, groupInfo, sortableEvents),
                        ),
                        Flexible(
                          flex: 2,
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.sm),
                            child: _buildQuickAccessSection(context, groupInfo,
                                expand: true),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          } else {
            return SafeArea(
              child: SingleChildScrollView(
                controller: widget.scrollController,
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Column(
                  children: [
                    _buildHeroHeader(groupInfo),
                    const SizedBox(height: AppSpacing.sm),
                    SizedBox(
                      height: 420,
                      child: _buildTimeline(context, groupInfo, sortableEvents),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _buildQuickAccessSection(context, groupInfo, expand: false),
                  ],
                ),
              ),
            );
          }
        },
      );
    } else if (state is GroupInformationError) {
      return Center(child: Text('Error: ${state.message}'));
    } else {
      return const Center(child: CircularProgressIndicator());
    }
  }

  // --- QUICK ACCESS (Messages / Group / Documents / Packing lists) ---
  //
  // These sections used to be shown directly on the homescreen. They now
  // live behind entry-point cards that open the same panel widgets inside a
  // dialog, so the timeline (the one thing meant to stay directly visible)
  // gets the space instead.

  static const Color _messagesAccent = Color(0xFF3B82F6);
  static const Color _groupAccent = Color(0xFF8B5CF6);
  static const Color _documentsAccent = Color(0xFFF59E0B);
  static const Color _packingListAccent = Color(0xFF10B981);

  /// [expand] controls whether the cards stretch to fill the available
  /// height (wide layout, where the column sits next to the timeline) or
  /// use a fixed height (narrow layout, where the whole page scrolls and an
  /// `Expanded` would have no bounded height to fill).
  Widget _buildQuickAccessSection(BuildContext context, GroupInformation groupInfo,
      {required bool expand}) {
    final user = FirebaseAuth.instance.currentUser;
    final cards = [
      _buildQuickAccessCard(
        icon: Icons.forum_outlined,
        title: 'Beskeder',
        subtitle: 'Se og besvar beskeder',
        accentColor: _messagesAccent,
        onTap: () => _showPanelDialog(
          context,
          (ctx, info) => _buildMessagesPanel(ctx, info, user),
        ),
      ),
      _buildQuickAccessCard(
        icon: Icons.groups_outlined,
        title: 'Gruppe',
        subtitle: groupInfo.isTemplate == true
            ? 'Skabelon — ingen medlemmer'
            : '${groupInfo.members.length} medlemmer · ${groupInfo.guides.length} guider',
        accentColor: _groupAccent,
        onTap: () => _showPanelDialog(context, _buildGroupPanel),
      ),
      _buildQuickAccessCard(
        icon: Icons.folder_outlined,
        title: 'Dokumenter',
        subtitle: 'Upload og administrer filer',
        accentColor: _documentsAccent,
        onTap: () => _showPanelDialog(
          context,
          _buildDocumentsPanel,
          onRefreshBinding: (refresh) => _documentsDialogRefresh = refresh,
        ),
      ),
      _buildQuickAccessCard(
        icon: Icons.checklist,
        title: 'Pakkelister',
        subtitle: '${groupInfo.packinglistCategories.length} kategorier',
        accentColor: _packingListAccent,
        onTap: () => _showPanelDialog(context, _buildPackingListPanel),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          expand ? Expanded(child: cards[i]) : SizedBox(height: 132, child: cards[i]),
        ],
      ],
    );
  }

  Widget _buildQuickAccessCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accentColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: AppRadii.lgRadius,
      child: InkWell(
        borderRadius: AppRadii.lgRadius,
        onTap: onTap,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: AppRadii.lgRadius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            children: [
              Positioned(
                right: -18,
                bottom: -18,
                child: Icon(icon, size: 110, color: accentColor.withOpacity(0.08)),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(icon, color: accentColor, size: 26),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title,
                              style: AppTextStyles.headingBold()),
                          const SizedBox(height: 3),
                          Text(subtitle,
                              style: GoogleFonts.kanit(
                                  fontSize: 12.5, color: Colors.grey[600]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.arrow_forward_rounded,
                          color: accentColor, size: 18),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens [panelBuilder] (one of the existing `_buildXPanel` methods) in a
  /// large centered dialog. Wrapped in its own [BlocBuilder] so edits made
  /// via nested dialogs (add/edit guide, upload a document, ...) are
  /// reflected immediately instead of showing a stale snapshot of
  /// [GroupInformation] from when the dialog was opened.
  ///
  /// [onRefreshBinding], if given, is called with the dialog's own rebuild
  /// function once it's mounted (and with `null` once it closes) — for
  /// panels like Documents whose data lives outside GroupInformation/the
  /// Bloc, so nothing else would tell this dialog to rebuild when that data
  /// changes.
  void _showPanelDialog(
    BuildContext context,
    Widget Function(BuildContext context, GroupInformation groupInfo) panelBuilder, {
    void Function(VoidCallback? refresh)? onRefreshBinding,
  }) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        final isNarrow = size.width < 700;
        final width = isNarrow ? size.width * 0.94 : (size.width * 0.6).clamp(420.0, 640.0);
        final height = size.height * 0.82;

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(
            horizontal: (size.width - width) / 2,
            vertical: (size.height - height) / 2,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: AppRadii.lgRadius,
                child: Container(
                  width: width,
                  height: height,
                  // Solid, not translucent: this sits over the dialog
                  // barrier, and the panels' own `_panelDecoration` uses a
                  // slightly transparent white meant for the gradient
                  // homescreen background behind it, not a dark scrim.
                  color: Colors.white,
                  child: StatefulBuilder(
                    builder: (localContext, localSetState) {
                      onRefreshBinding?.call(() => localSetState(() {}));
                      return BlocBuilder<GroupInformationBloc, GroupInformationState>(
                        builder: (blocContext, state) {
                          if (state is GroupInformationLoaded) {
                            return panelBuilder(blocContext, state.groupInformation);
                          }
                          return const Center(child: CircularProgressIndicator());
                        },
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: Material(
                  color: Colors.white,
                  shape: const CircleBorder(),
                  elevation: 2,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => Navigator.of(dialogContext).pop(),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.close, size: 18),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ).then((_) => onRefreshBinding?.call(null));
  }

  // --- TIMELINE ---
  Widget _buildTimeline(BuildContext context, GroupInformation groupInfo,
      List<dynamic> sortableEvents) {
    final user = FirebaseAuth.instance.currentUser;
    return Container(
      margin: const EdgeInsets.all(AppSpacing.sm),
      decoration: _panelDecoration,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              _buildPanelHeader(
                Icons.timeline,
                'Rejseforløb',
                trailing: (groupInfo.mapEnabled && widget.canEditTrips)
                    ? IconButton(
                        tooltip: 'Verificer lokationer på kort',
                        icon: Icon(Icons.map_outlined,
                            color: AppColors.primary, size: 20),
                        onPressed: () async {
                          final result = await showDialog(
                            context: context,
                            builder: (context) => TimelineMapOverviewDialog(
                              groupInformation: groupInfo,
                              repository:
                                  context.read<GroupInformationRepository>(),
                            ),
                          );
                          if (result == true && mounted) {
                            context.read<GroupInformationBloc>().add(
                                LoadGroupInformationById(
                                    groupId: groupInfo.groupId));
                          }
                        },
                      )
                    : null,
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  controller: widget.scrollController,
                  itemCount: sortableEvents.length,
                itemBuilder: (context, index) {
                  final itemData = sortableEvents[index];
                  final item = itemData['item'];
                  final isFirst = index == 0;
                  final isLast = index == sortableEvents.length - 1;

                  Widget childWidget;
                  switch (itemData['type']) {
                    case 'departure':
                      childWidget = DepartureBox2(information: item);
                      break;
                    case 'return':
                      childWidget = ReturnBox2(information: item);
                      break;
                    case 'event':
                      childWidget = TimelineEventBox(
                        event: item,
                        groupInformation: groupInfo,
                        repository: context.read<GroupInformationRepository>(),
                        canEdit: widget.canEditTrips,
                      );
                      break;
                    case 'flight':
                      childWidget = FlightBox4(flight: item);
                      break;
                    default:
                      childWidget = const SizedBox.shrink();
                  }

                  return TimelineTile(
                    alignment: TimelineAlign.manual,
                    lineXY: 0.05,
                    isFirst: isFirst,
                    isLast: isLast,
                    endChild: childWidget,
                    indicatorStyle: IndicatorStyle(
                      drawGap: true,
                      color: (itemData['type'] == 'departure' ||
                              itemData['type'] == 'return')
                          ? Colors.transparent
                          : Colors.black,
                      width: (itemData['type'] == 'departure' ||
                              itemData['type'] == 'return')
                          ? 35
                          : 7,
                      iconStyle: (itemData['type'] == 'departure' ||
                              itemData['type'] == 'return')
                          ? IconStyle(
                              color: Colors.black,
                              fontSize: 20,
                              iconData: itemData['type'] == 'departure'
                                  ? Icons.flight_takeoff
                                  : Icons.flight_land,
                            )
                          : null,
                    ),
                    beforeLineStyle:
                        const LineStyle(thickness: 2, color: Colors.black),
                  );
                },
              ),
            ),
          ],
        ),
        if ((user?.emailVerified ?? false) && widget.canEditTrips)
          Positioned(
            bottom: 24,
            right: 24,
            child: FloatingActionButton(
              onPressed: () async {
                final result = await showDialog(
                  context: context,
                  builder: (context) => TimelineDialog(
                    groupInformation: groupInfo,
                    repository: context.read<GroupInformationRepository>(),
                  ),
                );
                if (result != null && mounted) {
                  context.read<GroupInformationBloc>().add(
                      LoadGroupInformationById(groupId: groupInfo.groupId));
                }
              },
              backgroundColor: AppColors.primary,
              child: Icon(Icons.add, color: AppColors.onPrimary),
            ),
          ),
        ],
      ),
    );
  }

  // --- TIMELINE ---

  // --- MESSAGES PANEL ---
  Widget _buildMessagesPanel(
      BuildContext context, GroupInformation groupInfo, User? user) {
    return Container(
      decoration: _panelDecoration,
      clipBehavior: Clip.antiAlias, // Important for FAB to be contained
      child: Stack(
        children: [
          Column(
            children: [
              _buildPanelHeader(Icons.forum_outlined, 'Beskeder'),
              Expanded(
                child: StreamBuilder<List<Message>>(
                  stream: _messagesStream,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final messages = snapshot.data ?? [];
                    if (messages.isEmpty) {
                      return Center(
                        child: Text('Ingen beskeder.',
                            style: GoogleFonts.kanit(color: Colors.grey[500])),
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 72),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final msg = messages[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(AppSpacing.md),
                          decoration: BoxDecoration(
                            color: Colors.grey.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(msg.title,
                                        style: GoogleFonts.kanit(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black87),
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                  if ((user?.emailVerified ?? false) && widget.canEditTrips)
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: Icon(Icons.edit,
                                              size: 18, color: Colors.grey[600]),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () => _showEditMessageDialog(
                                              context, groupInfo, msg),
                                        ),
                                        const SizedBox(width: AppSpacing.md),
                                        IconButton(
                                          icon: const Icon(Icons.delete,
                                              size: 18, color: Colors.redAccent),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () => _removeMessage(
                                              context, groupInfo.groupId, msg),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(msg.content,
                                  style: GoogleFonts.kanit(
                                      fontSize: 13, color: Colors.black54, height: 1.4),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                              if (msg.timestamp != null) ...[
                                const SizedBox(height: 6),
                                Text(
                                  DateFormat('dd/MM/yyyy HH:mm')
                                      .format(msg.timestamp!),
                                  style: GoogleFonts.kanit(
                                      fontSize: 11, color: Colors.grey[500]),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton.extended(
              heroTag: 'messages_fab_${groupInfo.groupId}',
              onPressed: () => _showCreateMessageDialog(context, groupInfo),
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.onPrimary,
              icon: const Icon(Icons.edit_outlined),
              label: Text('Ny besked',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteDocumentConfirmationDialog(
      BuildContext context, Reference pdfFile) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Slet dokument?'),
          content: Text(
              'Er du sikker på, du vil slette "${pdfFile.name}"? Handlingen kan ikke fortrydes.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Annuller'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Slet'),
              onPressed: () {
                _deleteDocument(pdfFile);
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteDocument(Reference pdfFile) async {
    try {
      await pdfFile.delete();
      showAppSnackbar(context, 'Dokument slettet.');
      _fetchDocuments(); // Refresh the list
    } catch (e) {
      showErrorSnackbar(context, 'Fejl ved sletning af dokument: ${describeError(e)}');
    }
  }

  Future<void> _deleteFolderRecursive(Reference folderRef) async {
    final listResult = await folderRef.listAll();
    // Delete all files in the folder
    for (final item in listResult.items) {
      await item.delete();
    }
    // Recursively delete all subfolders
    for (final prefix in listResult.prefixes) {
      await _deleteFolderRecursive(prefix);
    }
  }

  void _showDeleteFolderConfirmationDialog(
      BuildContext context, Reference folder) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Slet mappe?'),
          content: Text(
              'Er du sikker på, du vil slette mappen "${folder.name}" og alt dens indhold? Handlingen kan ikke fortrydes.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Annuller'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Slet'),
              onPressed: () async {
                Navigator.of(dialogContext)
                    .pop(); // Close dialog before async operation
                try {
                  await _deleteFolderRecursive(folder);
                  if (mounted) {
                    showAppSnackbar(context, 'Mappe slettet.');
                  }
                  _fetchDocuments(); // Refresh the list
                } catch (e) {
                  if (mounted) {
                    showErrorSnackbar(context, 'Fejl ved sletning af mappe: ${describeError(e)}');
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _moveFolderContents(
      Reference source, Reference destination) async {
    final listResult = await source.listAll();

    // Move files
    for (final item in listResult.items) {
      final data = await item.getData();
      if (data != null) {
        await destination.child(item.name).putData(data);
        await item.delete();
      }
    }

    // Recursively move subfolders
    for (final prefix in listResult.prefixes) {
      final newDestination = destination.child(prefix.name);
      await _moveFolderContents(prefix, newDestination);
    }
  }

  void _showRenameFolderDialog(BuildContext context, Reference folder) {
    final folderNameController = TextEditingController(text: folder.name);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Omdøb mappe'),
        content: TextField(
          controller: folderNameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nyt mappenavn'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuller')),
          ElevatedButton(
            onPressed: () async {
              final newName = folderNameController.text.trim();
              if (newName.isNotEmpty && newName != folder.name) {
                Navigator.pop(context); // Close dialog
                final parent = folder.parent;
                if (parent != null) {
                  final newFolderRef = parent.child(newName);
                  try {
                    await _moveFolderContents(folder, newFolderRef);
                    if (mounted) {
                      showAppSnackbar(context, 'Mappe omdøbt.');
                    }
                    _fetchDocuments();
                  } catch (e) {
                    if (mounted) {
                      showErrorSnackbar(context, 'Fejl ved omdøbning af mappe: ${describeError(e)}');
                    }
                  }
                }
              }
            },
            child: const Text('Omdøb'),
          ),
        ],
      ),
    );
  }

  Future<List<Reference>> _fetchAllDocuments(Reference baseRef) async {
    final List<Reference> allFiles = [];
    try {
      final listResult = await baseRef.listAll();

      // Add files in the current directory, ignoring placeholder files
      allFiles
          .addAll(listResult.items.where((ref) => !ref.name.startsWith('.')));

      // Recursively get files from subdirectories
      for (final prefix in listResult.prefixes) {
        allFiles.addAll(await _fetchAllDocuments(prefix));
      }
    } catch (e) {
      print("Error fetching all documents recursively: $e");
      if (mounted) {
        showErrorSnackbar(context, 'Fejl ved hentning af dokumenter: ${describeError(e)}');
      }
    }
    return allFiles;
  }

  // --- DOCUMENTS PANEL ---
  Widget _buildDocumentsPanel(
      BuildContext context, GroupInformation groupInfo) {
    final user = FirebaseAuth.instance.currentUser;
    final isRoot =
        _currentDocsRef?.fullPath == '${groupInfo.groupId}/documents';

    return Container(
      decoration: _panelDecoration,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              _buildPanelHeader(
                Icons.folder_outlined,
                isRoot ? 'Dokumenter' : _currentDocsRef?.name ?? 'Dokumenter',
                leading: !isRoot
                    ? Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back, size: 20),
                          onPressed: _navigateBack,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: _currentFiles.isEmpty && _currentFolders.isEmpty
                    ? Center(
                        child: Text('Tom mappe.',
                            style: GoogleFonts.kanit(color: Colors.grey[500])))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 72),
                        itemCount:
                            _currentFolders.length + _currentFiles.length,
                        itemBuilder: (context, index) {
                          if (index < _currentFolders.length) {
                            // Folder Item
                            final folder = _currentFolders[index];
                            return _buildDocRow(
                              icon: Icons.folder,
                              iconColor: AppColors.darkGreen,
                              title: folder.name,
                              onTap: () => _navigateToFolder(folder),
                              trailing: ((user?.emailVerified ?? false) && widget.canEditTrips)
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: Icon(Icons.edit,
                                              size: 18, color: Colors.grey[600]),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () =>
                                              _showRenameFolderDialog(
                                                  context, folder),
                                          tooltip: 'Omdøb mappe',
                                        ),
                                        const SizedBox(width: AppSpacing.md),
                                        IconButton(
                                          icon: const Icon(Icons.delete,
                                              size: 18, color: Colors.redAccent),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () =>
                                              _showDeleteFolderConfirmationDialog(
                                                  context, folder),
                                          tooltip: 'Slet mappe',
                                        ),
                                      ],
                                    )
                                  : null,
                            );
                          } else {
                            // File Item
                            final fileIndex = index - _currentFolders.length;
                            final pdfFile = _currentFiles[fileIndex];
                            final metadata = _fileMetadata[pdfFile.name];
                            return _buildDocRow(
                              icon: Icons.picture_as_pdf,
                              iconColor: Colors.red,
                              title: pdfFile.name,
                              subtitle: metadata?.timeCreated != null
                                  ? DateFormat('dd/MM/yyyy HH:mm')
                                      .format(metadata!.timeCreated!)
                                  : null,
                              onTap: () async {
                                String downloadURL =
                                    await pdfFile.getDownloadURL();
                                openPdf(context, downloadURL);
                              },
                              trailing: ((user?.emailVerified ?? false) && widget.canEditTrips)
                                  ? IconButton(
                                      icon: const Icon(Icons.delete,
                                          size: 18, color: Colors.redAccent),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () =>
                                          _showDeleteDocumentConfirmationDialog(
                                              context, pdfFile),
                                    )
                                  : null,
                            );
                          }
                        },
                      ),
              ),
            ],
          ),
          if ((user?.emailVerified ?? false) && widget.canEditTrips)
            Positioned(
              bottom: 16,
              right: 16,
              child: FloatingActionButton(
                heroTag: 'documents_fab_${groupInfo.groupId}',
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    backgroundColor: AppColors.secondary,
                    builder: (sheetContext) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.upload_file),
                          title: const Text('Upload fil'),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _pickAndUploadDocument(context);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.create_new_folder),
                          title: const Text('Opret mappe'),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _createFolder(context);
                          },
                        ),
                      ],
                    ),
                  );
                },
                backgroundColor: AppColors.primary,
                child: Icon(Icons.add, color: AppColors.onPrimary),
              ),
            ),
        ],
      ),
    );
  }

  // --- CREATE / EDIT / DELETE MESSAGE ---
  void _showCreateMessageDialog(
          BuildContext context, GroupInformation groupInfo) =>
      showMessageComposer(context, group: groupInfo);

  void _showEditMessageDialog(
          BuildContext context, GroupInformation groupInfo, Message message) =>
      showMessageComposer(context, group: groupInfo, existing: message);

  void _removeMessage(BuildContext context, String groupId, Message message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Slet besked?'),
        content: const Text('Er du sikker på, du vil slette denne besked?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuller')),
          ElevatedButton(
            onPressed: () {
              context
                  .read<GroupInformationRepository>()
                  .deleteMessage(groupId, message.id);
              Navigator.pop(context);
            },
            child: const Text('Slet'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmailPickerRow({
    required IconData icon,
    required String label,
    required String valueText,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.cardBackground,
        borderRadius: AppRadii.mdRadius,
        child: InkWell(
          borderRadius: AppRadii.mdRadius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 19, color: AppColors.primary),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          style: AppTextStyles.caption()),
                      Text(valueText,
                          style: AppTextStyles.label(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                Icon(Icons.expand_more, color: Colors.grey[500]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showEmailComposer(BuildContext context, GroupInformation groupInfo,
      String bureauName, String bureauEmail, List<Reference> allDocuments) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      showWarningSnackbar(context, 'Du skal være logget ind for at sende e-mail');
      return;
    }

    final fromNameController = TextEditingController(text: bureauName);
    final subjectController = TextEditingController();
    final bodyController = TextEditingController();
    final replyToController = TextEditingController(text: bureauEmail);

    final allMembersWithEmail =
        groupInfo.members.where((m) => m.email.isNotEmpty).toList();

    List<String> selectedEmails =
        allMembersWithEmail.map((m) => m.email).toList();

    List<Reference> selectedDocuments = [];

    String signatureText = '';
    String? signatureImageUrl;
    bool includeSignature = false;
    bool signatureLoadRequested = false;
    bool isSending = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scrollController) => StatefulBuilder(
          builder: (context, setState) {
            if (!signatureLoadRequested) {
              signatureLoadRequested = true;
              FirebaseFirestore.instance
                  .collection('agency')
                  .doc(groupInfo.agencyCode)
                  .get()
                  .then((doc) {
                final data = doc.data();
                if (data == null) return;
                final text = data['emailSignatureText'] as String? ?? '';
                final imageUrl = data['emailSignatureImageUrl'] as String?;
                setState(() {
                  signatureText = text;
                  signatureImageUrl = imageUrl;
                  includeSignature = text.isNotEmpty || imageUrl != null;
                });
              });
            }

            Future<void> handleSend() async {
              if (selectedEmails.isEmpty) {
                showWarningSnackbar(context, 'Vælg mindst én modtager');
                return;
              }
              if (subjectController.text.trim().isEmpty) {
                showWarningSnackbar(context, 'Emne mangler');
                return;
              }

              setState(() => isSending = true);

              // Generate document links
              String documentLinksHtml = '';
              if (selectedDocuments.isNotEmpty) {
                documentLinksHtml +=
                    '<br><br><b>Vedhæftede dokumenter:</b><br><ul>';
                for (final docRef in selectedDocuments) {
                  try {
                    final url = await docRef.getDownloadURL();
                    documentLinksHtml +=
                        '<li><a href="$url">${docRef.name}</a></li>';
                  } catch (e) {
                    documentLinksHtml +=
                        '<li><i>(Link for ${docRef.name} kunne ikke genereres)</i></li>';
                  }
                }
                documentLinksHtml += '</ul>';
              }

              String signatureHtml = '';
              if (includeSignature &&
                  (signatureText.isNotEmpty || signatureImageUrl != null)) {
                signatureHtml +=
                    '<br><br><hr style="border:none;border-top:1px solid #e0e0e0;margin:12px 0;">';
                if (signatureText.isNotEmpty) {
                  signatureHtml += signatureText.trim().replaceAll('\n', '<br>');
                }
                if (signatureImageUrl != null) {
                  signatureHtml +=
                      '<br><img src="$signatureImageUrl" style="max-width:280px;margin-top:8px;">';
                }
              }

              try {
                await user.getIdToken(true);

                final functions = FirebaseFunctions.instanceFor(
                  region: 'europe-west1',
                );

                final callable = functions.httpsCallable('sendGroupEmail');

                await callable.call({
                  'to': selectedEmails,
                  'subject': subjectController.text.trim(),
                  'html': bodyController.text.trim().replaceAll('\n', '<br>') +
                      documentLinksHtml +
                      signatureHtml,
                  'fromName': fromNameController.text.trim(),
                  'replyTo': replyToController.text.trim(),
                });

                if (!context.mounted) return;

                Navigator.pop(context);
                showAppSnackbar(context, 'E-mail sendt');
              } on FirebaseFunctionsException catch (e) {
                setState(() => isSending = false);
                if (context.mounted) {
                  showErrorSnackbar(context, e.message ?? 'Kunne ikke sende e-mail');
                }
              } catch (e) {
                setState(() => isSending = false);
                if (context.mounted) {
                  showErrorSnackbar(context, 'Fejl: ${describeError(e)}');
                }
              }
            }

            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // HEADER
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.12),
                            borderRadius: AppRadii.mdRadius,
                          ),
                          child: Icon(Icons.mail_outline, color: AppColors.primary),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Text('Ny e-mail',
                              style: AppTextStyles.heading()),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: isSending ? null : () => Navigator.pop(context),
                        ),
                        Material(
                          color: AppColors.primary,
                          borderRadius: AppRadii.smRadius,
                          child: InkWell(
                            borderRadius: AppRadii.smRadius,
                            onTap: isSending ? null : handleSend,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              child: isSending
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: AppColors.onPrimary),
                                    )
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.send, size: 16, color: AppColors.onPrimary),
                                        const SizedBox(width: 6),
                                        Text('Send',
                                            style: GoogleFonts.kanit(
                                                color: AppColors.onPrimary,
                                                fontWeight: FontWeight.w700)),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: Colors.grey.withOpacity(0.15)),

                  // CONTENT
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                      children: [
                        _buildContactField(
                          controller: fromNameController,
                          label: 'Afsendernavn',
                          icon: Icons.badge_outlined,
                          onChanged: (_) {},
                        ),
                        _buildContactField(
                          controller: replyToController,
                          label: 'Svar til',
                          icon: Icons.reply_outlined,
                          keyboardType: TextInputType.emailAddress,
                          onChanged: (_) {},
                        ),
                        _buildEmailPickerRow(
                          icon: Icons.people_outline,
                          label: 'TIL',
                          valueText: selectedEmails.isEmpty
                              ? 'Ingen modtagere'
                              : '${selectedEmails.length} modtager${selectedEmails.length == 1 ? '' : 'e'}: ${selectedEmails.join(', ')}',
                          onTap: () async {
                            final result = await showDialog<List<String>>(
                              context: context,
                              builder: (dialogContext) {
                                List<String> tempSelected = List.from(selectedEmails);

                                return StatefulBuilder(
                                  builder: (dialogContext, setDialogState) {
                                    return Dialog(
                                      backgroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: AppRadii.lgRadius),
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                            maxWidth: 420,
                                            maxHeight:
                                                MediaQuery.of(dialogContext).size.height * 0.7),
                                        child: Padding(
                                          padding: const EdgeInsets.all(AppSpacing.xl),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text('Vælg modtagere',
                                                  style: GoogleFonts.kanit(
                                                      fontSize: 17,
                                                      fontWeight: FontWeight.w600,
                                                      color: Colors.black87)),
                                              const SizedBox(height: AppSpacing.md),
                                              Flexible(
                                                child: ListView.builder(
                                                  shrinkWrap: true,
                                                  itemCount: allMembersWithEmail.length,
                                                  itemBuilder: (context, index) {
                                                    final member = allMembersWithEmail[index];
                                                    final isSelected =
                                                        tempSelected.contains(member.email);

                                                    return CheckboxListTile(
                                                      title: Text(member.name,
                                                          style: GoogleFonts.kanit(
                                                              fontWeight: FontWeight.w600)),
                                                      subtitle: Text(member.email,
                                                          style: GoogleFonts.kanit(fontSize: 12)),
                                                      value: isSelected,
                                                      activeColor: AppColors.primary,
                                                      onChanged: (value) {
                                                        setDialogState(() {
                                                          value == true
                                                              ? tempSelected.add(member.email)
                                                              : tempSelected.remove(member.email);
                                                        });
                                                      },
                                                    );
                                                  },
                                                ),
                                              ),
                                              const SizedBox(height: AppSpacing.md),
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: TextButton(
                                                      onPressed: () => Navigator.pop(dialogContext),
                                                      child: Text('Annuller',
                                                          style: GoogleFonts.kanit(
                                                              color: Colors.grey[600],
                                                              fontWeight: FontWeight.w600)),
                                                    ),
                                                  ),
                                                  const SizedBox(width: AppSpacing.sm),
                                                  Expanded(
                                                    child: ElevatedButton(
                                                      style: ElevatedButton.styleFrom(
                                                        backgroundColor: AppColors.primary,
                                                        foregroundColor: AppColors.onPrimary,
                                                        elevation: 0,
                                                        padding:
                                                            const EdgeInsets.symmetric(vertical: 12),
                                                        shape: RoundedRectangleBorder(
                                                            borderRadius: AppRadii.smRadius),
                                                      ),
                                                      onPressed: () =>
                                                          Navigator.pop(dialogContext, tempSelected),
                                                      child: Text('OK',
                                                          style: GoogleFonts.kanit(
                                                              fontWeight: FontWeight.w700)),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            );

                            if (result != null && context.mounted) {
                              setState(() => selectedEmails = result);
                            }
                          },
                        ),
                        _buildEmailPickerRow(
                          icon: Icons.attach_file,
                          label: 'VEDHÆFTNINGER (SOM LINKS)',
                          valueText: selectedDocuments.isEmpty
                              ? 'Ingen dokumenter valgt'
                              : selectedDocuments.map((d) => d.name).join(', '),
                          onTap: () async {
                            final result = await showDialog<List<Reference>>(
                              context: context,
                              builder: (dialogContext) {
                                List<Reference> tempSelected = List.from(selectedDocuments);

                                return StatefulBuilder(
                                  builder: (dialogContext, setDialogState) {
                                    return Dialog(
                                      backgroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: AppRadii.lgRadius),
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                            maxWidth: 420,
                                            maxHeight:
                                                MediaQuery.of(dialogContext).size.height * 0.7),
                                        child: Padding(
                                          padding: const EdgeInsets.all(AppSpacing.xl),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text('Vælg dokumenter',
                                                  style: GoogleFonts.kanit(
                                                      fontSize: 17,
                                                      fontWeight: FontWeight.w600,
                                                      color: Colors.black87)),
                                              const SizedBox(height: AppSpacing.md),
                                              Flexible(
                                                child: allDocuments.isEmpty
                                                    ? Padding(
                                                        padding:
                                                            const EdgeInsets.symmetric(vertical: 20),
                                                        child: Text('Ingen dokumenter fundet.',
                                                            style: GoogleFonts.kanit(
                                                                color: Colors.grey[600])),
                                                      )
                                                    : ListView.builder(
                                                        shrinkWrap: true,
                                                        itemCount: allDocuments.length,
                                                        itemBuilder: (context, index) {
                                                          final doc = allDocuments[index];
                                                          final isSelected = tempSelected.any(
                                                              (d) => d.fullPath == doc.fullPath);

                                                          return CheckboxListTile(
                                                            title: Text(doc.name,
                                                                style: GoogleFonts.kanit(
                                                                    fontWeight: FontWeight.w600),
                                                                overflow: TextOverflow.ellipsis),
                                                            subtitle: Text(
                                                              doc.fullPath
                                                                  .replaceFirst(
                                                                      '${groupInfo.groupId}/documents/',
                                                                      '')
                                                                  .replaceFirst('/${doc.name}', ''),
                                                              style: GoogleFonts.kanit(
                                                                  color: Colors.grey[600],
                                                                  fontSize: 12),
                                                              overflow: TextOverflow.ellipsis,
                                                            ),
                                                            value: isSelected,
                                                            activeColor: AppColors.primary,
                                                            onChanged: (value) {
                                                              setDialogState(() {
                                                                if (value == true) {
                                                                  tempSelected.add(doc);
                                                                } else {
                                                                  tempSelected.removeWhere((d) =>
                                                                      d.fullPath == doc.fullPath);
                                                                }
                                                              });
                                                            },
                                                          );
                                                        },
                                                      ),
                                              ),
                                              const SizedBox(height: AppSpacing.md),
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: TextButton(
                                                      onPressed: () => Navigator.pop(dialogContext),
                                                      child: Text('Annuller',
                                                          style: GoogleFonts.kanit(
                                                              color: Colors.grey[600],
                                                              fontWeight: FontWeight.w600)),
                                                    ),
                                                  ),
                                                  const SizedBox(width: AppSpacing.sm),
                                                  Expanded(
                                                    child: ElevatedButton(
                                                      style: ElevatedButton.styleFrom(
                                                        backgroundColor: AppColors.primary,
                                                        foregroundColor: AppColors.onPrimary,
                                                        elevation: 0,
                                                        padding:
                                                            const EdgeInsets.symmetric(vertical: 12),
                                                        shape: RoundedRectangleBorder(
                                                            borderRadius: AppRadii.smRadius),
                                                      ),
                                                      onPressed: () =>
                                                          Navigator.pop(dialogContext, tempSelected),
                                                      child: Text('OK',
                                                          style: GoogleFonts.kanit(
                                                              fontWeight: FontWeight.w700)),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            );

                            if (result != null && context.mounted) {
                              setState(() => selectedDocuments = result);
                            }
                          },
                        ),
                        _buildContactField(
                          controller: subjectController,
                          label: 'Emne',
                          icon: Icons.subject,
                          onChanged: (_) {},
                        ),
                        _buildFormSectionLabel('BESKED'),
                        const SizedBox(height: AppSpacing.xs),
                        TextField(
                          controller: bodyController,
                          maxLines: 8,
                          minLines: 6,
                          keyboardType: TextInputType.multiline,
                          style: GoogleFonts.kanit(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Skriv din besked her...',
                            hintStyle: GoogleFonts.kanit(fontSize: 14, color: Colors.grey[500]),
                            filled: true,
                            fillColor: AppColors.cardBackground,
                            contentPadding: const EdgeInsets.all(14),
                            border: OutlineInputBorder(
                              borderRadius: AppRadii.mdRadius,
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: AppRadii.mdRadius,
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: AppRadii.mdRadius,
                              borderSide: BorderSide(color: AppColors.primary, width: 1.5),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),

                        // SIGNATURE
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.cardBackground,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.draw_outlined, size: 18, color: AppColors.primary),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Text('Signatur',
                                        style: AppTextStyles.label()),
                                  ),
                                  Switch(
                                    value: includeSignature,
                                    activeThumbColor: AppColors.primary,
                                    onChanged: (signatureText.isEmpty && signatureImageUrl == null)
                                        ? null
                                        : (val) => setState(() => includeSignature = val),
                                  ),
                                ],
                              ),
                              if (signatureText.isEmpty && signatureImageUrl == null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text('Du har ikke gemt en signatur endnu.',
                                      style: GoogleFonts.kanit(fontSize: 12, color: Colors.grey[600])),
                                )
                              else if (includeSignature) ...[
                                const SizedBox(height: 10),
                                if (signatureImageUrl != null)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(signatureImageUrl!,
                                        height: 50, fit: BoxFit.contain, alignment: Alignment.centerLeft),
                                  ),
                                if (signatureText.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(signatureText,
                                        style: GoogleFonts.kanit(fontSize: 12.5, color: Colors.black54)),
                                  ),
                              ],
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: () => _showSignatureEditorDialog(
                                    context,
                                    agencyCode: groupInfo.agencyCode,
                                    initialText: signatureText,
                                    initialImageUrl: signatureImageUrl,
                                    onSaved: (text, imageUrl) => setState(() {
                                      signatureText = text;
                                      signatureImageUrl = imageUrl;
                                      includeSignature = text.isNotEmpty || imageUrl != null;
                                    }),
                                  ),
                                  icon: const Icon(Icons.edit_outlined, size: 15),
                                  label: Text(
                                      signatureText.isEmpty && signatureImageUrl == null
                                          ? 'Opret signatur'
                                          : 'Rediger signatur',
                                      style: GoogleFonts.kanit(
                                          fontSize: 12.5, fontWeight: FontWeight.w600)),
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
            );
          },
        ),
      ),
    );
  }

  /// Lets an agency save a reusable email signature (text + optional image)
  /// under `agency/{agencyCode}` in Firestore, so it can be appended to any
  /// email sent from the group email composer.
  void _showSignatureEditorDialog(
    BuildContext context, {
    required String agencyCode,
    required String initialText,
    required String? initialImageUrl,
    required void Function(String text, String? imageUrl) onSaved,
  }) {
    final textController = TextEditingController(text: initialText);
    String? imageUrl = initialImageUrl;
    bool isUploading = false;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          Future<void> pickImage() async {
            final picker = ImagePicker();
            final XFile? file =
                await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
            if (file == null) return;

            setState(() => isUploading = true);
            try {
              final bytes = await file.readAsBytes();
              final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
              final fileName = '${DateTime.now().millisecondsSinceEpoch}_$safeName';
              final ref =
                  FirebaseStorage.instance.ref('agencies/$agencyCode/signature/$fileName');
              await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
              final url = await ref.getDownloadURL();
              setState(() {
                imageUrl = url;
                isUploading = false;
              });
            } catch (e) {
              setState(() => isUploading = false);
              if (context.mounted) {
                showErrorSnackbar(context, 'Kunne ikke uploade billede: ${describeError(e)}');
              }
            }
          }

          return Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: 460, maxHeight: MediaQuery.of(context).size.height * 0.85),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xxl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppColors.primary.withOpacity(0.12),
                              borderRadius: AppRadii.mdRadius,
                            ),
                            child: Icon(Icons.draw_outlined, color: AppColors.primary),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Text('Rediger signatur',
                                style: AppTextStyles.heading()),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => Navigator.pop(dialogContext),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text('Vises nederst i alle e-mails du sender herfra.',
                          style: GoogleFonts.kanit(fontSize: 12.5, color: Colors.grey[600])),
                      const SizedBox(height: 18),
                      _buildFormSectionLabel('BILLEDE (VALGFRI)'),
                      const SizedBox(height: AppSpacing.sm),
                      if (imageUrl != null)
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: AppRadii.mdRadius,
                              child: Container(
                                color: AppColors.cardBackground,
                                width: double.infinity,
                                height: 100,
                                child: Image.network(imageUrl!, fit: BoxFit.contain),
                              ),
                            ),
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Material(
                                color: Colors.black.withOpacity(0.5),
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => setState(() => imageUrl = null),
                                  child: const Padding(
                                    padding: EdgeInsets.all(6),
                                    child: Icon(Icons.close, size: 14, color: Colors.white),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      else
                        Material(
                          color: AppColors.cardBackground,
                          borderRadius: AppRadii.mdRadius,
                          child: InkWell(
                            borderRadius: AppRadii.mdRadius,
                            onTap: isUploading ? null : pickImage,
                            child: Container(
                              height: 90,
                              alignment: Alignment.center,
                              child: isUploading
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(strokeWidth: 2))
                                  : Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.add_photo_alternate_outlined,
                                            color: AppColors.primary),
                                        const SizedBox(height: AppSpacing.xs),
                                        Text('Tilføj billede',
                                            style: GoogleFonts.kanit(
                                                fontSize: 12.5,
                                                color: AppColors.primary,
                                                fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      if (imageUrl != null && !isUploading)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: TextButton.icon(
                            onPressed: pickImage,
                            icon: const Icon(Icons.swap_horiz, size: 16),
                            label: Text('Skift billede', style: GoogleFonts.kanit(fontSize: 12.5)),
                          ),
                        ),
                      const SizedBox(height: 14),
                      _buildFormSectionLabel('TEKST'),
                      const SizedBox(height: AppSpacing.sm),
                      TextField(
                        controller: textController,
                        maxLines: 5,
                        style: GoogleFonts.kanit(fontSize: 14),
                        decoration: InputDecoration(
                          hintText:
                              'F.eks.\nMed venlig hilsen\nDit Rejsebureau\ntlf. 12345678',
                          hintStyle: AppTextStyles.body(color: Colors.grey[500]),
                          filled: true,
                          fillColor: AppColors.cardBackground,
                          contentPadding: const EdgeInsets.all(14),
                          border: OutlineInputBorder(
                              borderRadius: AppRadii.mdRadius, borderSide: BorderSide.none),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: AppRadii.mdRadius, borderSide: BorderSide.none),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: AppRadii.mdRadius,
                            borderSide: BorderSide(color: AppColors.primary, width: 1.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: Text('Annuller',
                                  style: GoogleFonts.kanit(
                                      color: Colors.grey[600], fontWeight: FontWeight.w600)),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: AppColors.onPrimary,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape:
                                    RoundedRectangleBorder(borderRadius: AppRadii.smRadius),
                              ),
                              onPressed: () async {
                                final text = textController.text.trim();
                                try {
                                  await FirebaseFirestore.instance
                                      .collection('agency')
                                      .doc(agencyCode)
                                      .set({
                                    'emailSignatureText': text,
                                    'emailSignatureImageUrl': imageUrl,
                                  }, SetOptions(merge: true));
                                  onSaved(text, imageUrl);
                                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                                } catch (e) {
                                  if (context.mounted) {
                                    showErrorSnackbar(context, 'Kunne ikke gemme signatur: ${describeError(e)}');
                                  }
                                }
                              },
                              child: Text('Gem', style: GoogleFonts.kanit(fontWeight: FontWeight.w700)),
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
        },
      ),
    );
  }

  // --- GROUP PANEL ---
  Widget _buildGroupPanel(BuildContext context, GroupInformation groupInfo) {
    final user = FirebaseAuth.instance.currentUser;

    // If the group is a template, show a watermark instead of the member/guide lists.
    if (groupInfo.isTemplate == true) {
      return Container(
        decoration: _panelDecoration,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text(
              "Der kan ikke tilføjes medlemmer til en skabelon",
              textAlign: TextAlign.center,
              style: GoogleFonts.kanit(
                  fontSize: 15,
                  color: Colors.grey[600],
                  fontStyle: FontStyle.italic),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: _panelDecoration,
      clipBehavior: Clip.antiAlias,
      child: DefaultTabController(
        length: 2,
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: TabBar(
                    indicatorColor: AppColors.primary,
                    labelColor: AppColors.primary,
                    unselectedLabelColor: Colors.grey,
                    labelStyle: GoogleFonts.kanit(fontWeight: FontWeight.w600),
                    unselectedLabelStyle: GoogleFonts.kanit(),
                    tabs: const [Tab(text: 'Gruppemedlemmer'), Tab(text: 'Guides')],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildGroupMembersList(groupInfo),
                      _buildGuidesList(groupInfo),
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              left: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                heroTag: 'email_fab',
                onPressed: () async {
                  final docsRootRef = FirebaseStorage.instance
                      .ref('${groupInfo.groupId}/documents');
                  final allDocuments = await _fetchAllDocuments(docsRootRef);
                  if (mounted) {
                    _showEmailComposer(context, groupInfo, groupInfo.bureauName,
                        user?.email ?? '', allDocuments);
                  }
                },
                backgroundColor: AppColors.primary,
                icon: Icon(Icons.email, color: AppColors.onPrimary),
                label: Text(
                  "Send e-mail",
                  style: TextStyle(color: AppColors.onPrimary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGuidesList(GroupInformation groupInfo) => Stack(
        children: [
          ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
            itemCount: groupInfo.guides.length,
            itemBuilder: (context, i) => _buildDocRow(
              icon: Icons.support_agent,
              iconColor: AppColors.primary,
              title: groupInfo.guides[i].name,
              subtitle: _guideContactSummary(groupInfo.guides[i]),
              trailing:
                  ((FirebaseAuth.instance.currentUser?.emailVerified ?? false) && widget.canEditTrips)
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Icons.edit,
                                  size: 18, color: Colors.grey[600]),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _showAddEditGuideDialog(
                                context,
                                groupInfo: groupInfo,
                                guide: groupInfo.guides[i],
                                index: i,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            IconButton(
                              icon: const Icon(Icons.delete,
                                  size: 18, color: Colors.redAccent),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _removeGuide(
                                  context, groupInfo, i, groupInfo.guides[i]),
                            ),
                          ],
                        )
                      : null,
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              heroTag: 'guides_fab_${groupInfo.groupId}',
              backgroundColor: AppColors.primary,
              onPressed: () => _showAddEditGuideDialog(
                context,
                groupInfo: groupInfo,
                guide: null,
              ),
              child: Icon(
                Icons.add,
                color: AppColors.onPrimary,
              ),
            ),
          ),
        ],
      );

  String _guideContactSummary(Guide guide) {
    final parts = <String>[
      if (guide.hasTitle) guide.title,
      if (guide.hasPhone) 'Tlf: ${guide.phoneNumber}',
      if (guide.hasWhatsapp) 'WhatsApp: ${guide.whatsappNumber}',
      if (guide.hasEmail) guide.email,
    ];
    return parts.isEmpty ? 'Ingen kontaktoplysninger' : parts.join(' · ');
  }

  String _memberContactSummary(GroupMember member) {
    final parts = <String>[
      if (member.hasPhone) 'Tlf: ${member.phoneNumber}',
      if (member.hasWhatsapp) 'WhatsApp: ${member.whatsappNumber}',
      if (member.hasEmail) member.email,
    ];
    return parts.isEmpty ? 'Ingen kontaktoplysninger' : parts.join(' · ');
  }

  /// A rounded, icon-prefixed text field shared by the guide/member forms.
  Widget _buildContactField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    Color? iconColor,
    TextInputType? keyboardType,
    required ValueChanged<String> onChanged,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        onChanged: onChanged,
        enabled: enabled,
        style: GoogleFonts.kanit(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: AppTextStyles.body(color: Colors.grey[600]),
          prefixIcon: Icon(icon, size: 19, color: iconColor ?? Colors.grey[500]),
          filled: true,
          fillColor: AppColors.cardBackground,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: AppRadii.mdRadius,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: AppRadii.mdRadius,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: AppRadii.mdRadius,
            borderSide: BorderSide(color: AppColors.primary, width: 1.5),
          ),
        ),
      ),
    );
  }

  Widget _buildFormSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: GoogleFonts.kanit(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Colors.grey[500],
        ),
      ),
    );
  }

  /// Shared rounded-card dialog shell for the guide/member add-edit forms.
  Future<void> _showStyledFormDialog({
    required BuildContext context,
    required String title,
    required IconData icon,
    required List<Widget> fields,
    required String saveLabel,
    required void Function(BuildContext dialogContext) onSave,
  }) {
    return showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.15),
                          borderRadius: AppRadii.mdRadius,
                        ),
                        child: Icon(icon, color: AppColors.primary, size: 20),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(
                          title,
                          style: GoogleFonts.kanit(
                              fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  ...fields,
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: Text('Annuller',
                            style: GoogleFonts.kanit(
                                color: Colors.grey[600],
                                fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.onPrimary,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: AppRadii.smRadius),
                        ),
                        onPressed: () => onSave(dialogContext),
                        child: Text(saveLabel,
                            style:
                                GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Shared rounded delete-confirmation dialog for guides/members.
  void _showDeleteConfirmDialog({
    required BuildContext context,
    required String title,
    required String message,
    required Future<void> Function() onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title,
            style: GoogleFonts.kanit(fontWeight: FontWeight.w600, fontSize: 17)),
        content: Text(message, style: GoogleFonts.kanit(fontSize: 13.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('Annuller',
                style: GoogleFonts.kanit(color: Colors.grey[600])),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () async {
              await onConfirm();
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            },
            child: Text('Slet', style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  void _showAddEditGuideDialog(BuildContext context,
      {required GroupInformation groupInfo, Guide? guide, int? index}) {
    final isEditing = guide != null;
    String name = guide?.name ?? '';
    String title = guide?.title ?? '';
    String phone = guide?.phoneNumber ?? '';
    String whatsapp = guide?.whatsappNumber ?? '';
    String email = guide?.email ?? '';

    _showStyledFormDialog(
      context: context,
      title: isEditing ? 'Rediger guide' : 'Tilføj guide',
      icon: Icons.support_agent,
      saveLabel: 'Gem',
      fields: [
        _buildContactField(
          controller: TextEditingController(text: name),
          label: 'Navn',
          icon: Icons.badge_outlined,
          onChanged: (v) => name = v,
        ),
        _buildContactField(
          controller: TextEditingController(text: title),
          label: 'Titel (valgfri, fx Rejseleder)',
          icon: Icons.work_outline,
          onChanged: (v) => title = v,
        ),
        _buildFormSectionLabel('KONTAKT (VALGFRI)'),
        PhoneNumberField(
          initialValue: phone,
          label: 'Telefonnummer',
          icon: Icons.phone_outlined,
          iconColor: AppColors.primary,
          fillColor: AppColors.cardBackground,
          focusedBorderColor: AppColors.primary,
          onChanged: (v) => phone = v,
        ),
        PhoneNumberField(
          initialValue: whatsapp,
          label: 'WhatsApp-nummer',
          icon: MdiIcons.whatsapp,
          iconColor: const Color(0xFF25D366),
          fillColor: AppColors.cardBackground,
          focusedBorderColor: AppColors.primary,
          onChanged: (v) => whatsapp = v,
        ),
        _buildContactField(
          controller: TextEditingController(text: email),
          label: 'Email',
          icon: Icons.email_outlined,
          iconColor: AppColors.primary,
          keyboardType: TextInputType.emailAddress,
          onChanged: (v) => email = v,
        ),
      ],
      onSave: (dialogContext) async {
        final newGuide = Guide(
          name: name.trim(),
          title: title.trim(),
          phoneNumber: phone.trim(),
          whatsappNumber: whatsapp.trim(),
          email: email.trim(),
        );
        if (isEditing) {
          await dialogContext
              .read<GroupInformationRepository>()
              .updateGuide(groupInfo.groupId, index!, newGuide);
        } else {
          await dialogContext
              .read<GroupInformationRepository>()
              .addGuide(groupInfo.groupId, newGuide);
        }
        if (dialogContext.mounted) {
          dialogContext
              .read<GroupInformationBloc>()
              .add(LoadGroupInformationById(groupId: groupInfo.groupId));
          Navigator.of(dialogContext).pop();
        }
      },
    );
  }

  void _removeGuide(
      BuildContext context, GroupInformation groupInfo, int index, Guide guide) {
    _showDeleteConfirmDialog(
      context: context,
      title: 'Slet guide?',
      message:
          'Er du sikker på, du vil slette "${guide.name}"? Handlingen kan ikke fortrydes.',
      onConfirm: () async {
        await context
            .read<GroupInformationRepository>()
            .deleteGuide(groupInfo.groupId, index);
        if (context.mounted) {
          context.read<GroupInformationBloc>().add(
              LoadGroupInformationById(groupId: groupInfo.groupId));
        }
      },
    );
  }

  Widget _buildGroupMembersList(GroupInformation groupInfo) => Stack(
        children: [
          ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
            itemCount: groupInfo.members.length,
            itemBuilder: (context, i) => _buildDocRow(
              icon: Icons.person_outline,
              iconColor: AppColors.primary,
              title: groupInfo.members[i].name,
              subtitle: _memberContactSummary(groupInfo.members[i]),
              trailing:
                  ((FirebaseAuth.instance.currentUser?.emailVerified ?? false) && widget.canEditTrips)
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            (groupInfo.members[i].fcmToken != null &&
                                    groupInfo.members[i].fcmToken!.isNotEmpty)
                                ? const Icon(Icons.smartphone_outlined,
                                    size: 18, color: Color.fromARGB(255, 0, 111, 4))
                                : const Icon(Icons.phonelink_erase,
                                    size: 18, color: Color.fromARGB(255, 255, 82, 2)),
                            const SizedBox(width: AppSpacing.sm),
                            IconButton(
                              icon: Icon(Icons.edit,
                                  size: 18, color: Colors.grey[600]),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _showAddEditMemberDialog(
                                context,
                                groupInfo: groupInfo,
                                member: groupInfo.members[i],
                                index: i,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            IconButton(
                              icon: const Icon(Icons.delete,
                                  size: 18, color: Colors.redAccent),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _removeMember(context, groupInfo,
                                  i, groupInfo.members[i]),
                            ),
                          ],
                        )
                      : null,
            ),
          ),

          // Floating action button (add member)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              heroTag: 'members_fab_${groupInfo.groupId}',
              backgroundColor: AppColors.primary,
              onPressed: () => _showAddEditMemberDialog(
                context,
                groupInfo: groupInfo,
                member: null, // ✅ null means adding a new member
              ),
              child: Icon(
                Icons.add,
                color: AppColors.onPrimary,
              ),
            ),
          ),
        ],
      );

  String _generateRandomPassword() {
    const length = 16;
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%^&*()';
    final rnd = Random.secure();
    return String.fromCharCodes(Iterable.generate(
        length, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
  }

  void _showAddEditMemberDialog(BuildContext context,
      {required GroupInformation groupInfo, GroupMember? member, int? index}) {
    final isEditing = member != null;
    String name = member?.name ?? '';
    String email = member?.email ?? '';
    String phone = member?.phoneNumber ?? '';
    String whatsapp = member?.whatsappNumber ?? '';

    _showStyledFormDialog(
      context: context,
      title: isEditing ? 'Rediger medlem' : 'Tilføj medlem',
      icon: Icons.person_outline,
      saveLabel: 'Gem',
      fields: [
        _buildContactField(
          controller: TextEditingController(text: name),
          label: 'Navn',
          icon: Icons.badge_outlined,
          onChanged: (v) => name = v,
        ),
        _buildContactField(
          controller: TextEditingController(text: email),
          label: 'Email',
          icon: Icons.email_outlined,
          iconColor: AppColors.primary,
          keyboardType: TextInputType.emailAddress,
          enabled: !isEditing,
          onChanged: (v) => email = v,
        ),
        if (isEditing)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Email kan ikke ændres her — den er bundet til medlemmets login.',
              style:
                  AppTextStyles.caption(color: Colors.grey[500]),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'En login-konto oprettes automatisk, hvis email er udfyldt.',
              style:
                  AppTextStyles.caption(color: Colors.grey[500]),
            ),
          ),
        _buildFormSectionLabel('KONTAKT (VALGFRI)'),
        PhoneNumberField(
          initialValue: phone,
          label: 'Telefonnummer',
          icon: Icons.phone_outlined,
          iconColor: AppColors.primary,
          fillColor: AppColors.cardBackground,
          focusedBorderColor: AppColors.primary,
          onChanged: (v) => phone = v,
        ),
        PhoneNumberField(
          initialValue: whatsapp,
          label: 'WhatsApp-nummer',
          icon: MdiIcons.whatsapp,
          iconColor: const Color(0xFF25D366),
          fillColor: AppColors.cardBackground,
          focusedBorderColor: AppColors.primary,
          onChanged: (v) => whatsapp = v,
        ),
      ],
      onSave: (dialogContext) async {
        final newMember = GroupMember(
          name: name.trim(),
          email: email.trim(),
          phoneNumber: phone.trim(),
          whatsappNumber: whatsapp.trim(),
          fcmToken: member?.fcmToken,
        );
        if (isEditing) {
          await dialogContext
              .read<GroupInformationRepository>()
              .updateMember(groupInfo.groupId, index!, newMember);
        } else {
          if (newMember.email.isNotEmpty) {
            FirebaseApp? tempApp;
            try {
              tempApp = await Firebase.initializeApp(
                name:
                    'tempAuthApp_${DateTime.now().millisecondsSinceEpoch}',
                options: Firebase.app().options,
              );
              final generatedPassword = _generateRandomPassword();
              UserCredential userCredential =
                  await FirebaseAuth.instanceFor(app: tempApp)
                      .createUserWithEmailAndPassword(
                email: newMember.email,
                password: generatedPassword,
              );
              await userCredential.user?.updateDisplayName(newMember.name);
            } on FirebaseAuthException catch (e) {
              if (!dialogContext.mounted) return;
              if (e.code == 'email-already-in-use') {
                showInfoSnackbar(dialogContext, 'Brugeren findes allerede og tilføjes til gruppen.');
              } else {
                showErrorSnackbar(dialogContext, 'Fejl ved oprettelse af bruger: ${e.message}');
                return; // Stop if user creation fails
              }
            } catch (e) {
              if (!dialogContext.mounted) return;
              showErrorSnackbar(dialogContext, 'En uventet fejl opstod: ${describeError(e)}');
              return; // Stop on other errors
            } finally {
              await tempApp?.delete();
            }
          }
          // Add member to Firestore group only if auth creation was successful (or no email was provided)
          if (dialogContext.mounted) {
            await dialogContext
                .read<GroupInformationRepository>()
                .addMember(groupInfo.groupId, newMember);
          }
        }
        if (dialogContext.mounted) {
          // This will run for edits and successful adds
          dialogContext
              .read<GroupInformationBloc>()
              .add(LoadGroupInformationById(groupId: groupInfo.groupId));
          Navigator.of(dialogContext).pop();
        }
      },
    );
  }

  void _removeMember(BuildContext context, GroupInformation groupInfo,
      int index, GroupMember member) {
    _showDeleteConfirmDialog(
      context: context,
      title: 'Slet medlem?',
      message:
          'Er du sikker på, du vil slette "${member.name}"? Handlingen kan ikke fortrydes.',
      onConfirm: () async {
        await context
            .read<GroupInformationRepository>()
            .deleteMember(groupInfo.groupId, index);
        if (context.mounted) {
          context.read<GroupInformationBloc>().add(
              LoadGroupInformationById(groupId: groupInfo.groupId));
        }
      },
    );
  }

  // --- PACKING LIST CRUD ---

  void _showAddEditCategoryDialog(
    BuildContext context, {
    required GroupInformation groupInfo,
    PackinglistCategories? category,
  }) {
    final isEditing = category != null;
    final categoryNameController =
        TextEditingController(text: category?.categoryName ?? '');
    final List<String> items =
        isEditing ? List<String>.from(category.items) : [];

    // Keep track of selected icon name
    String selectedIconName = category?.iconName ?? 'mdi-folder';

    void addItem(StateSetter setState, BuildContext ctx) {
      final itemController = TextEditingController();
      showDialog(
        context: ctx,
        builder: (itemDialogContext) => Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Tilføj emne',
                    style: GoogleFonts.kanit(
                        fontSize: 17, fontWeight: FontWeight.w600, color: Colors.black87)),
                const SizedBox(height: 14),
                _buildContactField(
                  controller: itemController,
                  label: 'Emne',
                  icon: Icons.checklist_rtl,
                  onChanged: (_) {},
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(itemDialogContext),
                        child: Text('Annuller',
                            style: GoogleFonts.kanit(
                                color: Colors.grey[600], fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.onPrimary,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: AppRadii.smRadius),
                        ),
                        onPressed: () {
                          if (itemController.text.trim().isNotEmpty) {
                            setState(() => items.add(itemController.text.trim()));
                            Navigator.pop(itemDialogContext);
                          }
                        },
                        child: Text('Tilføj',
                            style: GoogleFonts.kanit(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    void pickIcon(StateSetter setState, BuildContext ctx) {
      final mdiIcons = {
        'mdi-folder': MdiIcons.folder, // General
        'mdi-tshirt-crew': MdiIcons.tshirtCrew, // Tøj
        'mdi-lotion-outline': MdiIcons.lotionOutline, // Toiletsager
        'mdi-pill': MdiIcons.pill, // Medicin
        'mdi-camera': MdiIcons.camera, // Elektronik
        'mdi-passport': MdiIcons.passport, // Dokumenter
        'mdi-beach': MdiIcons.beach, // Strand
        'mdi-hiking': MdiIcons.hiking, // Aktiviteter
        'mdi-wallet': MdiIcons.wallet, // Penge
        'mdi-sunglasses': MdiIcons.sunglasses, // Accessories
        'mdi-book-open-variant': MdiIcons.bookOpenVariant, // Læsestof
        'mdi-food-apple': MdiIcons.foodApple, // Snacks
        'mdi-star': MdiIcons.star, // Diverse
        'mdi-gift': MdiIcons.gift, // Gaver
        'mdi-headphones': MdiIcons.headphones, // Underholdning
        'mdi-power-plug': MdiIcons.powerPlug, // Opladere
      };

      showDialog(
        context: ctx,
        builder: (iconDialogContext) => Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(iconDialogContext).size.height * 0.7,
              maxWidth: 420,
            ),
            child: Padding(
              padding: const EdgeInsets.all(22.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('Vælg ikon',
                            style: GoogleFonts.kanit(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => Navigator.pop(iconDialogContext),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Flexible(
                    child: GridView.builder(
                      shrinkWrap: true,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4, crossAxisSpacing: 12, mainAxisSpacing: 12),
                      itemCount: mdiIcons.length,
                      itemBuilder: (context, index) {
                        final entry = mdiIcons.entries.elementAt(index);
                        final isSelected = entry.key == selectedIconName;
                        return InkWell(
                          borderRadius: AppRadii.mdRadius,
                          onTap: () {
                            setState(() => selectedIconName = entry.key);
                            Navigator.pop(iconDialogContext);
                          },
                          child: Container(
                            decoration: BoxDecoration(
                                color: isSelected
                                    ? AppColors.primary
                                    : AppColors.primary.withOpacity(0.1),
                                borderRadius: AppRadii.mdRadius),
                            child: Icon(entry.value,
                                size: 30,
                                color: isSelected ? AppColors.onPrimary : AppColors.primary),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Dialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 460,
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xxl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppColors.primary.withOpacity(0.12),
                              borderRadius: AppRadii.mdRadius,
                            ),
                            child: Icon(Icons.checklist, color: AppColors.primary),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Text(isEditing ? 'Rediger kategori' : 'Ny kategori',
                                style: AppTextStyles.heading()),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => Navigator.pop(dialogContext),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildContactField(
                                controller: categoryNameController,
                                label: 'Kategorinavn',
                                icon: Icons.label_outline,
                                onChanged: (_) {},
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              _buildFormSectionLabel('IKON'),
                              const SizedBox(height: AppSpacing.sm),
                              InkWell(
                                borderRadius: AppRadii.mdRadius,
                                onTap: () => pickIcon(setState, context),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: AppColors.cardBackground,
                                    borderRadius: AppRadii.mdRadius,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: AppColors.primary.withOpacity(0.14),
                                          borderRadius: AppRadii.smRadius,
                                        ),
                                        child: Icon(
                                            MdiIcons.fromString(selectedIconName) ??
                                                MdiIcons.folder,
                                            color: AppColors.primary,
                                            size: 19),
                                      ),
                                      const SizedBox(width: AppSpacing.md),
                                      Text('Skift ikon',
                                          style: GoogleFonts.kanit(
                                              fontWeight: FontWeight.w600,
                                              color: Colors.black87)),
                                      const Spacer(),
                                      Icon(Icons.chevron_right, color: Colors.grey[400]),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.xl),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  _buildFormSectionLabel('EMNER (${items.length})'),
                                  Material(
                                    color: AppColors.primary.withOpacity(0.1),
                                    borderRadius: AppRadii.lgRadius,
                                    child: InkWell(
                                      borderRadius: AppRadii.lgRadius,
                                      onTap: () => addItem(setState, context),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 5),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.add,
                                                size: 15, color: AppColors.primary),
                                            const SizedBox(width: 3),
                                            Text('Tilføj',
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
                              const SizedBox(height: AppSpacing.sm),
                              if (items.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  child: Text('Ingen emner endnu',
                                      style: AppTextStyles.body(color: Colors.grey[500])),
                                )
                              else
                                ...items.asMap().entries.map((entry) {
                                  final idx = entry.key;
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding:
                                        const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.cardBackground,
                                      borderRadius: AppRadii.mdRadius,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(entry.value,
                                              style: GoogleFonts.kanit(
                                                  fontSize: 14, color: Colors.black87)),
                                        ),
                                        IconButton(
                                          icon: Icon(Icons.close,
                                              size: 16, color: Colors.grey[500]),
                                          onPressed: () => setState(() => items.removeAt(idx)),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: Text('Annuller',
                                  style: GoogleFonts.kanit(
                                      color: Colors.grey[600], fontWeight: FontWeight.w600)),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: AppColors.onPrimary,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                    borderRadius: AppRadii.smRadius),
                              ),
                              onPressed: () async {
                                final newCategory = PackinglistCategories(
                                  categoryName: categoryNameController.text,
                                  items: items,
                                  iconName: selectedIconName,
                                );

                                if (isEditing) {
                                  await context
                                      .read<GroupInformationRepository>()
                                      .updatePackingListCategory(
                                          groupInfo.groupId, category, newCategory);
                                } else {
                                  await context
                                      .read<GroupInformationRepository>()
                                      .addPackingListCategory(groupInfo.groupId, newCategory);
                                }
                                if (context.mounted) {
                                  context.read<GroupInformationBloc>().add(
                                      LoadGroupInformationById(groupId: groupInfo.groupId));
                                }
                                Navigator.pop(dialogContext);
                              },
                              child: Text('Gem',
                                  style: GoogleFonts.kanit(fontWeight: FontWeight.w700)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _removePackingListCategory(BuildContext context,
      GroupInformation groupInfo, PackinglistCategories category) {
    _showDeleteConfirmDialog(
      context: context,
      title: 'Slet kategori?',
      message:
          'Er du sikker på, du vil slette kategorien "${category.categoryName}"? Handlingen kan ikke fortrydes.',
      onConfirm: () async {
        await context
            .read<GroupInformationRepository>()
            .deletePackingListCategory(groupInfo.groupId, category);
        if (context.mounted) {
          context
              .read<GroupInformationBloc>()
              .add(LoadGroupInformationById(groupId: groupInfo.groupId));
        }
      },
    );
  }

  Widget _buildPackingListPanel(
      BuildContext context, GroupInformation groupInfo) {
    final user = FirebaseAuth.instance.currentUser;
    return Container(
      decoration: _panelDecoration,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              _buildPanelHeader(Icons.checklist, 'Huskeliste'),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 72),
                  itemCount: groupInfo.packinglistCategories.length,
                  itemBuilder: (context, index) {
                    final category = groupInfo.packinglistCategories[index];
                    return _buildDocRow(
                      icon: Icons.check_circle_outline,
                      iconColor: AppColors.primary,
                      title: category.categoryName,
                      onTap: () => _openCategoryDialog(context, category),
                      trailing: ((user?.emailVerified ?? false) && widget.canEditTrips)
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.edit,
                                      size: 18, color: Colors.grey[600]),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () => _showAddEditCategoryDialog(
                                      context,
                                      groupInfo: groupInfo,
                                      category: category),
                                ),
                                const SizedBox(width: AppSpacing.md),
                                IconButton(
                                  icon: const Icon(Icons.delete,
                                      size: 18, color: Colors.redAccent),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () => _removePackingListCategory(
                                      context, groupInfo, category),
                                ),
                              ],
                            )
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
          if ((user?.emailVerified ?? false) && widget.canEditTrips)
            Positioned(
              bottom: 16,
              right: 16,
              child: FloatingActionButton(
                heroTag: 'packinglist_fab_${groupInfo.groupId}',
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    backgroundColor: AppColors.secondary,
                    builder: (sheetContext) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.add),
                          title: const Text('Opret ny'),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _showAddEditCategoryDialog(context,
                                groupInfo: groupInfo);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.library_books),
                          title: const Text('Vælg fra bibliotek'),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _showLibrarySelectionDialog(context, groupInfo);
                          },
                        ),
                      ],
                    ),
                  );
                },
                backgroundColor: AppColors.primary,
                child: Icon(Icons.add, color: AppColors.onPrimary),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showLibrarySelectionDialog(
      BuildContext context, GroupInformation groupInfo) async {
    List<Map<String, dynamic>> library = [];
    try {
      final doc = await FirebaseFirestore.instance
          .collection('agency')
          .doc(groupInfo.agencyCode)
          .get();
      if (doc.exists && doc.data()!.containsKey('packingListLibrary')) {
        library =
            List<Map<String, dynamic>>.from(doc.data()!['packingListLibrary']);
      }
    } catch (e) {
      if (context.mounted) {
        showErrorSnackbar(context, 'Kunne ikke hente bibliotek: ${describeError(e)}');
      }
      return;
    }

    if (!context.mounted) return;

    if (library.isEmpty) {
      showInfoSnackbar(context, 'Biblioteket er tomt');
      return;
    }

    final Set<int> selectedIndices = {};

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Dialog(
              backgroundColor: AppColors.secondary,
              shape: RoundedRectangleBorder(
                  borderRadius: AppRadii.lgRadius),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 500,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xxl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.library_books,
                              color: AppColors.darkGreen, size: 28),
                          const SizedBox(width: AppSpacing.md),
                          Text(
                            'Vælg fra bibliotek',
                            style: GoogleFonts.kanit(
                                fontSize: 22, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Vælg de pakkelister du vil tilføje til rejsen.',
                        style: GoogleFonts.kanit(
                            color: Colors.grey[600], fontSize: 14),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: ListView.separated(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            itemCount: library.length,
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: AppSpacing.sm),
                            itemBuilder: (context, index) {
                              final item = library[index];
                              final isSelected =
                                  selectedIndices.contains(index);
                              return InkWell(
                                onTap: () {
                                  setState(() {
                                    if (isSelected) {
                                      selectedIndices.remove(index);
                                    } else {
                                      selectedIndices.add(index);
                                    }
                                  });
                                },
                                borderRadius: AppRadii.mdRadius,
                                child: Container(
                                  padding: const EdgeInsets.all(AppSpacing.md),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? AppColors.primary.withOpacity(0.05)
                                        : Colors.white,
                                    border: Border.all(
                                      color: isSelected
                                          ? AppColors.darkGreen
                                          : Colors.grey.shade200,
                                      width: isSelected ? 2 : 1,
                                    ),
                                    borderRadius: AppRadii.mdRadius,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? AppColors.primary
                                              : Colors.grey.shade100,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          MdiIcons.fromString(
                                                  item['iconName'] ??
                                                      'mdi-folder') ??
                                              MdiIcons.folder,
                                          color: isSelected
                                              ? AppColors.onPrimary
                                              : Colors.grey.shade600,
                                          size: 20,
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.lg),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item['categoryName'] ??
                                                  'Uden navn',
                                              style: GoogleFonts.kanit(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w500,
                                                color: Colors.black87,
                                              ),
                                            ),
                                            Text(
                                              '${(item['items'] as List?)?.length ?? 0} ting',
                                              style: GoogleFonts.kanit(
                                                fontSize: 12,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isSelected)
                                        Icon(Icons.check_circle,
                                            color: AppColors.darkGreen)
                                      else
                                        Icon(Icons.circle_outlined,
                                            color: Colors.grey.shade300),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: Text('Annuller',
                                style:
                                    GoogleFonts.kanit(color: Colors.grey[700])),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              shape: RoundedRectangleBorder(
                                  borderRadius: AppRadii.mdRadius),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 12),
                              elevation: 2,
                            ),
                            onPressed: selectedIndices.isEmpty
                                ? null
                                : () async {
                                    final repo = context
                                        .read<GroupInformationRepository>();
                                    final bloc =
                                        context.read<GroupInformationBloc>();
                                    Navigator.pop(dialogContext);
                                    final futures = <Future>[];
                                    for (final index in selectedIndices) {
                                      final item = library[index];
                                      final newCategory = PackinglistCategories(
                                        categoryName:
                                            item['categoryName'] ?? 'Ny liste',
                                        items: List<String>.from(
                                            item['items'] ?? []),
                                        iconName:
                                            item['iconName'] ?? 'mdi-folder',
                                      );
                                      futures.add(repo.addPackingListCategory(
                                          groupInfo.groupId, newCategory));
                                    }
                                    await Future.wait(futures);
                                    bloc.add(LoadGroupInformationById(
                                        groupId: groupInfo.groupId));
                                  },
                            child: Text(
                                'Tilføj ${selectedIndices.isNotEmpty ? '(${selectedIndices.length})' : ''}',
                                style: GoogleFonts.kanit(
                                    color: AppColors.onPrimary,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openCategoryDialog(
      BuildContext context, PackinglistCategories category) {
    showDialog(
      context: context,
      builder: (context) {
        final width =
            MediaQuery.of(context).size.width * 0.3; // Matches app layout
        final height = MediaQuery.of(context).size.height * 0.6;

        return Dialog(
          backgroundColor: AppColors.secondary,
          shape:
              RoundedRectangleBorder(borderRadius: AppRadii.smRadius),
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Text(
                    category.categoryName,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w500),
                  ),
                ),
                const Divider(height: 1, thickness: 0.5),
                Expanded(
                  child: ListView.builder(
                    itemCount: category.items.length,
                    itemBuilder: (context, index) {
                      final item = category.items[index];
                      return ListTile(
                        title: Text(
                          item,
                          style: const TextStyle(fontSize: 16),
                        ),
                      );
                    },
                  ),
                ),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Luk',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

void openPdf(BuildContext context, String pdfUrl) {
  // Open the PDF in a new browser tab
  launchUrl(Uri.parse(pdfUrl));

  // Show a snackbar message
  showInfoSnackbar(context, 'PDF opened in a new tab', duration: const Duration(seconds: 3));
}

/// Confirms a document upload — lists every picked PDF with its size so
/// a multi-file pick can be checked before anything is sent.
class _UploadConfirmDialog extends StatelessWidget {
  const _UploadConfirmDialog({required this.files});

  final List<PlatformFile> files;

  static String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final single = files.length == 1;
    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.size);
    return AlertDialog(
      backgroundColor: AppColors.uploadDialogBackground,
      shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
      title: Text(
        single ? 'Upload fil' : 'Upload ${files.length} filer',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        textAlign: TextAlign.center,
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              single
                  ? 'Vil du uploade denne fil?'
                  : 'Vil du uploade disse filer? (${_formatSize(totalBytes)} i alt)',
              style: const TextStyle(fontSize: 15),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.md),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: files.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppSpacing.xs),
                itemBuilder: (context, index) {
                  final file = files[index];
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: AppRadii.smRadius,
                      border: Border.all(color: Colors.grey[200]!),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.picture_as_pdf,
                            size: 22, color: Colors.red),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            file.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(_formatSize(file.size),
                            style: AppTextStyles.caption()),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context, false),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.uploadDialogButton,
              ),
              child: const Text('Annuller', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.uploadDialogButton,
              ),
              child: Text(
                single ? 'Upload' : 'Upload alle',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
