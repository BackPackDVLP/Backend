import 'package:equatable/equatable.dart';

class GroupMember extends Equatable {
  final String name;
  final int phoneNumber;
  final String email;
  final String? fcmToken;

  const GroupMember({
    required this.name,
    required this.phoneNumber,
    required this.email,
    this.fcmToken,
  });

  factory GroupMember.fromSnapshot(Map<String, dynamic> snap) {
    return GroupMember(
      name: snap['name'] as String? ?? '',
      phoneNumber: snap['phoneNumber'] ?? 0,
      email: snap['email'] as String? ?? '',
      fcmToken: snap['fcmToken'] as String?, // ✅ read token
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'phoneNumber': phoneNumber,
      'email': email,
      'fcmToken': fcmToken, // ✅ write token
    };
  }

  @override
  List<Object?> get props => [
        name,
        phoneNumber,
        email,
        fcmToken, // ✅ included for Equatable
      ];

  static List<GroupMember> groupMember = [
    const GroupMember(
      name: 'John Doe',
      phoneNumber: 01012425,
      email: 'John@doe.com',
      fcmToken: 'test_token_1',
    ),
    const GroupMember(
      name: 'Jane Doe',
      phoneNumber: 01552425,
      email: 'Jane@doe.com',
      fcmToken: null,
    ),
  ];
}
