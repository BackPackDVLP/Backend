import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/message_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:backend/widget/app_snackbar.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

/// Opens the composer for a new message to [group], or for editing
/// [existing]. Returns once the dialog is closed.
Future<void> showMessageComposer(
  BuildContext context, {
  required GroupInformation group,
  Message? existing,
}) {
  return showDialog(
    context: context,
    // Closing by clicking outside would silently throw away a half-written
    // message — Annuller/✕ ask first instead.
    barrierDismissible: false,
    builder: (_) => RepositoryProvider.value(
      value: context.read<GroupInformationRepository>(),
      child: MessageComposerDialog(group: group, existing: existing),
    ),
  );
}

/// Message composer for a single trip: title, body and attachments on the
/// left, a live preview of how it lands on travelers' phones on the right
/// (wide screens only).
class MessageComposerDialog extends StatefulWidget {
  const MessageComposerDialog({super.key, required this.group, this.existing});

  final GroupInformation group;
  final Message? existing;

  @override
  State<MessageComposerDialog> createState() => _MessageComposerDialogState();
}

class _MessageComposerDialogState extends State<MessageComposerDialog> {
  static const _titleMaxLength = 80;

  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  late List<Map<String, String>> _attachments;
  bool _isUploading = false;
  bool _isSending = false;

  bool get _isEditing => widget.existing != null;

  bool get _canSend =>
      !_isSending &&
      !_isUploading &&
      _titleController.text.trim().isNotEmpty &&
      _contentController.text.trim().isNotEmpty;

  bool get _isDirty =>
      _titleController.text.trim() != (widget.existing?.title ?? '') ||
      _contentController.text.trim() != (widget.existing?.content ?? '') ||
      _attachments.length != (widget.existing?.attachments.length ?? 0);

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.existing?.title);
    _contentController = TextEditingController(text: widget.existing?.content);
    _attachments = List.from(widget.existing?.attachments ?? const []);
    // Rebuild on every keystroke so the preview and Send button stay live.
    _titleController.addListener(_onChanged);
    _contentController.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _pickAttachments() async {
    final result =
        await FilePicker.platform.pickFiles(allowMultiple: true, withData: true);
    final files = result?.files.where((f) => f.bytes != null).toList() ?? [];
    if (files.isEmpty || !mounted) return;

    setState(() => _isUploading = true);
    final repo = context.read<GroupInformationRepository>();
    var failed = 0;
    for (final file in files) {
      try {
        final url = await repo.uploadMessageAttachment(
            widget.group.groupId, file.name, file.bytes!);
        if (mounted) {
          setState(() => _attachments.add({'name': file.name, 'url': url}));
        }
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _isUploading = false);
    if (failed > 0) {
      showErrorSnackbar(context,
          '$failed af ${files.length} filer kunne ikke vedhæftes');
    }
  }

  Future<void> _send() async {
    if (!_canSend) return;
    setState(() => _isSending = true);
    final repo = context.read<GroupInformationRepository>();
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    try {
      if (_isEditing) {
        await repo.updateMessage(
          widget.group.groupId,
          widget.existing!.id,
          title,
          content,
          attachments: _attachments,
        );
      } else {
        final admin = FirebaseAuth.instance.currentUser;
        await repo.createMessage(
          widget.group.groupId,
          title,
          content,
          admin?.uid ?? 'admin',
          admin?.displayName ?? admin?.email ?? 'Admin',
          attachments: _attachments,
          isAdmin: true,
          bureauName: widget.group.bureauName,
        );
      }
      if (!mounted) return;
      // Shown before popping — this dialog's context is gone afterwards, and
      // the snackbar lives on the app-wide messenger so it outlasts the pop.
      showAppSnackbar(
          context, _isEditing ? 'Besked opdateret' : 'Besked sendt');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSending = false);
      showErrorSnackbar(
          context, 'Kunne ikke sende beskeden: ${describeError(e)}');
    }
  }

  Future<void> _close() async {
    if (_isSending) return;
    if (!_isDirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
        title: Text('Kassér ændringer?',
            style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
        content: Text(
            _isEditing
                ? 'Dine ændringer til beskeden bliver ikke gemt.'
                : 'Beskeden er ikke sendt endnu og bliver ikke gemt.',
            style: GoogleFonts.kanit()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Fortsæt med at skrive',
                style: GoogleFonts.kanit(color: Colors.grey[700])),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: AppRadii.smRadius),
            ),
            child: Text('Kassér',
                style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 900;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.all(AppSpacing.xxl),
        shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: isWide ? 900 : 560,
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              const Divider(height: 1),
              Flexible(
                child: isWide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 3, child: _buildForm()),
                          Container(
                            width: 320,
                            color: AppColors.panelBackground,
                            child: _buildPreview(),
                          ),
                        ],
                      )
                    : _buildForm(),
              ),
              const Divider(height: 1),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final memberCount = widget.group.members.length;
    final tripName = widget.group.groupName?.isNotEmpty == true
        ? widget.group.groupName!
        : widget.group.groupId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xxl, AppSpacing.xl, AppSpacing.md, AppSpacing.lg),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.darkGreen.withValues(alpha: 0.08),
              borderRadius: AppRadii.mdRadius,
            ),
            child: Icon(_isEditing ? Icons.edit_outlined : Icons.campaign_outlined,
                color: AppColors.darkGreen),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_isEditing ? 'Rediger besked' : 'Ny besked',
                    style: AppTextStyles.headingBold()),
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'Til '),
                    TextSpan(
                        text: tripName,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(
                        text: ' · $memberCount '
                            '${memberCount == 1 ? 'deltager' : 'deltagere'}'),
                  ]),
                  style: AppTextStyles.body(color: Colors.grey[600]),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Luk',
            icon: const Icon(Icons.close, color: Colors.black54),
            onPressed: _close,
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _fieldLabel('Overskrift'),
          TextField(
            controller: _titleController,
            autofocus: !_isEditing,
            maxLength: _titleMaxLength,
            textInputAction: TextInputAction.next,
            style: GoogleFonts.kanit(fontSize: 15, fontWeight: FontWeight.w500),
            decoration: _inputDecoration(
                hint: 'F.eks. Mødested ændret i morgen'),
          ),
          const SizedBox(height: AppSpacing.sm),
          _fieldLabel('Besked'),
          TextField(
            controller: _contentController,
            minLines: 7,
            maxLines: 14,
            keyboardType: TextInputType.multiline,
            style: GoogleFonts.kanit(fontSize: 14, height: 1.45),
            decoration: _inputDecoration(
                hint: 'Skriv beskeden til gruppen her...'),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              _fieldLabel('Vedhæftede filer', bottom: 0),
              const Spacer(),
              TextButton.icon(
                onPressed: _isUploading || _isSending ? null : _pickAttachments,
                icon: _isUploading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.attach_file, size: 18),
                label: Text(_isUploading ? 'Uploader...' : 'Tilføj filer',
                    style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                style:
                    TextButton.styleFrom(foregroundColor: AppColors.darkGreen),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (_attachments.isEmpty)
            InkWell(
              onTap: _isUploading || _isSending ? null : _pickAttachments,
              borderRadius: AppRadii.mdRadius,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                decoration: BoxDecoration(
                  borderRadius: AppRadii.mdRadius,
                  border: Border.all(color: Colors.grey.shade300),
                  color: AppColors.scaffoldGradientStart,
                ),
                child: Column(
                  children: [
                    Icon(Icons.upload_file, color: Colors.grey[500]),
                    const SizedBox(height: AppSpacing.xs),
                    Text('PDF\'er, billeder eller andre filer (valgfrit)',
                        style: AppTextStyles.caption()),
                  ],
                ),
              ),
            )
          else
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final att in _attachments)
                  InputChip(
                    avatar: Icon(_attachmentIcon(att['name'] ?? ''),
                        size: 16, color: AppColors.darkGreen),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(att['name'] ?? 'Fil',
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.kanit(fontSize: 13)),
                    ),
                    backgroundColor: Colors.white,
                    side: BorderSide(color: Colors.grey.shade300),
                    shape:
                        RoundedRectangleBorder(borderRadius: AppRadii.smRadius),
                    deleteButtonTooltipMessage: 'Fjern',
                    onDeleted: _isSending
                        ? null
                        : () => setState(() => _attachments.remove(att)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    final bureau = widget.group.bureauName.isNotEmpty
        ? widget.group.bureauName
        : 'Dit rejsebureau';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('FORHÅNDSVISNING',
              style: AppTextStyles.caption()
                  .copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.8)),
          if (!_isEditing) ...[
            const SizedBox(height: AppSpacing.md),
            Text('Notifikation', style: AppTextStyles.caption()),
            const SizedBox(height: AppSpacing.xs),
            // Mirrors sendGroupMessageNotification in functions/src/index.ts.
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(14),
                boxShadow: AppShadows.card,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.asset('assets/images/backpack_app_icon.png',
                        width: 22, height: 22),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Ny besked!',
                            style: GoogleFonts.kanit(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        Text('$bureau har sendt en ny besked til din gruppe',
                            style: GoogleFonts.kanit(
                                fontSize: 12, color: Colors.black54)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Text('I appen', style: AppTextStyles.caption()),
          const SizedBox(height: AppSpacing.xs),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: AppShadows.card,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: AppColors.primary,
                      child: Text(bureau[0].toUpperCase(),
                          style: GoogleFonts.kanit(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: AppColors.onPrimary)),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(bureau,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.caption()
                              .copyWith(fontWeight: FontWeight.w600)),
                    ),
                    Text('Nu', style: AppTextStyles.caption()),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  title.isEmpty ? 'Overskrift' : title,
                  style: GoogleFonts.kanit(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: title.isEmpty ? Colors.black26 : Colors.black87,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  content.isEmpty ? 'Din besked vises her...' : content,
                  style: GoogleFonts.kanit(
                    fontSize: 13,
                    height: 1.4,
                    color: content.isEmpty ? Colors.black26 : Colors.black54,
                  ),
                ),
                if (_attachments.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  for (final att in _attachments)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Row(
                        children: [
                          Icon(_attachmentIcon(att['name'] ?? ''),
                              size: 14, color: Colors.black45),
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(
                            child: Text(att['name'] ?? 'Fil',
                                overflow: TextOverflow.ellipsis,
                                style: AppTextStyles.caption()),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xxl, vertical: AppSpacing.lg),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(
                    _isEditing
                        ? Icons.info_outline
                        : Icons.notifications_active_outlined,
                    size: 16,
                    color: Colors.grey[500]),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(
                    _isEditing
                        ? 'Ændringer vises i appen — der sendes ingen ny notifikation.'
                        : 'Alle deltagere får en notifikation på telefonen.',
                    style: AppTextStyles.caption(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          TextButton(
            onPressed: _isSending ? null : _close,
            child: Text('Annuller',
                style: GoogleFonts.kanit(color: Colors.grey[700])),
          ),
          const SizedBox(width: AppSpacing.sm),
          Tooltip(
            message: _canSend ? 'Ctrl/⌘ + Enter' : 'Udfyld overskrift og besked',
            child: ElevatedButton.icon(
              onPressed: _canSend ? _send : null,
              icon: _isSending
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.onPrimary))
                  : Icon(_isEditing ? Icons.check : Icons.send_rounded,
                      size: 18),
              label: Text(_isEditing ? 'Gem ændringer' : 'Send besked',
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimary,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldLabel(String text, {double bottom = AppSpacing.sm}) => Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Text(text, style: AppTextStyles.label()),
      );

  InputDecoration _inputDecoration({required String hint}) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: AppRadii.mdRadius,
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.kanit(color: Colors.grey[400]),
      filled: true,
      fillColor: AppColors.scaffoldGradientStart,
      contentPadding: const EdgeInsets.all(AppSpacing.lg),
      border: border(Colors.grey.shade300),
      enabledBorder: border(Colors.grey.shade300),
      focusedBorder: border(AppColors.darkGreen, 1.5),
    );
  }

  static IconData _attachmentIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (RegExp(r'\.(png|jpe?g|gif|webp|heic)$').hasMatch(lower)) {
      return Icons.image_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}
