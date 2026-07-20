import 'package:backend/config/app_colors.dart';
import 'package:backend/screens/group_selection_screen/group_selection_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../blocs/groupinformation/groupinformation_bloc.dart';
import 'package:firebase_auth/firebase_auth.dart';

class _AgencyOption {
  final String code;
  final String name;

  const _AgencyOption({required this.code, required this.name});
}

/// Landing screen after login. Access is driven entirely by the
/// `admins/{uid}` Firestore doc — there is no manual bureau-kode entry.
/// A verified user with no admin doc simply has no access yet. An admin
/// attached to more than one agency (`agencyCodes`) is prompted to pick
/// which one to log into.
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
  // Admins whose agencyCodes include this special code get access to
  // every bureau, not just their own — the picker then lists them all.
  static const String _superAdminCode = 'BACKPACK-ADMIN';

  bool _accessDenied = false;
  String? _agencyCode;
  List<_AgencyOption>? _agencyOptions;

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

      await _resolveAgency(user.uid);
    });
  }

  Future<void> _resolveAgency(String uid) async {
    try {
      final adminDoc =
          await FirebaseFirestore.instance.collection('admins').doc(uid).get();
      final agencyCodes = (adminDoc.data()?['agencyCodes'] as List?)
              ?.whereType<String>()
              .where((code) => code.isNotEmpty)
              .toList() ??
          const <String>[];

      if (agencyCodes.contains(_superAdminCode)) {
        final options = await _fetchAllAgencyOptions();
        if (mounted) setState(() => _agencyOptions = options);
        return;
      }

      if (agencyCodes.length == 1) {
        _loadAgency(agencyCodes.first);
        return;
      }

      if (agencyCodes.length > 1) {
        final options = await _fetchAgencyOptions(agencyCodes);
        if (mounted) setState(() => _agencyOptions = options);
        return;
      }
    } catch (e) {
      // Fall through to access-denied — lookup failed.
    }

    if (mounted) setState(() => _accessDenied = true);
  }

  Future<List<_AgencyOption>> _fetchAgencyOptions(
      List<String> agencyCodes) async {
    final options = await Future.wait(agencyCodes.map((code) async {
      try {
        final doc =
            await FirebaseFirestore.instance.collection('agency').doc(code).get();
        final name = doc.data()?['agencyName'] as String?;
        return _AgencyOption(code: code, name: (name?.isNotEmpty ?? false) ? name! : code);
      } catch (e) {
        return _AgencyOption(code: code, name: code);
      }
    }));
    options.sort((a, b) => a.name.compareTo(b.name));
    return options;
  }

  /// Every bureau in the system — used for BACKPACK-ADMIN accounts, which
  /// aren't scoped to a fixed set of agencyCodes.
  Future<List<_AgencyOption>> _fetchAllAgencyOptions() async {
    final snapshot = await FirebaseFirestore.instance.collection('agency').get();
    final options = snapshot.docs.map((doc) {
      final name = doc.data()['agencyName'] as String?;
      return _AgencyOption(
          code: doc.id, name: (name?.isNotEmpty ?? false) ? name! : doc.id);
    }).toList();
    options.sort((a, b) => a.name.compareTo(b.name));
    return options;
  }

  void _loadAgency(String agencyCode) {
    _agencyCode = agencyCode;
    setState(() => _agencyOptions = null);
    context
        .read<GroupInformationBloc>()
        .add(LoadGroupsByAgency(agencyCode: agencyCode));
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
            if (state is GroupsByAgencyLoaded) {
              Navigator.push(
                context,
                GroupSelectionScreen.route(
                  groups: state.groups,
                  agencyCode: _agencyCode,
                ),
              );
            } else if (state is GroupInformationError) {
              // This is a workaround. Ideally, the BLoC should emit GroupsByAgencyLoaded with an empty list.
              // But if it emits an error for "not found", we handle it here to proceed to the selection screen.
              if (state.message.toLowerCase().contains('no groups found')) {
                Navigator.push(
                  context,
                  GroupSelectionScreen.route(
                    groups: [], // Pass an empty list of groups
                    agencyCode: _agencyCode,
                  ),
                );
              } else {
                // Handle other, actual errors — the admin's agency lookup
                // resolved but loading its groups failed.
                if (!mounted) return;
                setState(() => _accessDenied = true);
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
                  child: _accessDenied
                      ? _buildAccessDeniedView()
                      : _agencyOptions != null
                          ? _buildAgencyPickerView(_agencyOptions!)
                          : _buildLoadingView(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(
          'assets/images/BackPack.png',
          width: 400,
          fit: BoxFit.contain,
        ),
        const SizedBox(height: 40),
        const CircularProgressIndicator(color: Colors.white),
      ],
    );
  }

  Widget _buildAgencyPickerView(List<_AgencyOption> options) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(
          'assets/images/BackPack.png',
          width: 400,
          fit: BoxFit.contain,
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Vælg bureau',
                style: TextStyle(
                  color: AppColors.darkGreen,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Din konto har adgang til flere bureauer',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              const SizedBox(height: 20),
              ...options.map((option) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.darkGreen,
                          side: BorderSide(color: AppColors.darkGreen),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => _loadAgency(option.code),
                        child: Text(option.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                  )),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAccessDeniedView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(
          'assets/images/BackPack.png',
          width: 400,
          fit: BoxFit.contain,
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Ingen adgang endnu',
                style: TextStyle(
                  color: AppColors.darkGreen,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Din konto er endnu ikke knyttet til et bureau. Kontakt din bureau-ejer eller BackPack support for at få adgang.',
                style: TextStyle(color: Colors.grey[600], fontSize: 14),
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
                  onPressed: _handleLogout,
                  child: const Text('Log ud',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
