import 'package:backend/models/agencyInformation.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/config/app_colors.dart';
import 'package:backend/models/packinglist_model.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:backend/widget/backgroundVideo.dart';
import 'package:backend/blocs/groupinformation/groupinformation_bloc.dart';
import 'package:backend/rootscreen/rootscreen.dart';
import 'package:backend/screens/groupIDscreen/groupIDscreen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

enum SideMenuItem {
  groups,
  templates,
  photoLibrary,
  packingList,
  settings,
}

class GroupSelectionScreen extends StatefulWidget {
  static const String routeName = '/group-selection';
  final List<GroupInformation> groups;
  final String? agencyCode;

  const GroupSelectionScreen(
      {super.key, required this.groups, this.agencyCode});

  static Route route(
      {required List<GroupInformation> groups, String? agencyCode}) {
    return MaterialPageRoute(
      builder: (_) =>
          GroupSelectionScreen(groups: groups, agencyCode: agencyCode),
      settings: const RouteSettings(name: routeName),
    );
  }

  @override
  State<GroupSelectionScreen> createState() => _GroupSelectionScreenState();
}

class _GroupSelectionScreenState extends State<GroupSelectionScreen> {
  late List<GroupInformation> _groups;
  SideMenuItem _selectedMenuItem = SideMenuItem.groups;
  bool _isGridView = false; // Default to ListView
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _GroupFilters _filters = _GroupFilters();

  @override
  void initState() {
    super.initState();
    _groups = List.from(widget.groups);
    _searchController.addListener(() {
      if (mounted) {
        setState(() {
          _searchQuery = _searchController.text;
        });
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _selectGroup(BuildContext context, GroupInformation group) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('groupId', group.groupId);

    context
        .read<GroupInformationBloc>()
        .add(LoadGroupInformationById(groupId: group.groupId));
  }

  Future<void> _handleLogout() async {
    // Reset the GroupInformationBloc to its initial state
    context.read<GroupInformationBloc>().add(LogoutEvent());

    // Clear saved preferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('groupId');
    await prefs.remove('lastEnteredAgencyCode');

    // Sign out from Firebase
    await FirebaseAuth.instance.signOut();

    // Add a small delay to ensure the BLoC state is reset before the new screen builds.
    await Future.delayed(const Duration(milliseconds: 50));

    // Navigate to login screen and remove all previous routes
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const GroupIDScreen()),
        (route) => false,
      );
    }
  }

  void _showFilterDialog(Color primaryColor) async {
    final newFilters = await showDialog<_GroupFilters>(
      context: context,
      builder: (context) =>
          _FilterDialog(currentFilters: _filters, primaryColor: primaryColor),
    );

    if (newFilters != null && mounted) {
      setState(() {
        _filters = newFilters;
      });
    }
  }

  void _showDuplicateDialog(BuildContext context, GroupInformation group) {
    showDialog<GroupInformation>(
      context: context,
      builder: (context) => _DuplicateGroupDialog(originalGroup: group),
    ).then((newGroup) {
      if (newGroup != null) {
        setState(() {
          _groups.add(newGroup);
        });
      }
    });
  }

  void _showDeleteDialog(BuildContext context, GroupInformation group) {
    final passwordController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog<bool>(
      context: context,
      builder: (context) {
        bool isLoading = false;
        String? errorMessage;

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Slet rejse',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Er du sikker på, at du vil slette "${group.groupId}"?'),
                  const SizedBox(height: 8),
                  const Text(
                    'Dette kan ikke fortrydes. Indtast din adgangskode for at bekræfte.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Form(
                    key: formKey,
                    child: TextFormField(
                      controller: passwordController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: 'Adgangskode',
                        errorText: errorMessage,
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty)
                          return 'Indtast adgangskode';
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed:
                      isLoading ? null : () => Navigator.pop(context, false),
                  child: const Text('Annuller'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: isLoading
                      ? null
                      : () async {
                          if (formKey.currentState!.validate()) {
                            setState(() {
                              isLoading = true;
                              errorMessage = null;
                            });

                            try {
                              final user = FirebaseAuth.instance.currentUser;
                              if (user != null && user.email != null) {
                                AuthCredential credential =
                                    EmailAuthProvider.credential(
                                  email: user.email!,
                                  password: passwordController.text,
                                );

                                await user
                                    .reauthenticateWithCredential(credential);

                                // Delete from Firestore
                                await FirebaseFirestore.instance
                                    .collection('groups')
                                    .doc(group.groupId)
                                    .delete();

                                if (context.mounted) {
                                  Navigator.pop(context, true);
                                }
                              } else {
                                setState(() {
                                  isLoading = false;
                                  errorMessage = 'Ingen bruger fundet';
                                });
                              }
                            } on FirebaseAuthException catch (e) {
                              setState(() {
                                isLoading = false;
                                if (e.code == 'wrong-password' ||
                                    e.code == 'invalid-credential') {
                                  errorMessage = 'Forkert adgangskode';
                                } else {
                                  errorMessage = 'Fejl: ${e.message}';
                                }
                              });
                            } catch (e) {
                              setState(() {
                                isLoading = false;
                                errorMessage = 'Der skete en fejl';
                              });
                            }
                          }
                        },
                  child: isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Slet',
                          style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    ).then((confirmed) async {
      if (confirmed == true) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getString('groupId') == group.groupId) {
          await prefs.remove('groupId');
        }

        if (!mounted) return;
        setState(() {
          _groups.removeWhere((g) => g.groupId == group.groupId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rejse slettet')),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final String? resolvedAgencyCode =
        _groups.isNotEmpty ? _groups.first.agencyCode : widget.agencyCode;

    if (resolvedAgencyCode == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushNamedAndRemoveUntil(
            context, GroupIDScreen.routeName, (route) => false);
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final agencyCode = resolvedAgencyCode;

    final displayedGroups = _groups.where((g) {
      if (_selectedMenuItem == SideMenuItem.templates) {
        return g.isTemplate == true;
      }
      return g.isTemplate != true;
    }).where((g) {
      // Search filter
      if (_searchQuery.isEmpty) {
        return true;
      }
      final query = _searchQuery.toLowerCase();
      return (g.groupName?.toLowerCase().contains(query) ?? false) ||
          g.groupId.toLowerCase().contains(query) ||
          g.members.any((m) =>
              m.name.toLowerCase().contains(query) ||
              m.email.toLowerCase().contains(query)) ||
          g.guides.any((guide) => guide.name.toLowerCase().contains(query));
    }).where((g) {
      // Apply filters
      if (!_filters.isApplied) return true;

      bool passes = true;
      if (_filters.departureDateStart != null) {
        final filterStart = DateUtils.dateOnly(_filters.departureDateStart!);
        final groupDate = DateUtils.dateOnly(g.departureDate);
        passes = passes &&
            (groupDate.isAtSameMomentAs(filterStart) ||
                groupDate.isAfter(filterStart));
      }
      if (_filters.departureDateEnd != null) {
        final filterEnd = DateUtils.dateOnly(_filters.departureDateEnd!);
        final groupDate = DateUtils.dateOnly(g.departureDate);
        passes = passes &&
            (groupDate.isAtSameMomentAs(filterEnd) ||
                groupDate.isBefore(filterEnd));
      }
      if (_filters.flightAway != null)
        passes = passes && g.flightAway == _filters.flightAway;
      if (_filters.flightHome != null)
        passes = passes && g.flightHome == _filters.flightHome;
      return passes;
    }).toList();

    return BlocListener<GroupInformationBloc, GroupInformationState>(
      listener: (context, state) {
        if (state is GroupInformationLoaded) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => const RootScreen()),
            (route) => false,
          );
        } else if (state is GroupInformationError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.message)),
          );
        }
      },
      child: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('agency')
            .doc(agencyCode)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          final agencyInfo = AgencyInformation.fromSnapshot(snapshot.data!);
          final data = snapshot.data!.data() as Map<String, dynamic>;
          final appBarColor = AppColors.fromHex(agencyInfo.mainColor);

          return LayoutBuilder(
            builder: (context, constraints) {
              // Desktop: Grid layout, Mobile: List layout
              final isDesktop = constraints.maxWidth > 800;
              return Scaffold(
                drawer:
                    isDesktop ? null : _buildSideMenu(appBarColor, agencyInfo),
                appBar: AppBar(
                  centerTitle: true,
                  title: Column(
                    children: [
                      Text(
                        agencyInfo.agencyName,
                        style: GoogleFonts.kanit(
                            fontWeight: FontWeight.bold,
                            color: AppColors.homeGradientStart,
                            fontSize: 22),
                      ),
                      Text(
                        switch (_selectedMenuItem) {
                          SideMenuItem.groups => 'Rejseoversigt',
                          SideMenuItem.templates => 'Skabeloner',
                          SideMenuItem.photoLibrary => 'Fotobibliotek',
                          SideMenuItem.packingList => 'Pakkelister',
                          SideMenuItem.settings => 'Indstillinger',
                        },
                        style: GoogleFonts.kanit(
                            fontSize: 12, color: AppColors.panelBackground),
                      ),
                    ],
                  ),
                  backgroundColor: appBarColor,
                  elevation: 0,
                  iconTheme:
                      const IconThemeData(color: AppColors.homeGradientStart),
                  // actions removed for side menu
                ),
                floatingActionButton: isDesktop &&
                        (_selectedMenuItem == SideMenuItem.groups ||
                            _selectedMenuItem == SideMenuItem.templates)
                    ? FloatingActionButton(
                        backgroundColor: AppColors.navActive,
                        onPressed: () {
                          showDialog<GroupInformation>(
                            context: context,
                            builder: (context) => _AddGroupDialog(
                              bureauName: agencyInfo.agencyName,
                              agencyCode: agencyCode,
                            ),
                          ).then((newGroup) {
                            if (newGroup != null) {
                              setState(() {
                                _groups.add(newGroup);
                              });
                            }
                          });
                        },
                        child: const Icon(Icons.add, color: Colors.white),
                      )
                    : null,
                body: Container(
                  width: double.infinity,
                  padding: EdgeInsets
                      .zero, // Remove padding to let bottom panel touch edges
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
                  child: Row(
                    children: [
                      if (isDesktop)
                        _buildSideMenu(appBarColor, agencyInfo,
                            isDrawer: false),
                      Expanded(
                        child: _buildMainContent(
                          appBarColor: appBarColor,
                          agencyCode: agencyCode,
                          agencyInfo: agencyInfo,
                          data: data,
                          displayedGroups: displayedGroups,
                          isDesktop: isDesktop,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildMainContent({
    required Color appBarColor,
    required String agencyCode,
    required AgencyInformation agencyInfo,
    required Map<String, dynamic> data,
    required List<GroupInformation> displayedGroups,
    required bool isDesktop,
  }) {
    if (_selectedMenuItem == SideMenuItem.photoLibrary) {
      return AgencyImagesScreen(
        agencyCode: agencyCode,
        mainColor: appBarColor,
        isNested: true,
      );
    } else if (_selectedMenuItem == SideMenuItem.packingList) {
      return PackingListLibraryScreen(
        agencyCode: agencyCode,
        mainColor: appBarColor,
        isNested: true,
      );
    } else if (_selectedMenuItem == SideMenuItem.settings) {
      return BureauSettingsScreen(
        agencyInfo: agencyInfo,
        logoUrl: data['logoUrl'] as String?,
        standardMessage: data['standardMessage'] as String?,
        standardMessageTitle: data['standardMessageTitle'] as String?,
        isNested: true,
      );
    }

    return Column(
      children: [
        // Search and Filter controls
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText:
                        'Søg efter gruppenavn, deltagere eller rejse-ID...',
                    prefixIcon: Icon(Icons.search, color: Colors.grey[600]),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ),
              if (isDesktop) ...[
                const SizedBox(width: 16),
                ToggleButtons(
                  isSelected: [!_isGridView, _isGridView],
                  onPressed: (index) {
                    setState(() {
                      _isGridView = index == 1;
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  constraints:
                      const BoxConstraints(minHeight: 48, minWidth: 48),
                  children: const [
                    Tooltip(
                        message: 'Listevisning', child: Icon(Icons.view_list)),
                    Tooltip(
                        message: 'Gittervisning', child: Icon(Icons.grid_view)),
                  ],
                ),
              ],
              const SizedBox(width: 8),
              IconButton(
                  icon: Badge(
                    isLabelVisible: _filters.isApplied,
                    child: const Icon(Icons.filter_list),
                  ),
                  onPressed: () => _showFilterDialog(appBarColor),
                  tooltip: 'Filtrer',
                  iconSize: 28,
                  color: AppColors.fromHex(agencyInfo.mainColor)),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: displayedGroups.isEmpty
                ? Center(
                    child: Text(
                      _filters.isApplied || _searchQuery.isNotEmpty
                          ? 'Ingen rejser matcher din søgning/filtrering.'
                          : 'Ingen rejser fundet.',
                      style: GoogleFonts.kanit(
                          fontSize: 18, color: Colors.white70),
                    ),
                  )
                : (isDesktop && _isGridView)
                    ? GridView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 24),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 400,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.8,
                        ),
                        itemCount: displayedGroups.length,
                        itemBuilder: (context, index) =>
                            _buildGroupCard(context, displayedGroups[index]),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 24),
                        itemCount: displayedGroups.length,
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child:
                              _buildGroupCard(context, displayedGroups[index]),
                        ),
                      ),
          ),
        ),
      ],
    );
  }

  Widget _buildSideMenu(Color primaryColor, AgencyInformation agencyInfo,
      {bool isDrawer = false}) {
    final menuContent = Container(
      width: 250,
      color: Colors.white,
      child: Column(
        children: [
          if (isDrawer)
            DrawerHeader(
              decoration: BoxDecoration(color: primaryColor),
              child: Center(
                child: Text(agencyInfo.agencyName,
                    style: GoogleFonts.kanit(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          if (!isDrawer) const SizedBox(height: 20),
          _buildMenuOption('Rejser', Icons.flight, SideMenuItem.groups,
              primaryColor, agencyInfo, isDrawer),
          _buildMenuOption('Skabeloner', Icons.copy_all, SideMenuItem.templates,
              primaryColor, agencyInfo, isDrawer),
          _buildMenuOption('Fotobibliotek', Icons.photo_library,
              SideMenuItem.photoLibrary, primaryColor, agencyInfo, isDrawer),
          _buildMenuOption('Pakkelister', Icons.checklist,
              SideMenuItem.packingList, primaryColor, agencyInfo, isDrawer),
          _buildMenuOption('Indstillinger', Icons.settings,
              SideMenuItem.settings, primaryColor, agencyInfo, isDrawer),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: OutlinedButton.icon(
              onPressed: _handleLogout,
              icon: const Icon(Icons.logout),
              label: const Text('Log ud'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
                foregroundColor: Colors.red[700],
                side: BorderSide(color: Colors.red[700]!),
              ),
            ),
          ),
        ],
      ),
    );

    return isDrawer ? Drawer(child: menuContent) : menuContent;
  }

  Widget _buildMenuOption(String title, IconData icon, SideMenuItem item,
      Color primaryColor, AgencyInformation agencyInfo, bool isDrawer) {
    final isSelected = _selectedMenuItem == item;
    final agencyColor = AppColors.fromHex(agencyInfo.mainColor);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: Icon(icon, color: isSelected ? agencyColor : Colors.grey[700]),
        title: Text(title,
            style: GoogleFonts.kanit(
              color: isSelected ? agencyColor : Colors.black87,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            )),
        tileColor: isSelected ? agencyColor.withOpacity(0.1) : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        onTap: () {
          setState(() => _selectedMenuItem = item);
          if (isDrawer && mounted) Navigator.pop(context);
        },
      ),
    );
  }

  void _showEditGroupNameDialog(BuildContext context, GroupInformation group) {
    final controller =
        TextEditingController(text: group.groupName ?? 'Unavngivet rejse');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Rediger gruppenavn',
            style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Navn'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuller'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                await FirebaseFirestore.instance
                    .collection('groups')
                    .doc(group.groupId)
                    .update({'groupName': controller.text});

                if (mounted) {
                  setState(() {
                    group.groupName = controller.text;
                  });
                  Navigator.pop(context);
                }
              }
            },
            child: const Text('Gem'),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCard(BuildContext context, GroupInformation group) {
    final now = DateTime.now();
    final daysUntil = group.departureDate.difference(now).inDays;
    final daysLeft = group.returnDate.difference(now).inDays;

    String countdownText;
    IconData countdownIcon;

    if (daysUntil > 0) {
      countdownText = 'Afrejse om $daysUntil dage';
      countdownIcon = Icons.flight_takeoff;
    } else if (daysLeft > 0) {
      countdownText = 'Rejse i gang – $daysLeft dage tilbage';
      countdownIcon = Icons.beach_access;
    } else {
      countdownText = 'Rejse afsluttet';
      countdownIcon = Icons.check_circle_outline;
    }

    return InkWell(
      onTap: () => _selectGroup(context, group),
      borderRadius: BorderRadius.circular(16),
      child: Card(
        elevation: 5,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.withOpacity(0.5), width: 1),
        ),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, // allow card to grow with content
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildGroupInfo(group)),
                  IconButton(
                    icon: const Icon(Icons.edit),
                    color: Colors.black54,
                    iconSize: 20,
                    onPressed: () => _showEditGroupNameDialog(context, group),
                    tooltip: 'Rediger navn',
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy),
                    color: Colors.black54,
                    iconSize: 20,
                    onPressed: () => _showDuplicateDialog(context, group),
                    tooltip: 'Dupliker rejse',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    color: Colors.red.withOpacity(0.7),
                    iconSize: 20,
                    onPressed: () => _showDeleteDialog(context, group),
                    tooltip: 'Slet rejse',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  _infoChip(Icons.people, '${group.members.length} medlemmer'),
                  _infoChip(
                      Icons.support_agent, '${group.guides.length} guider'),
                  if (group.flightAway)
                    _infoChip(Icons.flight_takeoff, 'Udrejse'),
                  if (group.flightHome)
                    _infoChip(Icons.flight_land, 'Hjemrejse'),
                  if (group.emergencyPhone != null &&
                      group.emergencyPhone!.isNotEmpty)
                    _infoChip(Icons.phone, group.emergencyPhone!),
                  _infoChip(Icons.place, 'Start: ${group.departureFrom}'),
                  _infoChip(Icons.place, 'Slut: ${group.returnTo}'),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(countdownIcon, color: Colors.black54, size: 20),
                      const SizedBox(width: 6),
                      Text(
                        countdownText,
                        style: GoogleFonts.kanit(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  const Icon(Icons.arrow_forward_ios,
                      color: Colors.black54, size: 18),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroupInfo(GroupInformation group) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          group.groupName ?? 'Unavangivet rejse',
          style: GoogleFonts.kanit(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        Text(
          group.groupId,
          style: GoogleFonts.kanit(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.flight_takeoff, color: Colors.black54, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Afrejse: ${DateFormat('dd. MMMM yyyy', 'da_DK').format(group.departureDate)}',
                style: GoogleFonts.kanit(color: Colors.black87),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        Row(
          children: [
            const Icon(Icons.flight_land, color: Colors.black54, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Hjemkomst: ${DateFormat('dd. MMMM yyyy', 'da_DK').format(group.returnDate)}',
                style: GoogleFonts.kanit(color: Colors.black87),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _infoChip(IconData icon, String label) {
    return Chip(
      backgroundColor: AppColors.chipBackground,
      elevation: 0,
      avatar: Icon(icon, size: 16, color: Colors.black87),
      label: Text(label, style: GoogleFonts.kanit(fontSize: 14)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
    );
  }
}

class _GroupFilters {
  DateTime? departureDateStart;
  DateTime? departureDateEnd;
  bool? flightAway;
  bool? flightHome;

  _GroupFilters({
    this.departureDateStart,
    this.departureDateEnd,
    this.flightAway,
    this.flightHome,
  });

  // A copy constructor
  _GroupFilters.from(_GroupFilters other) {
    departureDateStart = other.departureDateStart;
    departureDateEnd = other.departureDateEnd;
    flightAway = other.flightAway;
    flightHome = other.flightHome;
  }

  bool get isApplied =>
      departureDateStart != null ||
      departureDateEnd != null ||
      flightAway != null ||
      flightHome != null;
}

class _FilterDialog extends StatefulWidget {
  final _GroupFilters currentFilters;
  final Color primaryColor;

  const _FilterDialog(
      {required this.currentFilters, required this.primaryColor});

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  late _GroupFilters _filters;

  @override
  void initState() {
    super.initState();
    // Create a mutable copy to work with inside the dialog
    _filters = _GroupFilters.from(widget.currentFilters);
  }

  Future<void> _pickDateRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(DateTime.now().year - 5),
      lastDate: DateTime(DateTime.now().year + 5),
      initialDateRange: _filters.departureDateStart != null &&
              _filters.departureDateEnd != null
          ? DateTimeRange(
              start: _filters.departureDateStart!,
              end: _filters.departureDateEnd!)
          : null,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: widget.primaryColor,
              onPrimary: Colors.white,
              onSurface: Colors.black,
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: widget.primaryColor,
              ),
            ),
          ),
          child: child!,
        );
      },
    );
    if (range != null) {
      setState(() {
        _filters.departureDateStart = range.start;
        _filters.departureDateEnd = range.end;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text('Filtrer rejser',
          style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Afrejsedato',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              InkWell(
                onTap: _pickDateRange,
                child: InputDecorator(
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.calendar_today),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  child: Text(
                    _filters.departureDateStart != null &&
                            _filters.departureDateEnd != null
                        ? '${DateFormat('dd/MM/yy').format(_filters.departureDateStart!)} - ${DateFormat('dd/MM/yy').format(_filters.departureDateEnd!)}'
                        : 'Vælg datointerval',
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text('Fly inkluderet',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              _buildBooleanFilter(
                  label: 'Udrejse',
                  value: _filters.flightAway,
                  onChanged: (val) =>
                      setState(() => _filters.flightAway = val)),
              const SizedBox(height: 8),
              _buildBooleanFilter(
                  label: 'Hjemrejse',
                  value: _filters.flightHome,
                  onChanged: (val) =>
                      setState(() => _filters.flightHome = val)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuller')),
        TextButton(
            onPressed: () => Navigator.pop(context, _GroupFilters()),
            child: const Text('Nulstil')),
        ElevatedButton(
            onPressed: () => Navigator.pop(context, _filters),
            child: const Text('Anvend')),
      ],
    );
  }

  Widget _buildBooleanFilter(
      {required String label,
      required bool? value,
      required ValueChanged<bool?> onChanged}) {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: GoogleFonts.kanit()),
      ToggleButtons(
        isSelected: [value == true, value == false, value == null],
        onPressed: (index) =>
            onChanged(index == 0 ? true : (index == 1 ? false : null)),
        borderRadius: BorderRadius.circular(8),
        constraints: const BoxConstraints(minHeight: 36, minWidth: 48),
        children: const [Text('Ja'), Text('Nej'), Text('Alle')],
      ),
    ]);
  }
}

class BureauSettingsScreen extends StatefulWidget {
  final AgencyInformation agencyInfo;
  final String? logoUrl;
  final String? standardMessage;
  final String? standardMessageTitle;
  final bool isNested;

  const BureauSettingsScreen({
    super.key,
    required this.agencyInfo,
    this.logoUrl,
    this.standardMessage,
    this.standardMessageTitle,
    this.isNested = false,
  });

  @override
  State<BureauSettingsScreen> createState() => _BureauSettingsScreenState();
}

class _BureauSettingsScreenState extends State<BureauSettingsScreen> {
  late TextEditingController _nameController;
  late TextEditingController _phoneController;
  late TextEditingController _emailController;
  late TextEditingController _colorController;
  late TextEditingController _standardMessageController;
  late TextEditingController _standardMessageTitleController;
  String? _logoUrl;
  String? _videoUrl;
  bool _isUploadingLogo = false;
  bool _isUploadingVideo = false;
  bool _isLoadingInitialLogo = true;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.agencyInfo.agencyName);
    _phoneController =
        TextEditingController(text: widget.agencyInfo.emergencyPhone);
    _emailController =
        TextEditingController(text: widget.agencyInfo.returnMail);
    _colorController = TextEditingController(text: widget.agencyInfo.mainColor);
    _standardMessageController =
        TextEditingController(text: widget.standardMessage ?? '');
    _standardMessageTitleController =
        TextEditingController(text: widget.standardMessageTitle ?? 'Velkommen');
    _videoUrl = widget.agencyInfo.videoUrl;
    _loadInitialLogo();
  }

  Future<void> _loadInitialLogo() async {
    try {
      final ref = FirebaseStorage.instance
          .ref('config/AgencyLogos/${widget.agencyInfo.agencyCode}.png');
      final url = await ref.getDownloadURL();
      if (mounted) {
        setState(() {
          _logoUrl = url;
        });
      }
    } catch (e) {
      // This is expected if no logo has been uploaded yet.
      debugPrint('No initial logo found: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingInitialLogo = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _colorController.dispose();
    _standardMessageController.dispose();
    _standardMessageTitleController.dispose();
    super.dispose();
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
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    try {
      await FirebaseFirestore.instance
          .collection('agency')
          .doc(widget.agencyInfo.agencyCode)
          .update({
        'agencyName': _nameController.text,
        'emergencyPhone': _phoneController.text,
        'returnMail': _emailController.text,
        'mainColor': _colorController.text,
        'standardMessage': _standardMessageController.text,
        'standardMessageTitle': _standardMessageTitleController.text,
        'logoUrl': _logoUrl,
        'videoUrl': _videoUrl,
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Gemt!')));
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

        String mimeType = 'image/png';
        SettableMetadata metadata = SettableMetadata(contentType: mimeType);

        if (file.bytes != null) {
          UploadTask uploadTask = storageRef.putData(file.bytes!, metadata);
          await uploadTask;
          String downloadUrl = await storageRef.getDownloadURL();

          setState(() {
            _logoUrl = downloadUrl;
            _isUploadingLogo = false;
          });
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

        // Delete old video if it exists
        if (_videoUrl != null && _videoUrl!.isNotEmpty) {
          try {
            Reference oldRef = FirebaseStorage.instance.refFromURL(_videoUrl!);
            await oldRef.delete();
            debugPrint('Old video deleted successfully');
          } catch (e) {
            debugPrint('Error deleting old video: $e');
            // Continue with upload even if deletion fails (might be a missing file)
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

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Video uploadet med succes')));
        }
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

        // Save immediately to update Firestore
        await _save();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Video slettet successfully')));
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isUploadingVideo = false);
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Kunne ikke slette video: $e')));
        }
      }
    }
  }

  Future<void> _handleLogout() async {
    context.read<GroupInformationBloc>().add(LogoutEvent());

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('groupId');
    await prefs.remove('lastEnteredAgencyCode');

    await FirebaseAuth.instance.signOut();

    await Future.delayed(const Duration(milliseconds: 50));

    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const GroupIDScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = AppColors.fromHex(widget.agencyInfo.mainColor);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: widget.isNested
          ? null
          : AppBar(
              title: Text('Bureauindstillinger',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              backgroundColor: themeColor,
              foregroundColor: Colors.white,
              elevation: 0,
              centerTitle: true,
            ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          children: [
            _buildCombinedPreview(themeColor),
            const SizedBox(height: 32),
            _buildSectionTitle('Kontaktinformation'),
            _buildContactCard(),
            const SizedBox(height: 24),
            _buildSectionTitle('Design & Indhold'),
            _buildDesignCard(themeColor),
            const SizedBox(height: 32),
            _buildActionButtons(themeColor),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton.icon(
                onPressed: _handleLogout,
                icon: const Icon(Icons.logout),
                label: Text('Log ud',
                    style: GoogleFonts.kanit(
                        fontSize: 16, fontWeight: FontWeight.w500)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: BorderSide(
                      color: Colors.red.withOpacity(0.5), width: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Emails brugt: ${widget.agencyInfo.emailCount} / ${widget.agencyInfo.maxEmails}',
              style: GoogleFonts.kanit(color: Colors.grey[600], fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: GoogleFonts.kanit(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
      ),
    );
  }

  Widget _buildCombinedPreview(Color themeColor) {
    return Center(
      child: Column(
        children: [
          Container(
            width: MediaQuery.of(context).size.width / 3.5,
            height: 250,
            decoration: BoxDecoration(
              color: themeColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Background Video
                  if (_videoUrl != null && _videoUrl!.isNotEmpty)
                    BackgroundVideo(videoUrl: _videoUrl)
                  else
                    const BackgroundVideo(videoUrl: null), // Default video

                  // Dim overlay to make logo pop
                  Container(color: Colors.black26),

                  // Agency Logo or Loading
                  GestureDetector(
                    onTap: _pickAndUploadLogo,
                    child: (_isUploadingLogo || _isLoadingInitialLogo)
                        ? const CircularProgressIndicator(color: Colors.white)
                        : _logoUrl != null
                            ? Padding(
                                padding: const EdgeInsets.all(32.0),
                                child: CachedNetworkImage(
                                  imageUrl: _logoUrl!,
                                  fit: BoxFit.contain,
                                  placeholder: (context, url) =>
                                      const CircularProgressIndicator(
                                          color: Colors.white),
                                  errorWidget: (context, url, error) =>
                                      const Icon(Icons.business,
                                          size: 50, color: Colors.white70),
                                ),
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_photo_alternate_outlined,
                                      size: 48, color: Colors.white70),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Tilføj logo',
                                    style: GoogleFonts.kanit(
                                        color: Colors.white70,
                                        fontWeight: FontWeight.w500),
                                  ),
                                ],
                              ),
                  ),

                  // Uploading Video Indicator overlay
                  if (_isUploadingVideo)
                    Container(
                      color: Colors.black45,
                      child: const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    ),

                  // Delete Video Button
                  if (_videoUrl != null &&
                      _videoUrl!.isNotEmpty &&
                      !_isUploadingVideo)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: IconButton(
                        icon:
                            const Icon(Icons.videocam_off, color: Colors.white),
                        onPressed: _deleteVideo,
                        tooltip: 'Slet baggrundsvideo',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black45,
                        ),
                      ),
                    ),

                  // Label indicator
                  Positioned(
                    bottom: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'FORVISNING',
                        style: GoogleFonts.kanit(
                          color: Colors.white,
                          fontSize: 10,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Action Buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildCompactActionButton(
                icon: Icons.image,
                label: 'Skift Logo',
                onTap: _isUploadingLogo || _isLoadingInitialLogo
                    ? () {}
                    : _pickAndUploadLogo,
                color: themeColor,
              ),
              const SizedBox(width: 12),
              _buildCompactActionButton(
                icon: Icons.video_library,
                label: _videoUrl != null ? 'Skift Video' : 'Tilføj Video',
                onTap: _isUploadingVideo ? () {} : _pickAndUploadVideo,
                color: themeColor,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCompactActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[200]!),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 5,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.kanit(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildTextField(
            controller: _nameController,
            label: 'Bureau Navn',
            icon: Icons.business,
          ),
          const SizedBox(height: 16),
          _buildTextField(
            controller: _phoneController,
            label: 'Nødtelefon',
            icon: Icons.phone,
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 16),
          _buildTextField(
            controller: _emailController,
            label: 'Kontakt e-mail',
            icon: Icons.email,
            keyboardType: TextInputType.emailAddress,
          ),
        ],
      ),
    );
  }

  void _showWelcomeMessageDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Velkomstbesked',
            style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _standardMessageTitleController,
              decoration: const InputDecoration(labelText: 'Titel'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _standardMessageController,
              decoration: const InputDecoration(labelText: 'Besked'),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuller'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {});
              Navigator.pop(context);
            },
            child: const Text('Gem'),
          ),
        ],
      ),
    );
  }

  Widget _buildDesignCard(Color themeColor) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey[300]!),
              borderRadius: BorderRadius.circular(12),
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
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _colorController,
                    decoration: InputDecoration(
                      labelText: 'Primær farve',
                      labelStyle: GoogleFonts.kanit(
                          fontSize: 12, color: Colors.grey[600]),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: GoogleFonts.kanit(fontSize: 16),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.palette, color: Colors.grey),
                  onPressed: _showColorPicker,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: _showWelcomeMessageDialog,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(12),
                color: Colors.grey[50],
              ),
              child: Row(
                children: [
                  Icon(Icons.message, color: Colors.grey[400], size: 20),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _standardMessageController.text.isNotEmpty
                              ? _standardMessageTitleController.text
                              : 'Standard velkomstbesked',
                          style: GoogleFonts.kanit(
                              fontWeight: FontWeight.w500,
                              color: Colors.black87),
                        ),
                        Text(
                          _standardMessageController.text.isNotEmpty
                              ? _standardMessageController.text
                              : 'Tryk for at tilføje besked',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.kanit(
                              fontSize: 12, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.edit, color: themeColor, size: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    int maxLines = 1,
    String? helperText,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      style: GoogleFonts.kanit(),
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        helperStyle: GoogleFonts.kanit(fontSize: 11),
        labelStyle: GoogleFonts.kanit(color: Colors.grey[600]),
        prefixIcon: Icon(icon, color: Colors.grey[400], size: 20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.primary, width: 2),
        ),
        filled: true,
        fillColor: Colors.grey[50],
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  Widget _buildActionButtons(Color themeColor) {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton.icon(
            onPressed: _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: themeColor,
              foregroundColor: Colors.white,
              elevation: 4,
              shadowColor: themeColor.withOpacity(0.4),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            icon: const Icon(Icons.save_rounded),
            label: Text('Gem ændringer',
                style: GoogleFonts.kanit(
                    fontSize: 18, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }
}

class AgencyImagesScreen extends StatefulWidget {
  final String agencyCode;
  final Color mainColor;
  final bool isNested;

  const AgencyImagesScreen({
    super.key,
    required this.agencyCode,
    required this.mainColor,
    this.isNested = false,
  });

  @override
  State<AgencyImagesScreen> createState() => _AgencyImagesScreenState();
}

class _AgencyImagesScreenState extends State<AgencyImagesScreen> {
  String _currentPath = '';
  List<Reference> _folders = [];
  List<Reference> _images = [];
  bool _isLoading = true;

  bool _isSelectionMode = false;
  Set<String> _selectedItems = {};

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

      setState(() {
        _folders = result.prefixes;
        _images = result.items.where((ref) => ref.name != '.keep').toList();
        _isLoading = false;

        if (!_isSelectionMode) {
          _selectedItems.clear();
        }
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kunne ikke hente billeder: $e')),
        );
      }
    }
  }

  Future<void> _uploadImage() async {
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
              toolbarColor: widget.mainColor,
              toolbarWidgetColor: Colors.white,
              initAspectRatio: CropAspectRatioPreset.ratio4x3,
              lockAspectRatio: true,
            ),
            IOSUiSettings(
              title: 'Beskær Billede',
              aspectRatioLockEnabled: true,
            ),
            WebUiSettings(
              context: context,
              presentStyle: WebPresentStyle.dialog,
              size: const CropperSize(
                width: 520,
                height: 520,
              ),
              customDialogBuilder: (cropper, init, crop, rotate, scale) {
                return StatefulBuilder(builder: (context, setState) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    init();
                  });

                  return Dialog(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
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
                                  onPressed: () => Navigator.of(context).pop()),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: 500,
                            height: 350,
                            child: ClipRect(child: cropper),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.zoom_out,
                                  size: 20, color: Colors.grey),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
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
                                  onPressed: () => Navigator.of(context).pop(),
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
                                    backgroundColor: widget.mainColor),
                                child: Text('Beskær',
                                    style:
                                        GoogleFonts.kanit(color: Colors.white)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                });
              },
            ),
          ],
        );

        if (croppedFile != null) {
          setState(() => _isLoading = true);

          final fileName = image.name;
          final ref =
              FirebaseStorage.instance.ref('$_storageBasePath/$fileName');

          final bytes = await croppedFile.readAsBytes();
          final metadata = SettableMetadata(contentType: 'image/jpeg');

          await ref.putData(bytes, metadata);
          await _loadImages();
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fejl ved upload: $e')),
        );
      }
    }
  }

  Future<void> _deleteImage(Reference ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Slet billede?'),
        content: const Text('Er du sikker på, at du vil slette dette billede?'),
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
      setState(() => _isLoading = true);
      try {
        await ref.delete();
        await _loadImages();
      } catch (e) {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Kunne ikke slette: $e')),
          );
        }
      }
    }
  }

  Future<void> _createNewFolder() async {
    String folderName = '';
    final created = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Opret ny mappe'),
          content: TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Mappenavn'),
            onChanged: (val) => folderName = val,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuller'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: widget.mainColor,
                  foregroundColor: Colors.white),
              child: const Text('Opret'),
            ),
          ],
        );
      },
    );

    if (created == true && folderName.trim().isNotEmpty) {
      setState(() => _isLoading = true);
      try {
        final sanitizedName = folderName.trim().replaceAll('/', '');
        final ref = FirebaseStorage.instance
            .ref('$_storageBasePath/$sanitizedName/.keep');
        await ref.putData(
            Uint8List(0), SettableMetadata(contentType: 'text/plain'));
        await _loadImages();
      } catch (e) {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Kunne ikke oprette mappe: $e')),
          );
        }
      }
    }
  }

  Future<void> _updateImageReferences(String oldUrl, String newUrl) async {
    final groupsSnap = await FirebaseFirestore.instance
        .collection('groups')
        .where('agencyCode', isEqualTo: widget.agencyCode)
        .get();

    final batch = FirebaseFirestore.instance.batch();

    for (var doc in groupsSnap.docs) {
      final data = doc.data();
      final events = data['timelineEvents'] as List<dynamic>?;
      if (events != null) {
        bool changed = false;
        final updatedEvents = events.map((e) {
          if (e is Map && e['imageURL'] == oldUrl) {
            changed = true;
            return {...e, 'imageURL': newUrl};
          }
          return e;
        }).toList();

        if (changed) {
          batch.update(doc.reference, {'timelineEvents': updatedEvents});
        }
      }
    }

    await batch.commit();
  }

  Future<void> _moveSelectedItems() async {
    setState(() => _isLoading = true);

    try {
      final rootRef = FirebaseStorage.instance
          .ref('agencies/${widget.agencyCode}/timeline_images');
      final rootResult = await rootRef.listAll();
      final rootFolders = rootResult.prefixes;

      setState(() => _isLoading = false);

      if (!mounted) return;

      final destinationPrefix = await showDialog<String>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Flyt til mappe'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.home),
                      title: const Text('Hovedmappe'),
                      onTap: () => Navigator.pop(context, ''),
                    ),
                    const Divider(),
                    ...rootFolders
                        .map((prefix) => ListTile(
                              leading: const Icon(Icons.folder),
                              title: Text(prefix.name),
                              onTap: () => Navigator.pop(context, prefix.name),
                            ))
                        .toList(),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Annuller'),
                ),
              ],
            );
          });

      if (destinationPrefix != null) {
        setState(() => _isLoading = true);
        final destPath = destinationPrefix.isEmpty
            ? 'agencies/${widget.agencyCode}/timeline_images'
            : 'agencies/${widget.agencyCode}/timeline_images/$destinationPrefix';

        for (var path in _selectedItems) {
          final oldRef = FirebaseStorage.instance.ref(path);
          final newRef =
              FirebaseStorage.instance.ref('$destPath/${oldRef.name}');

          if (oldRef.fullPath == newRef.fullPath) continue;

          final data = await oldRef.getData();
          if (data != null) {
            final oldUrl = await oldRef.getDownloadURL();

            final metadata = await oldRef.getMetadata();
            await newRef.putData(
                data, SettableMetadata(contentType: metadata.contentType));

            final newUrl = await newRef.getDownloadURL();

            // Execute the automated cross-referencing update over all Groups & Templates
            await _updateImageReferences(oldUrl, newUrl);

            await oldRef.delete();
          }
        }

        setState(() {
          _isSelectionMode = false;
          _selectedItems.clear();
        });
        await _loadImages();
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fejl ved flytning: $e')),
        );
      }
    }
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedItems.contains(path)) {
        _selectedItems.remove(path);
        if (_selectedItems.isEmpty) _isSelectionMode = false;
      } else {
        if (_selectedItems.length >= 5) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Du kan maksimalt vælge 5 billeder ad gangen.')),
          );
          return;
        }
        _selectedItems.add(path);
      }
    });
  }

  Widget _buildImageCard(Reference ref, bool isSelected) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(13),
      child: FutureBuilder<String>(
        future: ref.getDownloadURL(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Container(
              color: Colors.grey[100],
              child: const Center(
                  child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                imageUrl: snapshot.data!,
                fit: BoxFit.cover,
                placeholder: (context, url) =>
                    Container(color: Colors.grey[100]),
                errorWidget: (context, url, error) =>
                    const Icon(Icons.broken_image, color: Colors.grey),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withOpacity(0.7),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 24, 12, 12),
                  child: Text(
                    ref.name,
                    style: GoogleFonts.kanit(color: Colors.white, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
              if (!isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Row(
                    children: [
                      Material(
                        color: Colors.white.withOpacity(0.9),
                        shape: const CircleBorder(),
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              _selectedItems.clear();
                              _selectedItems.add(ref.fullPath);
                            });
                            _moveSelectedItems();
                          },
                          customBorder: const CircleBorder(),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.drive_file_move_outline,
                                color: Colors.blue, size: 20),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Material(
                        color: Colors.white.withOpacity(0.9),
                        shape: const CircleBorder(),
                        child: InkWell(
                          onTap: () => _deleteImage(ref),
                          customBorder: const CircleBorder(),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.delete_outline,
                                color: Colors.red, size: 20),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (isSelected)
                Positioned(
                    top: 8,
                    left: 8,
                    child: Icon(Icons.check_circle,
                        color: widget.mainColor, size: 28))
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: const Color(0xFFF8F9FA),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            showModalBottomSheet(
                context: context,
                backgroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(20))),
                builder: (context) {
                  return SafeArea(
                      child: Wrap(children: [
                    if (_currentPath.isEmpty)
                      ListTile(
                          leading: Icon(Icons.create_new_folder,
                              color: widget.mainColor),
                          title: const Text('Opret ny mappe'),
                          onTap: () {
                            Navigator.pop(context);
                            _createNewFolder();
                          }),
                    ListTile(
                        leading: Icon(Icons.add_photo_alternate,
                            color: widget.mainColor),
                        title: const Text('Upload billede'),
                        onTap: () {
                          Navigator.pop(context);
                          _uploadImage();
                        })
                  ]));
                });
          },
          backgroundColor: widget.mainColor,
          child: const Icon(Icons.add, color: Colors.white),
        ),
        appBar: widget.isNested
            ? null
            : AppBar(
                title: Text(
                    _currentPath.isEmpty ? 'Fotobibliotek' : _currentPath,
                    style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
                centerTitle: true,
                elevation: 0,
                backgroundColor: widget.mainColor,
                foregroundColor: Colors.white,
              ),
        body: Column(children: [
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              color: Colors.white,
              child: Row(children: [
                if (_currentPath.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      setState(() => _currentPath = '');
                      _loadImages();
                    },
                    tooltip: 'Tilbage',
                  ),
                if (_isSelectionMode) ...[
                  Text('${_selectedItems.length} valgt',
                      style: GoogleFonts.kanit(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _moveSelectedItems,
                    icon: const Icon(Icons.drive_file_move),
                    label: const Text('Flyt'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _isSelectionMode = false;
                      _selectedItems.clear();
                    }),
                  ),
                ] else ...[
                  Text(_currentPath.isEmpty ? 'Hovedmappe' : _currentPath,
                      style: GoogleFonts.kanit(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (_images.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => setState(() => _isSelectionMode = true),
                      icon: const Icon(Icons.checklist),
                      label: const Text('Vælg Billeder'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: widget.mainColor,
                        side: BorderSide(color: widget.mainColor),
                      ),
                    ),
                ]
              ])),
          Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : (_folders.isEmpty && _images.isEmpty)
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.photo_library_outlined,
                                  size: 64, color: Colors.grey[300]),
                              const SizedBox(height: 16),
                              Text('Mappen er tom',
                                  style: GoogleFonts.kanit(
                                      fontSize: 18,
                                      color: Colors.grey[500],
                                      fontWeight: FontWeight.w500)),
                            ],
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.all(20),
                          child: CustomScrollView(slivers: [
                            if (_folders.isNotEmpty)
                              SliverToBoxAdapter(
                                  child: Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Text('Mapper',
                                    style: GoogleFonts.kanit(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey[700])),
                              )),
                            if (_folders.isNotEmpty)
                              SliverGrid(
                                  gridDelegate:
                                      const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 200,
                                    mainAxisExtent: 60,
                                    crossAxisSpacing: 16,
                                    mainAxisSpacing: 16,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                      (context, index) {
                                    final folder = _folders[index];
                                    return InkWell(
                                        onTap: () {
                                          if (_isSelectionMode) return;
                                          setState(
                                              () => _currentPath = folder.name);
                                          _loadImages();
                                        },
                                        borderRadius: BorderRadius.circular(12),
                                        child: Container(
                                            decoration: BoxDecoration(
                                                color: Colors.white,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                boxShadow: [
                                                  BoxShadow(
                                                      color: Colors.black
                                                          .withOpacity(0.05),
                                                      blurRadius: 4,
                                                      offset:
                                                          const Offset(0, 2))
                                                ],
                                                border: Border.all(
                                                    color: Colors.grey[200]!)),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 16),
                                            child: Row(children: [
                                              Icon(Icons.folder,
                                                  color: widget.mainColor),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                  child: Text(folder.name,
                                                      style: GoogleFonts.kanit(
                                                          fontWeight:
                                                              FontWeight.w500),
                                                      overflow: TextOverflow
                                                          .ellipsis)),
                                            ])));
                                  }, childCount: _folders.length)),
                            if (_images.isNotEmpty)
                              SliverToBoxAdapter(
                                  child: Padding(
                                padding:
                                    const EdgeInsets.only(top: 24, bottom: 16),
                                child: Text('Billeder',
                                    style: GoogleFonts.kanit(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey[700])),
                              )),
                            if (_images.isNotEmpty)
                              SliverGrid(
                                  gridDelegate:
                                      const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 440,
                                    crossAxisSpacing: 16,
                                    mainAxisSpacing: 16,
                                    childAspectRatio: 2.3 / 1,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                      (context, index) {
                                    final ref = _images[index];
                                    final isSelected =
                                        _selectedItems.contains(ref.fullPath);
                                    return GestureDetector(
                                        onLongPress: () {
                                          setState(() {
                                            _isSelectionMode = true;
                                            _selectedItems.add(ref.fullPath);
                                          });
                                        },
                                        onTap: () {
                                          if (_isSelectionMode) {
                                            _toggleSelection(ref.fullPath);
                                          }
                                        },
                                        child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: isSelected
                                                  ? Border.all(
                                                      color: widget.mainColor,
                                                      width: 3)
                                                  : null,
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withOpacity(0.05),
                                                  blurRadius: 10,
                                                  offset: const Offset(0, 4),
                                                ),
                                              ],
                                            ),
                                            child: _buildImageCard(
                                                ref, isSelected)));
                                  }, childCount: _images.length))
                          ])))
        ]));
  }
}

class PackingListLibraryScreen extends StatefulWidget {
  final String agencyCode;
  final Color mainColor;
  final bool isNested;

  const PackingListLibraryScreen({
    super.key,
    required this.agencyCode,
    required this.mainColor,
    this.isNested = false,
  });

  @override
  State<PackingListLibraryScreen> createState() =>
      _PackingListLibraryScreenState();
}

class _PackingListLibraryScreenState extends State<PackingListLibraryScreen> {
  void _addOrEditCategory(
      [Map<String, dynamic>? existingCategory, int? index]) {
    showDialog(
      context: context,
      builder: (context) => _PackingListCategoryDialog(
        category: existingCategory,
        color: widget.mainColor,
        onSave: (category) async {
          final docRef = FirebaseFirestore.instance
              .collection('agency')
              .doc(widget.agencyCode);
          final doc = await docRef.get();
          List<dynamic> currentLibrary = [];
          if (doc.exists && doc.data()!.containsKey('packingListLibrary')) {
            currentLibrary = List.from(doc.data()!['packingListLibrary']);
          }

          if (index != null) {
            currentLibrary[index] = category;
          } else {
            currentLibrary.add(category);
          }

          await docRef.update({'packingListLibrary': currentLibrary});
        },
      ),
    );
  }

  void _deleteCategory(int index, List<dynamic> currentLibrary) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Slet kategori?'),
        content:
            const Text('Er du sikker på, at du vil slette denne kategori?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuller')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Slet', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm == true) {
      currentLibrary.removeAt(index);
      await FirebaseFirestore.instance
          .collection('agency')
          .doc(widget.agencyCode)
          .update({'packingListLibrary': currentLibrary});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: widget.isNested
          ? null
          : AppBar(
              title: Text('Pakkelister',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              centerTitle: true,
              elevation: 0,
              backgroundColor: widget.mainColor,
              foregroundColor: Colors.white,
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addOrEditCategory(),
        backgroundColor: widget.mainColor,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('agency')
            .doc(widget.agencyCode)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data!.data() as Map<String, dynamic>?;
          final library = List<Map<String, dynamic>>.from(
              data?['packingListLibrary'] ?? []);

          if (library.isEmpty) {
            return Center(
              child: Text('Ingen pakkelister i biblioteket',
                  style: GoogleFonts.kanit(color: Colors.grey)),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: library.length,
            itemBuilder: (context, index) {
              final category = library[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  leading: Icon(
                      MdiIcons.fromString(
                              category['iconName'] ?? 'mdi-folder') ??
                          MdiIcons.folder,
                      color: widget.mainColor),
                  title: Text(category['categoryName'] ?? 'Uden navn',
                      style: GoogleFonts.kanit(fontWeight: FontWeight.w500)),
                  subtitle: Text(
                      '${(category['items'] as List?)?.length ?? 0} ting',
                      style: GoogleFonts.kanit(fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.grey),
                        onPressed: () => _addOrEditCategory(category, index),
                      ),
                      IconButton(
                        icon:
                            const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () => _deleteCategory(index, library),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _PackingListCategoryDialog extends StatefulWidget {
  final Map<String, dynamic>? category;
  final Function(Map<String, dynamic>) onSave;
  final Color? color;

  const _PackingListCategoryDialog(
      {super.key, this.category, required this.onSave, this.color});

  @override
  State<_PackingListCategoryDialog> createState() =>
      _PackingListCategoryDialogState();
}

class _PackingListCategoryDialogState
    extends State<_PackingListCategoryDialog> {
  late TextEditingController _nameController;
  List<String> _items = [];
  String _selectedIconName = 'mdi-folder';

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.category?['categoryName'] ?? '');
    if (widget.category != null) {
      _selectedIconName = widget.category?['iconName'] ?? 'mdi-folder';
      if (widget.category!['items'] != null) {
        _items = List<String>.from(widget.category!['items']);
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _addItem() {
    final itemController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tilføj genstand'),
        content: TextField(
          controller: itemController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Genstande'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuller')),
          ElevatedButton(
              onPressed: () {
                if (itemController.text.isNotEmpty) {
                  setState(() => _items.add(itemController.text));
                  Navigator.pop(context);
                }
              },
              child: const Text('Tilføj')),
        ],
      ),
    );
  }

  void _pickIcon() {
    final mdiIcons = {
      'mdi-folder': MdiIcons.folder,
      'mdi-tshirt-crew': MdiIcons.tshirtCrew,
      'mdi-lotion-outline': MdiIcons.lotionOutline,
      'mdi-pill': MdiIcons.pill,
      'mdi-camera': MdiIcons.camera,
      'mdi-passport': MdiIcons.passport,
      'mdi-beach': MdiIcons.beach,
      'mdi-hiking': MdiIcons.hiking,
      'mdi-wallet': MdiIcons.wallet,
      'mdi-sunglasses': MdiIcons.sunglasses,
      'mdi-book-open-variant': MdiIcons.bookOpenVariant,
      'mdi-food-apple': MdiIcons.foodApple,
      'mdi-star': MdiIcons.star,
      'mdi-gift': MdiIcons.gift,
      'mdi-headphones': MdiIcons.headphones,
      'mdi-power-plug': MdiIcons.powerPlug,
    };

    showDialog(
      context: context,
      builder: (iconDialogContext) => Dialog(
        backgroundColor: AppColors.iconPickerDialog,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20.0)),
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
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
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
                      final isSelected = entry.key == _selectedIconName;
                      return InkWell(
                        onTap: () {
                          setState(() => _selectedIconName = entry.key);
                          Navigator.pop(iconDialogContext);
                        },
                        child: Container(
                          decoration: BoxDecoration(
                              color: isSelected
                                  ? Colors.brown[400]
                                  : Colors.brown[100],
                              borderRadius: BorderRadius.circular(12)),
                          child: Icon(entry.value,
                              size: 36,
                              color:
                                  isSelected ? Colors.white : Colors.black87),
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

  @override
  Widget build(BuildContext context) {
    final themeColor = widget.color ?? AppColors.primary;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 500,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: themeColor.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.edit_note, color: themeColor, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    widget.category == null
                        ? 'Ny Kategori'
                        : 'Rediger Kategori',
                    style: GoogleFonts.kanit(
                        fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Name Field
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Kategori Navn',
                  labelStyle: GoogleFonts.kanit(color: Colors.grey[600]),
                  prefixIcon:
                      Icon(Icons.label_outline, color: Colors.grey[400]),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: themeColor, width: 2),
                  ),
                  filled: true,
                  fillColor: Colors.grey[50],
                ),
                style: GoogleFonts.kanit(),
              ),
              const SizedBox(height: 16),

              // Icon Picker
              InkWell(
                onTap: _pickIcon,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 4,
                            )
                          ],
                        ),
                        child: Icon(
                          MdiIcons.fromString(_selectedIconName) ??
                              MdiIcons.folder,
                          color: themeColor,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Ikon',
                              style: GoogleFonts.kanit(
                                  fontSize: 12, color: Colors.grey[600])),
                          Text(_selectedIconName,
                              style: GoogleFonts.kanit(
                                  fontSize: 14, fontWeight: FontWeight.w500)),
                        ],
                      ),
                      const Spacer(),
                      Icon(Icons.arrow_forward_ios,
                          size: 16, color: Colors.grey[400]),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Items Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Indhold',
                      style: GoogleFonts.kanit(
                          fontSize: 18, fontWeight: FontWeight.w600)),
                  TextButton.icon(
                    onPressed: _addItem,
                    icon: Icon(Icons.add_circle_outline,
                        size: 20, color: themeColor),
                    label: Text('Tilføj',
                        style: GoogleFonts.kanit(color: themeColor)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      backgroundColor: themeColor.withOpacity(0.1),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Items List
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[200]!),
                  ),
                  child: _items.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.format_list_bulleted,
                                  color: Colors.grey[300], size: 48),
                              const SizedBox(height: 8),
                              Text('Ingen genstande tilføjet',
                                  style: GoogleFonts.kanit(
                                      color: Colors.grey[500])),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(8),
                          itemCount: _items.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            return ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: const Icon(Icons.circle,
                                  size: 8, color: Colors.grey),
                              title: Text(_items[index],
                                  style: GoogleFonts.kanit()),
                              trailing: IconButton(
                                icon: const Icon(Icons.close,
                                    color: Colors.grey, size: 18),
                                onPressed: () =>
                                    setState(() => _items.removeAt(index)),
                                splashRadius: 20,
                              ),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 24),

              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Annuller',
                        style: GoogleFonts.kanit(color: Colors.grey[600])),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () {
                      if (_nameController.text.isNotEmpty) {
                        widget.onSave({
                          'categoryName': _nameController.text,
                          'iconName': _selectedIconName,
                          'items': _items,
                        });
                        Navigator.pop(context);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('Gem',
                        style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DuplicateGroupDialog extends StatefulWidget {
  final GroupInformation originalGroup;

  const _DuplicateGroupDialog({required this.originalGroup});

  @override
  State<_DuplicateGroupDialog> createState() => _DuplicateGroupDialogState();
}

class _DuplicateGroupDialogState extends State<_DuplicateGroupDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _groupIdController;
  late TextEditingController _groupNameController;
  late DateTime _departureDate;
  late DateTime _returnDate;
  bool _isLoading = false;
  bool _isTemplate = false;

  @override
  void initState() {
    super.initState();
    _groupIdController =
        TextEditingController(text: '${widget.originalGroup.groupId}_copy');
    _groupNameController = TextEditingController(
        text:
            '${widget.originalGroup.groupName ?? widget.originalGroup.bureauName} (Kopi)');
    _departureDate = widget.originalGroup.departureDate;
    _returnDate = widget.originalGroup.returnDate;
    _isTemplate = widget.originalGroup.isTemplate ?? false;
  }

  @override
  void dispose() {
    _groupIdController.dispose();
    _groupNameController.dispose();
    super.dispose();
  }

  Future<void> _duplicateGroup() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });
      try {
        final durationDiff =
            _departureDate.difference(widget.originalGroup.departureDate);

        List<TimelineEvent> newTimelineEvents = [];
        for (var e in widget.originalGroup.timelineEvents) {
          String? newImageUrl = e.imageURL;
          if (e.imageURL.isNotEmpty && e.imageURL.contains('firebasestorage')) {
            try {
              final ref = FirebaseStorage.instance.refFromURL(e.imageURL);
              final data = await ref.getData();
              if (data != null) {
                final agencyCode = widget.originalGroup.agencyCode;
                final targetPath =
                    'agencies/$agencyCode/timeline_images/${ref.name}';

                // Only copy if it's not already in the agency folder
                if (ref.fullPath != targetPath) {
                  final newRef =
                      FirebaseStorage.instance.ref().child(targetPath);
                  await newRef.putData(data);
                  newImageUrl = await newRef.getDownloadURL();
                }
              }
            } catch (err) {
              debugPrint('Error copying image: $err');
            }
          }

          newTimelineEvents.add(TimelineEvent(
            id: e.id,
            type: e.type,
            country: e.country,
            startDate: e.startDate.add(durationDiff),
            endDate: e.endDate.add(durationDiff),
            dayNumber: e.dayNumber,
            isDestination: e.isDestination,
            imageURL: newImageUrl ?? '',
            description: e.description,
            accommodation: e.accommodation,
            transport: e.transport,
            transportIcon: e.transportIcon,
            meals: e.meals,
            activities: e.activities,
          ));
        }

        final newPackingLists =
            widget.originalGroup.packinglistCategories.map((e) {
          return PackinglistCategories(
            iconName: e.iconName,
            categoryName: e.categoryName,
            items: List.from(e.items),
          );
        }).toList();

        final group = GroupInformation(
          groupId: _groupIdController.text,
          id: _groupIdController.text,
          groupName: _groupNameController.text,
          coupons: widget.originalGroup.coupons != null
              ? List.from(widget.originalGroup.coupons!)
              : [],
          bureauName: widget.originalGroup.bureauName,
          agencyCode: widget.originalGroup.agencyCode,
          departureDate: _departureDate,
          returnDate: _returnDate,
          members: [],
          guides: [],
          timelineEvents: newTimelineEvents,
          packinglistCategories: newPackingLists,
          flightAway: widget.originalGroup.flightAway,
          flightHome: widget.originalGroup.flightHome,
          emergencyPhone: widget.originalGroup.emergencyPhone,
          departureFrom: widget.originalGroup.departureFrom,
          returnTo: widget.originalGroup.returnTo,
          isTemplate: _isTemplate,
        );

        await FirebaseFirestore.instance
            .collection('groups')
            .doc(group.groupId)
            .set({
          'groupId': group.groupId,
          'coupons': group.coupons?.map((e) => e.toMap()).toList(),
          'id': group.groupId,
          'groupName': group.groupName,
          'bureauName': group.bureauName,
          'agencyCode': group.agencyCode,
          'departureDate': group.departureDate,
          'returnDate': group.returnDate,
          'members': group.members.map((e) => e.toMap()).toList(),
          'guides': group.guides.map((e) => e.toMap()).toList(),
          'timelineEvents': group.timelineEvents.map((e) => e.toMap()).toList(),
          'packinglistCategories':
              group.packinglistCategories.map((e) => e.toMap()).toList(),
          'flightAway': group.flightAway,
          'flightHome': group.flightHome,
          'emergencyPhone': group.emergencyPhone,
          'departureFrom': group.departureFrom,
          'returnTo': group.returnTo,
          'isTemplate': group.isTemplate,
        });

        await FirebaseStorage.instance
            .ref('${group.groupId}/documents/.keep')
            .putString('');

        if (mounted) {
          Navigator.of(context).pop(group);
        }
      } catch (e) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fejl: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text('Dupliker rejse',
          style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _groupNameController,
                  decoration: InputDecoration(
                    labelText: 'Gruppe Navn',
                    prefixIcon: const Icon(Icons.label),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (v) => v!.isEmpty ? 'Påkrævet' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _groupIdController,
                  decoration: InputDecoration(
                    labelText: 'Ny Gruppe ID',
                    prefixIcon: const Icon(Icons.vpn_key),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (v) => v!.isEmpty ? 'Påkrævet' : null,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _departureDate,
                            firstDate: DateTime.now()
                                .subtract(const Duration(days: 365)),
                            lastDate: DateTime.now()
                                .add(const Duration(days: 365 * 5)),
                          );
                          if (picked != null)
                            setState(() => _departureDate = picked);
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Ny Afrejse',
                            prefixIcon: const Icon(Icons.calendar_today),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          child: Text(
                              DateFormat('dd/MM/yyyy').format(_departureDate)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _returnDate,
                            firstDate: DateTime.now()
                                .subtract(const Duration(days: 365)),
                            lastDate: DateTime.now()
                                .add(const Duration(days: 365 * 5)),
                          );
                          if (picked != null)
                            setState(() => _returnDate = picked);
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Ny Hjemkomst',
                            prefixIcon: const Icon(Icons.event),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          child: Text(
                              DateFormat('dd/MM/yyyy').format(_returnDate)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Du kan ændre dette til en skabelon:',
                    style: GoogleFonts.kanit(
                        color: Colors.grey[600], fontSize: 14),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: SwitchListTile(
                    title: Text(_isTemplate ? 'Skabelon' : 'Rejse'),
                    subtitle: Text(_isTemplate
                        ? 'Gemmes som en skabelon til fremtidig brug.'
                        : 'Oprettes som en almindelig rejse.'),
                    value: _isTemplate,
                    onChanged: (val) => setState(() => _isTemplate = val),
                    activeColor: AppColors.primary,
                    secondary: Icon(_isTemplate
                        ? Icons.copy_all_outlined
                        : Icons.flight_takeoff),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _isLoading ? null : () => Navigator.pop(context),
            child: const Text('Annuller')),
        ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _isLoading ? null : _duplicateGroup,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Dupliker')),
      ],
    );
  }
}

class _AddGroupDialog extends StatefulWidget {
  final String bureauName;
  final String agencyCode;

  const _AddGroupDialog({required this.bureauName, required this.agencyCode});

  @override
  State<_AddGroupDialog> createState() => _AddGroupDialogState();
}

class _AddGroupDialogState extends State<_AddGroupDialog> {
  final _formKey = GlobalKey<FormState>();
  final _groupIdController = TextEditingController();
  final _groupNameController = TextEditingController();

  DateTime _departureDate = DateTime.now();
  DateTime _returnDate = DateTime.now().add(const Duration(days: 7));
  final bool _flightAway = false;
  final bool _flightHome = false;
  bool _isTemplate = false;

  List<Map<String, dynamic>> _library = [];
  final Set<int> _selectedLibraryIndices = {};
  bool _loadingLibrary = true;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('agency')
          .doc(widget.agencyCode)
          .get();
      if (doc.exists && doc.data()!.containsKey('packingListLibrary')) {
        setState(() {
          _library = List<Map<String, dynamic>>.from(
              doc.data()!['packingListLibrary']);
          _loadingLibrary = false;
        });
      } else {
        setState(() => _loadingLibrary = false);
      }
    } catch (e) {
      setState(() => _loadingLibrary = false);
    }
  }

  @override
  void dispose() {
    _groupIdController.dispose();
    _groupNameController.dispose();
    super.dispose();
  }

  Future<void> _saveGroup() async {
    if (_formKey.currentState!.validate()) {
      try {
        final group = GroupInformation(
          groupId: _groupIdController.text,
          id: "1",
          groupName: _groupNameController.text,
          coupons: [],
          bureauName: widget.bureauName,
          agencyCode: widget.agencyCode,
          departureDate: _departureDate,
          returnDate: _returnDate,
          members: [],
          guides: [],
          timelineEvents: [
            TimelineEvent(
              id: 'template_1',
              type: 'Fx. Ankomst til Hoi An',
              country: 'Fx. Vietnam',
              startDate: _departureDate,
              endDate: _departureDate.add(const Duration(days: 1)),
              dayNumber: 1,
              isDestination: false,
              imageURL:
                  'https://images.unsplash.com/photo-1519414442781-fbd745c5b497?w=900&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8M3x8c3Vuc2V0JTIwbW91bnRhaW5zfGVufDB8MHwwfHx8MA%3D%3D',
              description: 'Skriv her en beskrivelse af begivenheden',
            ),
          ],
          packinglistCategories: _library.isNotEmpty
              ? _selectedLibraryIndices.map((i) {
                  final item = _library[i];
                  return PackinglistCategories(
                    iconName: item['iconName'] ?? 'folder',
                    categoryName: item['categoryName'] ?? 'Pakkeliste',
                    items: List<String>.from(item['items'] ?? []),
                  );
                }).toList()
              : [
                  PackinglistCategories(
                    iconName: 'text_box_multiple_outline',
                    categoryName: 'Dokumenter',
                    items: ['Pas', 'Lokal valuta', 'Rejseforsikring'],
                  ),
                ],
          flightAway: _flightAway,
          flightHome: _flightHome,
          emergencyPhone: '',
          departureFrom: '',
          returnTo: '',
          isTemplate: _isTemplate,
        );

        await FirebaseFirestore.instance
            .collection('groups')
            .doc(group.groupId)
            .set({
          'groupId': group.groupId,
          'coupons': group.coupons?.map((e) => e.toMap()).toList(),
          'id': group.groupId,
          'groupName': group.groupName,
          'bureauName': group.bureauName,
          'agencyCode': group.agencyCode,
          'departureDate': group.departureDate,
          'returnDate': group.returnDate,
          'members': group.members.map((e) => e.toMap()).toList(),
          'guides': group.guides.map((e) => e.toMap()).toList(),
          'timelineEvents': group.timelineEvents.map((e) => e.toMap()).toList(),
          'packinglistCategories':
              group.packinglistCategories.map((e) => e.toMap()).toList(),
          'flightAway': group.flightAway,
          'flightHome': group.flightHome,
          'emergencyPhone': group.emergencyPhone,
          'departureFrom': group.departureFrom,
          'returnTo': group.returnTo,
          'isTemplate': group.isTemplate,
        });

        // Add standard message if exists
        final agencyDoc = await FirebaseFirestore.instance
            .collection('agency')
            .doc(widget.agencyCode)
            .get();
        final standardMessage = agencyDoc.data()?['standardMessage'] as String?;
        final standardMessageTitle =
            agencyDoc.data()?['standardMessageTitle'] as String? ?? 'Velkommen';

        if (standardMessage != null && standardMessage.isNotEmpty) {
          await FirebaseFirestore.instance
              .collection('groups')
              .doc(group.groupId)
              .collection('messages')
              .add({
            'title': standardMessageTitle,
            'content': standardMessage,
            'timestamp': FieldValue.serverTimestamp(),
          });
        }

        if (mounted) {
          Navigator.of(context).pop(group);
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fejl: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text('Tilføj ny rejse',
          style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.business, color: Colors.black54),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.bureauName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            Text('Kode: ${widget.agencyCode}',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.black54)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _groupNameController,
                  decoration: InputDecoration(
                    labelText: 'Gruppe Navn',
                    prefixIcon: const Icon(Icons.label),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (v) => v!.isEmpty ? 'Påkrævet' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _groupIdController,
                  decoration: InputDecoration(
                    labelText: 'Gruppe ID',
                    prefixIcon: const Icon(Icons.vpn_key),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (v) => v!.isEmpty ? 'Påkrævet' : null,
                ),
                const SizedBox(height: 16),
                if (_loadingLibrary)
                  const Center(child: CircularProgressIndicator())
                else if (_library.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Vælg pakkelister',
                        style: GoogleFonts.kanit(color: Colors.grey[600])),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _library.length,
                      itemBuilder: (context, index) {
                        final item = _library[index];
                        return CheckboxListTile(
                          dense: true,
                          title: Text(item['categoryName'] ?? '',
                              style: GoogleFonts.kanit()),
                          value: _selectedLibraryIndices.contains(index),
                          onChanged: (val) {
                            setState(() {
                              if (val == true) {
                                _selectedLibraryIndices.add(index);
                              } else {
                                _selectedLibraryIndices.remove(index);
                              }
                            });
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _departureDate,
                            firstDate: DateTime.now()
                                .subtract(const Duration(days: 365)),
                            lastDate: DateTime.now()
                                .add(const Duration(days: 365 * 2)),
                          );
                          if (picked != null)
                            setState(() => _departureDate = picked);
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Afrejse',
                            prefixIcon: const Icon(Icons.calendar_today),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          child: Text(
                              DateFormat('dd/MM/yyyy').format(_departureDate)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _returnDate,
                            firstDate: DateTime.now()
                                .subtract(const Duration(days: 365)),
                            lastDate: DateTime.now()
                                .add(const Duration(days: 365 * 2)),
                          );
                          if (picked != null)
                            setState(() => _returnDate = picked);
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Hjemkomst',
                            prefixIcon: const Icon(Icons.event),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          child: Text(
                              DateFormat('dd/MM/yyyy').format(_returnDate)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Du kan ændre dette til en skabelon:',
                    style: GoogleFonts.kanit(
                        color: Colors.grey[600], fontSize: 14),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: SwitchListTile(
                    title: Text(_isTemplate ? 'Skabelon' : 'Rejse'),
                    subtitle: Text(_isTemplate
                        ? 'Oprettes som en skabelon til fremtidig brug.'
                        : 'Oprettes som en almindelig rejse.'),
                    value: _isTemplate,
                    onChanged: (val) => setState(() => _isTemplate = val),
                    activeColor: AppColors.primary,
                    secondary: Icon(_isTemplate
                        ? Icons.copy_all_outlined
                        : Icons.flight_takeoff),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuller')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: _saveGroup,
          child: const Text('Opret'),
        ),
      ],
    );
  }
}
