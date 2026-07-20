import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

class Message extends Equatable {
  final String id;
  final String title;
  final String content;
  final String? authorId;
  final String? authorName;
  final DateTime? timestamp; // Nullable because Firestore assigns timestamp
  final int replyCount; // Computed field, not stored in Firestore
  final List<Map<String, String>> attachments;
  final bool isAdmin;
  final String? bureauName;

  const Message({
    required this.id,
    required this.title,
    required this.content,
    this.authorId,
    this.authorName,
    this.timestamp,
    this.replyCount = 0,
    this.attachments = const [],
    this.isAdmin = false,
    this.bureauName,
  });

  factory Message.fromSnapshot(DocumentSnapshot snapshot) {
    final data = snapshot.data() as Map<String, dynamic>?;
    return Message(
      id: snapshot.id,
      title: data?['title'] as String? ?? '',
      content: data?['content'] as String? ?? '',
      authorId: data?['authorId'] as String?,
      authorName: data?['authorName'] as String?,
      timestamp: (data?['timestamp'] as Timestamp?)?.toDate(),
      attachments: (data?['attachments'] as List<dynamic>?)
              ?.map((e) => Map<String, String>.from(e as Map))
              .toList() ??
          [],
      isAdmin: data?['isAdmin'] as bool? ?? false,
      bureauName: data?['bureauName'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'content': content,
      if (authorId != null) 'authorId': authorId,
      if (authorName != null) 'authorName': authorName,
      'timestamp': FieldValue.serverTimestamp(),
      'attachments': attachments,
      'isAdmin': isAdmin,
      if (bureauName != null) 'bureauName': bureauName,
    };
  }

  Message copyWith({
    String? id,
    String? title,
    String? content,
    String? authorId,
    String? authorName,
    DateTime? timestamp,
    int? replyCount,
    List<Map<String, String>>? attachments,
    bool? isAdmin,
    String? bureauName,
  }) {
    return Message(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      authorId: authorId ?? this.authorId,
      authorName: authorName ?? this.authorName,
      timestamp: timestamp ?? this.timestamp,
      replyCount: replyCount ?? this.replyCount,
      attachments: attachments ?? this.attachments,
      isAdmin: isAdmin ?? this.isAdmin,
      bureauName: bureauName ?? this.bureauName,
    );
  }

  @override
  List<Object?> get props => [
        id,
        title,
        content,
        authorId,
        authorName,
        timestamp,
        replyCount,
        attachments,
        isAdmin,
        bureauName
      ];
}

/// Flattened view of a message used by the cross-group admin inbox, where
/// the owning groupId matters as much as the message content itself.
class GroupMessage {
  final String groupId;
  final String messageId;
  final String title;
  final String content;
  final String authorName;
  final DateTime? timestamp;
  final bool isRead;
  final List<Map<String, String>> attachments;

  GroupMessage({
    required this.groupId,
    required this.messageId,
    required this.title,
    required this.content,
    required this.authorName,
    this.timestamp,
    required this.isRead,
    this.attachments = const [],
  });
}

class Comment extends Equatable {
  final String id;
  final String content;
  final String authorId;
  final String authorName;
  final DateTime? timestamp;
  final bool isAdmin;
  final String? bureauName;

  const Comment({
    required this.id,
    required this.content,
    required this.authorId,
    required this.authorName,
    this.timestamp,
    this.isAdmin = false,
    this.bureauName,
  });

  factory Comment.fromSnapshot(DocumentSnapshot snapshot) {
    final data = snapshot.data() as Map<String, dynamic>?;
    return Comment(
      id: snapshot.id,
      content: data?['content'] as String? ?? '',
      authorId: data?['authorId'] as String? ?? '',
      authorName: data?['authorName'] as String? ?? 'Bruger',
      timestamp: (data?['timestamp'] as Timestamp?)?.toDate(),
      isAdmin: data?['isAdmin'] as bool? ?? false,
      bureauName: data?['bureauName'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'content': content,
      'authorId': authorId,
      'authorName': authorName,
      'timestamp': FieldValue.serverTimestamp(),
      'isAdmin': isAdmin,
      if (bureauName != null) 'bureauName': bureauName,
    };
  }

  @override
  List<Object?> get props =>
      [id, content, authorId, authorName, timestamp, isAdmin, bureauName];
}
