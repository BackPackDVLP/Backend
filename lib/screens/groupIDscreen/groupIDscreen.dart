import 'package:backend/config/app_colors.dart';
import 'package:backend/rootscreen/rootscreen.dart';
import 'package:backend/screens/group_selection_screen/group_selection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../blocs/groupinformation/groupinformation_bloc.dart';
import 'package:firebase_auth/firebase_auth.dart';

class GroupIDScreen extends StatefulWidget {
  static const String routeName = '/groupIDscreen';

  const GroupIDScreen({super.key});

  static Route route() {
    return MaterialPageRoute(
      builder: (_) => const GroupIDScreen(),
      settings: const RouteSettings(name: routeName),
    );
  }

  @override
  State<GroupIDScreen> createState() => _GroupIDScreenState();
}

class _GroupIDScreenState extends State<GroupIDScreen> {
  final _formKey = GlobalKey<FormState>();
  final _agencyCodeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _handleInitialAuthCheck();
  }

  void _handleInitialAuthCheck() {
    // Schedule this check to run after the first frame is built.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Ensure the widget is still in the tree before proceeding.
      if (!mounted) return;

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        // If no user is logged in, redirect to the login screen.
        // Note: Ensure you have a '/login' route defined in your app.
        Navigator.pushReplacementNamed(context, '/login');
        return;
      }

      // Check if the user's email is verified.
      if (!user.emailVerified) {
        // If not verified, show a message, sign out, and redirect to login.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bekræft venligst din email for at logge ind.'),
            duration: Duration(seconds: 5),
          ),
        );
        await FirebaseAuth.instance.signOut();
        // Add a small delay for the user to see the snackbar.
        await Future.delayed(const Duration(seconds: 1));
        Navigator.pushReplacementNamed(context, '/login');
        return;
      }
    });
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
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  @override
  void dispose() {
    _agencyCodeController.dispose();
    super.dispose();
  }

  Future<void> _saveLastEnteredAgencyCode(String agencyCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lastEnteredAgencyCode', agencyCode);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: _handleLogout,
            tooltip: 'Log ud',
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.darkGreen, AppColors.brown],
          ),
        ),
        child: BlocListener<GroupInformationBloc, GroupInformationState>(
          listener: (context, state) async {
            if (state is GroupInformationLoaded) {
              // Navigate directly to the RootScreen
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (context) => const RootScreen()),
                (route) => false,
              );
            } else if (state is GroupsByAgencyLoaded) {
              await _saveLastEnteredAgencyCode(
                  _agencyCodeController.text); // Save the agency code
              Navigator.push(
                context,
                GroupSelectionScreen.route(
                  groups: state.groups,
                  agencyCode: _agencyCodeController.text,
                ),
              );
            } else if (state is GroupInformationError) {
              // This is a workaround. Ideally, the BLoC should emit GroupsByAgencyLoaded with an empty list.
              // But if it emits an error for "not found", we handle it here to proceed to the selection screen.
              if (state.message.toLowerCase().contains('no groups found')) {
                await _saveLastEnteredAgencyCode(_agencyCodeController.text);
                Navigator.push(
                  context,
                  GroupSelectionScreen.route(
                    groups: [], // Pass an empty list of groups
                    agencyCode: _agencyCodeController.text,
                  ),
                );
              } else {
                // Handle other, actual errors
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove('groupId');

                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(state.message)),
                );
              }
            }
          },
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Image.asset(
                        'assets/images/BackPack.png',
                        width: 400,
                        fit: BoxFit.contain,
                      ),
                      Text(
                        'Ruten til dit eventyr – samlet ét sted',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 15,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 40),
                      Container(
                        padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 30,
                              offset: const Offset(0, 15),
                            ),
                          ],
                        ),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              StreamBuilder<User?>(
                                stream: FirebaseAuth.instance.authStateChanges(),
                                builder: (context, snapshot) {
                                  final displayName =
                                      snapshot.data?.displayName ?? 'Bruger';
                                  return Text(
                                    'Hej $displayName',
                                    style: TextStyle(
                                      color: AppColors.darkGreen,
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Indtast din bureau-kode for at fortsætte',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 28),
                              TextFormField(
                                controller: _agencyCodeController,
                                style: TextStyle(color: AppColors.darkGreen),
                                decoration: InputDecoration(
                                  labelText: 'Bureau-kode',
                                  labelStyle: TextStyle(
                                      color: Colors.grey[600], fontSize: 14),
                                  prefixIcon: Icon(Icons.confirmation_number_outlined,
                                      color: AppColors.darkGreen, size: 20),
                                  filled: true,
                                  fillColor: AppColors.chipBackground,
                                  contentPadding: const EdgeInsets.symmetric(
                                      vertical: 16, horizontal: 16),
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
                                    borderSide: BorderSide(
                                        color: AppColors.darkGreen, width: 1.5),
                                  ),
                                  errorBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: const BorderSide(
                                        color: Colors.redAccent, width: 1.2),
                                  ),
                                ),
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Indtast venligst en bureau-kode';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 28),
                              SizedBox(
                                width: double.infinity,
                                height: 52,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primary,
                                    foregroundColor: AppColors.onPrimary,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onPressed: () async {
                                    if (_formKey.currentState!.validate()) {
                                      context.read<GroupInformationBloc>().add(
                                            LoadGroupsByAgency(
                                              agencyCode:
                                                  _agencyCodeController.text,
                                            ),
                                          );
                                    }
                                  },
                                  child: const Text('Fortsæt',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
