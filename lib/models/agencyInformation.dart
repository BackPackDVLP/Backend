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
  final String? videoUrl;
  final double photoStorageLimitGb;

  // Plan-gated features: default to false (not activated) for any bureau
  // where these fields aren't set yet in Firestore. The corresponding
  // integration UI stays visible either way — it just shows as not
  // activated rather than disappearing, so bureaus can see what's
  // available and BackPack can pitch it.
  final bool crmEnabled;
  final bool emailIntegrationEnabled;
  final bool aiTripBuilderEnabled;

  const AgencyInformation({
    required this.agencyCode,
    required this.agencyName,
    required this.emailCount,
    required this.emergencyPhone,
    required this.mainColor,
    required this.maxEmails,
    required this.returnMail,
    this.videoUrl,
    this.photoStorageLimitGb = 2.0,
    this.crmEnabled = false,
    this.emailIntegrationEnabled = false,
    this.aiTripBuilderEnabled = false,
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
      videoUrl: data['videoUrl'] as String?,
      photoStorageLimitGb:
          (data['photoStorageLimitGb'] as num?)?.toDouble() ?? 2.0,
      crmEnabled: data['crmEnabled'] as bool? ?? false,
      emailIntegrationEnabled:
          data['emailIntegrationEnabled'] as bool? ?? false,
      aiTripBuilderEnabled: data['aiTripBuilderEnabled'] as bool? ?? false,
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
        videoUrl,
        photoStorageLimitGb,
        crmEnabled,
        emailIntegrationEnabled,
        aiTripBuilderEnabled,
      ];
}
