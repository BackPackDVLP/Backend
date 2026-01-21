import 'package:flutter/material.dart';
import 'package:backend/screens/group_selection_screen/group_selection_screen.dart';
import 'package:backend/screens/screens.dart';
import 'package:backend/screens/groupIDscreen/groupIDscreen.dart';
import 'package:backend/screens/login/loginscreen.dart';

class AppRouter {
  static Route onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case HomeScreen.routeName:
        return HomeScreen.route();
      case PackingListScreen.routeName:
        return PackingListScreen.route();
      case GroupIDScreen.routeName:
        return GroupIDScreen.route();
      case LoginScreen.routeName:
        return LoginScreen.route();
      case GroupSelectionScreen.routeName:
        // Note: This route is typically pushed with arguments,
        // so direct navigation might not have the 'groups' data.
        // This is a fallback.
        return GroupSelectionScreen.route(groups: []);

      default:
        return _errorRoute();
    }
  }
}

Route _errorRoute() {
  return MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(
        title: const Text('Error'),
      ),
    ),
    settings: const RouteSettings(name: '/error'),
  );
}
