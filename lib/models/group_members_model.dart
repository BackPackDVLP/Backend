import 'package:equatable/equatable.dart';

class GroupMember extends Equatable {
  final String name;
  final String phoneNumber;
  final String whatsappNumber;
  final String email;
  final String? fcmToken;

  const GroupMember({
    required this.name,
    this.phoneNumber = '',
    this.whatsappNumber = '',
    required this.email,
    this.fcmToken,
  });

  bool get hasPhone => phoneNumber.trim().isNotEmpty;
  bool get hasWhatsapp => whatsappNumber.trim().isNotEmpty;
  bool get hasEmail => email.trim().isNotEmpty;

  factory GroupMember.fromSnapshot(Map<String, dynamic> snap) {
    return GroupMember(
      name: snap['name'] as String? ?? '',
      phoneNumber: _parseContactValue(snap['phoneNumber']),
      whatsappNumber: _parseContactValue(snap['whatsappNumber']),
      email: snap['email'] as String? ?? '',
      fcmToken: snap['fcmToken'] as String?, // ✅ read token
    );
  }

  // Older member documents stored phoneNumber as a Firestore number; this
  // keeps those readable while new writes use plain strings so a leading
  // '+' or '0' survives.
  static String _parseContactValue(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num) {
      final intValue = value.toInt();
      return intValue == 0 ? '' : intValue.toString();
    }
    return value.toString();
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'phoneNumber': phoneNumber,
      'whatsappNumber': whatsappNumber,
      'email': email,
      'fcmToken': fcmToken, // ✅ write token
    };
  }

  @override
  List<Object?> get props => [
        name,
        phoneNumber,
        whatsappNumber,
        email,
        fcmToken, // ✅ included for Equatable
      ];

  static List<GroupMember> groupMember = [
    const GroupMember(
      name: 'John Doe',
      phoneNumber: '4520304050',
      email: 'John@doe.com',
      fcmToken: 'test_token_1',
    ),
    const GroupMember(
      name: 'Jane Doe',
      phoneNumber: '4520304051',
      email: 'Jane@doe.com',
      fcmToken: null,
    ),
  ];
}
