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
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/BackgroundV2.jpg'),
            fit: BoxFit.cover,
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
          child: Center(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'BackPack',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 64,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              const Shadow(
                                blurRadius: 10.0,
                                color: Colors.black45,
                                offset: Offset(2.0, 2.0),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          'Ruten til dit eventyr – samlet ét sted',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 50),
                        StreamBuilder<User?>(
                          stream: FirebaseAuth.instance.authStateChanges(),
                          builder: (context, snapshot) {
                            if (snapshot.hasData && snapshot.data != null) {
                              String displayName =
                                  snapshot.data!.displayName ?? 'Bruger';

                              return Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 20.0),
                                  child: Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                          text: "Hej ",
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.w400,
                                          ),
                                        ),
                                        TextSpan(
                                          text: displayName,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 22,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const TextSpan(text: '\n'),
                                        TextSpan(
                                          text: "Indtast din bureau-kode her:",
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 20,
                                              fontWeight: FontWeight.w400),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            } else {
                              return const SizedBox.shrink();
                            }
                          },
                        ),
                        TextFormField(
                          controller: _agencyCodeController,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                              labelText: 'Bureau-kode',
                              labelStyle: TextStyle(
                                color: Colors.white,
                                fontFamily: 'Nothing You Could Do',
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                              ),
                              enabledBorder: UnderlineInputBorder(
                                borderSide: BorderSide(color: Colors.white),
                              ),
                              focusedBorder: UnderlineInputBorder(
                                borderSide: BorderSide(color: Colors.white),
                              )),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Indtast venligst en bureau-kode';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton(
                          onPressed: () async {
                            if (_formKey.currentState!.validate()) {
                              context.read<GroupInformationBloc>().add(
                                    LoadGroupsByAgency(
                                      agencyCode: _agencyCodeController.text,
                                    ),
                                  );
                            }
                          },
                          child: const Text('Jeg er klar!',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black)),
                        ),
                        const SizedBox(height: 50),
                      ],
                    ),
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
