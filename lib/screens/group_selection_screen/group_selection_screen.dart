import 'package:backend/models/agencyInformation.dart';
import 'package:backend/config/design.dart';
import 'package:backend/config/permissions.dart';
import 'package:backend/screens/group_selection_screen/ai_trip_builder_screen.dart';
import 'package:backend/screens/group_selection_screen/crm_integration_screen.dart';
import 'package:backend/screens/group_selection_screen/dashboard_screen.dart';
import 'package:backend/screens/group_selection_screen/email_integration_screen.dart';
import 'package:backend/screens/group_selection_screen/users_screen.dart';
import 'package:backend/screens/group_selection_screen/team_screen.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/config/app_colors.dart';
import 'package:backend/models/packinglist_model.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:backend/widget/bureauLogoHeader.dart';
import 'package:backend/widget/logout.dart';
import 'package:backend/widget/saved_snackbar.dart';
import 'package:backend/widget/support_dialog.dart';
import 'package:backend/widget/powered_by_backpack.dart';
import 'package:backend/blocs/groupinformation/groupinformation_bloc.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:backend/screens/groupIDscreen/groupIDscreen.dart';
import 'package:backend/screens/home/homescreen.dart';
import 'package:backend/screens/details/detailsscreen.dart';
import 'package:backend/screens/group_selection_screen/app_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'package:backend/widget/app_snackbar.dart';

enum SideMenuItem {
  dashboard,
  groups,
  groupOverview,
  groupDetails,
  templates,
  photoLibrary,
  packingList,
  users,
  team,
  app,
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
  SideMenuItem _selectedMenuItem = SideMenuItem.dashboard;
  GroupInformation? _selectedGroup;
  final ScrollController _scrollController = ScrollController();
  bool _isGridView = false; // Default to ListView
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _GroupFilters _filters = _GroupFilters();
  // "Rejser" only shows current/upcoming trips by default — past trips
  // (returnDate before today) are hidden until explicitly asked for via
  // the toggle next to the search bar. Doesn't apply to Skabeloner, whose
  // dates are template defaults, not real trip dates.
  bool _showPastTrips = false;

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
    _scrollController.dispose();
    super.dispose();
  }

  void _selectGroup(BuildContext context, GroupInformation group) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('groupId', group.groupId);

    context
        .read<GroupInformationBloc>()
        .add(LoadGroupInformationById(groupId: group.groupId));
  }

  Future<void> _handleLogout() => performLogout(context);

  void _showFilterDialog(Color primaryColor) async {
    final newFilters = await showDialog<_GroupFilters>(
      context: context,
      builder: (context) => _FilterDialog(
        currentFilters: _filters,
        primaryColor: primaryColor,
        departureLocations: (_groups
                .where((g) => g.isTemplate != true)
                .map((g) => g.departureFrom.trim())
                .where((loc) => loc.isNotEmpty)
                .toSet()
                .toList()
              ..sort()),
      ),
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
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    'Dette kan ikke fortrydes. Indtast din adgangskode for at bekræfte.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: AppSpacing.lg),
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
        showAppSnackbar(context, 'Rejse slettet');
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
      // Only current/upcoming trips by default — a trip counts as "past"
      // once its returnDate is before today. Templates have no real trip
      // dates, so this only applies to the actual Rejser list. An explicit
      // status filter takes over, so "Afsluttede" can actually show them.
      if (_showPastTrips ||
          _filters.status != null ||
          _selectedMenuItem == SideMenuItem.templates) {
        return true;
      }
      final today = DateUtils.dateOnly(DateTime.now());
      return !DateUtils.dateOnly(g.returnDate).isBefore(today);
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
      if (_filters.status != null) {
        passes = passes && _TripStatus.of(g) == _filters.status;
      }
      if (_filters.departureFrom != null) {
        passes = passes && g.departureFrom.trim() == _filters.departureFrom;
      }
      if (_filters.hasGuide != null) {
        passes = passes && g.guides.isNotEmpty == _filters.hasGuide;
      }
      if (_filters.mapEnabled != null) {
        passes = passes && g.mapEnabled == _filters.mapEnabled;
      }
      return passes;
    }).toList();
    // Trips are listed by start date — soonest first unless the filter asks
    // for latest first. Templates have no real dates, so they keep their
    // existing order.
    if (_selectedMenuItem != SideMenuItem.templates) {
      displayedGroups.sort((a, b) => _filters.newestFirst
          ? b.departureDate.compareTo(a.departureDate)
          : a.departureDate.compareTo(b.departureDate));
    }

    return BlocListener<GroupInformationBloc, GroupInformationState>(
      listener: (context, state) {
        if (state is GroupInformationLoaded) {
          setState(() {
            _selectedGroup = state.groupInformation;
            _selectedMenuItem = SideMenuItem.groupOverview;
          });
        } else if (state is GroupInformationError) {
          showErrorSnackbar(context, state.message);
        }
      },
      child: AgencyPermissionsResolver(
        agencyCode: agencyCode,
        builder: (context, permissions) => StreamBuilder<DocumentSnapshot>(
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
                  drawer: isDesktop
                      ? null
                      : _buildSideMenu(appBarColor, agencyInfo, permissions),
                  appBar: AppBar(
                    automaticallyImplyLeading: !isDesktop,
                    centerTitle: true,
                    toolbarHeight: 50,
                    title: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(0.5),
                          child: BureauLogoHeader(
                            agencyCode: agencyCode,
                            fallbackText: agencyInfo.agencyName,
                            height: 40,
                          ),
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
                          ((_selectedMenuItem == SideMenuItem.groups &&
                                  permissions.contains('trips.create')) ||
                              (_selectedMenuItem == SideMenuItem.templates &&
                                  permissions.contains('templates.edit')))
                      ? FloatingActionButton(
                          backgroundColor: AppColors.navActive,
                          onPressed: () => _showAddGroupOptions(
                              context, agencyInfo, agencyCode),
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
                          _buildSideMenu(appBarColor, agencyInfo, permissions,
                              isDrawer: false),
                        Expanded(
                          child: _buildMainContent(
                            appBarColor: appBarColor,
                            agencyCode: agencyCode,
                            agencyInfo: agencyInfo,
                            data: data,
                            displayedGroups: displayedGroups,
                            isDesktop: isDesktop,
                            permissions: permissions,
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
      ),
    );
  }

  /// Shown when `_selectedMenuItem` points at a screen the caller's role
  /// doesn't have the matching permission for — reached via a dashboard
  /// shortcut or a stale selection rather than the (already-hidden)
  /// sidebar item, so this is the single choke point every path funnels
  /// through, not just the sidebar's own visibility gate.
  Widget _buildAccessDenied(Color themeColor) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 40, color: Colors.grey[400]),
            const SizedBox(height: AppSpacing.md),
            Text('Ingen adgang', style: AppTextStyles.headingBold()),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Din rolle giver ikke adgang til denne side.',
              style: AppTextStyles.body(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _showAddGroupOptions(
      BuildContext context, AgencyInformation agencyInfo, String agencyCode) {
    final themeColor = AppColors.fromHex(agencyInfo.mainColor);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Icon(Icons.edit_outlined, color: themeColor),
                title: Text('Opret manuelt',
                    style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                subtitle: Text('Udfyld rejsens oplysninger selv',
                    style: GoogleFonts.kanit(fontSize: 12)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openAddGroupDialog(context, agencyInfo, agencyCode);
                },
              ),
              ListTile(
                leading: Icon(Icons.auto_awesome, color: themeColor),
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Byg med AI',
                        style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                    if (!agencyInfo.aiTripBuilderEnabled) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF4E5),
                          borderRadius: AppRadii.lgRadius,
                        ),
                        child: Text('Ikke i din plan',
                            style: GoogleFonts.kanit(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF9A6700))),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                    'Upload flybilletter og bekræftelser — AI\'en bygger et udkast',
                    style: GoogleFonts.kanit(fontSize: 12)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (!agencyInfo.aiTripBuilderEnabled) {
                    showWarningSnackbar(context, 'AI Trip Builder er ikke en del af jeres plan endnu — se mere under Indstillinger.');
                    return;
                  }
                  Navigator.of(context)
                      .push(
                    MaterialPageRoute(
                      builder: (_) => AiTripBuilderScreen(
                        themeColor: themeColor,
                        agencyCode: agencyCode,
                        bureauName: agencyInfo.agencyName,
                      ),
                    ),
                  )
                      .then((newGroup) {
                    if (newGroup is GroupInformation && mounted) {
                      setState(() {
                        _groups.add(newGroup);
                      });
                    }
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openAddGroupDialog(
      BuildContext context, AgencyInformation agencyInfo, String agencyCode) {
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
  }

  Widget _buildMainContent({
    required Color appBarColor,
    required String agencyCode,
    required AgencyInformation agencyInfo,
    required Map<String, dynamic> data,
    required List<GroupInformation> displayedGroups,
    required bool isDesktop,
    required Set<String> permissions,
  }) {
    if (_selectedMenuItem == SideMenuItem.dashboard) {
      return DashboardScreen(
        groups: _groups,
        agencyCode: agencyCode,
        mainColor: appBarColor,
        onNavigateToGroups: () =>
            setState(() => _selectedMenuItem = SideMenuItem.groups),
        onNavigateToUsers: () =>
            setState(() => _selectedMenuItem = SideMenuItem.users),
        onNavigateToTeam: permissions.contains('employees.manage')
            ? () => setState(() => _selectedMenuItem = SideMenuItem.team)
            : null,
        onSelectGroup: (group) => _selectGroup(context, group),
        onCreateGroup: permissions.contains('trips.create')
            ? () => _openAddGroupDialog(context, agencyInfo, agencyCode)
            : null,
        onOpenCrm: permissions.contains('crm_integration.edit')
            ? () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) =>
                        CrmIntegrationScreen(agencyInfo: agencyInfo),
                  ),
                )
            : null,
      );
    } else if (_selectedMenuItem == SideMenuItem.groupOverview &&
        _selectedGroup != null) {
      return HomeScreen(
        scrollController: _scrollController,
        canEditTrips: permissions.contains('trips.edit'),
      );
    } else if (_selectedMenuItem == SideMenuItem.groupDetails &&
        _selectedGroup != null) {
      return GroupDetailsScreen(
        groupId: _selectedGroup!.groupId,
        repository: context.read<GroupInformationRepository>(),
        agencyInfo: agencyInfo,
        canEditTrips: permissions.contains('trips.edit'),
      );
    } else if (_selectedMenuItem == SideMenuItem.photoLibrary) {
      if (!permissions.contains('photo_library.edit')) {
        return _buildAccessDenied(appBarColor);
      }
      return AgencyImagesScreen(
        agencyCode: agencyCode,
        mainColor: appBarColor,
        photoStorageLimitGb: agencyInfo.photoStorageLimitGb,
        isNested: true,
      );
    } else if (_selectedMenuItem == SideMenuItem.packingList) {
      if (!permissions.contains('packing_lists.edit')) {
        return _buildAccessDenied(appBarColor);
      }
      return PackingListLibraryScreen(
        agencyCode: agencyCode,
        mainColor: appBarColor,
        isNested: true,
      );
    } else if (_selectedMenuItem == SideMenuItem.users) {
      if (!permissions.contains('users.edit')) {
        return _buildAccessDenied(appBarColor);
      }
      return UsersScreen(
        agencyCode: agencyCode,
        mainColor: appBarColor,
        isNested: true,
      );
    } else if (_selectedMenuItem == SideMenuItem.team) {
      if (!permissions.contains('employees.manage')) {
        return _buildAccessDenied(appBarColor);
      }
      return TeamScreen(
        agencyCode: agencyCode,
        mainColor: appBarColor,
        isNested: true,
      );
    } else if (_selectedMenuItem == SideMenuItem.app) {
      if (!permissions.contains('app_settings.edit')) {
        return _buildAccessDenied(appBarColor);
      }
      return AppScreen(
        agencyInfo: agencyInfo,
        logoUrl: data['logoUrl'] as String?,
        isNested: true,
      );
    } else if (_selectedMenuItem == SideMenuItem.settings) {
      if (!permissions.contains('agency_settings.edit')) {
        return _buildAccessDenied(appBarColor);
      }
      return BureauSettingsScreen(
        agencyInfo: agencyInfo,
        standardMessage: data['standardMessage'] as String?,
        standardMessageTitle: data['standardMessageTitle'] as String?,
        isNested: true,
        onGroupCreated: (newGroup) {
          if (mounted) setState(() => _groups.add(newGroup));
        },
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
                      borderRadius: AppRadii.mdRadius,
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ),
              if (isDesktop) ...[
                const SizedBox(width: AppSpacing.lg),
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
              if (_selectedMenuItem != SideMenuItem.templates) ...[
                const SizedBox(width: AppSpacing.sm),
                _PastTripsToggle(
                  themeColor: appBarColor,
                  active: _showPastTrips,
                  onTap: () => setState(() => _showPastTrips = !_showPastTrips),
                ),
              ],
              const SizedBox(width: AppSpacing.sm),
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
                          : (!_showPastTrips &&
                                  _selectedMenuItem != SideMenuItem.templates &&
                                  _groups.any((g) => g.isTemplate != true))
                              ? 'Ingen kommende rejser — tryk "Vis tidligere rejser" for at se overståede.'
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
                        itemBuilder: (context, index) => _buildGroupCard(
                            context, displayedGroups[index], appBarColor),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 24),
                        itemCount: displayedGroups.length,
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: _buildGroupCard(
                              context, displayedGroups[index], appBarColor),
                        ),
                      ),
          ),
        ),
      ],
    );
  }

  Widget _buildSideMenu(
      Color primaryColor, AgencyInformation agencyInfo, Set<String> permissions,
      {bool isDrawer = false}) {
    final menuContent = Container(
      width: 266,
      color: Colors.white,
      child: Column(
        children: [
          if (isDrawer)
            DrawerHeader(
              decoration: BoxDecoration(color: primaryColor),
              child: Center(
                child: BureauLogoHeader(
                  agencyCode: agencyInfo.agencyCode,
                  fallbackText: agencyInfo.agencyName,
                  height: 72,
                ),
              ),
            ),
          if (!isDrawer) const SizedBox(height: AppSpacing.xl),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildMenuOption(
                      'Dashboard',
                      Icons.space_dashboard,
                      SideMenuItem.dashboard,
                      primaryColor,
                      agencyInfo,
                      isDrawer),
                  _buildRejserMenuSection(primaryColor, agencyInfo, isDrawer),
                  if (permissions.contains('templates.edit'))
                    _buildMenuOption(
                        'Skabeloner',
                        Icons.copy_all,
                        SideMenuItem.templates,
                        primaryColor,
                        agencyInfo,
                        isDrawer),
                  if (permissions.contains('photo_library.edit'))
                    _buildMenuOption(
                        'Fotobibliotek',
                        Icons.photo_library,
                        SideMenuItem.photoLibrary,
                        primaryColor,
                        agencyInfo,
                        isDrawer),
                  if (permissions.contains('packing_lists.edit'))
                    _buildMenuOption(
                        'Pakkelister',
                        Icons.checklist,
                        SideMenuItem.packingList,
                        primaryColor,
                        agencyInfo,
                        isDrawer),
                  if (permissions.contains('users.edit'))
                    _buildMenuOption('Brugere', Icons.people,
                        SideMenuItem.users, primaryColor, agencyInfo, isDrawer),
                  if (permissions.contains('employees.manage'))
                    _buildMenuOption('Team', Icons.badge, SideMenuItem.team,
                        primaryColor, agencyInfo, isDrawer),
                  if (permissions.contains('app_settings.edit'))
                    _buildMenuOption('App', Icons.smartphone,
                        SideMenuItem.app, primaryColor, agencyInfo, isDrawer),
                  if (permissions.contains('agency_settings.edit'))
                    _buildMenuOption(
                        'Indstillinger',
                        Icons.settings,
                        SideMenuItem.settings,
                        primaryColor,
                        agencyInfo,
                        isDrawer),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: OutlinedButton.icon(
              onPressed: () => showSupportDialog(
                context,
                mainColor: primaryColor,
                agencyCode: agencyInfo.agencyCode,
                agencyName: agencyInfo.agencyName,
              ),
              icon: const Icon(Icons.support_agent),
              label: const Text('Support'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
                foregroundColor: Colors.grey[800],
                side: BorderSide(color: Colors.grey[400]!),
              ),
            ),
          ),
          _buildSwitchAgencyOption(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
          Divider(height: 1, indent: 16, endIndent: 16, color: Colors.grey[200]),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: PoweredByBackpack(),
          ),
        ],
      ),
    );

    return isDrawer ? Drawer(child: menuContent) : menuContent;
  }

  /// Only shown for accounts that actually have somewhere else to go:
  /// admins attached to more than one bureau, or BACKPACK-ADMIN accounts
  /// (which have implicit access to every bureau). Re-runs the same
  /// agency-resolution flow GroupIDScreen does on a fresh login, so it
  /// always reflects the account's current agencyCodes rather than
  /// whatever was true when this screen first loaded.
  Widget _buildSwitchAgencyOption() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot>(
      stream:
          FirebaseFirestore.instance.collection('admins').doc(uid).snapshots(),
      builder: (context, snapshot) {
        final agencyCodes = ((snapshot.data?.data()
                    as Map<String, dynamic>?)?['agencyCodes'] as List?)
                ?.whereType<String>()
                .toList() ??
            const <String>[];
        final canSwitch = agencyCodes.length > 1 ||
            agencyCodes.contains(GroupIDScreen.superAdminCode);
        if (!canSwitch) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: OutlinedButton.icon(
            onPressed: _handleSwitchAgency,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Skift bureau'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
              foregroundColor: Colors.grey[800],
              side: BorderSide(color: Colors.grey[400]!),
            ),
          ),
        );
      },
    );
  }

  void _handleSwitchAgency() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const GroupIDScreen()),
      (route) => false,
    );
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

  /// "Rejser" doubles as the trips list and, once a trip is selected, the
  /// parent of an Oversigt/Detaljer submenu — tapping it again while a trip
  /// is open collapses back to the list instead of navigating away.
  Widget _buildRejserMenuSection(
      Color primaryColor, AgencyInformation agencyInfo, bool isDrawer) {
    final agencyColor = AppColors.fromHex(agencyInfo.mainColor);
    final isInGroupView = _selectedMenuItem == SideMenuItem.groupOverview ||
        _selectedMenuItem == SideMenuItem.groupDetails;
    final isRejserActive =
        _selectedMenuItem == SideMenuItem.groups || isInGroupView;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ListTile(
            leading: Icon(Icons.flight,
                color: isRejserActive ? agencyColor : Colors.grey[700]),
            title: Text('Rejser',
                style: GoogleFonts.kanit(
                  color: isRejserActive ? agencyColor : Colors.black87,
                  fontWeight:
                      isRejserActive ? FontWeight.w600 : FontWeight.normal,
                )),
            trailing: _selectedGroup != null
                ? Icon(Icons.expand_less, size: 18, color: Colors.grey[500])
                : null,
            tileColor: isRejserActive && !isInGroupView
                ? agencyColor.withOpacity(0.1)
                : null,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            onTap: () {
              setState(() {
                _selectedGroup = null;
                _selectedMenuItem = SideMenuItem.groups;
              });
              if (isDrawer && mounted) Navigator.pop(context);
            },
          ),
        ),
        if (_selectedGroup != null) ...[
          Padding(
            padding:
                const EdgeInsets.only(left: 32, right: 16, top: 2, bottom: 2),
            child: Text(
              _selectedGroup!.groupName ?? _selectedGroup!.groupId,
              style: GoogleFonts.kanit(
                fontSize: 11,
                color: Colors.grey[500],
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _buildSubMenuOption('Oversigt', Icons.home,
              SideMenuItem.groupOverview, agencyColor, isDrawer),
          _buildSubMenuOption('Detaljer', Icons.info_outline,
              SideMenuItem.groupDetails, agencyColor, isDrawer),
          const SizedBox(height: AppSpacing.xs),
        ],
      ],
    );
  }

  Widget _buildSubMenuOption(String title, IconData icon, SideMenuItem item,
      Color agencyColor, bool isDrawer) {
    final isSelected = _selectedMenuItem == item;
    return Container(
      margin: const EdgeInsets.only(left: 24, right: 8, top: 2, bottom: 2),
      child: ListTile(
        leading: Icon(icon,
            color: isSelected ? agencyColor : Colors.grey[600], size: 20),
        title: Text(title,
            style: GoogleFonts.kanit(
              fontSize: 14,
              color: isSelected ? agencyColor : Colors.black87,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            )),
        tileColor: isSelected ? agencyColor.withOpacity(0.1) : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        dense: true,
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

  Widget _buildGroupCard(
      BuildContext context, GroupInformation group, Color themeColor) {
    final now = DateTime.now();
    final daysUntil = group.departureDate.difference(now).inDays;
    final daysLeft = group.returnDate.difference(now).inDays;

    final String statusLabel;
    final Color statusColor;
    if (group.isTemplate == true) {
      statusLabel = 'Skabelon';
      statusColor = Colors.grey[600]!;
    } else if (daysUntil > 0) {
      statusLabel = 'Om $daysUntil dage';
      statusColor = Colors.blue[700]!;
    } else if (daysLeft > 0) {
      statusLabel = 'I gang · $daysLeft dage tilbage';
      statusColor = Colors.green[700]!;
    } else {
      statusLabel = 'Afsluttet';
      statusColor = Colors.grey[600]!;
    }

    return InkWell(
      onTap: () => _selectGroup(context, group),
      borderRadius: AppRadii.lgRadius,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: AppRadii.lgRadius,
          boxShadow: AppShadows.card,
          border: Border(left: BorderSide(color: themeColor, width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, // allow card to grow with content
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.groupName ?? 'Unavngivet rejse',
                          style: AppTextStyles.headingBold(),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(group.groupId, style: AppTextStyles.caption()),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  _statusBadge(statusLabel, statusColor),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert,
                        color: Colors.grey[600], size: 20),
                    padding: EdgeInsets.zero,
                    onSelected: (value) {
                      switch (value) {
                        case 'edit':
                          _showEditGroupNameDialog(context, group);
                          break;
                        case 'duplicate':
                          _showDuplicateDialog(context, group);
                          break;
                        case 'delete':
                          _showDeleteDialog(context, group);
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Rediger navn'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'duplicate',
                        child: ListTile(
                          leading: Icon(Icons.copy_outlined),
                          title: Text('Dupliker rejse'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading:
                              Icon(Icons.delete_outline, color: Colors.red),
                          title: Text('Slet rejse',
                              style: TextStyle(color: Colors.red)),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Divider(height: 1, color: Colors.grey[200]),
              const SizedBox(height: AppSpacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _fieldTile(Icons.flight_takeoff, 'Afrejse',
                        '${DateFormat('dd. MMM yyyy', 'da_DK').format(group.departureDate)} · ${group.departureFrom}'),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _fieldTile(Icons.flight_land, 'Hjemkomst',
                        '${DateFormat('dd. MMM yyyy', 'da_DK').format(group.returnDate)} · ${group.returnTo}'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  _statTile(Icons.people_outline, '${group.members.length}',
                      'Medlemmer'),
                  const SizedBox(width: AppSpacing.xl),
                  _statTile(
                      Icons.support_agent, '${group.guides.length}', 'Guider'),
                  const Spacer(),
                  if (group.flightAway)
                    Padding(
                      padding: const EdgeInsets.only(left: AppSpacing.sm),
                      child: Icon(Icons.flight_takeoff,
                          size: 18, color: Colors.grey[400]),
                    ),
                  if (group.flightHome)
                    Padding(
                      padding: const EdgeInsets.only(left: AppSpacing.sm),
                      child: Icon(Icons.flight_land,
                          size: 18, color: Colors.grey[400]),
                    ),
                  const SizedBox(width: AppSpacing.md),
                  Icon(Icons.arrow_forward_ios,
                      color: Colors.grey[400], size: 16),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.kanit(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _fieldTile(IconData icon, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTextStyles.caption()
                .copyWith(letterSpacing: 0.3, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        Row(
          children: [
            Icon(icon, size: 15, color: Colors.grey[500]),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                value,
                style:
                    AppTextStyles.body().copyWith(fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statTile(IconData icon, String value, String label) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey[500]),
        const SizedBox(width: 5),
        Text(value,
            style: AppTextStyles.body().copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(width: 3),
        Text(label, style: AppTextStyles.caption()),
      ],
    );
  }
}

/// Toggle for revealing past trips in the Rejser list. A custom pill
/// instead of a plain FilterChip — FilterChip's selected state pulls from
/// Material's default ColorScheme (a purplish tone unrelated to the
/// bureau's own brand), so this uses the agency's actual theme color
/// explicitly instead, matching every other accent in the control panel.
class _PastTripsToggle extends StatelessWidget {
  const _PastTripsToggle({
    required this.themeColor,
    required this.active,
    required this.onTap,
  });

  final Color themeColor;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // No Tooltip (the label text already says what tapping it does — a
    // second, state-dependent tooltip on top was redundant) and no
    // AnimatedContainer. Both were removed after they lined up with a
    // Flutter-Web engine assertion spam (_engine/window.dart) — a
    // Tooltip whose message text changes while it could still be
    // showing/animating is a known trouble spot on the web renderer, and
    // this is a plain toggle button, not something that needs a live
    // color-transition animation.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: active ? themeColor.withValues(alpha: 0.12) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: active
                  ? themeColor.withValues(alpha: 0.5)
                  : Colors.grey[300]!,
            ),
            boxShadow: active ? null : AppShadows.card,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active ? Icons.history_toggle_off : Icons.history,
                size: 18,
                color: active ? themeColor : Colors.grey[700],
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                active ? 'Skjul tidligere rejser' : 'Vis tidligere rejser',
                style: AppTextStyles.label(
                    color: active ? themeColor : Colors.grey[800]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where a trip is relative to today — upcoming until it departs, ongoing
/// through its return date, finished after that.
enum _TripStatus {
  upcoming('Kommende'),
  ongoing('I gang'),
  finished('Afsluttede');

  const _TripStatus(this.label);
  final String label;

  static _TripStatus of(GroupInformation g) {
    final today = DateUtils.dateOnly(DateTime.now());
    if (DateUtils.dateOnly(g.departureDate).isAfter(today)) return upcoming;
    if (DateUtils.dateOnly(g.returnDate).isBefore(today)) return finished;
    return ongoing;
  }
}

class _GroupFilters {
  DateTime? departureDateStart;
  DateTime? departureDateEnd;
  bool? flightAway;
  bool? flightHome;
  _TripStatus? status;
  String? departureFrom;
  bool? hasGuide;
  bool? mapEnabled;
  bool newestFirst;

  _GroupFilters({this.newestFirst = false});

  // A copy constructor
  _GroupFilters.from(_GroupFilters other)
      : departureDateStart = other.departureDateStart,
        departureDateEnd = other.departureDateEnd,
        flightAway = other.flightAway,
        flightHome = other.flightHome,
        status = other.status,
        departureFrom = other.departureFrom,
        hasGuide = other.hasGuide,
        mapEnabled = other.mapEnabled,
        newestFirst = other.newestFirst;

  // Sort order isn't a filter — it doesn't hide anything, so it doesn't
  // light up the filter badge either.
  bool get isApplied =>
      departureDateStart != null ||
      departureDateEnd != null ||
      flightAway != null ||
      flightHome != null ||
      status != null ||
      departureFrom != null ||
      hasGuide != null ||
      mapEnabled != null;
}

class _FilterDialog extends StatefulWidget {
  final _GroupFilters currentFilters;
  final Color primaryColor;
  final List<String> departureLocations;

  const _FilterDialog({
    required this.currentFilters,
    required this.primaryColor,
    required this.departureLocations,
  });

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

  // Quick presets for the most common date questions, so they don't need a
  // trip through the date range picker.
  void _setDatePreset(int days) {
    final today = DateUtils.dateOnly(DateTime.now());
    setState(() {
      _filters.departureDateStart = today;
      _filters.departureDateEnd = today.add(Duration(days: days));
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasDateRange = _filters.departureDateStart != null &&
        _filters.departureDateEnd != null;
    return AlertDialog(
      backgroundColor: AppColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
      title: Text('Filtrer rejser',
          style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('Sortering'),
              _buildChoiceChips<bool>(
                options: const {false: 'Tidligste først', true: 'Seneste først'},
                selected: _filters.newestFirst,
                onSelected: (val) =>
                    setState(() => _filters.newestFirst = val ?? false),
                allowNone: false,
              ),
              const SizedBox(height: AppSpacing.xl),
              _sectionTitle('Status'),
              _buildChoiceChips<_TripStatus>(
                options: {for (final s in _TripStatus.values) s: s.label},
                selected: _filters.status,
                onSelected: (val) => setState(() => _filters.status = val),
              ),
              const SizedBox(height: AppSpacing.xl),
              _sectionTitle('Afrejsedato'),
              InkWell(
                onTap: _pickDateRange,
                child: InputDecorator(
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.calendar_today),
                    suffixIcon: hasDateRange
                        ? IconButton(
                            tooltip: 'Ryd datointerval',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() {
                              _filters.departureDateStart = null;
                              _filters.departureDateEnd = null;
                            }),
                          )
                        : null,
                    border: OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  child: Text(
                    hasDateRange
                        ? '${DateFormat('dd/MM/yy').format(_filters.departureDateStart!)} - ${DateFormat('dd/MM/yy').format(_filters.departureDateEnd!)}'
                        : 'Vælg datointerval',
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  for (final preset in const {
                    'Næste 30 dage': 30,
                    'Næste 3 mdr.': 90,
                    'Næste 12 mdr.': 365,
                  }.entries)
                    ActionChip(
                      label: Text(preset.key, style: AppTextStyles.body()),
                      backgroundColor: Colors.white,
                      onPressed: () => _setDatePreset(preset.value),
                    ),
                ],
              ),
              if (widget.departureLocations.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xl),
                _sectionTitle('Afrejsested'),
                DropdownButtonFormField<String?>(
                  initialValue: widget.departureLocations
                          .contains(_filters.departureFrom)
                      ? _filters.departureFrom
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.flight_takeoff),
                    border: OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('Alle')),
                    for (final loc in widget.departureLocations)
                      DropdownMenuItem<String?>(value: loc, child: Text(loc)),
                  ],
                  onChanged: (val) =>
                      setState(() => _filters.departureFrom = val),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              _sectionTitle('Fly inkluderet'),
              _buildBooleanFilter(
                  label: 'Udrejse',
                  value: _filters.flightAway,
                  onChanged: (val) =>
                      setState(() => _filters.flightAway = val)),
              const SizedBox(height: AppSpacing.sm),
              _buildBooleanFilter(
                  label: 'Hjemrejse',
                  value: _filters.flightHome,
                  onChanged: (val) =>
                      setState(() => _filters.flightHome = val)),
              const SizedBox(height: AppSpacing.xl),
              _sectionTitle('Øvrigt'),
              _buildBooleanFilter(
                  label: 'Guide tilknyttet',
                  value: _filters.hasGuide,
                  onChanged: (val) => setState(() => _filters.hasGuide = val)),
              const SizedBox(height: AppSpacing.sm),
              _buildBooleanFilter(
                  label: 'Kort aktiveret',
                  value: _filters.mapEnabled,
                  onChanged: (val) =>
                      setState(() => _filters.mapEnabled = val)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuller')),
        TextButton(
            // Reset clears the filters but keeps the chosen sort order.
            onPressed: () => Navigator.pop(
                context, _GroupFilters(newestFirst: _filters.newestFirst)),
            child: const Text('Nulstil')),
        ElevatedButton(
            onPressed: () => Navigator.pop(context, _filters),
            child: const Text('Anvend')),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(text, style: GoogleFonts.kanit(fontWeight: FontWeight.w500)),
      );

  // Single-select chips in the bureau's theme color. Tapping the selected
  // chip again clears it (unless [allowNone] is false).
  Widget _buildChoiceChips<T>({
    required Map<T, String> options,
    required T? selected,
    required ValueChanged<T?> onSelected,
    bool allowNone = true,
  }) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final entry in options.entries)
          ChoiceChip(
            label: Text(entry.value),
            selected: selected == entry.key,
            showCheckmark: false,
            backgroundColor: Colors.white,
            selectedColor: widget.primaryColor.withValues(alpha: 0.15),
            side: BorderSide(
              color: selected == entry.key
                  ? widget.primaryColor.withValues(alpha: 0.6)
                  : Colors.grey[300]!,
            ),
            labelStyle: AppTextStyles.body(
              color: selected == entry.key ? widget.primaryColor : null,
            ).copyWith(
                fontWeight: selected == entry.key ? FontWeight.w600 : null),
            onSelected: (isSelected) {
              if (isSelected) {
                onSelected(entry.key);
              } else if (allowNone) {
                onSelected(null);
              }
            },
          ),
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

// Purely administrative bureau fields only (agencyName, returnMail) plus
// the CRM integrations card. No logout button here — that already lives in
// the sidebar (see _handleLogout on GroupSelectionScreen above). Everything
// that's actually shown to a traveler in the app (branding, emergency
// phone, welcome message, map default) lives exclusively in AppScreen
// (app_screen.dart) now — deliberately not duplicated here, and saved via
// a separate callable (updateAppSettings) so the two screens can never
// clobber each other's fields.
class BureauSettingsScreen extends StatefulWidget {
  final AgencyInformation agencyInfo;
  // emergencyPhone/standardMessage/Title aren't on AgencyInformation's
  // fields shown elsewhere in this screen — same raw-data-map pattern
  // AppScreen already uses, since these two also live in the App screen's
  // editor now (see _AppSettingsEditor in app_screen.dart) and are edited
  // from either place.
  final String? standardMessage;
  final String? standardMessageTitle;
  final bool isNested;
  // Lets the AI Trip Builder entry point below hand a newly created trip
  // back up to GroupSelectionScreen's own `_groups` list — this screen
  // itself holds no group list to update, and (unlike _AddGroupDialog,
  // which GroupSelectionScreen pushes and awaits directly) the AI builder
  // is pushed from inside here, several widgets removed from `_groups`.
  final ValueChanged<GroupInformation>? onGroupCreated;

  const BureauSettingsScreen({
    super.key,
    required this.agencyInfo,
    this.standardMessage,
    this.standardMessageTitle,
    this.isNested = false,
    this.onGroupCreated,
  });

  @override
  State<BureauSettingsScreen> createState() => _BureauSettingsScreenState();
}

class _BureauSettingsScreenState extends State<BureauSettingsScreen> {
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _phoneController;
  late TextEditingController _standardMessageController;
  late TextEditingController _standardMessageTitleController;

  // Separate debounce timers per destination/field group — see the same
  // note on _AppSettingsEditor's timers in app_screen.dart for why a
  // single shared Timer would be wrong here (rapid edits across fields
  // would drop all but the last one's save).
  Timer? _bureauInfoDebounce;
  Timer? _phoneDebounce;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.agencyInfo.agencyName);
    _emailController =
        TextEditingController(text: widget.agencyInfo.returnMail);
    _phoneController =
        TextEditingController(text: widget.agencyInfo.emergencyPhone);
    _standardMessageController =
        TextEditingController(text: widget.standardMessage ?? '');
    _standardMessageTitleController =
        TextEditingController(text: widget.standardMessageTitle ?? 'Velkommen');
  }

  @override
  void dispose() {
    _bureauInfoDebounce?.cancel();
    _phoneDebounce?.cancel();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _standardMessageController.dispose();
    _standardMessageTitleController.dispose();
    super.dispose();
  }

  // agency/{agencyCode} is function-only in firestore.rules — this goes
  // through updateBureauSettings rather than a direct client write. Only
  // ever the two purely-administrative fields — see updateBureauSettings
  // in index.ts for why this deliberately can't touch anything
  // updateAppSettings owns.
  Future<void> _saveBureauInfo() async {
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('updateBureauSettings')
          .call({
        'agencyCode': widget.agencyInfo.agencyCode,
        'agencyName': _nameController.text,
        'returnMail': _emailController.text,
      });
      if (mounted) {
        showSavedSnackbar(
            context, AppColors.fromHex(widget.agencyInfo.mainColor));
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackbar(context, 'Fejl: ${describeError(e)}');
      }
    }
  }

  // emergencyPhone/standardMessage/Title are also edited from AppScreen's
  // own editor (a separate mounted widget) — this only ever sends the
  // field(s) that specific control here owns, via updateAppSettings'
  // partial update, so it can never clobber mainColor/logoUrl/videoUrl/
  // mapEnabledDefault (which this screen has no state for at all) or a
  // more recent edit made from the App screen.
  Future<void> _saveAppField(Map<String, dynamic> fields) async {
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('updateAppSettings')
          .call({'agencyCode': widget.agencyInfo.agencyCode, ...fields});
      if (mounted) {
        showSavedSnackbar(
            context, AppColors.fromHex(widget.agencyInfo.mainColor));
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackbar(context, 'Fejl: ${describeError(e)}');
      }
    }
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
            const SizedBox(height: AppSpacing.lg),
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
              _saveAppField({
                'standardMessage': _standardMessageController.text,
                'standardMessageTitle': _standardMessageTitleController.text,
              });
            },
            child: const Text('Gem'),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcomeMessageCard(Color themeColor) {
    return InkWell(
      onTap: _showWelcomeMessageDialog,
      borderRadius: AppRadii.lgRadius,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: _panelDecoration(themeColor),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    themeColor.withValues(alpha: 0.22),
                    themeColor.withValues(alpha: 0.08),
                  ],
                ),
              ),
              child: Icon(Icons.message_outlined, color: themeColor, size: 19),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _standardMessageController.text.isNotEmpty
                        ? _standardMessageTitleController.text
                        : 'Standard velkomstbesked',
                    style: GoogleFonts.kanit(
                        fontWeight: FontWeight.w600, color: Colors.black87),
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
            Icon(Icons.chevron_right, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = AppColors.fromHex(widget.agencyInfo.mainColor);

    return Scaffold(
      backgroundColor: AppColors.scaffoldGradientStart,
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
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(themeColor),
            const SizedBox(height: AppSpacing.xxl),
            _buildSectionTitle(
                'Kontaktinformation', Icons.badge_outlined, themeColor),
            _buildContactCard(themeColor),
            const SizedBox(height: AppSpacing.xxl),
            _buildSectionTitle(
                'Nødtelefon', Icons.emergency_outlined, themeColor),
            _buildPhoneCard(themeColor),
            const SizedBox(height: AppSpacing.xxl),
            _buildSectionTitle(
                'Velkomstbesked', Icons.message_outlined, themeColor),
            _buildWelcomeMessageCard(themeColor),
            const SizedBox(height: AppSpacing.xxl),
            _buildSectionTitle('Integrationer', Icons.hub_outlined, themeColor),
            _buildIntegrationsCardWithAdminAccess(themeColor),
            const SizedBox(height: AppSpacing.xl),
            Center(
              child: Text(
                'Emails brugt: ${widget.agencyInfo.emailCount} / ${widget.agencyInfo.maxEmails}',
                style: GoogleFonts.kanit(color: Colors.grey[600], fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Same gradient-identity header language as AppScreen's editor (see
  // app_screen.dart's _buildHeader) — no logo here since this screen is
  // purely administrative, never traveler-facing.
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
          Text('BUREAUINDSTILLINGER',
              textAlign: TextAlign.center,
              style: GoogleFonts.kanit(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: Colors.white.withValues(alpha: 0.75))),
          const SizedBox(height: 10),
          Text(name.isNotEmpty ? name : 'Jeres bureau',
              textAlign: TextAlign.center,
              style: GoogleFonts.kanit(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(height: 8),
          Text(
              'Kontaktoplysninger, velkomstbesked og integrationer for jeres bureau.',
              textAlign: TextAlign.center,
              style: GoogleFonts.kanit(
                  fontSize: 12.5, color: Colors.white.withValues(alpha: 0.85))),
        ],
      ),
    );
  }

  // (Panel decoration moved to the top-level _panelDecoration function near
  // _GlowSwitch below — shared with AgencyImagesScreen and
  // PackingListLibraryScreen, which need the same look too.)

  // Pill badge (icon + label) instead of a plain heading — same idiom as
  // AppScreen's section titles.
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

  Widget _buildContactCard(Color themeColor) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: _panelDecoration(themeColor),
      child: Column(
        children: [
          _buildTextField(
            controller: _nameController,
            label: 'Bureau Navn',
            icon: Icons.business,
            themeColor: themeColor,
            helperText: 'Internt navn — vises ikke i appen',
            onChanged: (_) => _debouncedSaveBureauInfo(),
          ),
          const SizedBox(height: AppSpacing.lg),
          _buildTextField(
            controller: _emailController,
            label: 'Kontakt e-mail',
            icon: Icons.email,
            themeColor: themeColor,
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) => _debouncedSaveBureauInfo(),
          ),
        ],
      ),
    );
  }

  void _debouncedSaveBureauInfo() {
    _bureauInfoDebounce?.cancel();
    _bureauInfoDebounce =
        Timer(const Duration(milliseconds: 700), _saveBureauInfo);
  }

  Widget _buildPhoneCard(Color themeColor) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: _panelDecoration(themeColor),
      child: _buildTextField(
        controller: _phoneController,
        label: 'Nødtelefon',
        icon: Icons.phone,
        themeColor: themeColor,
        keyboardType: TextInputType.phone,
        helperText: 'Vist til rejsende i appens nødhjælps-dialog',
        onChanged: (value) {
          _phoneDebounce?.cancel();
          _phoneDebounce = Timer(const Duration(milliseconds: 700),
              () => _saveAppField({'emergencyPhone': value}));
        },
      ),
    );
  }

  /// Only a BACKPACK-ADMIN account (the same superadmin check used in
  /// crm_integration_screen.dart/team_screen.dart) can see and flip the
  /// per-bureau plan toggles — a bureau shouldn't be able to grant itself a
  /// feature it isn't paying for by tapping its own settings screen.
  Widget _buildIntegrationsCardWithAdminAccess(Color themeColor) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    return StreamBuilder<DocumentSnapshot>(
      stream: currentUid == null
          ? const Stream.empty()
          : FirebaseFirestore.instance
              .collection('admins')
              .doc(currentUid)
              .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() as Map<String, dynamic>?;
        final agencyCodes =
            List<String>.from(data?['agencyCodes'] as List? ?? []);
        final isSuperAdmin = agencyCodes.contains('BACKPACK-ADMIN');
        return _buildIntegrationsCard(themeColor, isSuperAdmin);
      },
    );
  }

  // Routed through a callable (not a direct Firestore write) — plan flags
  // are BACKPACK-ADMIN-only server-side (see setAgencyPlanFlag in
  // functions/src/index.ts), and agency/{agencyCode} isn't client-writable
  // per firestore.rules regardless.
  Future<void> _setPlanFlag(String field, bool value) async {
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('setAgencyPlanFlag')
          .call({
        'agencyCode': widget.agencyInfo.agencyCode,
        'field': field,
        'value': value,
      });
    } catch (e) {
      if (mounted) {
        showErrorSnackbar(context, 'Kunne ikke ændre plan: ${describeError(e)}');
      }
    }
  }

  Widget _buildIntegrationsCard(Color themeColor, bool isSuperAdmin) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIntegrationTile(
          themeColor: themeColor,
          icon: Icons.hub_outlined,
          title: 'Forbind CRM',
          subtitle: 'Automatisér oprettelse af rejser fra jeres CRM',
          isActivated: widget.agencyInfo.crmEnabled,
          isSuperAdmin: isSuperAdmin,
          onToggle: (v) => _setPlanFlag('crmEnabled', v),
          onTap: widget.agencyInfo.crmEnabled || isSuperAdmin
              ? () => _openCrmIntegrationScreen(themeColor)
              : () => _showPlanUpgradeDialog(
                    themeColor: themeColor,
                    icon: Icons.hub_outlined,
                    title: 'Forbind CRM',
                    description:
                        'Forbind jeres CRM (fx HubSpot), og lad BackPack automatisk '
                        'oprette en rejse med rejsende, når en aftale når det trin, I '
                        'vælger — uden manuelt arbejde.',
                    highlights: const [
                      'Rejser oprettes automatisk fra jeres CRM',
                      'Rejsende hentes med fra tilknyttede kontakter',
                      'I vælger selv hvilket trin der udløser oprettelsen',
                    ],
                  ),
        ),
        const SizedBox(height: AppSpacing.md),
        _buildIntegrationTile(
          themeColor: themeColor,
          icon: Icons.alternate_email,
          title: 'Forbind e-mail',
          subtitle: 'Send rejsebeskeder fra jeres egen e-mailadresse',
          isActivated: widget.agencyInfo.emailIntegrationEnabled,
          isSuperAdmin: isSuperAdmin,
          onToggle: (v) => _setPlanFlag('emailIntegrationEnabled', v),
          onTap: widget.agencyInfo.emailIntegrationEnabled || isSuperAdmin
              ? () => _openEmailIntegrationScreen(themeColor)
              : () => _showPlanUpgradeDialog(
                    themeColor: themeColor,
                    icon: Icons.alternate_email,
                    title: 'Forbind e-mail',
                    description:
                        'Send alle jeres rejsebeskeder fra jeres eget bureau-domæne i '
                        'stedet for BackPacks standardafsender — de rejsende ser jeres '
                        'egen adresse i indbakken, ikke BackPack.',
                    highlights: const [
                      'Beskeder sendes fra jeres egen e-mailadresse',
                      'Rejsende ser jeres bureaunavn som afsender',
                      'I styrer selv afsendernavn og svar-adresse',
                    ],
                  ),
        ),
        const SizedBox(height: AppSpacing.md),
        _buildIntegrationTile(
          themeColor: themeColor,
          icon: Icons.auto_awesome,
          title: 'Byg rejser med AI',
          subtitle: 'Upload dokumenter og lad AI\'en bygge et udkast',
          isActivated: widget.agencyInfo.aiTripBuilderEnabled,
          isSuperAdmin: isSuperAdmin,
          onToggle: (v) => _setPlanFlag('aiTripBuilderEnabled', v),
          onTap: widget.agencyInfo.aiTripBuilderEnabled || isSuperAdmin
              ? () => _openAiTripBuilderScreen(themeColor)
              : () => _showPlanUpgradeDialog(
                    themeColor: themeColor,
                    icon: Icons.auto_awesome,
                    title: 'Byg rejser med AI',
                    description:
                        'Upload flybilletter, hotelbekræftelser og andre rejsedokumenter, '
                        'og lad AI\'en foreslå et udkast til rejsen — tidslinje, datoer og '
                        'detaljer udfyldt automatisk, klar til at blive gennemgået.',
                    highlights: const [
                      'Spar tid på manuel oprettelse af rejser',
                      'AI\'en foreslår en tidslinje ud fra jeres dokumenter',
                      'I gennemgår og redigerer udkastet, før det gemmes',
                    ],
                  ),
        ),
      ],
    );
  }

  /// Every plan-gated integration tile stays visible and tappable even when
  /// [isActivated] is false — bureaus can still see what the feature does
  /// (it opens the same preview either way), just with a badge making clear
  /// it isn't switched on for their account yet, instead of the option
  /// disappearing entirely. A BACKPACK-ADMIN viewer additionally gets a
  /// switch to flip the plan flag itself, right there on the tile.
  Widget _buildIntegrationTile({
    required Color themeColor,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isActivated,
    required VoidCallback onTap,
    bool isSuperAdmin = false,
    ValueChanged<bool>? onToggle,
  }) {
    final iconColor = isActivated ? themeColor : Colors.grey[400]!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: _panelDecoration(themeColor),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: isActivated
                    ? LinearGradient(colors: [
                        themeColor.withValues(alpha: 0.24),
                        themeColor.withValues(alpha: 0.08),
                      ])
                    : LinearGradient(
                        colors: [Colors.grey[200]!, Colors.grey[100]!]),
              ),
              child: Icon(icon, color: iconColor, size: 19),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title,
                          style: GoogleFonts.kanit(
                              fontWeight: FontWeight.w600,
                              color: Colors.black87)),
                      if (!isActivated) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF4E5),
                            borderRadius: AppRadii.lgRadius,
                          ),
                          child: Text('Ikke i din plan',
                              style: GoogleFonts.kanit(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF9A6700))),
                        ),
                      ],
                    ],
                  ),
                  Text(subtitle,
                      style: GoogleFonts.kanit(
                          fontSize: 12, color: Colors.grey[600])),
                ],
              ),
            ),
            if (isSuperAdmin && onToggle != null) ...[
              _GlowSwitch(
                value: isActivated,
                color: themeColor,
                onChanged: onToggle,
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
            Icon(Icons.chevron_right, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }

  // Shown instead of opening the feature screen when a plan-gated
  // integration tile (email, AI trip builder) isn't included in this
  // bureau's plan — explains what the feature does and how to get it
  // added, rather than letting them into a screen for a feature they can't
  // actually use yet.
  void _showPlanUpgradeDialog({
    required Color themeColor,
    required IconData icon,
    required String title,
    required String description,
    required List<String> highlights,
  }) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: themeColor.withOpacity(0.1),
                borderRadius: AppRadii.mdRadius,
              ),
              child: Icon(icon, color: themeColor, size: 20),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(title, style: AppTextStyles.headingBold()),
            ),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description,
                    style: GoogleFonts.kanit(
                        color: Colors.black87, height: 1.4, fontSize: 13.5)),
                const SizedBox(height: AppSpacing.lg),
                ...highlights.map((h) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.check_circle, size: 16, color: themeColor),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(h, style: AppTextStyles.body()),
                          ),
                        ],
                      ),
                    )),
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF4E5),
                    borderRadius: AppRadii.mdRadius,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline,
                          size: 18, color: Color(0xFF9A6700)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Denne funktion er ikke inkluderet i jeres nuværende '
                          'plan. Kontakt BackPack på kontakt@backpack-app.dk for '
                          'at få den tilføjet.',
                          style: GoogleFonts.kanit(
                              fontSize: 12.5, color: const Color(0xFF9A6700)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child:
                Text('Luk', style: GoogleFonts.kanit(color: Colors.grey[700])),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              final uri = Uri(
                scheme: 'mailto',
                path: 'kontakt@backpack-app.dk',
                query:
                    'subject=${Uri.encodeComponent('Tilføj "$title" til vores plan')}',
              );
              await launchUrl(uri);
            },
            icon: const Icon(Icons.email_outlined, size: 18),
            label: Text('Kontakt BackPack',
                style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: themeColor,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  void _openCrmIntegrationScreen(Color themeColor) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            CrmIntegrationScreen(agencyInfo: widget.agencyInfo),
      ),
    );
  }

  void _openEmailIntegrationScreen(Color themeColor) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => EmailIntegrationScreen(themeColor: themeColor),
      ),
    );
  }

  void _openAiTripBuilderScreen(Color themeColor) {
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (context) => AiTripBuilderScreen(
          themeColor: themeColor,
          agencyCode: widget.agencyInfo.agencyCode,
          bureauName: widget.agencyInfo.agencyName,
        ),
      ),
    )
        .then((newGroup) {
      if (newGroup is GroupInformation) {
        widget.onGroupCreated?.call(newGroup);
      }
    });
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required Color themeColor,
    TextInputType? keyboardType,
    int maxLines = 1,
    String? helperText,
    ValueChanged<String>? onChanged,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      style: GoogleFonts.kanit(),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        helperStyle: GoogleFonts.kanit(fontSize: 11),
        labelStyle: GoogleFonts.kanit(color: Colors.grey[600]),
        prefixIcon:
            Icon(icon, color: themeColor.withValues(alpha: 0.6), size: 20),
        border: OutlineInputBorder(
          borderRadius: AppRadii.mdRadius,
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadii.mdRadius,
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadii.mdRadius,
          borderSide: BorderSide(color: themeColor, width: 1.5),
        ),
        filled: true,
        fillColor: Colors.grey[50],
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }
}

// Soft gradient-tinted panel with a colored glow shadow instead of a flat
// gray card — same look as AppScreen's _panelDecoration (app_screen.dart).
// A top-level function (not a method) so BureauSettingsScreen,
// AgencyImagesScreen, and PackingListLibraryScreen can all share it.
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

// A hand-built pill toggle (not the stock Material Switch) — same look as
// AppScreen's _GlowSwitch (app_screen.dart): a colored glow halo behind the
// track when ON, and an animated sliding thumb.
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

class AgencyImagesScreen extends StatefulWidget {
  final String agencyCode;
  final Color mainColor;
  final double photoStorageLimitGb;
  final bool isNested;

  const AgencyImagesScreen({
    super.key,
    required this.agencyCode,
    required this.mainColor,
    this.photoStorageLimitGb = 2.0,
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

  // Storage quota. Usage is tracked incrementally after the initial full
  // scan (add on upload, subtract on delete) rather than re-scanning the
  // whole tree on every action, since that requires a metadata fetch per
  // file and can get slow for agencies with a lot of photos.
  int _usedBytes = 0;
  bool _isLoadingUsage = true;
  int get _limitBytes => (widget.photoStorageLimitGb * 1000000000).round();

  @override
  void initState() {
    super.initState();
    _loadImages();
    _loadUsage();
  }

  Future<void> _loadUsage() async {
    var photoBytes = 0;
    var videoBytes = 0;

    try {
      photoBytes = await _calculateFolderSize(FirebaseStorage.instance
          .ref('agencies/${widget.agencyCode}/timeline_images'));
    } catch (e) {
      // No photos uploaded yet (folder doesn't exist) or a transient error —
      // either way, don't block the screen on this.
    }

    try {
      // The bureau background video (uploaded from Bureauindstillinger)
      // lives directly under agencies/{agencyCode}/, a sibling of
      // timeline_images/ — listing just this level's items (not recursing
      // into subfolders) picks up the video without also pulling in the
      // separate email-signature folder that lives here too.
      final agencyRoot = await FirebaseStorage.instance
          .ref('agencies/${widget.agencyCode}')
          .listAll();
      for (final item in agencyRoot.items) {
        final metadata = await item.getMetadata();
        videoBytes += metadata.size ?? 0;
      }
    } catch (e) {
      // No video uploaded yet or a transient error.
    }

    if (mounted) {
      setState(() {
        _usedBytes = photoBytes + videoBytes;
        _isLoadingUsage = false;
      });
    }
  }

  Future<int> _calculateFolderSize(Reference ref) async {
    final result = await ref.listAll();
    var total = 0;
    for (final item in result.items) {
      if (item.name == '.keep') continue;
      final metadata = await item.getMetadata();
      total += metadata.size ?? 0;
    }
    for (final prefix in result.prefixes) {
      total += await _calculateFolderSize(prefix);
    }
    return total;
  }

  String _formatGb(int bytes) => (bytes / 1000000000).toStringAsFixed(2);

  Widget _buildUsageBar() {
    final fraction = (!_isLoadingUsage && _limitBytes > 0)
        ? (_usedBytes / _limitBytes).clamp(0.0, 1.0)
        : 0.0;
    final isFull = !_isLoadingUsage && _usedBytes >= _limitBytes;
    final isNearFull = !_isLoadingUsage && fraction >= 0.9;
    final barColor =
        isFull ? Colors.red : (isNearFull ? Colors.orange : widget.mainColor);

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: _panelDecoration(widget.mainColor),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Lagerplads (billeder + video)',
                  style:
                      GoogleFonts.kanit(fontSize: 12, color: Colors.grey[600])),
              Text(
                  _isLoadingUsage
                      ? 'Beregner...'
                      : '${_formatGb(_usedBytes)} / ${widget.photoStorageLimitGb.toStringAsFixed(1)} GB',
                  style: GoogleFonts.kanit(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isFull ? Colors.red : Colors.grey[700])),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: _isLoadingUsage
                ? LinearProgressIndicator(
                    minHeight: 6,
                    backgroundColor: Colors.grey[200],
                    valueColor: AlwaysStoppedAnimation<Color>(
                        widget.mainColor.withValues(alpha: 0.4)),
                  )
                : LinearProgressIndicator(
                    value: fraction,
                    minHeight: 6,
                    backgroundColor: Colors.grey[200],
                    valueColor: AlwaysStoppedAnimation<Color>(barColor),
                  ),
          ),
        ],
      ),
    );
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
        showErrorSnackbar(context, 'Kunne ikke hente billeder: ${describeError(e)}');
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
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Beskær & Zoom',
                                    style: AppTextStyles.headingBold()),
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
                                      style: AppTextStyles.body(
                                          color: Colors.grey)),
                                ),
                                const Icon(Icons.zoom_in,
                                    size: 20, color: Colors.grey),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xl),
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
                                      backgroundColor: widget.mainColor),
                                  child: Text('Beskær',
                                      style: GoogleFonts.kanit(
                                          color: Colors.white)),
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
          final bytes = await croppedFile.readAsBytes();

          if (!_isLoadingUsage && _usedBytes + bytes.length > _limitBytes) {
            if (mounted) {
              showWarningSnackbar(context, 'Billedbanken er fuld (${_formatGb(_usedBytes)} / ${widget.photoStorageLimitGb.toStringAsFixed(1)} GB). Kontakt BackPack for at få mere plads.');
            }
            return;
          }

          setState(() => _isLoading = true);

          final fileName = image.name;
          final ref =
              FirebaseStorage.instance.ref('$_storageBasePath/$fileName');

          final metadata = SettableMetadata(contentType: 'image/jpeg');

          await ref.putData(bytes, metadata);
          _usedBytes += bytes.length;
          await _loadImages();
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        showErrorSnackbar(context, 'Fejl ved upload: ${describeError(e)}');
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
        int? freedBytes;
        try {
          freedBytes = (await ref.getMetadata()).size;
        } catch (_) {
          // Metadata fetch failing shouldn't block the delete itself.
        }
        await ref.delete();
        if (freedBytes != null) _usedBytes -= freedBytes;
        await _loadImages();
      } catch (e) {
        setState(() => _isLoading = false);
        if (mounted) {
          showErrorSnackbar(context, 'Kunne ikke slette: ${describeError(e)}');
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
          showErrorSnackbar(context, 'Kunne ikke oprette mappe: ${describeError(e)}');
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
        showErrorSnackbar(context, 'Fejl ved flytning: ${describeError(e)}');
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
          showWarningSnackbar(context, 'Du kan maksimalt vælge 5 billeder ad gangen.');
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
                      const SizedBox(width: AppSpacing.sm),
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
        backgroundColor: AppColors.scaffoldGradientStart,
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
                      style: AppTextStyles.headingBold()),
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
          _buildUsageBar(),
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
                              const SizedBox(height: AppSpacing.lg),
                              Text('Mappen er tom',
                                  style: GoogleFonts.kanit(
                                      fontSize: 18,
                                      color: Colors.grey[500],
                                      fontWeight: FontWeight.w500)),
                            ],
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.all(AppSpacing.xl),
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
                                        borderRadius: AppRadii.mdRadius,
                                        child: Container(
                                            decoration: _panelDecoration(
                                                widget.mainColor),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 16),
                                            child: Row(children: [
                                              Icon(Icons.folder,
                                                  color: widget.mainColor),
                                              const SizedBox(
                                                  width: AppSpacing.md),
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

          // agency/{agencyCode} is function-only in firestore.rules.
          await FirebaseFunctions.instanceFor(region: 'europe-west1')
              .httpsCallable('updateAgencyPackingListLibrary')
              .call({
            'agencyCode': widget.agencyCode,
            'packingListLibrary': currentLibrary,
          });
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
      // agency/{agencyCode} is function-only in firestore.rules.
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('updateAgencyPackingListLibrary')
          .call({
        'agencyCode': widget.agencyCode,
        'packingListLibrary': currentLibrary,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldGradientStart,
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
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: library.length,
            itemBuilder: (context, index) {
              final category = library[index];
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: _panelDecoration(widget.mainColor),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [
                            widget.mainColor.withValues(alpha: 0.22),
                            widget.mainColor.withValues(alpha: 0.08),
                          ],
                        ),
                      ),
                      child: Icon(
                        MdiIcons.fromString(
                                category['iconName'] ?? 'mdi-folder') ??
                            MdiIcons.folder,
                        color: widget.mainColor,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(category['categoryName'] ?? 'Uden navn',
                              style: GoogleFonts.kanit(
                                  fontWeight: FontWeight.w600, fontSize: 15)),
                          const SizedBox(height: 2),
                          Text(
                              '${(category['items'] as List?)?.length ?? 0} ting',
                              style: GoogleFonts.kanit(
                                  fontSize: 12, color: Colors.grey[600])),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.edit_outlined, color: Colors.grey[600]),
                      onPressed: () => _addOrEditCategory(category, index),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _deleteCategory(index, library),
                    ),
                  ],
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
        shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
            maxWidth: MediaQuery.of(context).size.width * 0.4,
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Vælg ikon',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.xl),
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
                              borderRadius: AppRadii.mdRadius),
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
    final themeColor = widget.color ?? AppColors.darkGreen;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 500,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
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
                  const SizedBox(width: AppSpacing.lg),
                  Text(
                    widget.category == null
                        ? 'Ny Kategori'
                        : 'Rediger Kategori',
                    style: GoogleFonts.kanit(
                        fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xxl),

              // Name Field
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Kategori Navn',
                  labelStyle: GoogleFonts.kanit(color: Colors.grey[600]),
                  prefixIcon:
                      Icon(Icons.label_outline, color: Colors.grey[400]),
                  border: OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: AppRadii.mdRadius,
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: AppRadii.mdRadius,
                    borderSide: BorderSide(color: themeColor, width: 2),
                  ),
                  filled: true,
                  fillColor: Colors.grey[50],
                ),
                style: GoogleFonts.kanit(),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Icon Picker
              InkWell(
                onTap: _pickIcon,
                borderRadius: AppRadii.mdRadius,
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: AppRadii.mdRadius,
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
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
                      const SizedBox(width: AppSpacing.lg),
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
              const SizedBox(height: AppSpacing.xxl),

              // Items Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Indhold', style: AppTextStyles.heading()),
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
              const SizedBox(height: AppSpacing.sm),

              // Items List
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: AppRadii.mdRadius,
                    border: Border.all(color: Colors.grey[200]!),
                  ),
                  child: _items.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.format_list_bulleted,
                                  color: Colors.grey[300], size: 48),
                              const SizedBox(height: AppSpacing.sm),
                              Text('Ingen genstande tilføjet',
                                  style: GoogleFonts.kanit(
                                      color: Colors.grey[500])),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(AppSpacing.sm),
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
              const SizedBox(height: AppSpacing.xxl),

              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Annuller',
                        style: GoogleFonts.kanit(color: Colors.grey[600])),
                  ),
                  const SizedBox(width: AppSpacing.md),
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
                          borderRadius: AppRadii.mdRadius),
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
          mapEnabled: widget.originalGroup.mapEnabled,
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
          'mapEnabled': group.mapEnabled,
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
        showErrorSnackbar(context, 'Fejl: ${describeError(e)}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
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
                    border: OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (v) => v!.isEmpty ? 'Påkrævet' : null,
                ),
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  controller: _groupIdController,
                  decoration: InputDecoration(
                    labelText: 'Ny Gruppe ID',
                    prefixIcon: const Icon(Icons.vpn_key),
                    border: OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (v) => v!.isEmpty ? 'Påkrævet' : null,
                ),
                const SizedBox(height: AppSpacing.lg),
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
                                borderRadius: AppRadii.mdRadius),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          child: Text(
                              DateFormat('dd/MM/yyyy').format(_departureDate)),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
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
                                borderRadius: AppRadii.mdRadius),
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
                const SizedBox(height: AppSpacing.lg),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Du kan ændre dette til en skabelon:',
                    style: GoogleFonts.kanit(
                        color: Colors.grey[600], fontSize: 14),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: AppRadii.mdRadius,
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: SwitchListTile(
                    title: Text(_isTemplate ? 'Skabelon' : 'Rejse'),
                    subtitle: Text(_isTemplate
                        ? 'Gemmes som en skabelon til fremtidig brug.'
                        : 'Oprettes som en almindelig rejse.'),
                    value: _isTemplate,
                    onChanged: (val) => setState(() => _isTemplate = val),
                    activeColor: AppColors.darkGreen,
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
              foregroundColor: AppColors.onPrimary,
              shape: RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
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
  // Bureau-wide default for a new group's own mapEnabled field (see
  // BureauSettingsScreen's "App-indstillinger" toggle).
  bool _agencyMapEnabledDefault = false;

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
      final data = doc.data();
      _agencyMapEnabledDefault = data?['mapEnabledDefault'] as bool? ?? false;
      if (doc.exists && data!.containsKey('packingListLibrary')) {
        setState(() {
          _library =
              List<Map<String, dynamic>>.from(data['packingListLibrary']);
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
          mapEnabled: _agencyMapEnabledDefault,
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
          'mapEnabled': group.mapEnabled,
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
        showErrorSnackbar(context, 'Fejl: ${describeError(e)}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
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
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: Colors.white54,
                    borderRadius: AppRadii.mdRadius,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.business, color: Colors.black54),
                      const SizedBox(width: AppSpacing.md),
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
                const SizedBox(height: AppSpacing.xl),
                TextFormField(
                  controller: _groupNameController,
                  decoration: InputDecoration(
                    labelText: 'Gruppe Navn',
                    prefixIcon: const Icon(Icons.label),
                    border: OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (v) => v!.isEmpty ? 'Påkrævet' : null,
                ),
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  controller: _groupIdController,
                  decoration: InputDecoration(
                    labelText: 'Gruppe ID',
                    prefixIcon: const Icon(Icons.vpn_key),
                    border: OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (v) => v!.isEmpty ? 'Påkrævet' : null,
                ),
                const SizedBox(height: AppSpacing.lg),
                if (_loadingLibrary)
                  const Center(child: CircularProgressIndicator())
                else if (_library.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Vælg pakkelister',
                        style: GoogleFonts.kanit(color: Colors.grey[600])),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: AppRadii.mdRadius,
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
                  const SizedBox(height: AppSpacing.lg),
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
                                borderRadius: AppRadii.mdRadius),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          child: Text(
                              DateFormat('dd/MM/yyyy').format(_departureDate)),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
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
                                borderRadius: AppRadii.mdRadius),
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
                const SizedBox(height: AppSpacing.lg),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Du kan ændre dette til en skabelon:',
                    style: GoogleFonts.kanit(
                        color: Colors.grey[600], fontSize: 14),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: AppRadii.mdRadius,
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: SwitchListTile(
                    title: Text(_isTemplate ? 'Skabelon' : 'Rejse'),
                    subtitle: Text(_isTemplate
                        ? 'Oprettes som en skabelon til fremtidig brug.'
                        : 'Oprettes som en almindelig rejse.'),
                    value: _isTemplate,
                    onChanged: (val) => setState(() => _isTemplate = val),
                    activeColor: AppColors.darkGreen,
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
            foregroundColor: AppColors.onPrimary,
            shape: RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
          ),
          onPressed: _saveGroup,
          child: const Text('Opret'),
        ),
      ],
    );
  }
}
