import 'package:backend/models/coupon_model.dart';
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

  // Bureau-wide default for new groups' own `mapEnabled` field (see
  // group_information_model.dart) — a specific trip's Detaljer screen can
  // still override this per group; this only seeds the value at creation.
  final bool mapEnabledDefault;

  // Whether the traveler app asks new travelers for a WhatsApp-reachable
  // phone number right after login, before the onboarding showcase.
  final bool whatsappConfirmEnabled;

  // Which of the traveler app's optional bottom-nav screens this bureau
  // shows. Default true — a bureau that hasn't touched these keeps every
  // screen it has today; Home itself is never optional.
  final bool packingListScreenEnabled;
  final bool groupScreenEnabled;
  final bool documentsScreenEnabled;

  // Whether travelers can compose new message threads and reply to
  // existing ones. Default true — false restricts a bureau's message
  // boards to bureau-only sending, travelers can still read every thread.
  final bool travelersCanMessage;

  // Whether a first-time traveler is shown the app's onboarding showcase
  // (the guided tour of Home/Huskeliste/Gruppe/Dokumenter) right after
  // login. Default true — same "don't change existing bureaus' behavior"
  // reasoning as the toggles above.
  final bool introTourEnabled;

  // Whether a traveler who hasn't answered yet is asked for email-marketing
  // consent right after login/the tour. Default true. Travelers who are
  // never asked (this off, or they just haven't logged in since) count as
  // "no consent on record" wherever this is read — see MarketingConsentDialog
  // and UsersScreen's "Email marketing" chip — never as an unknown state.
  final bool marketingConsentEnabled;

  // Bureau-wide affiliate links, shown on every trip's packing list in the
  // traveler app (alongside any trip-specific ones a group has of its own).
  final List<Coupon> coupons;

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
    this.mapEnabledDefault = false,
    this.whatsappConfirmEnabled = false,
    this.packingListScreenEnabled = true,
    this.groupScreenEnabled = true,
    this.documentsScreenEnabled = true,
    this.travelersCanMessage = true,
    this.introTourEnabled = true,
    this.marketingConsentEnabled = true,
    this.coupons = const [],
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
      mapEnabledDefault: data['mapEnabledDefault'] as bool? ?? false,
      whatsappConfirmEnabled: data['whatsappConfirmEnabled'] as bool? ?? false,
      packingListScreenEnabled:
          data['packingListScreenEnabled'] as bool? ?? true,
      groupScreenEnabled: data['groupScreenEnabled'] as bool? ?? true,
      documentsScreenEnabled: data['documentsScreenEnabled'] as bool? ?? true,
      travelersCanMessage: data['travelersCanMessage'] as bool? ?? true,
      introTourEnabled: data['introTourEnabled'] as bool? ?? true,
      marketingConsentEnabled:
          data['marketingConsentEnabled'] as bool? ?? true,
      coupons: ((data['coupons'] as List?) ?? const [])
          .map((c) => Coupon.fromSnapshot(Map<String, dynamic>.from(c as Map)))
          .toList(),
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
        mapEnabledDefault,
        whatsappConfirmEnabled,
        packingListScreenEnabled,
        groupScreenEnabled,
        documentsScreenEnabled,
        travelersCanMessage,
        introTourEnabled,
        marketingConsentEnabled,
        coupons,
      ];
}
