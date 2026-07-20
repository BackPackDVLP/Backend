import 'package:backend/blocs/groupinformation/groupinformation_bloc.dart';
import 'package:backend/config/app_colors.dart';
import 'package:backend/config/app_router.dart';
import 'package:backend/firebase_options.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart'; // Import GroupIDScreen
import 'package:backend/screens/groupIDscreen/groupIDscreen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'screens/login/loginscreen.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print("Handling a background or terminated message: ${message.messageId}");
  // Handle the message here (e.g., show a local notification)
  // You might want to use a local notification plugin if you want to show the notification.
}

Future<void> setupPushNotifications() async {
  // Request permission for notifications (Android 13+ requires this)
  NotificationSettings settings =
      await FirebaseMessaging.instance.requestPermission(
    alert: true,
    announcement: false,
    badge: true,
    carPlay: false,
    criticalAlert: false,
    provisional: false,
    sound: true,
  );

  print('User granted permission: ${settings.authorizationStatus}');

  await _getAndStoreFCMToken();

  // Handle token refresh
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
    print('FCM Token Refreshed: $newToken');
    storeToken(newToken);
  });

  // Foreground message handler
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    print('Got a message whilst in the foreground!');
    print('Message data: ${message.data}');

    if (message.notification != null) {
      print('Message also contained a notification: ${message.notification}');
      // Handle the notification (e.g., show an in-app notification)
    }
  });

  // Background/terminated message handler (using the top-level function)
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Handle message when app is opened from a terminated state
  FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
    if (message != null) {
      print('App was opened from a terminated state: ${message.messageId}');
      // Handle the message here (e.g., navigate to a specific screen)
      // You might use Navigator.push to navigate to the desired screen.
    }
  });
}

Future<void> _getAndStoreFCMToken() async {
  try {
    final fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken != null) {
      print('FCM Token: $fcmToken');
      await storeToken(fcmToken);
    } else {
      print("Failed to retrieve FCM token: Token is null");
    }
  } catch (e) {
    print("Failed to retrieve FCM token: $e");
  }
}

Future<void> storeToken(String? fcmToken) async {
  if (fcmToken != null) {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
          {'fcmToken': fcmToken, 'email': user.email}, SetOptions(merge: true));
    } else {
      print('User is null, cannot store token');
    }
  } else {
    print("Token is null");
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize date formatting for the 'da_DK' locale.
  await initializeDateFormatting('da_DK', null);

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // Initialize Hive
    if (kIsWeb) {
      await Hive.initFlutter();
    } else {
      final appDocDir = await getApplicationDocumentsDirectory();
      Hive.init(appDocDir.path);
    }
    // Open all necessary boxes here
    await Hive.openBox<List<String>>('pdfFileCache');
    await Hive.openBox<String>('agencyLogoImageCache');
    // The 'groupInformationCache' is opened within its repository, which is also fine.

    // Call setupPushNotifications
    await setupPushNotifications();
  } catch (e) {
    print("Initialization failed: $e");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<GroupInformationRepository>(
          create: (_) => GroupInformationRepository(),
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            create: (context) => GroupInformationBloc(
              groupInformationRepository:
                  context.read<GroupInformationRepository>(),
            ),
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'BackPack',
          theme: ThemeData(
            primaryColor: Colors.transparent,
            primarySwatch: Colors.green,
            fontFamily: 'Kanit',
            scaffoldBackgroundColor: AppColors.scaffoldGradientStart,
            checkboxTheme: CheckboxThemeData(
              fillColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return const Color.fromARGB(255, 255, 255, 255); // Your desired checked color
                }
                return Colors.transparent; // Your desired unchecked color
              }),
              shape: const CircleBorder(), // Use a circular shape
              // Add more customizations as needed (checkColor, side, etc.)
            ),
          ),
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: StreamBuilder<User?>(
            // Use a StreamBuilder to listen for auth changes
            stream: FirebaseAuth.instance.authStateChanges(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.active) {
                // User is logged in
                if (snapshot.data != null) {
                  return const GroupIDScreen();
                } else {
                  // User is not logged in
                  return const LoginScreen();
                }
              } else {
                // Still checking authentication state, show a loading indicator
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
            },
          ), // Start with GroupIDScreen
        ),
      ),
    );
    }
}