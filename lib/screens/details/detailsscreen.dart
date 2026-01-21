import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _loadGroup();
  }

  Future<void> _loadGroup() async {
    // Use .first to treat the stream like a future for a one-time load.
    // This prevents setState calls after the widget is disposed if the user navigates away.
    final group = await widget.repository.getGroupInformation(widget.groupId).first;
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
      });

      // Optionally, reload the main group info in the BLoC
      // context.read<GroupInformationBloc>().add(LoadGroupInformationById(groupId: _group!.groupId));

      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Details saved')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving details: $e')));
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
      builder: (_) => AlertDialog(
        title: Text(existingCoupon == null ? 'Add Coupon' : 'Edit Coupon'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Coupon Name'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: descriptionController,
                decoration: const InputDecoration(labelText: 'Description'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: imageUrlController,
                decoration: const InputDecoration(labelText: 'Image URL'),
                validator: (v) {
                  if (v!.isNotEmpty && !Uri.tryParse(v)!.isAbsolute) {
                    return 'Enter a valid URL';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: linkController,
                decoration: const InputDecoration(labelText: 'Link'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (_group == null) return;

              final newCoupon = Coupon(
                couponName: nameController.text,
                description: descriptionController.text,
                imageURL: imageUrlController.text,
                link: linkController.text,
              );

              final groupRef = widget.repository.firestore
                  .collection('groups')
                  .doc(_group!.groupId);

              List<Coupon> updatedCoupons = List.from(_group!.coupons ?? []);

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

              Navigator.pop(context);
            },
            child: Text(existingCoupon == null ? 'Add' : 'Save'),
          )
        ],
      ),
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

  @override
  Widget build(BuildContext context) {
    if (_loading || _group == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.scaffoldGradientStart,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            title: Text('Rejsedetaljer', style: GoogleFonts.kanit(fontWeight: FontWeight.bold, color: AppColors.homeGradientStart)),
            backgroundColor: AppColors.navActive,
            iconTheme: const IconThemeData(color: AppColors.homeGradientStart),
            pinned: true,
            elevation: 2,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSectionCard(
                      title: 'Rejseoplysninger',
                      icon: Icons.flight_takeoff,
                      children: [
                        _buildDateRow(),
                        const SizedBox(height: 16),
                        _buildTextFormField(_departureFromController, 'Afrejse fra / Rejsen starter i', Icons.location_on_outlined),
                        const SizedBox(height: 16),
                        _buildTextFormField(_returnToController, 'Hjemkomst til / Rejsen slutter i', Icons.location_on),
                        const SizedBox(height: 16),
                        _buildTextFormField(_emergencyPhoneController, 'Nødtelefon', Icons.phone, keyboardType: TextInputType.phone, isRequired: false),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildSectionCard(
                      title: 'Flyindstillinger',
                      icon: Icons.flight,
                      children: [
                        SwitchListTile(
                          title: Text('Afrejse: ${_flightAway ? "Inkluderet" : "Ikke inkluderet"}', style: GoogleFonts.kanit()),
                          value: _flightAway,
                          onChanged: (val) => setState(() => _flightAway = val),
                          activeColor: AppColors.primary,
                        ),
                        SwitchListTile(
                          title: Text('Hjemrejse: ${_flightHome ? "Inkluderet" : "Ikke inkluderet"}', style: GoogleFonts.kanit()),
                          value: _flightHome,
                          onChanged: (val) => setState(() => _flightHome = val),
                          activeColor: AppColors.primary,
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
                          const Center(child: Text('Ingen kuponer tilføjet endnu.'))
                        else
                          ..._group!.coupons!.map((coupon) => _buildCouponTile(coupon)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saveGroupDetails,
        backgroundColor: AppColors.primary,
        label: Text('Gem Ændringer', style: GoogleFonts.kanit(fontWeight: FontWeight.bold, color: Colors.white)),
        icon: const Icon(Icons.save, color: Colors.white),
      ),
    );
  }

  Widget _buildSectionCard({required String title, required IconData icon, required List<Widget> children, Widget? action}) {
    return Card(
      elevation: 4,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: AppColors.panelBackground,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(icon, color: Colors.black54),
                    const SizedBox(width: 10),
                    Text(title, style: GoogleFonts.kanit(fontSize: 20, fontWeight: FontWeight.bold)),
                  ],
                ),
                if (action != null) action,
              ],
            ),
            const Divider(height: 24, thickness: 1),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildCouponTile(Coupon coupon) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        title: Text(coupon.couponName, style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
        subtitle: Text(coupon.description),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(icon: Icon(Icons.edit, color: AppColors.primary), onPressed: () => _addOrEditCoupon(existingCoupon: coupon)),
            IconButton(icon: const Icon(Icons.delete, color: Colors.redAccent), onPressed: () => _deleteCoupon(coupon)),
          ],
        ),
      ),
    );
  }

  Widget _buildTextFormField(TextEditingController controller, String label, IconData icon, {TextInputType? keyboardType, bool isRequired = true}) {
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
      validator: (value) => isRequired && (value == null || value.isEmpty) ? 'Dette felt er påkrævet' : null,
    );
  }

  Widget _buildDateRow() {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () => _pickDate(_departureDateController, _group!.departureDate),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Afrejsedato',
                prefixIcon: const Icon(Icons.calendar_today),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
              ),
              child: Text(_departureDateController.text, style: GoogleFonts.kanit()),
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
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
              ),
              child: Text(_returnDateController.text, style: GoogleFonts.kanit()),
            ),
          ),
        ),
      ],
    );
  }
}
