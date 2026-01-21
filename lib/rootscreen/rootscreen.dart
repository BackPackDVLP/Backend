import 'dart:async';
import 'dart:ui';
import 'package:backend/blocs/groupinformation/groupinformation_bloc.dart';
import 'package:backend/config/app_colors.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart' show GroupInformationRepository;
import 'package:backend/screens/group_selection_screen/group_selection_screen.dart';
import 'package:backend/screens/groupIDscreen/groupIDscreen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Import your screens here:
import 'package:backend/screens/home/homescreen.dart';
import 'package:backend/screens/details/detailsscreen.dart';

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  final PageController _pageController = PageController();
  final ScrollController _scrollController = ScrollController();

  int _selectedIndex = 1; // Set to 1 for 'Oversigt'/'Hjem' on load
  bool _isNavbarVisible = true;
  Timer? _hideTimer;
  
  @override
  void initState() {
    super.initState();
  }

  void _onScroll() {
    // If currently visible, hide navbar on scroll
    if (_isNavbarVisible) {
      setState(() {
        _isNavbarVisible = false;
      });
    }

    // Cancel any previous timer
    _hideTimer?.cancel();

    // Show navbar again after 800ms of no scroll
    _hideTimer = Timer(const Duration(milliseconds: 300), () {
      setState(() {
        _isNavbarVisible = true;
      });
    });
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });

    if (index == 1 || index == 2) { // 'Oversigt' or 'Detaljer' tapped
      _pageController.animateToPage(
        index - 1, // Animate to the corresponding page (0 for Home, 1 for Details)
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else if (index == 0) { // 'Skift Rejse' tapped
      _handleChangeGroup();
    } else if (index == 3) { // 'Log ud' tapped
      _handleLogout();
    }
    HapticFeedback.selectionClick();
  }

  Future<void> _handleChangeGroup() async {
    final currentState = context.read<GroupInformationBloc>().state;
    if (currentState is GroupInformationLoaded) {
      // Dispatch event to load all groups for the current agency.
      // The BlocListener below will handle the navigation.
      context.read<GroupInformationBloc>().add(
          LoadGroupsByAgency(agencyCode: currentState.groupInformation.agencyCode));
    }
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
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const GroupIDScreen()),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _scrollController.dispose();
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groupInfoState = context.watch<GroupInformationBloc>().state;

    // Define pages dynamically based on the BLoC state.
    final List<Widget> pages;
    if (groupInfoState is GroupInformationLoaded) {
      pages = [
        HomeScreen(scrollController: _scrollController),
        GroupDetailsScreen(
            groupId: groupInfoState.groupInformation.groupId,
            repository: context.read<GroupInformationRepository>(),
        ),
      ];
    } else {
      // Show loading indicators or placeholders if group info isn't loaded yet.
      pages = [
        HomeScreen(scrollController: _scrollController),
        const Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      ];
    }
    return BlocListener<GroupInformationBloc, GroupInformationState>(
      listener: (context, state) {
        if (state is GroupsByAgencyLoaded) {
          // When groups are loaded, navigate to the selection screen.
          Navigator.pushAndRemoveUntil(
            context,
            GroupSelectionScreen.route(groups: state.groups),
            (route) => false,
          );
        }
      },
      child: LayoutBuilder(builder: (context, constraints) {
        // Use a sidebar for wider screens (laptops/desktops)
        if (constraints.maxWidth > 640) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: _selectedIndex < 3 ? _selectedIndex : null,
                  onDestinationSelected: (int index) {
                    _onItemTapped(index);
                  },
                  labelType: NavigationRailLabelType.all,
                  backgroundColor: AppColors.panelBackground,
                  trailing: Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 20.0),
                        child: TextButton(
                          onPressed: () => _onItemTapped(3),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                vertical: 12, horizontal: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.logout, color: Colors.red, size: 24),
                              SizedBox(height: 4),
                              Text(
                                'Log ud',
                                style: TextStyle(color: Colors.red, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  destinations: <NavigationRailDestination>[
                    NavigationRailDestination(
                      icon: const Icon(Icons.list_outlined),
                      selectedIcon: Icon(Icons.list, color: AppColors.navActive,),
                      label: const Text('Forside'),
                    ),
                    NavigationRailDestination(
                      icon: const Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home, color: AppColors.navActive),
                      label: const Text('Oversigt'),
                    ),
                    NavigationRailDestination(
                      icon: const Icon(Icons.info_outline),
                      selectedIcon: Icon(Icons.info, color: AppColors.navActive),
                      label: const Text('Detaljer'),
                    ),
                  ],
                ),
                const VerticalDivider(thickness: 1, width: 1),
                // This is the main content.
                Expanded(child: PageView(
                  controller: _pageController,
                  children: pages,
                  onPageChanged: (pageIndex) => setState(() => _selectedIndex = pageIndex + 1),
                )),
              ],
            ),
          );
        }
        // Use the bottom navigation bar for narrower screens (mobile)
        else {
          return Scaffold(
            body: Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is ScrollUpdateNotification) {
                      _onScroll();
                    }
                    return false;
                  },
                  child: PageView(
                    controller: _pageController,
                    children: pages,
                    onPageChanged: (index) {
                      setState(() => _selectedIndex = index + 1); // Map PageView index (0, 1) to nav index (1, 2)
                      if (_scrollController.hasClients) {
                        _scrollController.jumpTo(0);
                      }
                    },
                  ),
                ),
                Positioned(
                  left: 22,
                  right: 22,
                  bottom: 16,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 300),
                    opacity: _isNavbarVisible ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !_isNavbarVisible,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            height: 70,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.3),
                                width: 1.5,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _buildNavItem(Icons.list, 'Skift Rejse', 0),
                                _buildNavItem(Icons.home, 'Hjem', 1),
                                _buildNavItem(Icons.info, 'Detaljer', 2),
                                _buildNavItem(Icons.logout, 'Log ud', 3),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
      }),
    );
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final bool isSelected = _selectedIndex == index;
    final Color activeColor = AppColors.navActive;
    final Color inactiveColor = Colors.white.withOpacity(0.8);

    // Special handling for the logout button color
    final Color iconColor = (index == 3) // Logout is now at index 3
        ? Colors.red.withOpacity(0.9)
        : (isSelected ? activeColor : inactiveColor);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _onItemTapped(index),
      child: AnimatedContainer(
        height: 60,
        width: 65,
        duration: const Duration(milliseconds: 25),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: isSelected
            ? BoxDecoration(
                color: Colors.white.withOpacity(0.25),
                borderRadius: BorderRadius.circular(16),
              )
            : null,
        child: Icon(
          icon,
          size: 28,
          color: iconColor,
        ),
      ),
    );
  }
}
