import 'dart:math';

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
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:timeline_tile/timeline_tile.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:backend/widget/timelineeventbox.dart';
import '../../widget/timelineDialog.dart';
import '../../widget/departurebox2.dart';
import '../../widget/returnbox2.dart';
import '../../blocs/groupinformation/groupinformation_bloc.dart';

class HomeScreen extends StatefulWidget {
  static const String routeName = '/home';
  final ScrollController scrollController;

  const HomeScreen({super.key, required this.scrollController});

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
    }
  }

  Future<void> _pickAndUploadDocument(BuildContext context) async {
    if (_currentDocsRef == null) return;
    print("Upload button pressed");

    try {
      // Open file picker to select a PDF
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true,
      );

      if (result != null) {
        String fileName = result.files.single.name;
        final fileBytes = result.files.single.bytes;

        if (!mounted) return;

        final confirmed = await showDialog<bool>(
          // Use the captured context
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              backgroundColor:
                  AppColors.uploadDialogBackground, // Background color
              title: Text(
                "Upload filer",
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.picture_as_pdf, size: 48, color: Colors.red),
                  const SizedBox(height: 10),
                  Text(
                    "Vil du uploade denne fil?",
                    style: const TextStyle(fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    fileName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
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
                      child: Text(
                        "Annuller",
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.uploadDialogButton,
                      ),
                      child: Text(
                        "Upload",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );

        // If user confirms, proceed with upload
        if (confirmed == true) {
          Reference storageRef = _currentDocsRef!.child(fileName);
          if (fileBytes != null) {
            UploadTask uploadTask = storageRef.putData(fileBytes);
            await uploadTask;
            _fetchDocuments(); // Refresh file list
          }
        } else {
          print("Upload canceled.");
        }
      } else {
        print("No file selected.");
      }
    } catch (e) {
      print("Error uploading file: $e");
    }
  }

  Future<void> _createFolder(BuildContext context) async {
    if (_currentDocsRef == null) return;
    String folderName = '';
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogAltBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Opret ny mappe',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.create_new_folder, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'For at oprette en mappe skal du uploade mindst én fil til den.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Mappenavn',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              if (folderName.trim().isNotEmpty) {
                Navigator.pop(context);
                try {
                  FilePickerResult? result =
                      await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['pdf'],
                    withData: true,
                  );

                  if (result != null) {
                    String fileName = result.files.single.name;
                    Reference storageRef = _currentDocsRef!
                        .child(folderName.trim())
                        .child(fileName);

                    if (result.files.single.bytes != null) {
                      UploadTask uploadTask =
                          storageRef.putData(result.files.single.bytes!);
                      await uploadTask;
                      _fetchDocuments();
                    }
                  }
                } catch (e) {
                  print('Error creating folder: $e');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text('Fejl ved oprettelse af mappe: $e')),
                    );
                  }
                }
              }
            },
            child: const Text('Vælg fil & opret'),
          ),
        ],
      ),
    );
  }

  void _navigateToFolder(Reference folder) {
    setState(() {
      _currentDocsRef = folder;
    });
    _fetchDocuments();
  }

  void _navigateBack() {
    if (_currentDocsRef == null || groupId == null) return;
    // Check if we are at the root documents folder
    if (_currentDocsRef!.fullPath == '$groupId/documents') return;

    setState(() {
      _currentDocsRef = _currentDocsRef!.parent;
    });
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
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
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
          const SizedBox(width: 16),
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
          const SizedBox(width: 12),
          _buildHeroChip(Icons.people_outline, '${groupInfo.members.length}'),
          const SizedBox(width: 8),
          _buildHeroChip(Icons.support_agent, '${groupInfo.guides.length}'),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: (isActive ? Colors.orange : AppColors.primary)
                  .withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
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
        borderRadius: BorderRadius.circular(10),
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
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      );

  Widget _buildPanelHeader(IconData icon, String title, {Widget? leading}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Row(
        children: [
          if (leading != null) leading,
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
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
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 18),
        ),
        title: Text(title,
            style: GoogleFonts.kanit(fontWeight: FontWeight.w600, fontSize: 14),
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
      final user = FirebaseAuth.instance.currentUser;

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
                            padding: const EdgeInsets.all(8.0),
                            child: Column(
                              children: [
                                Expanded(
                                    child: _buildMessagesPanel(
                                        context, groupInfo, user)),
                                const SizedBox(height: 8),
                                Expanded(child: _buildGroupPanel(context, groupInfo)),
                              ],
                            ),
                          ),
                        ),
                        Flexible(
                          flex: 2,
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Column(
                              children: [
                                Expanded(
                                    child: _buildDocumentsPanel(context, groupInfo)),
                                const SizedBox(height: 8),
                                Expanded(
                                    child:
                                        _buildPackingListPanel(context, groupInfo)),
                              ],
                            ),
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
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  children: [
                    _buildHeroHeader(groupInfo),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 300,
                      child: _buildMessagesPanel(context, groupInfo, user),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 300,
                      child: _buildGroupPanel(context, groupInfo),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 300,
                      child: _buildDocumentsPanel(context, groupInfo),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 300,
                      child: _buildPackingListPanel(context, groupInfo),
                    ),
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

  // --- TIMELINE ---
  Widget _buildTimeline(BuildContext context, GroupInformation groupInfo,
      List<dynamic> sortableEvents) {
    final user = FirebaseAuth.instance.currentUser;
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: _panelDecoration,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              _buildPanelHeader(Icons.timeline, 'Rejseforløb'),
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
        if (user?.emailVerified ?? false)
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
                          padding: const EdgeInsets.all(12),
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
                                  if (user?.emailVerified ?? false)
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
                                        const SizedBox(width: 12),
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
            child: FloatingActionButton(
              heroTag: 'messages_fab_${groupInfo.groupId}',
              onPressed: () => _showCreateMessageDialog(context, groupInfo),
              backgroundColor: AppColors.primary,
              child: Icon(Icons.add, color: AppColors.onPrimary),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dokument slettet.')),
      );
      _fetchDocuments(); // Refresh the list
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fejl ved sletning af dokument: $e')),
      );
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Mappe slettet.')),
                    );
                  }
                  _fetchDocuments(); // Refresh the list
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Fejl ved sletning af mappe: $e')),
                    );
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
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Mappe omdøbt.')),
                      );
                    }
                    _fetchDocuments();
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text('Fejl ved omdøbning af mappe: $e')),
                      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fejl ved hentning af dokumenter: $e')),
        );
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
                              trailing: (user?.emailVerified ?? false)
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
                                        const SizedBox(width: 12),
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
                              trailing: (user?.emailVerified ?? false)
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
          if (user?.emailVerified ?? false)
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
      BuildContext context, GroupInformation groupInfo) {
    String title = '', content = '';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogAltBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Ny besked', style: const TextStyle(fontSize: 21)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(hintText: 'Titel'),
              onChanged: (v) => title = v,
            ),
            TextField(
              decoration: const InputDecoration(hintText: 'Besked'),
              onChanged: (v) => content = v,
              maxLines: null,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuller')),
          ElevatedButton(
            onPressed: () {
              if (title.isNotEmpty && content.isNotEmpty) {
                final admin = FirebaseAuth.instance.currentUser;
                context.read<GroupInformationRepository>().createMessage(
                      groupInfo.groupId,
                      title,
                      content,
                      admin?.uid ?? 'admin',
                      admin?.displayName ?? admin?.email ?? 'Admin',
                      isAdmin: true,
                      bureauName: groupInfo.bureauName,
                    );
                Navigator.pop(context);
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  void _showEditMessageDialog(
      BuildContext context, GroupInformation groupInfo, Message message) {
    String title = message.title;
    String content = message.content;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogAltBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Rediger besked', style: const TextStyle(fontSize: 21)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(hintText: 'Titel'),
              controller: TextEditingController(text: title),
              onChanged: (v) => title = v,
            ),
            TextField(
              decoration: const InputDecoration(hintText: 'Besked'),
              controller: TextEditingController(text: content),
              onChanged: (v) => content = v,
              maxLines: null,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuller')),
          ElevatedButton(
            onPressed: () {
              if (title.isNotEmpty && content.isNotEmpty) {
                context.read<GroupInformationRepository>().updateMessage(
                      groupInfo.groupId, // This was missing
                      message.id,
                      title,
                      content,
                    );
                Navigator.pop(context);
              }
            },
            child: const Text('Gem'),
          ),
        ],
      ),
    );
  }

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

  void _showEmailComposer(BuildContext context, GroupInformation groupInfo,
      String bureauName, String bureauEmail, List<Reference> allDocuments) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Du skal være logget ind for at sende e-mail')),
      );
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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scrollController) => StatefulBuilder(
          builder: (context, setState) => Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              children: [
                // HEADER
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Text(
                        "Ny e-mail",
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w500),
                      ),
                      IconButton(
                        icon: Icon(Icons.send, color: AppColors.darkGreen),
                        onPressed: () async {
                          if (selectedEmails.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Vælg mindst én modtager')),
                            );
                            return;
                          }

                          if (subjectController.text.trim().isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Emne mangler')),
                            );
                            return;
                          }

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

                          try {
                            await user.getIdToken(true);

                            final functions = FirebaseFunctions.instanceFor(
                              region: 'europe-west1',
                            );

                            final callable =
                                functions.httpsCallable('sendGroupEmail');

                            await callable.call({
                              'to': selectedEmails,
                              'subject': subjectController.text.trim(),
                              'html': bodyController.text
                                      .trim()
                                      .replaceAll('\n', '<br>') +
                                  documentLinksHtml,
                              'fromName': fromNameController.text.trim(),
                              'replyTo': replyToController.text.trim(),
                            });

                            if (!context.mounted) return;

                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('E-mail sendt')),
                            );
                          } on FirebaseFunctionsException catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(
                                      e.message ?? 'Kunne ikke sende e-mail')),
                            );
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Fejl: $e')),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),

                const Divider(),

                // CONTENT
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      // FROM
                      const Text("Fra", style: TextStyle(color: Colors.grey)),
                      TextField(
                        controller: fromNameController,
                        decoration: const InputDecoration(
                            labelText: 'Navn (vises som afsender)'),
                      ),

                      const Divider(),

                      // REPLY-TO
                      const Text("Svar til",
                          style: TextStyle(color: Colors.grey)),
                      TextField(
                        controller: replyToController,
                        decoration: const InputDecoration(
                            labelText: 'E-mail (svar vil gå til denne)'),
                        keyboardType: TextInputType.emailAddress,
                      ),

                      const Divider(),

                      // TO
                      InkWell(
                        onTap: () async {
                          final result = await showDialog<List<String>>(
                            context: context,
                            builder: (context) {
                              List<String> tempSelected =
                                  List.from(selectedEmails);

                              return StatefulBuilder(
                                builder: (context, setDialogState) {
                                  return AlertDialog(
                                    title: const Text('Vælg modtagere'),
                                    content: SizedBox(
                                      width: 400,
                                      child: ListView.builder(
                                        shrinkWrap: true,
                                        itemCount: allMembersWithEmail.length,
                                        itemBuilder: (context, index) {
                                          final member =
                                              allMembersWithEmail[index];
                                          final isSelected = tempSelected
                                              .contains(member.email);

                                          return CheckboxListTile(
                                            title: Text(member.name),
                                            subtitle: Text(member.email),
                                            value: isSelected,
                                            onChanged: (value) {
                                              setDialogState(() {
                                                value == true
                                                    ? tempSelected
                                                        .add(member.email)
                                                    : tempSelected
                                                        .remove(member.email);
                                              });
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Annuller'),
                                      ),
                                      ElevatedButton(
                                        onPressed: () => Navigator.pop(
                                            context, tempSelected),
                                        child: const Text('OK'),
                                      ),
                                    ],
                                  );
                                },
                              );
                            },
                          );

                          if (result != null && context.mounted) {
                            setState(() => selectedEmails = result);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              const Text("Til:",
                                  style: TextStyle(
                                      color: Colors.grey, fontSize: 16)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  selectedEmails.isEmpty
                                      ? 'Ingen modtagere'
                                      : selectedEmails.join(', '),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Icon(Icons.arrow_drop_down),
                            ],
                          ),
                        ),
                      ),

                      const Divider(height: 1),

                      // ATTACHMENTS
                      InkWell(
                        onTap: () async {
                          final result = await showDialog<List<Reference>>(
                            context: context,
                            builder: (context) {
                              List<Reference> tempSelected =
                                  List.from(selectedDocuments);

                              return StatefulBuilder(
                                builder: (context, setDialogState) {
                                  return AlertDialog(
                                    title: const Text('Vælg dokumenter'),
                                    content: SizedBox(
                                      width: 400,
                                      child: allDocuments.isEmpty
                                          ? const Center(
                                              child: Text(
                                                  'Ingen dokumenter fundet.'))
                                          : ListView.builder(
                                              shrinkWrap: true,
                                              itemCount: allDocuments.length,
                                              itemBuilder: (context, index) {
                                                final doc = allDocuments[index];
                                                final isSelected =
                                                    tempSelected.any((d) =>
                                                        d.fullPath ==
                                                        doc.fullPath);

                                                return CheckboxListTile(
                                                  title: Text(doc.name,
                                                      overflow: TextOverflow
                                                          .ellipsis),
                                                  subtitle: Text(
                                                    doc.fullPath
                                                        .replaceFirst(
                                                            '${groupInfo.groupId}/documents/',
                                                            '')
                                                        .replaceFirst(
                                                            '/${doc.name}', ''),
                                                    style: const TextStyle(
                                                        color: Colors.grey,
                                                        fontSize: 12),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  value: isSelected,
                                                  onChanged: (value) {
                                                    setDialogState(() {
                                                      if (value == true) {
                                                        tempSelected.add(doc);
                                                      } else {
                                                        tempSelected
                                                            .removeWhere((d) =>
                                                                d.fullPath ==
                                                                doc.fullPath);
                                                      }
                                                    });
                                                  },
                                                );
                                              },
                                            ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Annuller'),
                                      ),
                                      ElevatedButton(
                                        onPressed: () => Navigator.pop(
                                            context, tempSelected),
                                        child: const Text('OK'),
                                      ),
                                    ],
                                  );
                                },
                              );
                            },
                          );

                          if (result != null && context.mounted) {
                            setState(() => selectedDocuments = result);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              const Icon(Icons.attach_file, color: Colors.grey),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  selectedDocuments.isEmpty
                                      ? 'Vedhæft dokumenter (som links)'
                                      : selectedDocuments
                                          .map((d) => d.name)
                                          .join(', '),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Icon(Icons.arrow_drop_down),
                            ],
                          ),
                        ),
                      ),

                      const Divider(height: 1),

                      // SUBJECT
                      TextField(
                        controller: subjectController,
                        decoration: const InputDecoration(
                          hintText: 'Emne',
                          border: InputBorder.none,
                        ),
                      ),

                      const Divider(height: 1),

                      // IMAGE INSERTION

                      const Divider(height: 1),

                      // BODY
                      TextField(
                        controller: bodyController,
                        decoration: const InputDecoration(
                          hintText: 'Skriv e-mail',
                          border: InputBorder.none,
                        ),
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
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
            padding: const EdgeInsets.all(16.0),
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
              subtitle: 'Tel: ${groupInfo.guides[i].phoneNumber}',
              trailing:
                  (FirebaseAuth.instance.currentUser?.emailVerified ?? false)
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
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              icon: const Icon(Icons.delete,
                                  size: 18, color: Colors.redAccent),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _removeGuide(
                                  context, groupInfo, groupInfo.guides[i]),
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

  void _showAddEditGuideDialog(BuildContext context,
      {required GroupInformation groupInfo, Guide? guide}) {
    final isEditing = guide != null;
    String name = guide?.name ?? '';
    String phone = guide?.phoneNumber.toString() ?? '';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isEditing ? 'Rediger guide' : 'Tilføj guide'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: TextEditingController(text: name),
                decoration: const InputDecoration(labelText: 'Navn'),
                onChanged: (v) => name = v),
            TextField(
                controller: TextEditingController(text: phone),
                decoration: const InputDecoration(labelText: 'Telefonnummer'),
                keyboardType: TextInputType.phone,
                onChanged: (v) => phone = v),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuller')),
          ElevatedButton(
            onPressed: () {
              final newGuide = Guide(
                name: name,
                phoneNumber: int.tryParse(phone) ?? 0,
              );
              if (isEditing) {
                context
                    .read<GroupInformationRepository>()
                    .updateGuide(groupInfo.groupId, guide, newGuide);
              } else {
                context
                    .read<GroupInformationRepository>()
                    .addGuide(groupInfo.groupId, newGuide);
              }
              Navigator.pop(context);
            },
            child: const Text('Gem'),
          ),
        ],
      ),
    );
  }

  void _removeGuide(
      BuildContext context, GroupInformation groupInfo, Guide guide) {
    context
        .read<GroupInformationRepository>()
        .deleteGuide(groupInfo.groupId, guide);
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
              subtitle: groupInfo.members[i].email.isNotEmpty
                  ? groupInfo.members[i].email
                  : 'No email',
              trailing:
                  (FirebaseAuth.instance.currentUser?.emailVerified ?? false)
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            (groupInfo.members[i].fcmToken != null &&
                                    groupInfo.members[i].fcmToken!.isNotEmpty)
                                ? const Icon(Icons.smartphone_outlined,
                                    size: 18, color: Color.fromARGB(255, 0, 111, 4))
                                : const Icon(Icons.phonelink_erase,
                                    size: 18, color: Color.fromARGB(255, 255, 82, 2)),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: Icon(Icons.edit,
                                  size: 18, color: Colors.grey[600]),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _showAddEditMemberDialog(
                                context,
                                groupInfo: groupInfo,
                                member: groupInfo.members[i],
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              icon: const Icon(Icons.delete,
                                  size: 18, color: Colors.redAccent),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _removeMember(
                                  context, groupInfo, groupInfo.members[i]),
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
      {required GroupInformation groupInfo, GroupMember? member}) {
    final isEditing = member != null;
    String name = member?.name ?? '';
    String email = member?.email ?? '';
    String phone = member?.phoneNumber.toString() ?? '';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isEditing ? 'Rediger medlem' : 'Tilføj medlem'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: TextEditingController(text: name),
                decoration: const InputDecoration(labelText: 'Navn'),
                onChanged: (v) => name = v),
            TextField(
                controller: TextEditingController(text: email),
                decoration: const InputDecoration(labelText: 'Email'),
                onChanged: (v) => email = v),
            TextField(
                controller: TextEditingController(text: phone),
                decoration: const InputDecoration(labelText: 'Telefonnummer'),
                keyboardType: TextInputType.phone,
                onChanged: (v) => phone = v),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuller')),
          ElevatedButton(
            onPressed: () async {
              final newMember = GroupMember(
                name: name,
                email: email,
                phoneNumber: int.tryParse(phone) ?? 0,
              );
              if (isEditing) {
                await context
                    .read<GroupInformationRepository>()
                    .updateMember(groupInfo.groupId, member, newMember);
              } else {
                if (email.isNotEmpty) {
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
                      email: email,
                      password: generatedPassword,
                    );
                    await userCredential.user?.updateDisplayName(name);
                  } on FirebaseAuthException catch (e) {
                    if (!context.mounted) return;
                    if (e.code == 'email-already-in-use') {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text(
                              'Brugeren findes allerede og tilføjes til gruppen.')));
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                              'Fejl ved oprettelse af bruger: ${e.message}')));
                      return; // Stop if user creation fails
                    }
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('En uventet fejl opstod: $e')));
                    return; // Stop on other errors
                  } finally {
                    await tempApp?.delete();
                  }
                }
                // Add member to Firestore group only if auth creation was successful (or no email was provided)
                if (context.mounted) {
                  await context
                      .read<GroupInformationRepository>()
                      .addMember(groupInfo.groupId, newMember);
                }
              }
              if (context.mounted) {
                // This will run for edits and successful adds
                context
                    .read<GroupInformationBloc>()
                    .add(LoadGroupInformationById(groupId: groupInfo.groupId));
                Navigator.pop(context);
              }
            },
            child: const Text('Gem'),
          ),
        ],
      ),
    );
  }

  void _removeMember(
      BuildContext context, GroupInformation groupInfo, GroupMember member) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Slet medlem?'),
          content: Text(
              'Er du sikker på, du vil slette "${member.name}"? Handlingen kan ikke fortrydes.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Annuller'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Slet'),
              onPressed: () async {
                await context
                    .read<GroupInformationRepository>()
                    .deleteMember(groupInfo.groupId, member);
                if (context.mounted) {
                  context.read<GroupInformationBloc>().add(
                      LoadGroupInformationById(groupId: groupInfo.groupId));
                  Navigator.of(dialogContext).pop();
                }
              },
            ),
          ],
        );
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

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            void addItem() {
              final itemController = TextEditingController();
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Tilføj emne'),
                  content: TextField(
                    controller: itemController,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Emne'),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Annuller')),
                    ElevatedButton(
                        onPressed: () {
                          if (itemController.text.isNotEmpty) {
                            setState(() => items.add(itemController.text));
                            Navigator.pop(context);
                          }
                        },
                        child: const Text('Tilføj')),
                  ],
                ),
              );
            }

            void pickIcon() {
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
                context: context,
                builder: (iconDialogContext) => Dialog(
                  backgroundColor: AppColors.iconPickerDialog,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20.0)),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.7,
                      maxWidth: MediaQuery.of(context).size.width * 0.4,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('Vælg ikon',
                              style: TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center),
                          const SizedBox(height: 20),
                          Expanded(
                            child: GridView.builder(
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 4,
                                      crossAxisSpacing: 12,
                                      mainAxisSpacing: 12),
                              itemCount: mdiIcons.length,
                              itemBuilder: (context, index) {
                                final entry = mdiIcons.entries.elementAt(index);
                                final isSelected =
                                    entry.key == selectedIconName;
                                return InkWell(
                                  onTap: () {
                                    setState(
                                        () => selectedIconName = entry.key);
                                    Navigator.pop(iconDialogContext);
                                  },
                                  child: Container(
                                    decoration: BoxDecoration(
                                        color: isSelected
                                            ? Colors.brown[400]
                                            : Colors.brown[100],
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    child: Icon(entry.value,
                                        size: 36,
                                        color: isSelected
                                            ? Colors.white
                                            : Colors.black87),
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

            return AlertDialog(
              backgroundColor: AppColors.dialogAltBackground,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: Text(isEditing ? 'Rediger Kategori' : 'Ny Kategori'),
              content: SizedBox(
                width: MediaQuery.of(context).size.width * 0.3,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Category Name
                    TextField(
                      controller: categoryNameController,
                      decoration:
                          const InputDecoration(labelText: 'Kategorinavn'),
                    ),
                    const SizedBox(height: 16),

                    // Icon Picker Row
                    Row(
                      children: [
                        const Text('Ikon:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 12),
                        IconButton(
                          icon: Icon(MdiIcons.fromString(selectedIconName) ??
                              MdiIcons.folder),
                          onPressed: pickIcon,
                          tooltip: 'Vælg ikon',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Items List
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Emner',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        IconButton(
                            icon: const Icon(Icons.add_circle),
                            onPressed: addItem),
                      ],
                    ),
                    Expanded(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          return ListTile(
                            title: Text(items[index]),
                            trailing: IconButton(
                              icon: const Icon(Icons.remove_circle_outline,
                                  color: Colors.red),
                              onPressed: () =>
                                  setState(() => items.removeAt(index)),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Annuller')),
                ElevatedButton(
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
                          .addPackingListCategory(
                              groupInfo.groupId, newCategory);
                    }
                    if (context.mounted) {
                      context.read<GroupInformationBloc>().add(
                          LoadGroupInformationById(groupId: groupInfo.groupId));
                    }
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('Gem'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _removePackingListCategory(BuildContext context,
      GroupInformation groupInfo, PackinglistCategories category) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Slet Kategori?'),
        content: Text(
            'Er du sikker på, du vil slette kategorien "${category.categoryName}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuller')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              await context
                  .read<GroupInformationRepository>()
                  .deletePackingListCategory(groupInfo.groupId, category);
              if (context.mounted) {
                context
                    .read<GroupInformationBloc>()
                    .add(LoadGroupInformationById(groupId: groupInfo.groupId));
              }
              Navigator.pop(dialogContext);
            },
            child: const Text('Slet', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
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
                      trailing: (user?.emailVerified ?? false)
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
                                const SizedBox(width: 12),
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
          if (user?.emailVerified ?? false)
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
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Kunne ikke hente bibliotek: $e')));
      }
      return;
    }

    if (!context.mounted) return;

    if (library.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Biblioteket er tomt')));
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
                  borderRadius: BorderRadius.circular(20)),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 500,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.library_books,
                              color: AppColors.darkGreen, size: 28),
                          const SizedBox(width: 12),
                          Text(
                            'Vælg fra bibliotek',
                            style: GoogleFonts.kanit(
                                fontSize: 22, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Vælg de pakkelister du vil tilføje til rejsen.',
                        style: GoogleFonts.kanit(
                            color: Colors.grey[600], fontSize: 14),
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: library.length,
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: 8),
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
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.all(12),
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
                                    borderRadius: BorderRadius.circular(12),
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
                                      const SizedBox(width: 16),
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
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: Text('Annuller',
                                style:
                                    GoogleFonts.kanit(color: Colors.grey[700])),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
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
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
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
                    padding: const EdgeInsets.all(8.0),
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
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('PDF opened in a new tab'),
      duration: Duration(seconds: 3),
    ),
  );
}
