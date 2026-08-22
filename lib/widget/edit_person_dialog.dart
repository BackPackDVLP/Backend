import 'package:flutter/material.dart';
import 'package:backend/config/design.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:backend/widget/phone_number_field.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

/// Shows a styled dialog for editing a name/(optional phone)/email record.
///
/// [onSave] should perform the update and return `null` on success, or an
/// error message to show inline (keeping the dialog open) on failure.
/// Returns `true` once the save succeeds and the dialog is dismissed.
///
/// The WhatsApp toggle only appears when a phone field is shown at all
/// (i.e. [initialPhone] is non-null) — a dialog with no phone number has no
/// meaningful "same as phone number" default to offer.
Future<bool> showEditPersonDialog(
  BuildContext context, {
  required String title,
  required String subtitle,
  required Color mainColor,
  required String initialName,
  String? initialPhone,
  String? initialWhatsapp,
  required String initialEmail,
  required Future<String?> Function(
          String name, String? phone, String email, String? whatsapp)
      onSave,
}) async {
  final formKey = GlobalKey<FormState>();
  final nameController = TextEditingController(text: initialName);
  final hasPhoneField = initialPhone != null;
  String phoneValue = initialPhone ?? '';
  String whatsappValue = initialWhatsapp ?? '';
  bool hasWhatsapp = whatsappValue.isNotEmpty;
  final emailController = TextEditingController(text: initialEmail);

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      bool isLoading = false;
      String? errorMessage;

      return StatefulBuilder(
        builder: (ctx, setState) {
          return Dialog(
            shape:
                RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.xxl),
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: mainColor.withOpacity(0.15),
                            child: Icon(Icons.person, color: mainColor),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: AppTextStyles.headingBold(),
                                ),
                                Text(
                                  subtitle,
                                  style: GoogleFonts.kanit(
                                      fontSize: 12, color: Colors.grey[600]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            color: Colors.grey[500],
                            onPressed: isLoading
                                ? null
                                : () => Navigator.pop(ctx, false),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      EditField(
                        controller: nameController,
                        label: 'Navn',
                        icon: Icons.badge_outlined,
                      ),
                      if (hasPhoneField) ...[
                        const SizedBox(height: AppSpacing.md),
                        PhoneNumberField(
                          initialValue: phoneValue,
                          label: 'Telefonnummer',
                          icon: Icons.phone_outlined,
                          onChanged: (v) {
                            phoneValue = v;
                            // Mirrors the phone number into WhatsApp until
                            // the user diverges it on its own field.
                            if (hasWhatsapp && whatsappValue == phoneValue) {
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
                            crossAxisAlignment: CrossAxisAlignment.stretch,
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
                                    activeColor: mainColor,
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
                                  key: ValueKey('whatsapp-$hasWhatsapp'),
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
                      ] else
                        const SizedBox(height: 14),
                      EditField(
                        controller: emailController,
                        label: 'Email',
                        icon: Icons.email_outlined,
                        keyboardType: TextInputType.emailAddress,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Indtast venligst en email'
                            : null,
                      ),
                      if (errorMessage != null) ...[
                        const SizedBox(height: AppSpacing.lg),
                        Container(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.08),
                            borderRadius: AppRadii.mdRadius,
                            border:
                                Border.all(color: Colors.red.withOpacity(0.2)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                      const SizedBox(height: AppSpacing.xxl),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: isLoading
                                ? null
                                : () => Navigator.pop(ctx, false),
                            child: Text('Annuller',
                                style:
                                    GoogleFonts.kanit(color: Colors.grey[600])),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          ElevatedButton(
                            onPressed: isLoading
                                ? null
                                : () async {
                                    if (!formKey.currentState!.validate()) {
                                      return;
                                    }
                                    setState(() {
                                      isLoading = true;
                                      errorMessage = null;
                                    });
                                    final error = await onSave(
                                      nameController.text.trim(),
                                      hasPhoneField ? phoneValue.trim() : null,
                                      emailController.text.trim(),
                                      hasPhoneField && hasWhatsapp
                                          ? whatsappValue.trim()
                                          : null,
                                    );
                                    if (error != null) {
                                      setState(() {
                                        isLoading = false;
                                        errorMessage = error;
                                      });
                                      return;
                                    }
                                    if (ctx.mounted) Navigator.pop(ctx, true);
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: mainColor,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius: AppRadii.smRadius),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 12),
                            ),
                            child: isLoading
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
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );

  return result == true;
}

class EditField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;

  const EditField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      validator: validator,
      style: GoogleFonts.kanit(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.kanit(color: Colors.grey[600]),
        prefixIcon: Icon(icon, size: 20, color: Colors.grey[500]),
        filled: true,
        fillColor: Colors.grey[50],
        border: OutlineInputBorder(
          borderRadius: AppRadii.mdRadius,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadii.mdRadius,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadii.mdRadius,
          borderSide: BorderSide(color: Colors.grey.shade400),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}

/// A compact "Ja/Nej" segmented toggle — deliberately not a [Switch], since
/// this is a two-way pick (e.g. does the user have WhatsApp: yes or no)
/// rather than an on/off setting, and spelling out both states reads
/// clearer than a bare switch would here.
class YesNoToggle extends StatelessWidget {
  final bool value;
  final Color activeColor;
  final ValueChanged<bool> onChanged;

  const YesNoToggle({
    super.key,
    required this.value,
    required this.activeColor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.12),
        borderRadius: AppRadii.smRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment('Ja', value, () => onChanged(true)),
          _segment('Nej', !value, () => onChanged(false)),
        ],
      ),
    );
  }

  Widget _segment(String label, bool selected, VoidCallback onTap) {
    return Material(
      color: selected ? activeColor : Colors.transparent,
      borderRadius: AppRadii.smRadius,
      child: InkWell(
        borderRadius: AppRadii.smRadius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            label,
            style: GoogleFonts.kanit(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : Colors.grey[600],
            ),
          ),
        ),
      ),
    );
  }
}
