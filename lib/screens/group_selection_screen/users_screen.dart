import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:backend/widget/edit_person_dialog.dart';
import 'package:backend/widget/phone_number_field.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

/// Agency-scoped view of the app users who are members of at least one of
/// this bureau's trips. Users can be edited (name/phone/email) or deleted.
///
/// Deleting is failsafe: a user who also travels with another bureau can
/// only be removed from this bureau's trips — their account and the other
/// bureau's data are left untouched. Only when this is their sole bureau
/// is their account, including their Firebase Auth login, fully deleted.
class UsersScreen extends StatefulWidget {
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
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  // `users/{uid}` doesn't carry a name of its own — it lives on the member
  // record inside each `groups/{groupId}.members[]` entry. Cache group
  // fetches by id so trips shared by several travelers only cost one read.
  final Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>>
      _groupCache = {};

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _AppInstallSort _sort = _AppInstallSort.none;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _getGroup(String groupId) {
    return _groupCache.putIfAbsent(
      groupId,
      () => FirebaseFirestore.instance.collection('groups').doc(groupId).get(),
    );
  }

  /// Every trip under this bureau this user belongs to, to show on their
  /// card and to look their member record up in. Prefers memberships
  /// scoped to this bureau (new schema); falls back to the legacy single
  /// `groupId` field most existing users still have.
  List<String> _groupIdsForUser(Map<String, dynamic> data) {
    final memberships = (data['memberships'] as List?) ?? const [];
    final ids = memberships
        .cast<Map?>()
        .where((m) => m != null && m['agencyCode'] == widget.agencyCode)
        .map((m) => m!['groupId'] as String?)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isNotEmpty) return ids;
    final legacyGroupId = data['groupId'] as String?;
    if (legacyGroupId != null && legacyGroupId.isNotEmpty) {
      return [legacyGroupId];
    }
    return const [];
  }

  Map<String, dynamic>? _findMemberByEmail(
    DocumentSnapshot<Map<String, dynamic>> groupDoc,
    String email,
  ) {
    final members = (groupDoc.data()?['members'] as List?) ?? const [];
    final member = members.cast<Map?>().firstWhere(
          (m) =>
              m != null &&
              (m['email'] as String?)?.toLowerCase() == email.toLowerCase(),
          orElse: () => null,
        );
    return member?.cast<String, dynamic>();
  }

  // Memoized on the doc-list identity (not on `_searchQuery`) — Firestore's
  // stream only emits a new `docs` list when the data actually changes, so
  // this only recomputes then, not on every keystroke. Typing filters the
  // already-resolved list synchronously.
  List<QueryDocumentSnapshot>? _cachedUserDocs;
  Future<List<_UserSearchEntry>>? _cachedSearchEntries;

  Future<List<_UserSearchEntry>> _getSearchEntries(
      List<QueryDocumentSnapshot> userDocs) {
    if (!identical(_cachedUserDocs, userDocs)) {
      _cachedUserDocs = userDocs;
      _cachedSearchEntries =
          Future.wait(userDocs.map(_resolveSearchEntry));
    }
    return _cachedSearchEntries!;
  }

  bool _hasAppInstalled(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ((data['fcmToken'] as String?) ?? '').isNotEmpty;
  }

  // Stable sort — within each install-status group, users keep whatever
  // order Firestore/the search filter already gave them, so this doesn't
  // fight with e.g. a future "sort by name" option added alongside it.
  List<QueryDocumentSnapshot> _applySort(List<QueryDocumentSnapshot> docs) {
    if (_sort == _AppInstallSort.none) return docs;
    final sorted = List<QueryDocumentSnapshot>.of(docs);
    final installedFirst = _sort == _AppInstallSort.installedFirst;
    sorted.sort((a, b) {
      final aInstalled = _hasAppInstalled(a);
      final bInstalled = _hasAppInstalled(b);
      if (aInstalled == bInstalled) return 0;
      final aFirst = installedFirst ? aInstalled : !aInstalled;
      return aFirst ? -1 : 1;
    });
    return sorted;
  }

  // `name`/`phoneNumber` on the `users/{uid}` doc itself are frequently
  // blank (see the class-level comment) — the real values, and the trip
  // names search should also match, only live on each group's member
  // record, so those need resolving here rather than filtering the raw
  // doc fields directly.
  Future<_UserSearchEntry> _resolveSearchEntry(
      QueryDocumentSnapshot doc) async {
    final data = doc.data() as Map<String, dynamic>;
    final email = (data['email'] as String? ?? '').toLowerCase();
    var name = (data['name'] as String? ?? '');
    var phone = data['phoneNumber']?.toString() ?? '';
    final groupNames = <String>[];

    final groupIds = _groupIdsForUser(data);
    if (groupIds.isNotEmpty) {
      final groupDocs = await Future.wait(groupIds.map(_getGroup));
      for (final groupDoc in groupDocs) {
        if (!groupDoc.exists) continue;
        final groupData = groupDoc.data();
        groupNames
            .add((groupData?['groupName'] as String?) ?? groupDoc.id);
        final member = _findMemberByEmail(groupDoc, email);
        if (member != null) {
          if (name.isEmpty) name = (member['name'] as String?) ?? '';
          if (phone.isEmpty || phone == '0') {
            final memberPhone = member['phoneNumber'];
            if (memberPhone != null) phone = memberPhone.toString();
          }
        }
      }
    }

    final searchableText =
        [name, email, phone, ...groupNames].join(' ').toLowerCase();
    return _UserSearchEntry(doc: doc, searchableText: searchableText);
  }

  Future<void> _openEditDialog(
    BuildContext context,
    QueryDocumentSnapshot doc,
  ) async {
    final data = doc.data() as Map<String, dynamic>;
    final uid = doc.id;
    final email = data['email'] as String? ?? '';
    final emailLower = email.toLowerCase();
    final hasAppInstalled = ((data['fcmToken'] as String?) ?? '').isNotEmpty;

    String prefillName = data['name'] as String? ?? '';
    String prefillPhone =
        (data['phoneNumber'] != null) ? data['phoneNumber'].toString() : '';
    String prefillWhatsapp =
        (data['whatsappNumber'] as String?)?.trim() ?? '';

    final groupIds = _groupIdsForUser(data);
    if (groupIds.isNotEmpty) {
      final groupDoc = await _getGroup(groupIds.first);
      final member = _findMemberByEmail(groupDoc, email);
      if (member != null) {
        prefillName = (member['name'] as String?) ?? prefillName;
        prefillPhone = member['phoneNumber'] != null
            ? member['phoneNumber'].toString()
            : prefillPhone;
        prefillWhatsapp =
            (member['whatsappNumber'] as String?)?.trim() ?? prefillWhatsapp;
      }
    }

    if (!context.mounted) return;

    final nameController = TextEditingController(text: prefillName);
    String phoneValue = prefillPhone;
    String whatsappValue = prefillWhatsapp;
    bool hasWhatsapp = prefillWhatsapp.isNotEmpty;
    final emailController = TextEditingController(text: email);
    final formKey = GlobalKey<FormState>();
    final pendingGroupIds = <String>{};

    final success = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        bool isSaving = false;
        String? errorMessage;
        // A bureau can have hundreds of trips — always listing every single
        // one just to toggle membership for one traveler doesn't scale.
        // Trips they're already on are always shown (normally a handful);
        // anything else only appears once you search for it by name.
        String tripSearchQuery = '';

        return StatefulBuilder(
          builder: (dialogCtx, setState) {
            Future<void> toggleGroup(String groupId, bool attach) async {
              setState(() => pendingGroupIds.add(groupId));
              try {
                await FirebaseFunctions.instanceFor(region: 'europe-west1')
                    .httpsCallable(
                        attach ? 'attachUserToGroup' : 'detachUserFromGroup')
                    .call({
                  'uid': uid,
                  'agencyCode': widget.agencyCode,
                  'groupId': groupId,
                });
              } on FirebaseFunctionsException catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content:
                            Text(e.message ?? 'Kunne ikke opdatere rejse')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Der skete en fejl')),
                  );
                }
              } finally {
                setState(() => pendingGroupIds.remove(groupId));
              }
            }

            Future<void> save() async {
              if (!formKey.currentState!.validate()) return;
              setState(() {
                isSaving = true;
                errorMessage = null;
              });
              try {
                await FirebaseFunctions.instanceFor(region: 'europe-west1')
                    .httpsCallable('updateAppUser')
                    .call({
                  'uid': uid,
                  'agencyCode': widget.agencyCode,
                  'name': nameController.text.trim(),
                  'phoneNumber': int.tryParse(
                          phoneValue.replaceAll(RegExp(r'[^0-9]'), '')) ??
                      0,
                  'email': emailController.text.trim(),
                  'whatsappNumber': hasWhatsapp ? whatsappValue.trim() : '',
                });
                if (dialogCtx.mounted) Navigator.pop(dialogCtx, true);
              } on FirebaseFunctionsException catch (e) {
                setState(() {
                  isSaving = false;
                  errorMessage = e.message ?? 'Kunne ikke gemme';
                });
              } catch (e) {
                setState(() {
                  isSaving = false;
                  errorMessage = 'Der skete en fejl';
                });
              }
            }

            return Dialog(
              shape: RoundedRectangleBorder(
                  borderRadius: AppRadii.lgRadius),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 480, maxHeight: 680),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: widget.mainColor.withOpacity(0.15),
                            child: Icon(Icons.person, color: widget.mainColor),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Rediger bruger',
                                    style: AppTextStyles.headingBold()),
                                Text(email,
                                    style: GoogleFonts.kanit(
                                        fontSize: 12, color: Colors.grey[600]),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            color: Colors.grey[500],
                            onPressed: isSaving
                                ? null
                                : () => Navigator.pop(dialogCtx, false),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                        child: Form(
                          key: formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Whether the traveler has actually opened the
                              // app: `fcmToken` is only ever set once the app
                              // has run on their device and registered for
                              // push notifications.
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: (hasAppInstalled
                                          ? Colors.green
                                          : Colors.grey)
                                      .withOpacity(0.08),
                                  borderRadius: AppRadii.mdRadius,
                                  border: Border.all(
                                    color: (hasAppInstalled
                                            ? Colors.green
                                            : Colors.grey)
                                        .withOpacity(0.25),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      hasAppInstalled
                                          ? Icons.check_circle_outline
                                          : Icons.help_outline,
                                      size: 18,
                                      color: hasAppInstalled
                                          ? Colors.green[700]
                                          : Colors.grey[600],
                                    ),
                                    const SizedBox(width: AppSpacing.sm),
                                    Expanded(
                                      child: Text(
                                        hasAppInstalled
                                            ? 'Appen er installeret'
                                            : 'Appen er endnu ikke installeret',
                                        style: GoogleFonts.kanit(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: hasAppInstalled
                                              ? Colors.green[700]
                                              : Colors.grey[700],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: AppSpacing.lg),
                              EditField(
                                controller: nameController,
                                label: 'Navn',
                                icon: Icons.badge_outlined,
                              ),
                              const SizedBox(height: AppSpacing.md),
                              PhoneNumberField(
                                initialValue: phoneValue,
                                label: 'Telefonnummer',
                                icon: Icons.phone_outlined,
                                onChanged: (v) {
                                  phoneValue = v;
                                  // WhatsApp defaults to mirroring the
                                  // phone number until the user diverges
                                  // it themselves — once they've edited the
                                  // WhatsApp field on its own, further phone
                                  // edits should stop overwriting it.
                                  if (hasWhatsapp &&
                                      whatsappValue == phoneValue) {
                                    setState(() => whatsappValue = v);
                                  }
                                },
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Colors.grey.withOpacity(0.06),
                                  borderRadius: AppRadii.mdRadius,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(MdiIcons.whatsapp,
                                            size: 19,
                                            color: hasWhatsapp
                                                ? const Color(0xFF25D366)
                                                : Colors.grey[500]),
                                        const SizedBox(width: AppSpacing.sm),
                                        Expanded(
                                          child: Text('Har brugeren WhatsApp?',
                                              style: GoogleFonts.kanit(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.grey[700])),
                                        ),
                                        YesNoToggle(
                                          value: hasWhatsapp,
                                          activeColor: widget.mainColor,
                                          onChanged: (v) => setState(() {
                                            hasWhatsapp = v;
                                            if (v && whatsappValue.isEmpty) {
                                              whatsappValue = phoneValue;
                                            }
                                          }),
                                        ),
                                      ],
                                    ),
                                    if (hasWhatsapp) ...[
                                      const SizedBox(height: AppSpacing.sm),
                                      PhoneNumberField(
                                        key: ValueKey(
                                            'whatsapp-$hasWhatsapp'),
                                        initialValue: whatsappValue,
                                        label: 'WhatsApp-nummer',
                                        icon: MdiIcons.whatsapp,
                                        iconColor: const Color(0xFF25D366),
                                        onChanged: (v) => whatsappValue = v,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              EditField(
                                controller: emailController,
                                label: 'Email',
                                icon: Icons.email_outlined,
                                keyboardType: TextInputType.emailAddress,
                                validator: (v) =>
                                    (v == null || v.trim().isEmpty)
                                        ? 'Indtast venligst en email'
                                        : null,
                              ),
                              if (errorMessage != null) ...[
                                const SizedBox(height: 14),
                                Container(
                                  padding: const EdgeInsets.all(AppSpacing.md),
                                  decoration: BoxDecoration(
                                    color: Colors.red.withOpacity(0.08),
                                    borderRadius: AppRadii.mdRadius,
                                    border: Border.all(
                                        color: Colors.red.withOpacity(0.2)),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Icon(Icons.error_outline,
                                          color: Colors.red, size: 18),
                                      const SizedBox(width: AppSpacing.sm),
                                      Expanded(
                                        child: Text(
                                          errorMessage!,
                                          style: AppTextStyles.body(color: Colors.red[700]),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: AppSpacing.xl),
                              Text(
                                'Rejser hos ${widget.agencyCode}',
                                style: GoogleFonts.kanit(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey[700]),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              StreamBuilder<QuerySnapshot>(
                                stream: FirebaseFirestore.instance
                                    .collection('groups')
                                    .where('agencyCode',
                                        isEqualTo: widget.agencyCode)
                                    .snapshots(),
                                builder: (context, groupsSnapshot) {
                                  if (!groupsSnapshot.hasData) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 16),
                                      child: Center(
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: widget.mainColor),
                                        ),
                                      ),
                                    );
                                  }
                                  final allGroupDocs = groupsSnapshot
                                      .data!.docs
                                      .where((g) =>
                                          (g.data() as Map<String, dynamic>)[
                                              'isTemplate'] !=
                                          true)
                                      .toList()
                                    ..sort((a, b) {
                                      final an = ((a.data() as Map)['groupName']
                                              as String?) ??
                                          a.id;
                                      final bn = ((b.data() as Map)['groupName']
                                              as String?) ??
                                          b.id;
                                      return an.compareTo(bn);
                                    });

                                  bool isMemberOf(QueryDocumentSnapshot g) {
                                    final members =
                                        ((g.data() as Map)['members']
                                                as List?) ??
                                            const [];
                                    return members.cast<Map?>().any((m) =>
                                        m != null &&
                                        (m['email'] as String?)
                                                ?.toLowerCase() ==
                                            emailLower);
                                  }

                                  final memberGroups =
                                      allGroupDocs.where(isMemberOf).toList();
                                  final query =
                                      tripSearchQuery.trim().toLowerCase();
                                  // Only searched for, never dumped in full —
                                  // a bureau can have hundreds of trips, and
                                  // an empty query showing all of them is
                                  // exactly the problem this replaces.
                                  final searchResults = query.isEmpty
                                      ? const <QueryDocumentSnapshot>[]
                                      : allGroupDocs
                                          .where((g) => !isMemberOf(g))
                                          .where((g) {
                                          final name = (((g.data() as Map)[
                                                      'groupName']
                                                  as String?) ??
                                              g.id);
                                          return name
                                              .toLowerCase()
                                              .contains(query);
                                        }).take(20).toList();

                                  Widget tripRow(
                                      QueryDocumentSnapshot groupDoc,
                                      bool isMember) {
                                    final groupName = ((groupDoc.data()
                                                as Map)['groupName']
                                            as String?) ??
                                        groupDoc.id;
                                    final isPending = pendingGroupIds
                                        .contains(groupDoc.id);
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 2),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(groupName,
                                                style: GoogleFonts.kanit(
                                                    fontSize: 14)),
                                          ),
                                          if (isPending)
                                            SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: widget.mainColor),
                                            )
                                          else
                                            Switch(
                                              value: isMember,
                                              activeThumbColor:
                                                  widget.mainColor,
                                              onChanged: (value) =>
                                                  toggleGroup(
                                                      groupDoc.id, value),
                                            ),
                                        ],
                                      ),
                                    );
                                  }

                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (memberGroups.isEmpty)
                                        Text(
                                          'Brugeren er ikke tilknyttet nogen rejser endnu.',
                                          style: AppTextStyles.body(
                                              color: Colors.grey),
                                        )
                                      else
                                        ...memberGroups
                                            .map((g) => tripRow(g, true)),
                                      const SizedBox(height: AppSpacing.md),
                                      TextField(
                                        onChanged: (v) => setState(
                                            () => tripSearchQuery = v),
                                        style: GoogleFonts.kanit(fontSize: 13),
                                        decoration: InputDecoration(
                                          isDense: true,
                                          hintText:
                                              'Søg for at tilføje en anden rejse...',
                                          hintStyle: AppTextStyles.body(
                                              color: Colors.grey[500]),
                                          prefixIcon: const Icon(
                                              Icons.search,
                                              size: 18),
                                          border: OutlineInputBorder(
                                              borderRadius:
                                                  AppRadii.smRadius),
                                        ),
                                      ),
                                      if (query.isNotEmpty) ...[
                                        const SizedBox(height: AppSpacing.sm),
                                        if (searchResults.isEmpty)
                                          Text('Ingen rejser matcher.',
                                              style: AppTextStyles.body(
                                                  color: Colors.grey))
                                        else
                                          ...searchResults
                                              .map((g) => tripRow(g, false)),
                                      ],
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: AppSpacing.sm),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: isSaving
                                ? null
                                : () => Navigator.pop(dialogCtx, false),
                            child: Text('Luk',
                                style:
                                    GoogleFonts.kanit(color: Colors.grey[600])),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          ElevatedButton(
                            onPressed: isSaving ? null : save,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: widget.mainColor,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius: AppRadii.smRadius),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 12),
                            ),
                            child: isSaving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        color: Colors.white, strokeWidth: 2),
                                  )
                                : Text('Gem',
                                    style: GoogleFonts.kanit(
                                        fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (success == true) {
      // The group member records just changed — drop the cached reads so
      // the list picks up the new name immediately instead of on next
      // rebuild. `updateAppUser` touches every one of this bureau's trips
      // the user belongs to, not just the first.
      for (final id in groupIds) {
        _groupCache.remove(id);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bruger opdateret')),
        );
      }
    }
  }

  Future<void> _deleteUser(
    BuildContext context,
    QueryDocumentSnapshot doc,
  ) async {
    final data = doc.data() as Map<String, dynamic>;
    final uid = doc.id;
    final email = data['email'] as String? ?? '';
    final agencyCodes = ((data['agencyCodes'] as List?) ?? const [])
        .whereType<String>()
        .toList();
    final isMultiBureau = agencyCodes.length > 1;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Slet bruger',
            style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
        content: Text(
          isMultiBureau
              ? '$email rejser også med et andet bureau. Brugeren fjernes kun fra dette bureaus rejser — kontoen og den anden bureaus data bevares.'
              : 'Er du sikker på, at du vil slette $email? Rejser brugeren udelukkende med dette bureau, slettes kontoen permanent, inkl. login. Rejser brugeren også med et andet bureau, fjernes de kun herfra.',
        ),
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
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('deleteAppUser')
          .call({'uid': uid, 'agencyCode': widget.agencyCode});
      final partial = result.data?['partial'] == true;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(partial
                ? 'Bruger fjernet fra dette bureaus rejser'
                : 'Bruger slettet permanent'),
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Kunne ikke slette bruger')),
        );
      }
    }
  }

  Widget _buildUserCard(BuildContext context, QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final email = data['email'] as String? ?? '';
    final cachedName = data['name'] as String? ?? '';
    final agencyCodes = ((data['agencyCodes'] as List?) ?? const [])
        .whereType<String>()
        .toList();
    final isMultiBureau = agencyCodes.length > 1;
    final hasAppInstalled = ((data['fcmToken'] as String?) ?? '').isNotEmpty;
    final groupIds = _groupIdsForUser(data);

    Widget buildTile(String displayName, List<String> groupNames) {
      return GestureDetector(
        onTap: () => _openEditDialog(context, doc),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: AppShadows.card,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: widget.mainColor.withValues(alpha: 0.12),
                child: Icon(Icons.luggage, color: widget.mainColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(displayName.isNotEmpty ? displayName : email,
                        style: GoogleFonts.kanit(
                            fontWeight: FontWeight.w600, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(email,
                        style: GoogleFonts.kanit(
                            fontSize: 12, color: Colors.grey[600])),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (groupNames.isEmpty)
                          _infoChip(Icons.card_travel, 'Ingen rejser',
                              color: Colors.grey)
                        else
                          for (final groupName in groupNames)
                            _infoChip(Icons.card_travel, groupName,
                                color: widget.mainColor),
                        _infoChip(
                          hasAppInstalled
                              ? Icons.phone_iphone
                              : Icons.phone_disabled_outlined,
                          hasAppInstalled
                              ? 'App installeret'
                              : 'App ikke installeret',
                          color: hasAppInstalled ? Colors.green : Colors.grey,
                        ),
                        if (isMultiBureau)
                          _infoChip(Icons.apartment_outlined,
                              'Rejser også med et andet bureau',
                              color: Colors.orange),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                tooltip: 'Slet bruger',
                onPressed: () => _deleteUser(context, doc),
              ),
            ],
          ),
        ),
      );
    }

    if (groupIds.isEmpty) {
      return buildTile(cachedName, const []);
    }

    return FutureBuilder<List<DocumentSnapshot<Map<String, dynamic>>>>(
      future: Future.wait(groupIds.map(_getGroup)),
      builder: (context, groupsSnap) {
        var displayName = cachedName;
        final groupNames = <String>[];
        for (final groupDoc in groupsSnap.data ?? const []) {
          if (!groupDoc.exists) continue;
          final groupData = groupDoc.data();
          groupNames.add((groupData?['groupName'] as String?) ?? groupDoc.id);
          if (displayName.isEmpty) {
            final member = _findMemberByEmail(groupDoc, email);
            displayName = (member?['name'] as String?) ?? displayName;
          }
        }
        return buildTile(displayName, groupNames);
      },
    );
  }

  Widget _infoChip(IconData icon, String label, {required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: GoogleFonts.kanit(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openCreateDialog(BuildContext context) async {
    final success = await showEditPersonDialog(
      context,
      title: 'Tilføj bruger',
      subtitle: 'Ny bruger hos ${widget.agencyCode}',
      mainColor: widget.mainColor,
      initialName: '',
      initialPhone: '',
      initialWhatsapp: '',
      initialEmail: '',
      onSave: (name, phone, email, whatsapp) async {
        try {
          await FirebaseFunctions.instanceFor(region: 'europe-west1')
              .httpsCallable('createAppUser')
              .call({
            'agencyCode': widget.agencyCode,
            'name': name,
            'phoneNumber':
                int.tryParse((phone ?? '').replaceAll(RegExp(r'[^0-9]'), '')) ??
                    0,
            'email': email,
            'whatsappNumber': (whatsapp ?? '').trim(),
          });
          return null;
        } on FirebaseFunctionsException catch (e) {
          return e.message ?? 'Kunne ikke oprette bruger';
        } catch (e) {
          return 'Der skete en fejl';
        }
      },
    );

    if (success && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bruger oprettet')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldGradientStart,
      appBar: widget.isNested
          ? null
          : AppBar(
              title: Text('Brugere',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              centerTitle: true,
              elevation: 0,
              backgroundColor: widget.mainColor,
              foregroundColor: Colors.white,
            ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Søg efter navn, email eller telefon...',
                      prefixIcon: Icon(Icons.search, color: Colors.grey[600]),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: AppRadii.mdRadius,
                        borderSide: BorderSide.none,
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                PopupMenuButton<_AppInstallSort>(
                  tooltip: 'Sortér',
                  icon: Badge(
                    isLabelVisible: _sort != _AppInstallSort.none,
                    child: const Icon(Icons.sort),
                  ),
                  initialValue: _sort,
                  onSelected: (value) => setState(() => _sort = value),
                  itemBuilder: (context) => [
                    CheckedPopupMenuItem(
                      value: _AppInstallSort.none,
                      checked: _sort == _AppInstallSort.none,
                      child: Text('Standard', style: GoogleFonts.kanit()),
                    ),
                    CheckedPopupMenuItem(
                      value: _AppInstallSort.installedFirst,
                      checked: _sort == _AppInstallSort.installedFirst,
                      child: Text('App installeret først',
                          style: GoogleFonts.kanit()),
                    ),
                    CheckedPopupMenuItem(
                      value: _AppInstallSort.notInstalledFirst,
                      checked: _sort == _AppInstallSort.notInstalledFirst,
                      child: Text('App ikke installeret først',
                          style: GoogleFonts.kanit()),
                    ),
                  ],
                ),
                const SizedBox(width: AppSpacing.sm),
                TextButton.icon(
                  onPressed: () => _openCreateDialog(context),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: Text('Tilføj bruger', style: GoogleFonts.kanit()),
                ),
              ],
            ),
          ),
          Expanded(child: _buildUsersList(context)),
        ],
      ),
    );
  }

  Widget _buildUsersList(BuildContext context) {
    // Matches both the legacy single `agencyCode` field (what today's
    // data actually has) and the newer `agencyCodes` array (populated by
    // the `syncGroupMembersToUsers` trigger and `createAppUser` going
    // forward) — most existing users predate both and haven't migrated.
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .where(Filter.or(
            Filter('agencyCode', isEqualTo: widget.agencyCode),
            Filter('agencyCodes', arrayContains: widget.agencyCode),
          ))
          .snapshots(),
      builder: (context, usersSnapshot) {
        if (!usersSnapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final userDocs = usersSnapshot.data!.docs;
        if (userDocs.isEmpty) {
          return _buildEmptyState('Ingen brugere fundet endnu');
        }
        final query = _searchQuery.trim().toLowerCase();
        if (query.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            children: _applySort(userDocs)
                .map((doc) => _buildUserCard(context, doc))
                .toList(),
          );
        }
        return FutureBuilder<List<_UserSearchEntry>>(
          future: _getSearchEntries(userDocs),
          builder: (context, searchSnapshot) {
            if (!searchSnapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final filteredDocs = _applySort(searchSnapshot.data!
                .where((e) => e.searchableText.contains(query))
                .map((e) => e.doc)
                .toList());
            if (filteredDocs.isEmpty) {
              return _buildEmptyState('Ingen brugere matcher din søgning');
            }
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              children: filteredDocs
                  .map((doc) => _buildUserCard(context, doc))
                  .toList(),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(String message) {
    return Center(
      child: Text(message, style: GoogleFonts.kanit(color: Colors.grey)),
    );
  }
}

/// A user doc paired with the fully-resolved (name/email/phone/trip names)
/// lowercased text the search bar matches against — see
/// _UsersScreenState._resolveSearchEntry.
class _UserSearchEntry {
  const _UserSearchEntry({required this.doc, required this.searchableText});

  final QueryDocumentSnapshot doc;
  final String searchableText;
}

enum _AppInstallSort { none, installedFirst, notInstalledFirst }
