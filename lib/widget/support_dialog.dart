import 'package:backend/config/design.dart';
import 'package:backend/widget/app_snackbar.dart';
import 'package:backend/widget/edit_person_dialog.dart';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Lets an admin report a problem, suggest an idea or ask a question. The
/// `sendSupportRequest` Cloud Function emails it to kontakt@backpack-app.dk
/// with the admin's own account email as reply-to. Attached files travel
/// base64-encoded in the same call, so their combined size is capped well
/// under the callable request limit (~10 MB).
const _maxAttachmentBytes = 7 * 1024 * 1024;

Future<void> showSupportDialog(
  BuildContext context, {
  required Color mainColor,
  String? agencyCode,
  String? agencyName,
}) async {
  final formKey = GlobalKey<FormState>();
  final subjectController = TextEditingController();
  final messageController = TextEditingController();
  const categories = {
    'problem': ('Problem', Icons.bug_report_outlined),
    'idea': ('Idé', Icons.lightbulb_outline),
    'question': ('Spørgsmål', Icons.help_outline),
    'other': ('Andet', Icons.chat_bubble_outline),
  };
  String category = 'problem';
  final attachments = <PlatformFile>[];

  final sent = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      bool isLoading = false;
      String? errorMessage;

      return StatefulBuilder(
        builder: (ctx, setState) {
          final totalBytes =
              attachments.fold<int>(0, (sum, f) => sum + f.size);

          Future<void> pickFiles() async {
            final result = await FilePicker.platform
                .pickFiles(allowMultiple: true, withData: true);
            final picked =
                result?.files.where((f) => f.bytes != null).toList() ?? [];
            if (picked.isEmpty) return;
            final newTotal =
                picked.fold<int>(totalBytes, (sum, f) => sum + f.size);
            setState(() {
              if (newTotal > _maxAttachmentBytes) {
                errorMessage =
                    'Vedhæftede filer må samlet højst fylde 7 MB';
              } else {
                errorMessage = null;
                attachments.addAll(picked);
              }
            });
          }

          Future<void> submit() async {
            if (!formKey.currentState!.validate()) return;
            setState(() {
              isLoading = true;
              errorMessage = null;
            });
            try {
              await FirebaseFunctions.instanceFor(region: 'europe-west1')
                  .httpsCallable('sendSupportRequest')
                  .call({
                'category': category,
                'subject': subjectController.text.trim(),
                'message': messageController.text.trim(),
                'agencyCode': agencyCode,
                'agencyName': agencyName,
                'attachments': [
                  for (final f in attachments)
                    {
                      'filename': f.name,
                      'content': base64Encode(f.bytes!),
                    },
                ],
              });
              if (ctx.mounted) Navigator.pop(ctx, true);
            } on FirebaseFunctionsException catch (e) {
              setState(() {
                isLoading = false;
                errorMessage = e.message ?? 'Kunne ikke sende beskeden';
              });
            } catch (e) {
              setState(() {
                isLoading = false;
                errorMessage = describeError(e);
              });
            }
          }

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
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
                            child: Icon(Icons.support_agent, color: mainColor),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Support',
                                    style: AppTextStyles.headingBold()),
                                Text(
                                  'Fortæl os om et problem, en idé eller andet',
                                  style: GoogleFonts.kanit(
                                      fontSize: 12, color: Colors.grey[600]),
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
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.sm,
                        children: [
                          for (final entry in categories.entries)
                            ChoiceChip(
                              avatar: Icon(entry.value.$2,
                                  size: 18,
                                  color: category == entry.key
                                      ? Colors.white
                                      : Colors.grey[700]),
                              label: Text(entry.value.$1),
                              labelStyle: GoogleFonts.kanit(
                                  color: category == entry.key
                                      ? Colors.white
                                      : Colors.grey[800]),
                              selected: category == entry.key,
                              showCheckmark: false,
                              selectedColor: mainColor,
                              onSelected: isLoading
                                  ? null
                                  : (_) =>
                                      setState(() => category = entry.key),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      EditField(
                        controller: subjectController,
                        label: 'Emne',
                        icon: Icons.title,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Indtast venligst et emne'
                            : null,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        controller: messageController,
                        minLines: 5,
                        maxLines: 10,
                        style: GoogleFonts.kanit(fontSize: 14),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Beskriv venligst din henvendelse'
                            : null,
                        decoration: InputDecoration(
                          hintText: 'Beskriv så præcist som muligt…',
                          hintStyle:
                              GoogleFonts.kanit(color: Colors.grey[500]),
                          filled: true,
                          fillColor: Colors.grey[50],
                          border: OutlineInputBorder(
                            borderRadius: AppRadii.mdRadius,
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: AppRadii.mdRadius,
                            borderSide:
                                BorderSide(color: Colors.grey.shade400),
                          ),
                          contentPadding: const EdgeInsets.all(14),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.sm,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (final file in attachments)
                            InputChip(
                              avatar: const Icon(Icons.insert_drive_file_outlined,
                                  size: 18),
                              label: Text(
                                '${file.name} (${_formatSize(file.size)})',
                                style: GoogleFonts.kanit(fontSize: 12),
                              ),
                              onDeleted: isLoading
                                  ? null
                                  : () => setState(
                                      () => attachments.remove(file)),
                            ),
                          TextButton.icon(
                            onPressed: isLoading ? null : pickFiles,
                            icon: const Icon(Icons.attach_file, size: 18),
                            label: Text('Vedhæft filer',
                                style: GoogleFonts.kanit()),
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.grey[800]),
                          ),
                        ],
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
                                  style: AppTextStyles.body(
                                      color: Colors.red[700]),
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
                            onPressed: isLoading ? null : submit,
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
                                : Text('Send',
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

  subjectController.dispose();
  messageController.dispose();

  if (sent == true && context.mounted) {
    showAppSnackbar(context, 'Tak! Din henvendelse er sendt');
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
