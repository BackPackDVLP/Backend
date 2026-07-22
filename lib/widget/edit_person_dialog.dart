import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:backend/widget/phone_number_field.dart';

/// Shows a styled dialog for editing a name/(optional phone)/email record.
///
/// [onSave] should perform the update and return `null` on success, or an
/// error message to show inline (keeping the dialog open) on failure.
/// Returns `true` once the save succeeds and the dialog is dismissed.
Future<bool> showEditPersonDialog(
  BuildContext context, {
  required String title,
  required String subtitle,
  required Color mainColor,
  required String initialName,
  String? initialPhone,
  required String initialEmail,
  required Future<String?> Function(String name, String? phone, String email)
      onSave,
}) async {
  final formKey = GlobalKey<FormState>();
  final nameController = TextEditingController(text: initialName);
  final hasPhoneField = initialPhone != null;
  String phoneValue = initialPhone ?? '';
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
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
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
                                  style: GoogleFonts.kanit(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold),
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
                      const SizedBox(height: 24),
                      EditField(
                        controller: nameController,
                        label: 'Navn',
                        icon: Icons.badge_outlined,
                      ),
                      if (hasPhoneField) ...[
                        const SizedBox(height: 2),
                        PhoneNumberField(
                          initialValue: phoneValue,
                          label: 'Telefonnummer',
                          icon: Icons.phone_outlined,
                          onChanged: (v) => phoneValue = v,
                        ),
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
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: Colors.red.withOpacity(0.2)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.error_outline,
                                  color: Colors.red, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  errorMessage!,
                                  style: GoogleFonts.kanit(
                                      color: Colors.red[700], fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
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
                          const SizedBox(width: 12),
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
                                  borderRadius: BorderRadius.circular(10)),
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
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade400),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}
