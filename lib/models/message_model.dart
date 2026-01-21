import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

class Message extends Equatable {
  final String id;
  final String title;
  final String content;
  final DateTime? timestamp; // Nullable because Firestore assigns timestamp

  const Message({
    required this.id,
    required this.title,
    required this.content,
    this.timestamp,
  });

  /// ✅ Convert Firestore DocumentSnapshot to Message Object
  factory Message.fromSnapshot(DocumentSnapshot snapshot) {
    final data = snapshot.data() as Map<String, dynamic>?; // Ensure null safety
    return Message(
      id: snapshot.id, // Get Firestore document ID
      title: data?['title'] as String? ?? '',
      content: data?['content'] as String? ?? '',
      timestamp: (data?['timestamp'] as Timestamp?)?.toDate(),
    );
  }

  /// ✅ Convert Message Object to Firestore Map (for writing to Firestore)
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'content': content,
      'timestamp': FieldValue.serverTimestamp(), // Firestore assigns timestamp
    };
  }

  @override
  List<Object?> get props => [id, title, content, timestamp];
}
