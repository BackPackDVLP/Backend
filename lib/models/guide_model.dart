import 'package:equatable/equatable.dart';

class Guide extends Equatable {
  final String name;
  final String title;
  final String phoneNumber;
  final String whatsappNumber;
  final String email;

  const Guide({
    required this.name,
    this.title = '',
    this.phoneNumber = '',
    this.whatsappNumber = '',
    this.email = '',
  });

  bool get hasTitle => title.trim().isNotEmpty;
  bool get hasPhone => phoneNumber.trim().isNotEmpty;
  bool get hasWhatsapp => whatsappNumber.trim().isNotEmpty;
  bool get hasEmail => email.trim().isNotEmpty;
  bool get hasAnyContact => hasPhone || hasWhatsapp || hasEmail;

  factory Guide.fromSnapshot(Map<String, dynamic> snap) {
    return Guide(
      name: snap['name'] as String? ?? '',
      title: snap['title'] as String? ?? '',
      phoneNumber: _parseContactValue(snap['phoneNumber']),
      whatsappNumber: _parseContactValue(snap['whatsappNumber']),
      email: snap['email'] as String? ?? '',
    );
  }

  // Older guide documents stored phoneNumber as a Firestore number; this
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
      'title': title,
      'phoneNumber': phoneNumber,
      'whatsappNumber': whatsappNumber,
      'email': email,
    };
  }

  Map<String, dynamic> toJson() => toMap();

  @override
  List<Object?> get props => [
        name,
        title,
        phoneNumber,
        whatsappNumber,
        email,
      ];

  static List<Guide> groupMember = [
    const Guide(
      name: 'John Doe',
      title: 'Rejseleder',
      phoneNumber: '4520304050',
    )
  ];
}
