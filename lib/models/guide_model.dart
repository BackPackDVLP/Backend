import 'package:equatable/equatable.dart';

class Guide extends Equatable {
  final String name;
  final int phoneNumber;

  const Guide({
    required this.name,
    required this.phoneNumber,
  });

  factory Guide.fromSnapshot(Map<String, dynamic> snap) {
    return Guide(
      name: snap['name'] as String? ?? '',
      phoneNumber: snap['phoneNumber'] ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'phoneNumber': phoneNumber,
    };
  }

  Map<String, dynamic> toJson() => toMap();

  @override
  List<Object?> get props => [
        name,
        phoneNumber,
      ];

  static List<Guide> groupMember = [
    const Guide(
      name: 'John Doe',
      phoneNumber: 1012425,
    )
  ];
}
