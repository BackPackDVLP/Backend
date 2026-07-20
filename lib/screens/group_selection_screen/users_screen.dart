import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Agency-scoped, read-only view of the app users who are members of at
/// least one of this bureau's trips.
class UsersScreen extends StatelessWidget {
  final String agencyCode;
  final Color mainColor;
  final bool isNested;

  const UsersScreen({
    super.key,
    required this.agencyCode,
    required this.mainColor,
    this.isNested = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: isNested
          ? null
          : AppBar(
              title: Text('Brugere',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              centerTitle: true,
              elevation: 0,
              backgroundColor: mainColor,
              foregroundColor: Colors.white,
            ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .where('agencyCode', isEqualTo: agencyCode)
            .snapshots(),
        builder: (context, usersSnapshot) {
          if (!usersSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final userDocs = usersSnapshot.data!.docs;
          if (userDocs.isEmpty) {
            return _buildEmptyState('Ingen brugere fundet endnu');
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: userDocs.map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final email = data['email'] as String? ?? '';
              final groupId = data['groupId'] as String? ?? '';
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: mainColor.withOpacity(0.15),
                    child: Icon(Icons.luggage, color: mainColor),
                  ),
                  title: Text(email,
                      style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                  subtitle: Text('Rejse-ID: $groupId'),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    return Center(
      child: Text(message, style: GoogleFonts.kanit(color: Colors.grey)),
    );
  }
}
