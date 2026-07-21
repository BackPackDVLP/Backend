import 'package:backend/widget/edit_person_dialog.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Agency-scoped view of the admin employees who can log in to this
/// control panel for this bureau. Invite/edit/remove is owner-only.
class TeamScreen extends StatefulWidget {
  final String agencyCode;
  final Color mainColor;
  final bool isNested;

  const TeamScreen({
    super.key,
    required this.agencyCode,
    required this.mainColor,
    this.isNested = false,
  });

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  Future<void> _showInviteDialog() async {
    final emailController = TextEditingController();
    final nameController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        bool isLoading = false;
        String? errorMessage;

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Inviter medarbejder',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Navn'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: 'Email',
                        errorText: errorMessage,
                      ),
                      validator: (value) => (value == null || value.isEmpty)
                          ? 'Indtast venligst en email'
                          : null,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      isLoading ? null : () => Navigator.pop(context, false),
                  child: const Text('Annuller'),
                ),
                ElevatedButton(
                  onPressed: isLoading
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setState(() {
                            isLoading = true;
                            errorMessage = null;
                          });
                          try {
                            await FirebaseFunctions.instanceFor(
                                    region: 'europe-west1')
                                .httpsCallable('inviteEmployee')
                                .call({
                              'email': emailController.text.trim(),
                              'name': nameController.text.trim(),
                              'agencyCode': widget.agencyCode,
                            });
                            if (context.mounted) Navigator.pop(context, true);
                          } on FirebaseFunctionsException catch (e) {
                            setState(() {
                              isLoading = false;
                              errorMessage = e.message ?? 'Kunne ikke invitere';
                            });
                          } catch (e) {
                            setState(() {
                              isLoading = false;
                              errorMessage = 'Der skete en fejl';
                            });
                          }
                        },
                  child: isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : const Text('Inviter'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invitation sendt')),
      );
    }
  }

  Future<void> _editEmployee(
    String uid,
    String currentName,
    String currentEmail,
  ) async {
    final success = await showEditPersonDialog(
      context,
      title: 'Rediger medarbejder',
      subtitle: currentEmail,
      mainColor: widget.mainColor,
      initialName: currentName,
      initialEmail: currentEmail,
      onSave: (name, _, newEmail) async {
        try {
          await FirebaseFunctions.instanceFor(region: 'europe-west1')
              .httpsCallable('updateEmployee')
              .call({
            'uid': uid,
            'agencyCode': widget.agencyCode,
            'name': name,
            'email': newEmail,
          });
          return null;
        } on FirebaseFunctionsException catch (e) {
          return e.message ?? 'Kunne ikke gemme';
        } catch (e) {
          return 'Der skete en fejl';
        }
      },
    );

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Medarbejder opdateret')),
      );
    }
  }

  Future<void> _removeEmployee(String uid, String email) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Fjern medarbejder',
            style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
        content: Text('Er du sikker på, at du vil fjerne $email?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuller'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Fjern', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('removeEmployee')
          .call({'uid': uid, 'agencyCode': widget.agencyCode});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Medarbejder fjernet')),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Kunne ikke fjerne medarbejder')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: widget.isNested
          ? null
          : AppBar(
              title: Text('Team',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              centerTitle: true,
              elevation: 0,
              backgroundColor: widget.mainColor,
              foregroundColor: Colors.white,
            ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('admins')
            .where('agencyCodes', arrayContains: widget.agencyCode)
            .snapshots(),
        builder: (context, adminsSnapshot) {
          final employeeDocs = adminsSnapshot.data?.docs ?? [];
          final isOwner = employeeDocs.any((doc) =>
              doc.id == currentUid &&
              (doc.data() as Map<String, dynamic>)['role'] == 'owner');

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _buildSectionHeader(
                'Medarbejdere',
                trailing: isOwner
                    ? TextButton.icon(
                        onPressed: _showInviteDialog,
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('Inviter'),
                      )
                    : null,
              ),
              const SizedBox(height: 8),
              if (!adminsSnapshot.hasData)
                const Center(child: CircularProgressIndicator())
              else if (employeeDocs.isEmpty)
                _buildEmptyState('Ingen medarbejdere fundet')
              else
                ...employeeDocs.map((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final role = data['role'] as String? ?? 'employee';
                  final email = data['email'] as String? ?? '';
                  final name = data['name'] as String? ?? '';
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: widget.mainColor.withOpacity(0.15),
                        child: Icon(
                          role == 'owner' ? Icons.star : Icons.person,
                          color: widget.mainColor,
                        ),
                      ),
                      title: Text(name.isNotEmpty ? name : email,
                          style:
                              GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          '$email · ${role == 'owner' ? 'Ejer' : 'Medarbejder'}'),
                      trailing: isOwner
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined),
                                  tooltip: 'Rediger medarbejder',
                                  onPressed: () =>
                                      _editEmployee(doc.id, name, email),
                                ),
                                if (role != 'owner')
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        color: Colors.red),
                                    tooltip: 'Fjern medarbejder',
                                    onPressed: () =>
                                        _removeEmployee(doc.id, email),
                                  ),
                              ],
                            )
                          : null,
                    ),
                  );
                }),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(String title, {Widget? trailing}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title,
            style: GoogleFonts.kanit(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87)),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _buildEmptyState(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(message, style: GoogleFonts.kanit(color: Colors.grey)),
    );
  }
}
