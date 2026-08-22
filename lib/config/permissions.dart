import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// A single capability a bureau's custom roles can grant. Fixed on purpose
/// — a permission is only meaningful because some screen/Cloud Function
/// actually checks it, so this list isn't end-user-extensible. What's
/// customizable per bureau is which named roles grant which of these, and
/// which role each employee is assigned. Mirrored server-side in
/// `backpack/functions/src/index.ts` (`PERMISSIONS`) — keep both in sync.
class AppPermission {
  final String id;
  final String label;
  final IconData icon;

  const AppPermission(this.id, this.label, this.icon);
}

const List<AppPermission> kAllAppPermissions = [
  AppPermission('crm_integration.edit', 'Rediger CRM-integration', Icons.sync_alt),
  AppPermission('employees.manage', 'Administrer medarbejdere og roller', Icons.badge),
  AppPermission('users.edit', 'Rediger brugere', Icons.people),
  AppPermission('agency_settings.edit', 'Rediger bureau-indstillinger', Icons.settings),
  AppPermission('app_settings.edit', 'Rediger app-indstillinger', Icons.smartphone),
  AppPermission('photo_library.edit', 'Rediger fotobibliotek', Icons.photo_library),
  AppPermission('packing_lists.edit', 'Rediger pakkelister', Icons.checklist),
  AppPermission('templates.edit', 'Rediger skabeloner', Icons.copy_all),
  AppPermission('trips.create', 'Opret rejser', Icons.add_circle_outline),
  AppPermission('trips.edit', 'Rediger rejser', Icons.edit_calendar),
];

final Set<String> kAllPermissionIds =
    kAllAppPermissions.map((p) => p.id).toSet();

/// One bureau-defined role: a name plus a checklist of [kAllAppPermissions].
class AgencyRole {
  final String id;
  final String name;
  final Set<String> permissions;

  const AgencyRole({
    required this.id,
    required this.name,
    required this.permissions,
  });

  factory AgencyRole.fromSnapshot(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return AgencyRole(
      id: doc.id,
      name: data['name'] as String? ?? '',
      permissions: Set<String>.from(data['permissions'] as List? ?? []),
    );
  }
}

/// Resolves the signed-in caller's permission set for [agencyCode] and
/// rebuilds whenever it changes, via [builder]. Mirrors the server's
/// `hasPermission` logic in index.ts:
/// - BACKPACK-ADMIN or `role: 'owner'` → every permission.
/// - No `roles[agencyCode]` entry assigned yet → every permission too, a
///   deliberate rollout choice (see the roles feature's design notes) so
///   shipping this never silently revokes access nobody's been asked to
///   reassign yet.
/// - Otherwise, exactly the permissions on the assigned role doc (missing
///   role doc fails open to full access, matching the server).
class AgencyPermissionsResolver extends StatelessWidget {
  final String agencyCode;
  final Widget Function(BuildContext context, Set<String> permissions)
      builder;

  const AgencyPermissionsResolver({
    super.key,
    required this.agencyCode,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return builder(context, const {});

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('admins')
          .doc(uid)
          .snapshots(),
      builder: (context, ownDocSnapshot) {
        final ownData =
            ownDocSnapshot.data?.data() as Map<String, dynamic>?;
        if (ownData == null) return builder(context, const {});

        final agencyCodes =
            List<String>.from(ownData['agencyCodes'] as List? ?? []);
        final isSuperAdmin = agencyCodes.contains('BACKPACK-ADMIN');
        final role = ownData['role'] as String?;
        if (isSuperAdmin || role == 'owner') {
          return builder(context, kAllPermissionIds);
        }

        final rolesMap =
            (ownData['roles'] as Map?)?.cast<String, dynamic>();
        final roleId = rolesMap?[agencyCode] as String?;
        if (roleId == null || roleId.isEmpty) {
          return builder(context, kAllPermissionIds);
        }

        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('agency')
              .doc(agencyCode)
              .collection('roles')
              .doc(roleId)
              .snapshots(),
          builder: (context, roleSnapshot) {
            if (!roleSnapshot.hasData || roleSnapshot.data?.exists != true) {
              return builder(context, kAllPermissionIds);
            }
            final data = roleSnapshot.data!.data() as Map<String, dynamic>;
            final permissions =
                Set<String>.from(data['permissions'] as List? ?? []);
            return builder(context, permissions);
          },
        );
      },
    );
  }
}
