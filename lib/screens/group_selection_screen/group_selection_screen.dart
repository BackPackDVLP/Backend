import 'package:backend/models/group_information_model.dart';
import 'package:backend/config/app_colors.dart';
import 'package:backend/models/agencyInformation.dart';
import 'package:backend/models/packinglist_model.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:backend/blocs/groupinformation/groupinformation_bloc.dart';
import 'package:backend/rootscreen/rootscreen.dart';
import 'package:backend/screens/groupIDscreen/groupIDscreen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

class GroupSelectionScreen extends StatefulWidget {
  static const String routeName = '/group-selection';
  final List<GroupInformation> groups;

  const GroupSelectionScreen({super.key, required this.groups});

  static Route route({required List<GroupInformation> groups}) {
    return MaterialPageRoute(
      builder: (_) => GroupSelectionScreen(groups: groups),
      settings: const RouteSettings(name: routeName),
    );
  }

  @override
  State<GroupSelectionScreen> createState() => _GroupSelectionScreenState();
}

class _GroupSelectionScreenState extends State<GroupSelectionScreen> {
  late List<GroupInformation> _groups;

  @override
  void initState() {
    super.initState();
    _groups = List.from(widget.groups);
  }

  void _selectGroup(BuildContext context, GroupInformation group) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('groupId', group.groupId);

    context
        .read<GroupInformationBloc>()
        .add(LoadGroupInformationById(groupId: group.groupId));
  }

  void _showDuplicateDialog(BuildContext context, GroupInformation group) {
    showDialog<GroupInformation>(
      context: context,
      builder: (context) => _DuplicateGroupDialog(originalGroup: group),
    ).then((newGroup) {
      if (newGroup != null) {
        setState(() {
          _groups.add(newGroup);
        });
      }
    });
  }

  void _showDeleteDialog(BuildContext context, GroupInformation group) {
    final passwordController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog<bool>(
      context: context,
      builder: (context) {
        bool isLoading = false;
        String? errorMessage;

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Slet rejse', style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Er du sikker på, at du vil slette "${group.groupId}"?'),
                  const SizedBox(height: 8),
                  const Text(
                    'Dette kan ikke fortrydes. Indtast din adgangskode for at bekræfte.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Form(
                    key: formKey,
                    child: TextFormField(
                      controller: passwordController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: 'Adgangskode',
                        errorText: errorMessage,
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) return 'Indtast adgangskode';
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isLoading ? null : () => Navigator.pop(context, false),
                  child: const Text('Annuller'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: isLoading
                      ? null
                      : () async {
                          if (formKey.currentState!.validate()) {
                            setState(() {
                              isLoading = true;
                              errorMessage = null;
                            });

                            try {
                              final user = FirebaseAuth.instance.currentUser;
                              if (user != null && user.email != null) {
                                AuthCredential credential = EmailAuthProvider.credential(
                                  email: user.email!,
                                  password: passwordController.text,
                                );

                                await user.reauthenticateWithCredential(credential);

                                // Delete from Firestore
                                await FirebaseFirestore.instance
                                    .collection('groups')
                                    .doc(group.groupId)
                                    .delete();

                                if (context.mounted) {
                                  Navigator.pop(context, true);
                                }
                              } else {
                                setState(() {
                                  isLoading = false;
                                  errorMessage = 'Ingen bruger fundet';
                                });
                              }
                            } on FirebaseAuthException catch (e) {
                              setState(() {
                                isLoading = false;
                                if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
                                  errorMessage = 'Forkert adgangskode';
                                } else {
                                  errorMessage = 'Fejl: ${e.message}';
                                }
                              });
                            } catch (e) {
                              setState(() {
                                isLoading = false;
                                errorMessage = 'Der skete en fejl';
                              });
                            }
                          }
                        },
                  child: isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Slet', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    ).then((confirmed) async {
      if (confirmed == true) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getString('groupId') == group.groupId) {
          await prefs.remove('groupId');
        }

        if (!mounted) return;
        setState(() {
          _groups.removeWhere((g) => g.groupId == group.groupId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rejse slettet')),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_groups.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushNamedAndRemoveUntil(
            context, GroupIDScreen.routeName, (route) => false);
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final bureauName = _groups.first.bureauName;
    final agencyCode = _groups.first.agencyCode;

    return BlocListener<GroupInformationBloc, GroupInformationState>(
      listener: (context, state) {
        if (state is GroupInformationLoaded) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => const RootScreen()),
            (route) => false,
          );
        } else if (state is GroupInformationError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.message)),
          );
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Desktop: Grid layout, Mobile: List layout
          final isDesktop = constraints.maxWidth > 800;
          return Scaffold(
          appBar: AppBar(
            centerTitle: true,
            title: Column(
              children: [
                Text(
                  bureauName,
                  style: GoogleFonts.kanit(
                      fontWeight: FontWeight.bold, color: AppColors.homeGradientStart, fontSize: 22),
                ),
                Text(
                  'Rejseoversigt',
                  style: GoogleFonts.kanit(fontSize: 12, color: AppColors.panelBackground),
                ),
              ],
            ),
            backgroundColor: AppColors.navActive,
            elevation: 0,
            iconTheme: const IconThemeData(color: AppColors.homeGradientStart),
          ),
          floatingActionButton: isDesktop
              ? FloatingActionButton(
                  onPressed: () {
                    showDialog<GroupInformation>(
                      context: context,
                      builder: (context) => _AddGroupDialog(
                        bureauName: bureauName,
                        agencyCode: agencyCode,
                      ),
                    ).then((newGroup) {
                      if (newGroup != null) {
                        setState(() {
                          _groups.add(newGroup);
                        });
                      }
                    });
                  },
                  child: const Icon(Icons.add),
                )
              : null,
          body: Container(
            width: double.infinity,
            padding: EdgeInsets.zero, // Remove padding to let bottom panel touch edges
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.scaffoldGradientStart,
                  AppColors.scaffoldGradientEnd,
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.5],
              ),
            ),
            child: Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: isDesktop
                        ? GridView.builder(
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 400, // max width per card
                              mainAxisSpacing: 16,
                              crossAxisSpacing: 16,
                              childAspectRatio: 0.8, // slightly smaller, cards can grow
                            ),
                            itemCount: _groups.length,
                            itemBuilder: (context, index) =>
                                _buildGroupCard(context, _groups[index]),
                          )
                        : ListView.builder(
                            itemCount: _groups.length,
                            itemBuilder: (context, index) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: _buildGroupCard(context, _groups[index]),
                            ),
                          ),
                  ),
                ),
                _buildAgencyPanel(agencyCode),
              ],
            ),
          ),
        );
      },
      ),
    );
  }

  Widget _buildAgencyPanel(String agencyCode) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('agency')
          .doc(agencyCode)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }

        final agencyInfo = AgencyInformation.fromSnapshot(snapshot.data!);

        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, -4),
              ),
            ],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              title: Text('Bureauindstillinger',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.w600, color: AppColors.primary, fontSize: 18)),
              subtitle: Text(agencyInfo.agencyName, style: GoogleFonts.kanit(color: Colors.grey[600])),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: _AgencyEditForm(agencyInfo: agencyInfo),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGroupCard(BuildContext context, GroupInformation group) {
    final now = DateTime.now();
    final daysUntil = group.departureDate.difference(now).inDays;
    final daysLeft = group.returnDate.difference(now).inDays;

    String countdownText;
    IconData countdownIcon;

    if (daysUntil > 0) {
      countdownText = 'Afrejse om $daysUntil dage';
      countdownIcon = Icons.flight_takeoff;
    } else if (daysLeft > 0) {
      countdownText = 'Rejse i gang – $daysLeft dage tilbage';
      countdownIcon = Icons.beach_access;
    } else {
      countdownText = 'Rejse afsluttet';
      countdownIcon = Icons.check_circle_outline;
    }

    return InkWell(
      onTap: () => _selectGroup(context, group),
      borderRadius: BorderRadius.circular(16),
      child: Card(
        elevation: 5,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.withOpacity(0.5), width: 1),
        ),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, // allow card to grow with content
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildGroupInfo(group)),
                  IconButton(
                    icon: const Icon(Icons.copy),
                    color: Colors.black54,
                    iconSize: 20,
                    onPressed: () => _showDuplicateDialog(context, group),
                    tooltip: 'Dupliker rejse',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    color: Colors.red.withOpacity(0.7),
                    iconSize: 20,
                    onPressed: () => _showDeleteDialog(context, group),
                    tooltip: 'Slet rejse',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  _infoChip(Icons.people, '${group.members.length} medlemmer'),
                  _infoChip(Icons.support_agent, '${group.guides.length} guider'),
                  if (group.flightAway) _infoChip(Icons.flight_takeoff, 'Udrejse'),
                  if (group.flightHome) _infoChip(Icons.flight_land, 'Hjemrejse'),
                  if (group.emergencyPhone != null && group.emergencyPhone!.isNotEmpty)
                    _infoChip(Icons.phone, group.emergencyPhone!),
                  _infoChip(Icons.place, 'Start: ${group.departureFrom}'),
                  _infoChip(Icons.place, 'Slut: ${group.returnTo}'),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(countdownIcon, color: Colors.black54, size: 20),
                      const SizedBox(width: 6),
                      Text(
                        countdownText,
                        style: GoogleFonts.kanit(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  const Icon(Icons.arrow_forward_ios, color: Colors.black54, size: 18),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroupInfo(GroupInformation group) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          group.bureauName,
          style: GoogleFonts.kanit(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        Text(
          group.groupId,
          style: GoogleFonts.kanit(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.flight_takeoff, color: Colors.black54, size: 18),
            const SizedBox(width: 6),
            Text(
              'Afrejse: ${DateFormat('dd. MMMM yyyy', 'da_DK').format(group.departureDate)}',
              style: GoogleFonts.kanit(color: Colors.black87),
            ),
          ],
        ),
        Row(
          children: [
            const Icon(Icons.flight_land, color: Colors.black54, size: 18),
            const SizedBox(width: 6),
            Text(
              'Hjemkomst: ${DateFormat('dd. MMMM yyyy', 'da_DK').format(group.returnDate)}',
              style: GoogleFonts.kanit(color: Colors.black87),
            ),
          ],
        ),
      ],
    );
  }

  Widget _infoChip(IconData icon, String label) {
    return Chip(
      backgroundColor: AppColors.chipBackground,
      elevation: 0,
      avatar: Icon(icon, size: 16, color: Colors.black87),
      label: Text(label, style: GoogleFonts.kanit(fontSize: 14)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
    );
  }
}

class _AgencyEditForm extends StatefulWidget {
  final AgencyInformation agencyInfo;

  const _AgencyEditForm({required this.agencyInfo});

  @override
  State<_AgencyEditForm> createState() => _AgencyEditFormState();
}

class _AgencyEditFormState extends State<_AgencyEditForm> {
  late TextEditingController _nameController;
  late TextEditingController _phoneController;
  late TextEditingController _emailController;
  late TextEditingController _colorController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.agencyInfo.agencyName);
    _phoneController =
        TextEditingController(text: widget.agencyInfo.emergencyPhone);
    _emailController =
        TextEditingController(text: widget.agencyInfo.returnMail);
    _colorController = TextEditingController(text: widget.agencyInfo.mainColor);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  Color _getColorFromHex(String hexColor) {
    try {
      return AppColors.fromHex(hexColor);
    } catch (e) {
      return Colors.black;
    }
  }

  void _showColorPicker() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vælg farve'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: _getColorFromHex(_colorController.text),
            onColorChanged: (color) {
              setState(() {
                _colorController.text =
                    '#${color.value.toRadixString(16).substring(2).toUpperCase()}';
              });
            },
            enableAlpha: false,
            displayThumbColor: true,
            paletteType: PaletteType.hsvWithHue,
          ),
        ),
        actions: [
          ElevatedButton(
            child: const Text('Vælg'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    try {
      await FirebaseFirestore.instance
          .collection('agency')
          .doc(widget.agencyInfo.agencyCode)
          .update({
        'agencyName': _nameController.text,
        'emergencyPhone': _phoneController.text,
        'returnMail': _emailController.text,
        'mainColor': _colorController.text,
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Gemt!')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Fejl: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextFormField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Navn')),
        TextFormField(
            controller: _phoneController,
            decoration: const InputDecoration(labelText: 'Nødtelefon')),
        TextFormField(
            controller: _emailController,
            decoration: const InputDecoration(labelText: 'Kontakt e-mail')),
        TextFormField(
          controller: _colorController,
          decoration: InputDecoration(
            labelText: 'Primær farve (Hex)',
            suffixIcon: IconButton(
              icon: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: _getColorFromHex(_colorController.text),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.grey),
                ),
              ),
              onPressed: _showColorPicker,
            ),
          ),
          onChanged: (value) => setState(() {}),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('Emails brugt: ${widget.agencyInfo.emailCount} / ${widget.agencyInfo.maxEmails}'),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
          ),
          child: const Text('Gem ændringer'),
        ),
      ],
    );
  }
}

class _DuplicateGroupDialog extends StatefulWidget {
  final GroupInformation originalGroup;

  const _DuplicateGroupDialog({required this.originalGroup});

  @override
  State<_DuplicateGroupDialog> createState() => _DuplicateGroupDialogState();
}

class _DuplicateGroupDialogState extends State<_DuplicateGroupDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _groupIdController;
  late DateTime _departureDate;
  late DateTime _returnDate;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _groupIdController = TextEditingController(text: '${widget.originalGroup.groupId}_copy');
    _departureDate = widget.originalGroup.departureDate;
    _returnDate = widget.originalGroup.returnDate;
  }

  @override
  void dispose() {
    _groupIdController.dispose();
    super.dispose();
  }

  Future<void> _duplicateGroup() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });
      try {
        final durationDiff = _departureDate.difference(widget.originalGroup.departureDate);

        List<TimelineEvent> newTimelineEvents = [];
        for (var e in widget.originalGroup.timelineEvents) {
          String? newImageUrl = e.imageURL;
          if (e.imageURL.isNotEmpty &&
              e.imageURL.contains('firebasestorage')) {
            try {
              final ref = FirebaseStorage.instance.refFromURL(e.imageURL);
              final data = await ref.getData();
              if (data != null) {
                final agencyCode = widget.originalGroup.agencyCode;
                final targetPath = 'agencies/$agencyCode/timeline_images/${ref.name}';

                // Only copy if it's not already in the agency folder
                if (ref.fullPath != targetPath) {
                  final newRef = FirebaseStorage.instance.ref().child(targetPath);
                  await newRef.putData(data);
                  newImageUrl = await newRef.getDownloadURL();
                }
              }
            } catch (err) {
              debugPrint('Error copying image: $err');
            }
          }

          newTimelineEvents.add(TimelineEvent(
            id: e.id,
            type: e.type,
            country: e.country,
            startDate: e.startDate.add(durationDiff),
            endDate: e.endDate.add(durationDiff),
            dayNumber: e.dayNumber,
            isDestination: e.isDestination,
            imageURL: newImageUrl ?? '',
            description: e.description,
          ));
        }

        final newPackingLists = widget.originalGroup.packinglistCategories.map((e) {
          return PackinglistCategories(
            iconName: e.iconName,
            categoryName: e.categoryName,
            items: List.from(e.items),
          );
        }).toList();

        final group = GroupInformation(
          groupId: _groupIdController.text,
          id: _groupIdController.text,
          coupons: widget.originalGroup.coupons != null ? List.from(widget.originalGroup.coupons!) : [],
          bureauName: widget.originalGroup.bureauName,
          agencyCode: widget.originalGroup.agencyCode,
          departureDate: _departureDate,
          returnDate: _returnDate,
          members: [],
          guides: [],
          timelineEvents: newTimelineEvents,
          packinglistCategories: newPackingLists,
          flightAway: widget.originalGroup.flightAway,
          flightHome: widget.originalGroup.flightHome,
          emergencyPhone: widget.originalGroup.emergencyPhone,
          departureFrom: widget.originalGroup.departureFrom,
          returnTo: widget.originalGroup.returnTo,
        );

        await FirebaseFirestore.instance.collection('groups').doc(group.groupId).set({
          'groupId': group.groupId,
          'coupons': group.coupons?.map((e) => e.toMap()).toList(),
          'id': group.groupId,
          'bureauName': group.bureauName,
          'agencyCode': group.agencyCode,
          'departureDate': group.departureDate,
          'returnDate': group.returnDate,
          'members': group.members.map((e) => e.toMap()).toList(),
          'guides': group.guides.map((e) => e.toMap()).toList(),
          'timelineEvents': group.timelineEvents.map((e) => e.toMap()).toList(),
          'packinglistCategories': group.packinglistCategories.map((e) => e.toMap()).toList(),
          'flightAway': group.flightAway,
          'flightHome': group.flightHome,
          'emergencyPhone': group.emergencyPhone,
          'departureFrom': group.departureFrom,
          'returnTo': group.returnTo,
        });

        await FirebaseStorage.instance.ref('${group.groupId}/documents/.keep').putString('');

        if (mounted) {
          Navigator.of(context).pop(group);
        }
      } catch (e) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fejl: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text('Dupliker rejse', style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _groupIdController,
                  decoration: InputDecoration(
                    labelText: 'Ny Gruppe ID',
                    prefixIcon: const Icon(Icons.vpn_key),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (v) => v!.isEmpty ? 'Påkrævet' : null,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _departureDate,
                            firstDate: DateTime.now().subtract(const Duration(days: 365)),
                            lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
                          );
                          if (picked != null) setState(() => _departureDate = picked);
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Ny Afrejse',
                            prefixIcon: const Icon(Icons.calendar_today),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          child: Text(DateFormat('dd/MM/yyyy').format(_departureDate)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _returnDate,
                            firstDate: DateTime.now().subtract(const Duration(days: 365)),
                            lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
                          );
                          if (picked != null) setState(() => _returnDate = picked);
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Ny Hjemkomst',
                            prefixIcon: const Icon(Icons.event),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          child: Text(DateFormat('dd/MM/yyyy').format(_returnDate)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _isLoading ? null : () => Navigator.pop(context),
            child: const Text('Annuller')),
        ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _isLoading ? null : _duplicateGroup,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Dupliker')),
      ],
    );
  }
}

class _AddGroupDialog extends StatefulWidget {
  final String bureauName;
  final String agencyCode;

  const _AddGroupDialog({required this.bureauName, required this.agencyCode});

  @override
  State<_AddGroupDialog> createState() => _AddGroupDialogState();
}

class _AddGroupDialogState extends State<_AddGroupDialog> {
  final _formKey = GlobalKey<FormState>();
  final _groupIdController = TextEditingController();

  DateTime _departureDate = DateTime.now();
  DateTime _returnDate = DateTime.now().add(const Duration(days: 7));
  final bool _flightAway = false;
  final bool _flightHome = false;

  @override
  void dispose() {
    _groupIdController.dispose();
    super.dispose();
  }

  Future<void> _saveGroup() async {
    if (_formKey.currentState!.validate()) {
      try {
        final group = GroupInformation(
          groupId: _groupIdController.text,
          id: "1",
          coupons:[],
          bureauName: widget.bureauName,
          agencyCode: widget.agencyCode,
          departureDate: _departureDate,
          returnDate: _returnDate,
          members: []
           ,
          guides: [],
          timelineEvents: [
            TimelineEvent(
              id: 'template_1',
              type: 'Fx. Ankomst til Hoi An',
              country: 'Fx. Vietnam',
              startDate: _departureDate,
              endDate: _departureDate.add(const Duration(days: 1)),
              dayNumber: 1,
              isDestination: false,
              imageURL: 'https://images.unsplash.com/photo-1519414442781-fbd745c5b497?w=900&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8M3x8c3Vuc2V0JTIwbW91bnRhaW5zfGVufDB8MHwwfHx8MA%3D%3D',
              description: 'Skriv her en beskrivelse af begivenheden',
            ),
          ],
          packinglistCategories: [
            PackinglistCategories(
              iconName: 'text_box_multiple_outline',
      categoryName: 'Dokumenter',
      items: ['Pas', 'Lokal valuta', 'Rejseforsikring'],
            ),
          ],
          flightAway: _flightAway,
          flightHome: _flightHome,
          emergencyPhone: '',
          departureFrom: '',
          returnTo: '',
        );

        await FirebaseFirestore.instance
            .collection('groups')
            .doc(group.groupId)
            .set({
          'groupId': group.groupId,
          'coupons': group.coupons?.map((e) => e.toMap()).toList(),
          'id': group.groupId,
          'bureauName': group.bureauName,
          'agencyCode': group.agencyCode,
          'departureDate': group.departureDate,
          'returnDate': group.returnDate,
          'members': group.members.map((e) => e.toMap()).toList(),
          'guides': group.guides.map((e) => e.toMap()).toList(),
          'timelineEvents': group.timelineEvents.map((e) => e.toMap()).toList(),
          'packinglistCategories': group.packinglistCategories.map((e) => e.toMap()).toList(),
          'flightAway': group.flightAway,
          'flightHome': group.flightHome,
          'emergencyPhone': group.emergencyPhone,
          'departureFrom': group.departureFrom,
          'returnTo': group.returnTo,
        });

        
        if (mounted) {
          Navigator.of(context).pop(group);
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fejl: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text('Tilføj ny rejse', style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.business, color: Colors.black54),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.bureauName, style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('Kode: ${widget.agencyCode}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _groupIdController,
                  decoration: InputDecoration(
                    labelText: 'Gruppe ID',
                    prefixIcon: const Icon(Icons.vpn_key),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (v) => v!.isEmpty ? 'Påkrævet' : null,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _departureDate,
                            firstDate: DateTime.now().subtract(const Duration(days: 365)),
                            lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
                          );
                          if (picked != null) setState(() => _departureDate = picked);
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Afrejse',
                            prefixIcon: const Icon(Icons.calendar_today),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          child: Text(DateFormat('dd/MM/yyyy').format(_departureDate)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _returnDate,
                            firstDate: DateTime.now().subtract(const Duration(days: 365)),
                            lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
                          );
                          if (picked != null) setState(() => _returnDate = picked);
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Hjemkomst',
                            prefixIcon: const Icon(Icons.event),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          child: Text(DateFormat('dd/MM/yyyy').format(_returnDate)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuller')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: _saveGroup,
          child: const Text('Opret'),
        ),
      ],
    );
  }
}
