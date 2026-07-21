import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:backend/config/app_colors.dart';
import 'package:intl/intl.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/coupon_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:google_fonts/google_fonts.dart';

class GroupDetailsScreen extends StatefulWidget {
  final String groupId;
  final GroupInformationRepository repository;

  const GroupDetailsScreen({
    super.key,
    required this.groupId,
    required this.repository,
  });

  @override
  State<GroupDetailsScreen> createState() => _GroupDetailsScreenState();
}

class _GroupDetailsScreenState extends State<GroupDetailsScreen> {
  GroupInformation? _group;
  bool _loading = true;
  final _formKey = GlobalKey<FormState>();

  // Controllers
  final _departureDateController = TextEditingController();
  final _returnDateController = TextEditingController();
  final _departureFromController = TextEditingController();
  final _returnToController = TextEditingController();
  final _emergencyPhoneController = TextEditingController();
  bool _flightAway = false;
  bool _flightHome = false;
  bool _mapEnabled = false;
  List<String> _beforeDepartureItems = [];

  @override
  void initState() {
    super.initState();
    _loadGroup();
  }

  Future<void> _loadGroup() async {
    // Use .first to treat the stream like a future for a one-time load.
    // This prevents setState calls after the widget is disposed if the user navigates away.
    final group =
        await widget.repository.getGroupInformation(widget.groupId).first;
    if (!mounted) return;

    setState(() {
      _group = group;
      _departureDateController.text =
          DateFormat('dd. MMMM yyyy', 'da_DK').format(group.departureDate);
      _returnDateController.text =
          DateFormat('dd. MMMM yyyy', 'da_DK').format(group.returnDate);
      _departureFromController.text = group.departureFrom;
      _returnToController.text = group.returnTo;
      _emergencyPhoneController.text = group.emergencyPhone ?? '';
      _flightAway = group.flightAway;
      _flightHome = group.flightHome;
      _mapEnabled = group.mapEnabled;
      _beforeDepartureItems = List.from(group.beforeDepartureItems ?? []);
      _loading = false;
    });
  }

  Future<void> _pickDate(
      TextEditingController controller, DateTime initialDate) async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        controller.text = DateFormat('dd. MMMM yyyy', 'da_DK').format(picked);
      });
    }
  }

  Future<void> _saveGroupDetails() async {
    if (_group == null || !_formKey.currentState!.validate()) return;

    try {
      final groupRef =
          widget.repository.firestore.collection('groups').doc(_group!.groupId);

      // Use a locale-aware parser to handle the Danish date format
      final dateFormat = DateFormat('dd. MMMM yyyy', 'da_DK');

      await groupRef.update({
        'departureDate': dateFormat.parse(_departureDateController.text),
        'returnDate': dateFormat.parse(_returnDateController.text),
        'departureFrom': _departureFromController.text,
        'returnTo': _returnToController.text,
        'emergencyPhone': _emergencyPhoneController.text,
        'flightAway': _flightAway,
        'flightHome': _flightHome,
        'mapEnabled': _mapEnabled,
      });

      // Optionally, reload the main group info in the BLoC
      // context.read<GroupInformationBloc>().add(LoadGroupInformationById(groupId: _group!.groupId));

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Details saved')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error saving details: $e')));
      }
    }
  }

  void _addOrEditCoupon({Coupon? existingCoupon}) {
    final nameController =
        TextEditingController(text: existingCoupon?.couponName ?? '');
    final descriptionController =
        TextEditingController(text: existingCoupon?.description ?? '');
    final imageUrlController =
        TextEditingController(text: existingCoupon?.imageURL ?? '');
    final linkController =
        TextEditingController(text: existingCoupon?.link ?? '');

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.beige,
            surfaceTintColor: Colors.transparent,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(
              children: [
                Icon(existingCoupon == null ? Icons.add_circle : Icons.edit,
                    color: AppColors.darkGreen),
                const SizedBox(width: 12),
                Text(
                  existingCoupon == null ? 'Tilføj Kupon' : 'Rediger Kupon',
                  style: GoogleFonts.kanit(
                      fontWeight: FontWeight.bold, fontSize: 22),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (imageUrlController.text.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        height: 120,
                        width: double.infinity,
                        color: Colors.white,
                        child: CachedNetworkImage(
                          imageUrl: imageUrlController.text,
                          fit: BoxFit.contain,
                          placeholder: (context, url) =>
                              const Center(child: CircularProgressIndicator()),
                          errorWidget: (context, url, error) => const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.broken_image,
                                  color: Colors.grey, size: 40),
                              Text('Ugyldig billed-URL',
                                  style: TextStyle(
                                      color: Colors.grey, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _buildDialogField(
                    controller: nameController,
                    label: 'Navn',
                    hint: 'F.eks. 20% rabat på Safari',
                    icon: Icons.label_outline,
                  ),
                  const SizedBox(height: 12),
                  _buildDialogField(
                    controller: descriptionController,
                    label: 'Beskrivelse',
                    hint: 'F.eks. Gælder alle bookinger i 2024',
                    icon: Icons.description_outlined,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                  _buildDialogField(
                    controller: imageUrlController,
                    label: 'Billed-URL',
                    hint: 'Link til logo eller billede',
                    icon: Icons.image_outlined,
                    onChanged: (val) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  _buildDialogField(
                    controller: linkController,
                    label: 'Link',
                    hint: 'Hvor skal kuponen føre hen?',
                    icon: Icons.link,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Annuller',
                    style: GoogleFonts.kanit(color: Colors.grey[600])),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.onPrimary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                onPressed: () async {
                  if (nameController.text.isEmpty) return;

                  final newCoupon = Coupon(
                    couponName: nameController.text,
                    description: descriptionController.text,
                    imageURL: imageUrlController.text,
                    link: linkController.text,
                  );

                  final groupRef = widget.repository.firestore
                      .collection('groups')
                      .doc(_group!.groupId);

                  List<Coupon> updatedCoupons =
                      List.from(_group!.coupons ?? []);

                  if (existingCoupon != null) {
                    updatedCoupons.removeWhere(
                        (c) => c.couponName == existingCoupon.couponName);
                  }

                  updatedCoupons.add(newCoupon);

                  await groupRef.update({
                    'coupons': updatedCoupons
                        .map((c) => {
                              'couponName': c.couponName,
                              'description': c.description,
                              'imageURL': c.imageURL,
                              'link': c.link,
                            })
                        .toList(),
                  });

                  if (context.mounted) Navigator.pop(context);
                },
                child: Text(existingCoupon == null ? 'Tilføj' : 'Gem',
                    style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              )
            ],
          );
        },
      ),
    );
  }

  Widget _buildDialogField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    int maxLines = 1,
    Function(String)? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(label,
              style: GoogleFonts.kanit(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.black87)),
        ),
        TextFormField(
          controller: controller,
          maxLines: maxLines,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, size: 20, color: AppColors.darkGreen),
            filled: true,
            fillColor: Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey[350]!),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey[300]!),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.darkGreen, width: 2),
            ),
          ),
          style: GoogleFonts.kanit(fontSize: 15),
        ),
      ],
    );
  }

  Future<void> _deleteCoupon(Coupon coupon) async {
    if (_group == null) return;

    final groupRef =
        widget.repository.firestore.collection('groups').doc(_group!.groupId);

    List<Coupon> updatedCoupons = List.from(_group!.coupons ?? []);
    updatedCoupons.removeWhere((c) => c.couponName == coupon.couponName);

    await groupRef.update({
      'coupons': updatedCoupons
          .map((c) => {
                'couponName': c.couponName,
                'description': c.description,
                'imageURL': c.imageURL,
                'link': c.link,
              })
          .toList(),
    });
  }

  Future<void> _saveBeforeDepartureItems() async {
    if (_group == null) return;
    final groupRef =
        widget.repository.firestore.collection('groups').doc(_group!.groupId);
    await groupRef.update({'beforeDepartureItems': _beforeDepartureItems});
  }

  void _addOrEditPreDepartureItem({String? existing, int? index}) {
    final controller = TextEditingController(text: existing ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.beige,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Icon(existing == null ? Icons.add_circle : Icons.edit,
                color: AppColors.darkGreen),
            const SizedBox(width: 12),
            Text(
              existing == null ? 'Tilføj Punkt' : 'Rediger Punkt',
              style:
                  GoogleFonts.kanit(fontWeight: FontWeight.bold, fontSize: 22),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: _buildDialogField(
            controller: controller,
            label: 'Punkt',
            hint: 'F.eks. Husk pas og forsikringskort',
            icon: Icons.checklist_outlined,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                Text('Annuller', style: GoogleFonts.kanit(color: Colors.grey[600])),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.onPrimary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            onPressed: () async {
              if (controller.text.isEmpty) return;
              setState(() {
                if (index != null) {
                  _beforeDepartureItems[index] = controller.text;
                } else {
                  _beforeDepartureItems.add(controller.text);
                }
              });
              await _saveBeforeDepartureItems();
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(existing == null ? 'Tilføj' : 'Gem',
                style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _deletePreDepartureItem(int index) async {
    setState(() => _beforeDepartureItems.removeAt(index));
    await _saveBeforeDepartureItems();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _group == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
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
        child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTripHeader(),
                    const SizedBox(height: 24),
                    _buildSectionCard(
                      title: 'Rejseoplysninger',
                      icon: Icons.flight_takeoff,
                      children: [
                        _buildDateRow(),
                        const SizedBox(height: 16),
                        _buildTextFormField(
                            _departureFromController,
                            'Afrejse fra / Rejsen starter i',
                            Icons.location_on_outlined),
                        const SizedBox(height: 16),
                        _buildTextFormField(
                            _returnToController,
                            'Hjemkomst til / Rejsen slutter i',
                            Icons.location_on),
                        const SizedBox(height: 16),
                        _buildTextFormField(_emergencyPhoneController,
                            'Nødtelefon', Icons.phone,
                            keyboardType: TextInputType.phone,
                            isRequired: false),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildSectionCard(
                      title: 'Flyindstillinger',
                      icon: Icons.flight,
                      children: [
                        SwitchListTile(
                          title: Text(
                              'Afrejse: ${_flightAway ? "Inkluderet" : "Ikke inkluderet"}',
                              style: GoogleFonts.kanit()),
                          value: _flightAway,
                          onChanged: (val) => setState(() => _flightAway = val),
                          activeThumbColor: AppColors.darkGreen,
                        ),
                        SwitchListTile(
                          title: Text(
                              'Hjemrejse: ${_flightHome ? "Inkluderet" : "Ikke inkluderet"}',
                              style: GoogleFonts.kanit()),
                          value: _flightHome,
                          onChanged: (val) => setState(() => _flightHome = val),
                          activeThumbColor: AppColors.darkGreen,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildSectionCard(
                      title: 'App-funktioner',
                      icon: Icons.map_outlined,
                      children: [
                        SwitchListTile(
                          title: Text('"Vis kort"-knap',
                              style: GoogleFonts.kanit()),
                          subtitle: Text(
                            _mapEnabled
                                ? 'Vises på rejsekortet i appen'
                                : 'Skjult i appen',
                            style: GoogleFonts.kanit(fontSize: 12),
                          ),
                          value: _mapEnabled,
                          onChanged: (val) => setState(() => _mapEnabled = val),
                          activeThumbColor: AppColors.darkGreen,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildSectionCard(
                      title: 'Før afrejse',
                      icon: Icons.checklist,
                      action: ElevatedButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Tilføj'),
                        onPressed: () => _addOrEditPreDepartureItem(),
                      ),
                      children: [
                        if (_beforeDepartureItems.isEmpty)
                          const Center(child: Text('Ingen punkter endnu.'))
                        else
                          ..._beforeDepartureItems.asMap().entries.map(
                                (entry) => _buildPreDepartureItemTile(
                                    entry.value, entry.key),
                              ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildSectionCard(
                      title: 'Kuponer',
                      icon: Icons.local_offer,
                      action: ElevatedButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Tilføj'),
                        onPressed: () => _addOrEditCoupon(),
                      ),
                      children: [
                        if (_group!.coupons == null || _group!.coupons!.isEmpty)
                          const Center(
                              child: Text('Ingen kuponer tilføjet endnu.'))
                        else
                          ..._group!.coupons!
                              .map((coupon) => _buildCouponTile(coupon)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saveGroupDetails,
        backgroundColor: AppColors.primary,
        label: Text('Gem Ændringer',
            style: GoogleFonts.kanit(
                fontWeight: FontWeight.bold, color: AppColors.onPrimary)),
        icon: Icon(Icons.save, color: AppColors.onPrimary),
      ),
    );
  }

  Widget _buildTripHeader() {
    final group = _group!;
    final now = DateTime.now();
    final daysUntil = group.departureDate.difference(now).inDays;
    final isActive =
        group.departureDate.isBefore(now) && group.returnDate.isAfter(now);
    final countdownText = isActive
        ? 'Rejsen er i gang'
        : daysUntil >= 0
            ? 'Afrejse om $daysUntil dage'
            : 'Rejse afsluttet';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.darkGreen.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.info_outline, color: AppColors.darkGreen, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(group.groupName ?? group.groupId,
                    style: GoogleFonts.kanit(
                        fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(group.groupId,
                    style: GoogleFonts.kanit(fontSize: 13, color: Colors.black45)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: (isActive ? Colors.orange : AppColors.darkGreen).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(countdownText,
                style: GoogleFonts.kanit(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isActive ? Colors.orange[800] : AppColors.darkGreen)),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard(
      {required String title,
      required IconData icon,
      required List<Widget> children,
      Widget? action}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.darkGreen.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, color: AppColors.darkGreen, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Text(title,
                        style: GoogleFonts.kanit(
                            fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
                  ],
                ),
                if (action != null) action,
              ],
            ),
            Divider(height: 24, thickness: 1, color: Colors.grey.withValues(alpha: 0.15)),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildPreDepartureItemTile(String item, int index) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
              color: AppColors.darkGreen, shape: BoxShape.circle),
        ),
        title: Text(item, style: GoogleFonts.kanit(fontSize: 14)),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.black38, size: 18),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          onSelected: (value) {
            if (value == 'edit') {
              _addOrEditPreDepartureItem(existing: item, index: index);
            } else if (value == 'delete') {
              _deletePreDepartureItem(index);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit, size: 18, color: AppColors.darkGreen),
                  const SizedBox(width: 10),
                  Text('Rediger', style: GoogleFonts.kanit()),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  const Icon(Icons.delete, size: 18, color: Colors.redAccent),
                  const SizedBox(width: 10),
                  Text('Slet', style: GoogleFonts.kanit()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCouponTile(Coupon coupon) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: AppColors.beige,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: coupon.imageURL.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: coupon.imageURL,
                    fit: BoxFit.contain,
                    errorWidget: (context, url, error) =>
                        Icon(Icons.local_offer, color: AppColors.darkGreen),
                  )
                : Icon(Icons.local_offer, color: AppColors.darkGreen),
          ),
        ),
        title: Text(
          coupon.couponName,
          style: GoogleFonts.kanit(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Colors.black87,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            coupon.description,
            style: GoogleFonts.kanit(
              fontSize: 14,
              color: Colors.black54,
            ),
          ),
        ),
        trailing: Container(
          decoration: BoxDecoration(
            color: AppColors.beige,
            shape: BoxShape.circle,
          ),
          child: PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.black54),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) {
              if (value == 'edit') {
                _addOrEditCoupon(existingCoupon: coupon);
              } else if (value == 'delete') {
                _deleteCoupon(coupon);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit, size: 20, color: AppColors.darkGreen),
                    const SizedBox(width: 12),
                    Text('Rediger', style: GoogleFonts.kanit()),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    const Icon(Icons.delete, size: 20, color: Colors.redAccent),
                    const SizedBox(width: 12),
                    Text('Slet', style: GoogleFonts.kanit()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextFormField(
      TextEditingController controller, String label, IconData icon,
      {TextInputType? keyboardType, bool isRequired = true}) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.white,
      ),
      validator: (value) => isRequired && (value == null || value.isEmpty)
          ? 'Dette felt er påkrævet'
          : null,
    );
  }

  Widget _buildDateRow() {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () =>
                _pickDate(_departureDateController, _group!.departureDate),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Afrejsedato',
                prefixIcon: const Icon(Icons.calendar_today),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
              ),
              child: Text(_departureDateController.text,
                  style: GoogleFonts.kanit()),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: InkWell(
            onTap: () => _pickDate(_returnDateController, _group!.returnDate),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Hjemkomstdato',
                prefixIcon: const Icon(Icons.calendar_today),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
              ),
              child:
                  Text(_returnDateController.text, style: GoogleFonts.kanit()),
            ),
          ),
        ),
      ],
    );
  }
}
