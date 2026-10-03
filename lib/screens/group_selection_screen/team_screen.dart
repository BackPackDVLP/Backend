import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:backend/config/permissions.dart';
import 'package:backend/widget/edit_person_dialog.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Agency-scoped view of the admin employees who can log in to this
/// control panel for this bureau, plus the bureau's custom roles.
///
/// Reaching this screen at all already requires the `employees.manage`
/// permission (gated one level up, in group_selection_screen.dart's
/// `_buildMainContent`), so every action here — invite, edit, remove,
/// create/edit/delete a role, assign a role — is available to anyone who
/// got this far. The one thing nobody (not even another `employees.manage`
/// holder) can do is touch the bureau's owner: no edit/delete/role-assign
/// controls ever show on the owner's own row, and the server enforces the
/// same rule independently.
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
  Future<void> _showInviteDialog(List<AgencyRole> roles) async {
    final emailController = TextEditingController();
    final nameController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    String? selectedRoleId;

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
              content: SizedBox(
                width: 420,
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: nameController,
                        decoration: const InputDecoration(labelText: 'Navn'),
                      ),
                      const SizedBox(height: AppSpacing.md),
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
                      const SizedBox(height: AppSpacing.md),
                      DropdownButtonFormField<String?>(
                        initialValue: selectedRoleId,
                        decoration: const InputDecoration(labelText: 'Rolle'),
                        hint: const Text('Ingen valgt endnu'),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Fuld adgang (ingen rolle endnu)'),
                          ),
                          ...roles.map((r) => DropdownMenuItem<String?>(
                                value: r.id,
                                child: Text(r.name),
                              )),
                        ],
                        onChanged: (v) => setState(() => selectedRoleId = v),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'Vælger du ingen rolle, har medarbejderen fuld adgang, indtil du tildeler en rolle.',
                        style: AppTextStyles.caption(),
                      ),
                    ],
                  ),
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
                              if (selectedRoleId != null)
                                'roleId': selectedRoleId,
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
    String currentPhone,
    String currentWhatsapp,
  ) async {
    final success = await showEditPersonDialog(
      context,
      title: 'Rediger medarbejder',
      subtitle: currentEmail,
      mainColor: widget.mainColor,
      initialName: currentName,
      initialPhone: currentPhone,
      initialWhatsapp: currentWhatsapp,
      initialEmail: currentEmail,
      onSave: (name, phone, newEmail, whatsapp) async {
        try {
          await FirebaseFunctions.instanceFor(region: 'europe-west1')
              .httpsCallable('updateEmployee')
              .call({
            'uid': uid,
            'agencyCode': widget.agencyCode,
            'name': name,
            'email': newEmail,
            'phoneNumber': (phone ?? '').trim(),
            'whatsappNumber': (whatsapp ?? '').trim(),
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

  Future<void> _assignRole(String uid, String? roleId) async {
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('assignEmployeeRole')
          .call({
        'uid': uid,
        'agencyCode': widget.agencyCode,
        'roleId': roleId,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rolle opdateret')),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Kunne ikke tildele rolle')),
        );
      }
    }
  }

  Future<void> _showRoleDialog({AgencyRole? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final selectedPermissions = <String>{...?existing?.permissions};
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        bool isLoading = false;
        String? errorMessage;

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(existing == null ? 'Opret rolle' : 'Rediger rolle',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              content: SizedBox(
                width: 440,
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: nameController,
                        decoration:
                            const InputDecoration(labelText: 'Rollenavn'),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Indtast venligst et navn'
                            : null,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Text('Rettigheder', style: AppTextStyles.label()),
                      const SizedBox(height: AppSpacing.xs),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 340),
                        child: SingleChildScrollView(
                          child: Column(
                            children: kAllAppPermissions.map((p) {
                              final checked =
                                  selectedPermissions.contains(p.id);
                              return CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: checked,
                                activeColor: widget.mainColor,
                                secondary: Icon(p.icon,
                                    size: 20, color: Colors.grey[600]),
                                title: Text(p.label,
                                    style: GoogleFonts.kanit(fontSize: 13)),
                                onChanged: (v) => setState(() {
                                  if (v == true) {
                                    selectedPermissions.add(p.id);
                                  } else {
                                    selectedPermissions.remove(p.id);
                                  }
                                }),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                      if (errorMessage != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(errorMessage!,
                            style: AppTextStyles.body(color: Colors.red[700])),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      isLoading ? null : () => Navigator.pop(context, false),
                  child: const Text('Annuller'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: widget.mainColor),
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
                                .httpsCallable('saveAgencyRole')
                                .call({
                              'agencyCode': widget.agencyCode,
                              if (existing != null) 'roleId': existing.id,
                              'name': nameController.text.trim(),
                              'permissions': selectedPermissions.toList(),
                            });
                            if (context.mounted) Navigator.pop(context, true);
                          } on FirebaseFunctionsException catch (e) {
                            setState(() {
                              isLoading = false;
                              errorMessage = e.message ?? 'Kunne ikke gemme';
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
                      : const Text('Gem',
                          style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(existing == null ? 'Rolle oprettet' : 'Rolle opdateret')),
      );
    }
  }

  Future<void> _deleteRole(AgencyRole role) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Slet rolle',
            style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
        content: Text('Er du sikker på, at du vil slette "${role.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuller'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Slet', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('deleteAgencyRole')
          .call({'agencyCode': widget.agencyCode, 'roleId': role.id});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rolle slettet')),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Kunne ikke slette rollen')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldGradientStart,
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
            .collection('agency')
            .doc(widget.agencyCode)
            .collection('roles')
            .snapshots(),
        builder: (context, rolesSnapshot) {
          final roles = (rolesSnapshot.data?.docs ?? [])
              .map(AgencyRole.fromSnapshot)
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('admins')
                .where('agencyCodes', arrayContains: widget.agencyCode)
                .snapshots(),
            builder: (context, adminsSnapshot) {
              final employeeDocs = adminsSnapshot.data?.docs ?? [];

              return LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth > 900;
                  final rolesPanel = _buildRolesPanel(rolesSnapshot, roles);
                  final employeesPanel =
                      _buildEmployeesPanel(adminsSnapshot, employeeDocs, roles);

                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: isWide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(width: 360, child: rolesPanel),
                              const SizedBox(width: AppSpacing.xl),
                              Expanded(child: employeesPanel),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              rolesPanel,
                              const SizedBox(height: AppSpacing.xl),
                              employeesPanel,
                            ],
                          ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildPanelContainer({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: _panelDecoration(widget.mainColor),
      child: child,
    );
  }

  Widget _buildRolesPanel(
      AsyncSnapshot<QuerySnapshot> rolesSnapshot, List<AgencyRole> roles) {
    return _buildPanelContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            'Roller',
            trailing: TextButton.icon(
              onPressed: () => _showRoleDialog(),
              icon: const Icon(Icons.add),
              label: const Text('Opret rolle'),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (!rolesSnapshot.hasData)
            const Center(child: CircularProgressIndicator())
          else if (roles.isEmpty)
            _buildEmptyState(
                'Ingen roller oprettet endnu — opret en rolle for at give medarbejdere afgrænsede rettigheder.')
          else
            ...roles.map((role) => _buildRoleCard(role)),
        ],
      ),
    );
  }

  Widget _buildEmployeesPanel(AsyncSnapshot<QuerySnapshot> adminsSnapshot,
      List<QueryDocumentSnapshot> employeeDocs, List<AgencyRole> roles) {
    return _buildPanelContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            'Medarbejdere',
            trailing: TextButton.icon(
              onPressed: () => _showInviteDialog(roles),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Inviter'),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (!adminsSnapshot.hasData)
            const Center(child: CircularProgressIndicator())
          else if (employeeDocs.isEmpty)
            _buildEmptyState('Ingen medarbejdere fundet')
          else
            ...employeeDocs.map((doc) => _buildEmployeeCard(doc, roles)),
        ],
      ),
    );
  }

  Widget _permissionChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: widget.mainColor.withValues(alpha: 0.1),
        borderRadius: AppRadii.smRadius,
      ),
      child: Text(label,
          style: GoogleFonts.kanit(fontSize: 11, color: widget.mainColor)),
    );
  }

  Widget _buildRoleCard(AgencyRole role) {
    final matchedPermissions = kAllAppPermissions
        .where((p) => role.permissions.contains(p.id))
        .toList();
    const maxChipsShown = 4;
    final visiblePermissions = matchedPermissions.take(maxChipsShown).toList();
    final overflowCount = matchedPermissions.length - visiblePermissions.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: AppRadii.mdRadius,
        border: Border.all(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      widget.mainColor.withValues(alpha: 0.22),
                      widget.mainColor.withValues(alpha: 0.08),
                    ],
                  ),
                ),
                child: Icon(Icons.shield_outlined,
                    size: 15, color: widget.mainColor),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(role.name,
                    style: GoogleFonts.kanit(
                        fontWeight: FontWeight.w600, fontSize: 14)),
              ),
              IconButton(
                icon: Icon(Icons.edit_outlined,
                    size: 18, color: Colors.grey[600]),
                tooltip: 'Rediger rolle',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _showRoleDialog(existing: role),
              ),
              const SizedBox(width: AppSpacing.md),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: Colors.red),
                tooltip: 'Slet rolle',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _deleteRole(role),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (matchedPermissions.isEmpty)
            Text('Ingen rettigheder valgt', style: AppTextStyles.caption())
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ...visiblePermissions.map((p) => _permissionChip(p.label)),
                if (overflowCount > 0) _permissionChip('+$overflowCount mere'),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildEmployeeCard(QueryDocumentSnapshot doc, List<AgencyRole> roles) {
    final data = doc.data() as Map<String, dynamic>;
    final isOwner = (data['role'] as String? ?? 'employee') == 'owner';
    final email = data['email'] as String? ?? '';
    final name = data['name'] as String? ?? '';
    final phone = data['phoneNumber'] as String? ?? '';
    final whatsapp = data['whatsappNumber'] as String? ?? '';
    final rolesMap = (data['roles'] as Map?)?.cast<String, dynamic>();
    final assignedRoleId = rolesMap?[widget.agencyCode] as String?;
    final matchingRoles = roles.where((r) => r.id == assignedRoleId).toList();
    final assignedRole = matchingRoles.isEmpty ? null : matchingRoles.first;

    final String statusLabel;
    if (isOwner) {
      statusLabel = 'Ejer';
    } else if (assignedRoleId == null) {
      statusLabel = 'Fuld adgang (ingen rolle)';
    } else if (assignedRole == null) {
      statusLabel = 'Ukendt rolle';
    } else {
      statusLabel = assignedRole.name;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: AppRadii.mdRadius,
        border: Border.all(color: Colors.grey.withValues(alpha: 0.15)),
      ),
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
              isOwner ? Icons.star : Icons.person,
              color: widget.mainColor,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name.isNotEmpty ? name : email,
                    style: GoogleFonts.kanit(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 2),
                Text('$email · $statusLabel',
                    style: GoogleFonts.kanit(
                        fontSize: 12, color: Colors.grey[600])),
              ],
            ),
          ),
          if (!isOwner) ...[
            _RolePickerPill(
              label: statusLabel,
              themeColor: widget.mainColor,
              roles: roles,
              currentRoleId: assignedRoleId,
              onSelected: (roleId) => _assignRole(doc.id, roleId),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(Icons.edit_outlined, color: Colors.grey[600]),
                tooltip: 'Rediger medarbejder',
                onPressed: () =>
                    _editEmployee(doc.id, name, email, phone, whatsapp),
              ),
              if (!isOwner)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  tooltip: 'Fjern medarbejder',
                  onPressed: () => _removeEmployee(doc.id, email),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, {Widget? trailing}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: AppTextStyles.headingBold()),
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

// Soft gradient-tinted panel with a colored glow shadow instead of a flat
// gray card — same look as AppScreen's _panelDecoration (app_screen.dart),
// kept screen-local like every other copy of this in the app.
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

// `PopupMenuButton<T>` treats a `null` result from its menu as "dismissed
// without a selection" and calls `onCanceled` instead of `onSelected` —
// Flutter can't tell "no choice made" apart from "the chosen value happens
// to be null". Picking "Fuld adgang" (which needs to assign `null` as the
// role) would silently do nothing. A sentinel non-null value sidesteps
// that entirely; only this widget ever sees it, translated back to `null`
// right before it reaches `onSelected`.
const String _kNoRoleValue = '__no_role__';

/// A rounded pill showing an employee's current role, tapping opens a menu
/// to change it — styled to read as a real control rather than a bare
/// icon button, and to double as the status label itself.
class _RolePickerPill extends StatelessWidget {
  final String label;
  final Color themeColor;
  final List<AgencyRole> roles;
  final String? currentRoleId;
  final ValueChanged<String?> onSelected;

  const _RolePickerPill({
    required this.label,
    required this.themeColor,
    required this.roles,
    required this.currentRoleId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Tildel rolle',
      offset: const Offset(0, 40),
      shape: RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
      onSelected: (value) => onSelected(value == _kNoRoleValue ? null : value),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: _kNoRoleValue,
          child: Row(
            children: [
              Icon(Icons.all_inclusive,
                  size: 18,
                  color: currentRoleId == null ? themeColor : Colors.grey[500]),
              const SizedBox(width: AppSpacing.sm),
              const Text('Fuld adgang (ingen rolle)'),
            ],
          ),
        ),
        if (roles.isNotEmpty) const PopupMenuDivider(),
        ...roles.map((r) => PopupMenuItem<String>(
              value: r.id,
              child: Row(
                children: [
                  Icon(Icons.badge_outlined,
                      size: 18,
                      color: currentRoleId == r.id
                          ? themeColor
                          : Colors.grey[500]),
                  const SizedBox(width: AppSpacing.sm),
                  Text(r.name),
                ],
              ),
            )),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: themeColor.withValues(alpha: 0.08),
          borderRadius: AppRadii.smRadius,
          border: Border.all(color: themeColor.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.badge_outlined, size: 16, color: themeColor),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(
                label,
                style: GoogleFonts.kanit(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: themeColor),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 18, color: themeColor),
          ],
        ),
      ),
    );
  }
}
