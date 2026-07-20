import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/message_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:url_launcher/url_launcher.dart';

/// Cross-trip admin inbox for this bureau: every message across every one
/// of its trips in one place, with unread counts and inline replies.
class GroupMessagesDialog extends StatefulWidget {
  final Color mainColor;
  final List<GroupInformation> groups;
  final GroupMessage? initialThread;

  const GroupMessagesDialog({
    super.key,
    required this.mainColor,
    required this.groups,
    this.initialThread,
  });

  @override
  State<GroupMessagesDialog> createState() => _GroupMessagesDialogState();
}

class _GroupMessagesDialogState extends State<GroupMessagesDialog> {
  GroupMessage? _selectedThread;
  final TextEditingController _replyController = TextEditingController();
  final ScrollController _commentsScrollController = ScrollController();
  bool _isSendingReply = false;

  List<String> get _groupIds => widget.groups.map((g) => g.groupId).toList();
  List<GroupInformation> get _tripGroups =>
      widget.groups.where((g) => g.isTemplate != true).toList();

  @override
  void initState() {
    super.initState();
    _selectedThread = widget.initialThread;
    if (_selectedThread != null && !_selectedThread!.isRead) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context
            .read<GroupInformationRepository>()
            .markMessageAsRead(_selectedThread!.groupId, _selectedThread!.messageId);
      });
    }
  }

  @override
  void dispose() {
    _replyController.dispose();
    _commentsScrollController.dispose();
    super.dispose();
  }

  String? _bureauNameForGroup(String groupId) {
    for (final group in widget.groups) {
      if (group.groupId == groupId) return group.bureauName;
    }
    return null;
  }

  Future<void> _sendReply() async {
    final thread = _selectedThread;
    if (thread == null || _replyController.text.trim().isEmpty) return;
    setState(() => _isSendingReply = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      final bureauName = _bureauNameForGroup(thread.groupId);
      await context.read<GroupInformationRepository>().createComment(
            thread.groupId,
            thread.messageId,
            _replyController.text.trim(),
            user?.uid ?? 'admin',
            user?.displayName ?? user?.email ?? 'Admin',
            isAdmin: true,
            bureauName: bureauName,
          );
      _replyController.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_commentsScrollController.hasClients) {
          _commentsScrollController.animateTo(
            _commentsScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } finally {
      if (mounted) setState(() => _isSendingReply = false);
    }
  }

  Future<List<Map<String, String>>> _pickAndUploadFiles(
      GroupInformationRepository repo, String groupId, List<Map<String, String>> existing) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return existing;

    final updated = List<Map<String, String>>.from(existing);
    for (final file in result.files) {
      if (file.bytes == null) continue;
      final url = await repo.uploadMessageAttachment(groupId, file.name, file.bytes!);
      updated.add({'name': file.name, 'url': url});
    }
    return updated;
  }

  void _showMessageDialog({GroupMessage? existing}) {
    String? selectedGroupId = existing?.groupId;
    final titleController = TextEditingController(text: existing?.title);
    final contentController = TextEditingController(text: existing?.content);
    List<Map<String, String>> attachments = List.from(existing?.attachments ?? []);
    bool isUploading = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    existing == null ? 'Ny besked til gruppe' : 'Rediger besked',
                    style: GoogleFonts.kanit(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 20),
                  if (existing == null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade400),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: DropdownButton<String>(
                        value: selectedGroupId,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        hint: Text('Vælg rejse', style: GoogleFonts.kanit(color: Colors.grey[500])),
                        items: _tripGroups
                            .map((g) => DropdownMenuItem(
                                  value: g.groupId,
                                  child: Text(g.groupName ?? g.groupId,
                                      style: GoogleFonts.kanit(fontSize: 14)),
                                ))
                            .toList(),
                        onChanged: (val) => setInner(() => selectedGroupId = val),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _buildField(titleController, 'Titel'),
                  const SizedBox(height: 12),
                  _buildField(contentController, 'Besked', maxLines: 4),
                  const SizedBox(height: 16),
                  ...attachments.map((att) => _buildAttachmentRow(
                        att,
                        onRemove: () => setInner(() => attachments.remove(att)),
                      )),
                  if (isUploading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(
                          child: SizedBox(
                              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                    )
                  else
                    TextButton.icon(
                      onPressed: (existing?.groupId ?? selectedGroupId) == null
                          ? null
                          : () async {
                              setInner(() => isUploading = true);
                              final repo = context.read<GroupInformationRepository>();
                              final groupId = existing?.groupId ?? selectedGroupId!;
                              final updated =
                                  await _pickAndUploadFiles(repo, groupId, attachments);
                              setInner(() {
                                attachments = updated;
                                isUploading = false;
                              });
                            },
                      icon: const Icon(Icons.attach_file, size: 16),
                      label: Text('Tilføj filer', style: GoogleFonts.kanit(fontSize: 13)),
                    ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text('Annuller', style: GoogleFonts.kanit(color: Colors.grey[600])),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: () async {
                          if (titleController.text.trim().isEmpty ||
                              contentController.text.trim().isEmpty) return;
                          if (existing == null && selectedGroupId == null) return;

                          final user = FirebaseAuth.instance.currentUser;
                          final repo = context.read<GroupInformationRepository>();

                          if (existing == null) {
                            await repo.createMessage(
                              selectedGroupId!,
                              titleController.text.trim(),
                              contentController.text.trim(),
                              user?.uid ?? 'admin',
                              user?.displayName ?? user?.email ?? 'Admin',
                              attachments: attachments,
                              isAdmin: true,
                              bureauName: _bureauNameForGroup(selectedGroupId!),
                            );
                          } else {
                            await repo.updateMessage(
                              existing.groupId,
                              existing.messageId,
                              titleController.text.trim(),
                              contentController.text.trim(),
                              attachments: attachments,
                            );
                            if (mounted) setState(() => _selectedThread = null);
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: widget.mainColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        ),
                        child: Text(
                          existing == null ? 'Send' : 'Gem',
                          style: GoogleFonts.kanit(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _confirmDelete(GroupMessage msg) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Slet besked?', style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
        content: Text('Er du sikker på at du vil slette "${msg.title}"?', style: GoogleFonts.kanit()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Annuller', style: GoogleFonts.kanit(color: Colors.grey[600])),
          ),
          ElevatedButton(
            onPressed: () async {
              await context.read<GroupInformationRepository>().deleteMessage(msg.groupId, msg.messageId);
              if (mounted) setState(() => _selectedThread = null);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('Slet', style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildField(TextEditingController ctrl, String label, {int maxLines = 1}) {
    return TextField(
      controller: ctrl,
      style: GoogleFonts.kanit(fontSize: 14),
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.kanit(color: Colors.grey[600]),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  Widget _buildAttachmentRow(Map<String, String> att, {VoidCallback? onRemove}) {
    final name = att['name'] ?? 'Fil';
    final url = att['url'] ?? '';
    final isPdf = name.toLowerCase().endsWith('.pdf');
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Icon(isPdf ? Icons.picture_as_pdf : Icons.insert_drive_file_outlined,
              size: 16, color: isPdf ? Colors.red[400] : Colors.blueGrey[400]),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final uri = Uri.parse(url);
                if (await canLaunchUrl(uri)) await launchUrl(uri);
              },
              child: Text(name,
                  style: GoogleFonts.kanit(fontSize: 13, color: Colors.black87),
                  overflow: TextOverflow.ellipsis),
            ),
          ),
          if (onRemove != null)
            IconButton(
              icon: const Icon(Icons.close, size: 16, color: Colors.red),
              onPressed: onRemove,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            )
          else
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 16, color: Colors.blueGrey),
              onPressed: () async {
                final uri = Uri.parse(url);
                if (await canLaunchUrl(uri)) await launchUrl(uri);
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 960,
          height: 640,
          child: Column(
            children: [
              _buildHeader(),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(width: 340, child: _buildThreadList()),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildThreadDetail()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
      child: Row(
        children: [
          Icon(Icons.forum_outlined, color: widget.mainColor, size: 22),
          const SizedBox(width: 10),
          Text('Beskeder',
              style: GoogleFonts.kanit(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87)),
          const SizedBox(width: 12),
          StreamBuilder<int>(
            stream: context.read<GroupInformationRepository>().streamUnreadMessageCount(_groupIds),
            builder: (context, snapshot) {
              final count = snapshot.data ?? 0;
              if (count == 0) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  '$count ulæst${count == 1 ? '' : 'e'}',
                  style: GoogleFonts.kanit(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              );
            },
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: () => _showMessageDialog(),
            icon: const Icon(Icons.add, size: 16),
            label: Text('Ny besked', style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.mainColor,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.black54),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildThreadList() {
    return StreamBuilder<List<GroupMessage>>(
      stream: context.read<GroupInformationRepository>().streamAllGroupMessages(_groupIds),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final messages = snapshot.data ?? [];
        if (messages.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.forum_outlined, size: 48, color: Colors.grey[300]),
                const SizedBox(height: 12),
                Text('Ingen beskeder endnu', style: GoogleFonts.kanit(color: Colors.grey[400])),
              ],
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: messages.length,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
          itemBuilder: (context, index) {
            final msg = messages[index];
            final isSelected = _selectedThread?.messageId == msg.messageId &&
                _selectedThread?.groupId == msg.groupId;
            return InkWell(
              onTap: () async {
                setState(() => _selectedThread = msg);
                if (!msg.isRead) {
                  await context.read<GroupInformationRepository>().markMessageAsRead(msg.groupId, msg.messageId);
                }
              },
              child: Container(
                color: isSelected ? widget.mainColor.withOpacity(0.08) : null,
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5, right: 8),
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: msg.isRead ? Colors.transparent : Colors.red,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            msg.title,
                            style: GoogleFonts.kanit(
                              fontSize: 14,
                              fontWeight: msg.isRead ? FontWeight.normal : FontWeight.bold,
                              color: Colors.black87,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            msg.content,
                            style: GoogleFonts.kanit(fontSize: 12, color: Colors.black45),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: widget.mainColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(msg.groupId,
                                    style: GoogleFonts.kanit(
                                        fontSize: 9, color: widget.mainColor, fontWeight: FontWeight.w600)),
                              ),
                              const SizedBox(width: 6),
                              if (msg.timestamp != null)
                                Text(
                                  DateFormat('dd. MMM HH:mm').format(msg.timestamp!),
                                  style: GoogleFonts.kanit(fontSize: 10, color: Colors.grey[400]),
                                ),
                              if (msg.attachments.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Icon(Icons.attach_file, size: 11, color: Colors.grey[400]),
                                Text('${msg.attachments.length}',
                                    style: GoogleFonts.kanit(fontSize: 10, color: Colors.grey[400])),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert, size: 18, color: Colors.grey[400]),
                      onSelected: (v) {
                        if (v == 'edit') _showMessageDialog(existing: msg);
                        if (v == 'delete') _confirmDelete(msg);
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(children: [
                            const Icon(Icons.edit_outlined, size: 16),
                            const SizedBox(width: 8),
                            Text('Rediger', style: GoogleFonts.kanit()),
                          ]),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(children: [
                            const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                            const SizedBox(width: 8),
                            Text('Slet', style: GoogleFonts.kanit(color: Colors.red)),
                          ]),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildThreadDetail() {
    final thread = _selectedThread;
    if (thread == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 56, color: Colors.grey[200]),
            const SizedBox(height: 16),
            Text('Vælg en tråd for at se indholdet',
                style: GoogleFonts.kanit(color: Colors.grey[400], fontSize: 16)),
          ],
        ),
      );
    }

    // The header (with a potentially long message body) and the comments
    // list share a single scrollable region — otherwise a long message
    // pushes the fixed-size dialog's content past its bottom edge.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            controller: _commentsScrollController,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: Colors.grey[50],
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: widget.mainColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(thread.groupId,
                                style: GoogleFonts.kanit(
                                    fontSize: 11, color: widget.mainColor, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 8),
                          Text(thread.authorName,
                              style: GoogleFonts.kanit(fontSize: 12, color: Colors.grey[500])),
                          if (thread.timestamp != null) ...[
                            Text(' · ', style: TextStyle(color: Colors.grey[400])),
                            Text(DateFormat('dd. MMM yyyy HH:mm').format(thread.timestamp!),
                                style: GoogleFonts.kanit(fontSize: 12, color: Colors.grey[400])),
                          ],
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            color: Colors.grey[500],
                            tooltip: 'Rediger',
                            onPressed: () => _showMessageDialog(existing: thread),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          const SizedBox(width: 12),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            color: Colors.red[400],
                            tooltip: 'Slet',
                            onPressed: () => _confirmDelete(thread),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(thread.title,
                          style: GoogleFonts.kanit(
                              fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
                      const SizedBox(height: 4),
                      Text(thread.content,
                          style: GoogleFonts.kanit(fontSize: 14, color: Colors.black54, height: 1.4)),
                      if (thread.attachments.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: thread.attachments.map((att) => _buildAttachmentRow(att)).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
                const Divider(height: 1),
                StreamBuilder<List<Comment>>(
                  stream:
                      context.read<GroupInformationRepository>().getComments(thread.groupId, thread.messageId),
                  builder: (context, snapshot) {
                    final comments = snapshot.data ?? [];
                    if (comments.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text('Ingen svar endnu',
                              style: GoogleFonts.kanit(color: Colors.grey[400], fontSize: 14)),
                        ),
                      );
                    }
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: comments.map((comment) {
                          final timeStr = comment.timestamp != null
                              ? DateFormat('dd. MMM HH:mm').format(comment.timestamp!)
                              : '';
                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey[50],
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.grey.withOpacity(0.15)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 12,
                                      backgroundColor: widget.mainColor.withOpacity(0.15),
                                      child: Text(
                                        comment.authorName.isNotEmpty
                                            ? comment.authorName[0].toUpperCase()
                                            : '?',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: widget.mainColor,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(comment.authorName,
                                        style: GoogleFonts.kanit(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.black87)),
                                    const Spacer(),
                                    if (timeStr.isNotEmpty)
                                      Text(timeStr,
                                          style: GoogleFonts.kanit(fontSize: 11, color: Colors.grey[400])),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(comment.content,
                                    style: GoogleFonts.kanit(
                                        fontSize: 13, color: Colors.black54, height: 1.4)),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _replyController,
                  style: GoogleFonts.kanit(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Svar på tråden...',
                    hintStyle: GoogleFonts.kanit(color: Colors.grey[400], fontSize: 14),
                    filled: true,
                    fillColor: Colors.grey[50],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.withOpacity(0.2)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.withOpacity(0.2)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: widget.mainColor, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                  onSubmitted: (_) => _sendReply(),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                onPressed: _isSendingReply ? null : _sendReply,
                icon: _isSendingReply
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, size: 18),
                style: IconButton.styleFrom(
                  backgroundColor: widget.mainColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
