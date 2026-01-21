import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

class AgencyInformation extends Equatable {
  final String agencyCode;
  final String agencyName;
  final int emailCount;
  final String emergencyPhone;
  final String mainColor;
  final int maxEmails;
  final String returnMail;

  const AgencyInformation({
    required this.agencyCode,
    required this.agencyName,
    required this.emailCount,
    required this.emergencyPhone,
    required this.mainColor,
    required this.maxEmails,
    required this.returnMail,
  });

  factory AgencyInformation.fromSnapshot(DocumentSnapshot snapshot) {
    final data = snapshot.data() as Map<String, dynamic>;
    return AgencyInformation(
      agencyCode: data['agencyCode'] ?? '',
      agencyName: data['agencyName'] ?? '',
      emailCount: data['emailCount'] ?? 0,
      emergencyPhone: data['emergencyPhone'] ?? '',
      mainColor: data['mainColor'] ?? '#000000',
      maxEmails: data['maxEmails'] ?? 0,
      returnMail: data['returnMail'] ?? '',
    );
  }

  @override
  List<Object?> get props => [
        agencyCode,
        agencyName,
        emailCount,
        emergencyPhone,
        mainColor,
        maxEmails,
        returnMail,
      ];
}
