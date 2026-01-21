import 'dart:io';
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
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timeline_tile/timeline_tile.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:backend/widget/agencyLogo.dart';
import 'package:backend/widget/timelineeventbox.dart';
import '../../blocs/groupinformation/groupinformation_bloc.dart';
import '../../widget/timelineDialog.dart';
import '../../widget/departurebox2.dart';
import '../../widget/returnbox2.dart';

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
      if (currentState is! GroupInformationLoaded || currentState.groupInformation.groupId != groupId) {
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
      final doc = await FirebaseFirestore.instance.collection('agency').doc(agencyCode).get();
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
        final pdfFiles = listResult.items.where((ref) => !ref.name.startsWith('.')).toList();
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
                backgroundColor: AppColors.uploadDialogBackground, // Background color
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
          UploadTask uploadTask;
          if (kIsWeb) {
            uploadTask = storageRef.putData(fileBytes!);
          } else {
            final filePath = result.files.single.path;
            uploadTask = storageRef.putFile(File(filePath!));
          }
          await uploadTask;

          String downloadUrl = await storageRef.getDownloadURL();
          print("File uploaded successfully! URL: $downloadUrl");

          _fetchDocuments(); // Refresh file list
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
        title: const Text('Ny mappe'),
        content: TextField(
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Mappenavn'),
          onChanged: (value) => folderName = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuller'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (folderName.trim().isNotEmpty) {
                try {
                  // Create a placeholder file to "create" the folder
                  await _currentDocsRef!
                      .child(folderName.trim())
                      .child('.keep')
                      .putString('');
                  if (mounted) Navigator.pop(context);
                  _fetchDocuments();
                } catch (e) {
                  print('Error creating folder: $e');
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Fejl ved oprettelse af mappe: $e')),
                  );
                }
              }
            },
            child: const Text('Opret'),
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
          _updateAgencyColor(state.groupInformation.agencyCode);
        }
      },
      child: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.homeGradientStart,
            AppColors.scaffoldGradientEnd,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, 0.45],
        ),
      ),
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: AppColors.navActive,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: BlocBuilder<GroupInformationBloc, GroupInformationState>(
            builder: (context, state) {
              if (state is GroupInformationLoaded) {
                return Padding(
                  padding: const EdgeInsets.only(top: 20, bottom: 10),
                  child: SizedBox(
                    height: 80,
                    child: Hero(
                      tag: 'agencyLogo_${state.groupInformation.groupId}', // Unique tag
                      child: AgencyLogo(
                          agencyCode: state.groupInformation.agencyCode),
                    ),
                  ),
                );
              }
              // Fallback while loading
              return const SizedBox.shrink();
            },
          ),
          centerTitle: true, // keep it centered
        ),
        backgroundColor: Colors.transparent,
        body: BlocBuilder<GroupInformationBloc, GroupInformationState>(
          builder: (context, state) {
            if (state is GroupInformationLoading) {
              return const Center(child: CircularProgressIndicator());
            } else if (state is GroupInformationLoaded) {
              final groupInfo = state.groupInformation;
              final user = FirebaseAuth.instance.currentUser;

              // Merge events and flights into a single timeline list
              final List<dynamic> sortableEvents = [
                ...groupInfo.timelineEvents.map(
                    (e) => {'date': e.startDate, 'item': e, 'type': 'event'}),
                ...(groupInfo.flights ?? []).map(
                    (f) => {'date': f.flightDate, 'item': f, 'type': 'flight'}),
              ]..sort((a, b) => a['date'].compareTo(b['date']));

              sortableEvents.insert(0, {
                'date': groupInfo.departureDate,
                'item': groupInfo,
                'type': 'departure'
              });
              sortableEvents.add({
                'date': groupInfo.returnDate,
                'item': groupInfo,
                'type': 'return'
              });

              return LayoutBuilder(
  builder: (context, constraints) {
    final isNarrow = constraints.maxWidth < 1000; // adjust breakpoint

    if (!isNarrow) {
      // --- Wide screen layout ---
      return SafeArea(
        child: Row(
          children: [
            Flexible(
              flex: 3, // Timeline takes more space
              child: _buildTimeline(context, groupInfo, sortableEvents),
            ),
            Flexible(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  children: [
                    Expanded(child: _buildMessagesPanel(context, groupInfo, user)),
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
                    Expanded(child: _buildDocumentsPanel(context, groupInfo)),
                    const SizedBox(height: 8),
                    Expanded(child: _buildPackingListPanel(context, groupInfo)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      // --- Narrow / mobile layout ---
return SafeArea(
  child: SingleChildScrollView(
    controller: widget.scrollController,
    padding: const EdgeInsets.all(8.0),
    child: Column(
      children: [
        SizedBox(
          height: 300, // or adjust to your preferred panel height
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
          },
        ),
      ),
    ),
    );
  }

  // --- TIMELINE ---
  Widget _buildTimeline(BuildContext context, GroupInformation groupInfo,
      List<dynamic> sortableEvents) {
    final user = FirebaseAuth.instance.currentUser;
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: ListView.builder(
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
                      color: (itemData['type'] == 'departure' || itemData['type'] == 'return')
                          ? Colors.transparent
                          : Colors.black,
                      width: (itemData['type'] == 'departure' || itemData['type'] == 'return') ? 35 : 7,
                      iconStyle: (itemData['type'] == 'departure' || itemData['type'] == 'return')
                          ? IconStyle(
                              color: Colors.black,
                              fontSize: 20,
                              iconData: itemData['type'] == 'departure' ? Icons.flight_takeoff : Icons.flight_land,
                            )
                          : null,
                    ),
                    beforeLineStyle: const LineStyle(thickness: 2, color: Colors.black),
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
                  context.read<GroupInformationBloc>().add(LoadGroupInformationById(groupId: groupInfo.groupId));
                }
              },
              backgroundColor: AppColors.primary,
              child: const Icon(Icons.add, color: Colors.white),
            ),
          ),
      ],
    );
  }

  // --- TIMELINE ---

  // --- MESSAGES PANEL ---
  Widget _buildMessagesPanel(
      BuildContext context, GroupInformation groupInfo, User? user) {
    return Card(
      elevation: 10,
      color: AppColors.panelBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias, // Important for FAB to be contained
      child: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Beskeder',
                        style: const TextStyle(
                            fontSize: 21, fontWeight: FontWeight.w300)),
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 0.5),
              Expanded(
                child: StreamBuilder<List<Message>>(
                  stream: _messagesStream,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final messages = snapshot.data ?? [];
                    if (messages.isEmpty) {
                      return const Center(child: Text('Ingen beskeder.'));
                    }

                    return ListView.builder(
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final msg = messages[index];
                        return ListTile(
                          title: Text(msg.title,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(msg.content,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              if (msg.timestamp != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  DateFormat('dd/MM/yyyy HH:mm').format(msg.timestamp!),
                                  style: const TextStyle(fontSize: 12, color: Color.fromARGB(255, 0, 0, 0)),
                                ),
                              ],
                            ],
                          ),
                          trailing: (user?.emailVerified ?? false)
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit,
                                          color: Colors.black),
                                      onPressed: () => _showEditMessageDialog(
                                          context, groupInfo, msg),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete,
                                          color: Colors.red),
                                      onPressed: () => _removeMessage(
                                          context, groupInfo.groupId, msg),
                                    ),
                                  ],
                                )
                              : null,
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
              child: const Icon(Icons.add, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteDocumentConfirmationDialog(BuildContext context, Reference pdfFile) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Slet dokument?'),
          content: Text('Er du sikker på, du vil slette "${pdfFile.name}"? Handlingen kan ikke fortrydes.'),
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

  void _showDeleteFolderConfirmationDialog(BuildContext context, Reference folder) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Slet mappe?'),
          content: Text('Er du sikker på, du vil slette mappen "${folder.name}" og alt dens indhold? Handlingen kan ikke fortrydes.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Annuller'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Slet'),
              onPressed: () async {
                Navigator.of(dialogContext).pop(); // Close dialog before async operation
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

  Future<void> _moveFolderContents(Reference source, Reference destination) async {
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuller')),
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
                        SnackBar(content: Text('Fejl ved omdøbning af mappe: $e')),
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
      allFiles.addAll(listResult.items.where((ref) => !ref.name.startsWith('.')));

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
    final isRoot = _currentDocsRef?.fullPath == '${groupInfo.groupId}/documents';

    return Card(
      elevation: 10,
      color: AppColors.panelBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    if (!isRoot)
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: _navigateBack,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    if (!isRoot) const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isRoot ? 'Dokumenter' : _currentDocsRef?.name ?? 'Dokumenter',
                        style: const TextStyle(
                            fontSize: 21, fontWeight: FontWeight.w300),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 0.5),
              Expanded(
                child: _currentFiles.isEmpty && _currentFolders.isEmpty
                    ? const Center(child: Text('Tom mappe.'))
                    : ListView.builder(
                        itemCount: _currentFolders.length + _currentFiles.length,
                        itemBuilder: (context, index) {
                          if (index < _currentFolders.length) {
                            // Folder Item
                            final folder = _currentFolders[index];
                            return ListTile(
                              leading: Icon(Icons.folder,
                                  color: AppColors.primary),
                              title: Text(folder.name,
                                  overflow: TextOverflow.ellipsis),
                              onTap: () => _navigateToFolder(folder),
                              trailing: (user?.emailVerified ?? false)
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.edit, color: Colors.black),
                                          onPressed: () => _showRenameFolderDialog(context, folder),
                                          tooltip: 'Omdøb mappe',
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete, color: Colors.red),
                                          onPressed: () => _showDeleteFolderConfirmationDialog(context, folder),
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
                            return ListTile(
                              leading: const Icon(Icons.picture_as_pdf,
                                  color: Colors.red),
                              title: Text(pdfFile.name,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: metadata?.timeCreated != null
                                  ? Text(
                                      DateFormat('dd/MM/yyyy HH:mm')
                                          .format(metadata!.timeCreated!),
                                      style: const TextStyle(
                                          fontSize: 12, color: Color.fromARGB(255, 0, 0, 0)),
                                    )
                                  : null,
                              onTap: () async {
                                String downloadURL =
                                    await pdfFile.getDownloadURL();
                                openPdf(context, downloadURL);
                              },
                              trailing: (user?.emailVerified ?? false)
                                  ? IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red),
                                      onPressed: () => _showDeleteDocumentConfirmationDialog(context, pdfFile),
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
                child: const Icon(Icons.add, color: Colors.white),
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
                context.read<GroupInformationRepository>().createMessage(
                      groupInfo.groupId,
                      title,
                      content,
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
      const SnackBar(content: Text('Du skal være logget ind for at sende e-mail')),
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
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                    ),
                    IconButton(
                      icon: Icon(Icons.send,
                          color: AppColors.primary),
                      onPressed: () async {
                        if (selectedEmails.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Vælg mindst én modtager')),
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

                          final callable = functions.httpsCallable('sendGroupEmail');

                          await callable.call({
                            'to': selectedEmails,
                            'subject': subjectController.text.trim(),
                            'html': bodyController.text.trim().replaceAll('\n', '<br>') +
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
                            SnackBar(content: Text(e.message ?? 'Kunne ikke sende e-mail')),
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
                      decoration: const InputDecoration(labelText: 'Navn (vises som afsender)'),
                    ),

                    const Divider(),

                    // REPLY-TO
                    const Text("Svar til", style: TextStyle(color: Colors.grey)),
                    TextField(
                      controller: replyToController,
                      decoration: const InputDecoration(labelText: 'E-mail (svar vil gå til denne)'),
                      keyboardType: TextInputType.emailAddress,
                    ),

                    const Divider(),

                    // TO
                    InkWell(
                      onTap: () async {
                        final result = await showDialog<List<String>>(
                          context: context,
                          builder: (context) {
                            List<String> tempSelected = List.from(selectedEmails);

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
                                        final member = allMembersWithEmail[index];
                                        final isSelected = tempSelected.contains(member.email);

                                        return CheckboxListTile(
                                          title: Text(member.name),
                                          subtitle: Text(member.email),
                                          value: isSelected,
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
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Annuller'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(context, tempSelected),
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
                            const Text("Til:", style: TextStyle(color: Colors.grey, fontSize: 16)),
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
                                            child:
                                                Text('Ingen dokumenter fundet.'))
                                        : ListView.builder(
                                            shrinkWrap: true,
                                            itemCount: allDocuments.length,
                                            itemBuilder: (context, index) {
                                              final doc = allDocuments[index];
                                              final isSelected = tempSelected.any(
                                                  (d) => d.fullPath == doc.fullPath);

                                              return CheckboxListTile(
                                                title: Text(doc.name,
                                                    overflow:
                                                        TextOverflow.ellipsis),
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
                                                      tempSelected.removeWhere((d) =>
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
                                      onPressed: () =>
                                          Navigator.pop(context, tempSelected),
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
    return Card(
      elevation: 10,
      color: AppColors.panelBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: DefaultTabController(
        length: 2,
        child: Stack(
          children: [
            Column(
              children: [
                const TabBar(
                  indicatorColor: Colors.black87,
                  labelColor: Colors.black,
                  unselectedLabelColor: Colors.grey,
                  tabs: [Tab(text: 'Gruppemedlemmer'), Tab(text: 'Guides')],
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
                    _showEmailComposer(context, groupInfo,
                        groupInfo.bureauName, user?.email ?? '', allDocuments);
                  }
                },
                backgroundColor: AppColors.primary,
                icon: const Icon(Icons.email, color: Colors.white),
                label: Text(
                  "Send e-mail",
                  style: const TextStyle(color: Colors.white),
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
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: groupInfo.guides.length,
            itemBuilder: (context, i) => ListTile(
              leading: const Icon(Icons.support_agent),
              title: Text(groupInfo.guides[i].name),
              subtitle: Text('Tel: ${groupInfo.guides[i].phoneNumber}'),
              trailing: (FirebaseAuth.instance.currentUser?.emailVerified ??
                      false)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, color: Colors.black),
                          onPressed: () => _showAddEditGuideDialog(
                            context,
                            groupInfo: groupInfo,
                            guide: groupInfo.guides[i],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
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
              child: const Icon(
                Icons.add,
                color: Colors.white,
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
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: groupInfo.members.length,
            itemBuilder: (context, i) => ListTile(
              leading: const Icon(Icons.group_outlined),
              title: Text(groupInfo.members[i].name),
              subtitle: Text(
                groupInfo.members[i].email.isNotEmpty
                    ? groupInfo.members[i].email
                    : 'No email',
              ),
              trailing: (FirebaseAuth.instance.currentUser?.emailVerified ??
                      false)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        (groupInfo.members[i].fcmToken != null &&
                                groupInfo.members[i].fcmToken!.isNotEmpty)
                            ? const Icon(Icons.smartphone_outlined, color: Color.fromARGB(255, 0, 111, 4))
                            : const Icon(Icons.phonelink_erase, color: Color.fromARGB(255, 255, 82, 2)),
                        IconButton(
                          icon: const Icon(Icons.edit, color: Colors.black),
                          onPressed: () => _showAddEditMemberDialog(
                            context,
                            groupInfo: groupInfo,
                            member: groupInfo.members[i],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
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
              child: const Icon(
                Icons.add,
                color: Colors.white,
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
                  try {
                    FirebaseApp tempApp = await Firebase.initializeApp(
                      name:
                          'tempAuthApp_${DateTime.now().millisecondsSinceEpoch}',
                      options: Firebase.app().options,
                    );
                    try {
                      final generatedPassword = _generateRandomPassword();
                      UserCredential userCredential =
                          await FirebaseAuth.instanceFor(app: tempApp)
                              .createUserWithEmailAndPassword(
                        email: email,
                        password: generatedPassword,
                      );
                      await userCredential.user?.updateDisplayName(name);
                    } catch (e) {
                      print('Error creating user: $e');
                    } finally {
                      await tempApp.delete();
                    }
                  } catch (e) {
                    print('Error initializing temp app: $e');
                  }
                }
                if (context.mounted) {
                  await context
                      .read<GroupInformationRepository>()
                      .addMember(groupInfo.groupId, newMember);
                }
              }
              if (context.mounted) {
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
  final List<String> items = isEditing ? List<String>.from(category.items) : [];

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
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20.0)),
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
                        const Text('Vælg ikon', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                        const SizedBox(height: 20),
                        Expanded(
                          child: GridView.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 12, mainAxisSpacing: 12),
                            itemCount: mdiIcons.length,
                            itemBuilder: (context, index) {
                              final entry = mdiIcons.entries.elementAt(index);
                              final isSelected = entry.key == selectedIconName;
                              return InkWell(
                                onTap: () {
                                  setState(() => selectedIconName = entry.key);
                                  Navigator.pop(iconDialogContext);
                                },
                                child: Container(
                                  decoration: BoxDecoration(color: isSelected ? Colors.brown[400] : Colors.brown[100], borderRadius: BorderRadius.circular(12)),
                                  child: Icon(entry.value, size: 36, color: isSelected ? Colors.white : Colors.black87),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(isEditing ? 'Rediger Kategori' : 'Ny Kategori'),
            content: SizedBox(
              width: MediaQuery.of(context).size.width * 0.3,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Category Name
                  TextField(
                    controller: categoryNameController,
                    decoration: const InputDecoration(labelText: 'Kategorinavn'),
                  ),
                  const SizedBox(height: 16),

                  // Icon Picker Row
                  Row(
                    children: [
                      const Text('Ikon:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: Icon(MdiIcons.fromString(selectedIconName) ?? MdiIcons.folder),
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
                      const Text('Emner', style: TextStyle(fontWeight: FontWeight.bold)),
                      IconButton(icon: const Icon(Icons.add_circle), onPressed: addItem),
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
                            icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                            onPressed: () => setState(() => items.removeAt(index)),
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
                onPressed: () {
                  final newCategory = PackinglistCategories(
                    categoryName: categoryNameController.text,
                    items: items,
                    iconName: selectedIconName,
                  );

                  if (isEditing) {
                    context
                        .read<GroupInformationRepository>()
                        .updatePackingListCategory(groupInfo.groupId, category, newCategory);
                  } else {
                    context
                        .read<GroupInformationRepository>()
                        .addPackingListCategory(groupInfo.groupId, newCategory);
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


  void _removePackingListCategory(
      BuildContext context, GroupInformation groupInfo, PackinglistCategories category) {
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
            onPressed: () {
              context
                  .read<GroupInformationRepository>()
                  .deletePackingListCategory(groupInfo.groupId, category);
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
    return Card(
      elevation: 10,
      color: AppColors.panelBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Huskeliste',
                        style: const TextStyle(
                            fontSize: 21, fontWeight: FontWeight.w300)),
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 0.5),
              Expanded(
                child: ListView.builder(
                  itemCount: groupInfo.packinglistCategories.length,
                  itemBuilder: (context, index) {
                    final category = groupInfo.packinglistCategories[index];
                    return ListTile(
                      leading: const Icon(Icons.check_circle_outline, color: Colors.black),
                      title: Text(category.categoryName, style: const TextStyle(fontWeight: FontWeight.w500)),
                      onTap: () => _openCategoryDialog(context, category),
                      trailing: (user?.emailVerified ?? false)
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit, color: Colors.black),
                                  onPressed: () => _showAddEditCategoryDialog(context, groupInfo: groupInfo, category: category),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () => _removePackingListCategory(context, groupInfo, category),
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
                onPressed: () =>
                    _showAddEditCategoryDialog(context, groupInfo: groupInfo),
                backgroundColor: AppColors.primary,
                child: const Icon(Icons.add, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  void _openCategoryDialog(BuildContext context, PackinglistCategories category) {
    showDialog(
      context: context,
      builder: (context) {
        final width = MediaQuery.of(context).size.width * 0.3; // Matches app layout
        final height = MediaQuery.of(context).size.height * 0.6;

        return Dialog(
          backgroundColor: AppColors.secondary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    category.categoryName,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
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
                      child: const Text('Luk', style: TextStyle(fontWeight: FontWeight.bold)),
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
