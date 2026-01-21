import 'package:backend/models/coupon_model.dart';
import 'package:backend/models/flight_model.dart';
import 'package:backend/models/group_members_model.dart';
import 'package:backend/models/guide_model.dart';
import 'package:backend/models/message_model.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

import 'packinglist_model.dart';

class GroupInformation extends Equatable {
  final String groupId;
  final String id;
  final DateTime departureDate;
  final DateTime returnDate;
  final String departureFrom;
  final String returnTo;
  final List<GroupMember> members;
  final List<Guide> guides;
  final List<TimelineEvent> timelineEvents;
  final List<PackinglistCategories> packinglistCategories;
  final String agencyCode;
  final List<FlightModel>? flights;
  final String? emergencyPhone;
  final String bureauName;
  final List<Coupon>? coupons;
  final bool flightHome;
  final bool flightAway;
  final List<Message>? messages;

  const GroupInformation({
    required this.groupId,
    required this.id,
    required this.departureDate,
    required this.returnDate,
    required this.departureFrom,
    required this.returnTo,
    required this.members,
    required this.guides,
    required this.timelineEvents,
    required this.packinglistCategories,
    required this.agencyCode,
    this.emergencyPhone,
    required this.bureauName,
    required this.flightHome,
    required this.flightAway,
    this.coupons,
    this.flights,
    this.messages,
  });

  factory GroupInformation.fromSnapshot(DocumentSnapshot snapshot) {
    final data = snapshot.data() as Map<String, dynamic>;
    return GroupInformation(
      groupId: snapshot.id,
      bureauName: data['bureauName'],
      id: data['id'],
      departureDate:
          (data['departureDate'] as Timestamp).toDate(), // Use data here
      returnDate: (data['returnDate'] as Timestamp).toDate(), // Use data here
      departureFrom: data['departureFrom'],
      returnTo: data['returnTo'],
      members: (data['members'] as List) // Use data here
          .map((member) => GroupMember.fromSnapshot(member))
          .toList(),
      guides: (data['guides'] as List) // Use data here
          .map((guide) => Guide.fromSnapshot(guide))
          .toList(),
      timelineEvents: (data['timelineEvents'] as List) // Use data here
          .map((event) => TimelineEvent.fromSnapshot(event))
          .toList(),
      packinglistCategories:
          (data['packinglistCategories'] as List) // Use data here
              .map((event) => PackinglistCategories.fromSnapshot(event))
              .toList(),
      agencyCode: data['agencyCode'],
      flights: data['flights'] !=
              null // Check if 'flights' field exists and is not null
          ? (data['flights'] as List)
              .map((flight) => FlightModel.fromSnapshot(flight))
              .toList()
          : null,
      emergencyPhone: data['emergencyPhone'],
      coupons: (data['coupons'] as List?)
        ?.where((coupon) => coupon is Map<String, dynamic>) // only map entries
        .map((coupon) => Coupon.fromSnapshot(coupon as Map<String, dynamic>))
        .toList(),
      flightAway: data['flightAway'],
      flightHome: data['flightHome'],
      messages: data['messages'] != null // Check for null before mapping
          ? (data['messages'] as List)
              .map((message) => Message.fromSnapshot(message))
              .toList()
          : null,
    );
  }

  @override
  List<Object?> get props => [
        id,
        departureDate,
        returnDate,
        departureFrom,
        returnTo,
        members,
        timelineEvents,
        agencyCode,
        emergencyPhone,
        bureauName,
        coupons,
        flightAway,
        flightHome
      ];

  static List<GroupInformation> groupInformations = [
    GroupInformation(
        packinglistCategories: PackinglistCategories.packinglistCategories,
        agencyCode: 'ADK',
        bureauName: 'AdventureDK',
        groupId: 'AdventureDK0001',
        id: 'AdventureDK0001',
        departureDate: DateTime.utc(2024, 9, 14),
        returnDate: DateTime.utc(2024, 10, 19),
        returnTo: 'Kastrup Lufthavn',
        departureFrom: 'Billund Lufthavn',
        members: const [
          GroupMember(
            name: 'John Doe',
            phoneNumber: 01012425,
            email: 'John@doe.com',
          ),
          GroupMember(
            name: 'Jane Doe',
            phoneNumber: 01552425,
            email: 'Jane@doe.com',
          )
        ],
        guides: const [
          Guide(
            name: 'John Doe',
            phoneNumber: 01012425,
          ),
          Guide(
            name: 'Jane Doe',
            phoneNumber: 01552425,
          )
        ],
        timelineEvents: [
          TimelineEvent(
              id: '1',
              type: 'Destination',
              country: 'America',
              startDate: DateTime.utc(1989, 11, 9),
              endDate: DateTime.utc(1989, 11, 9),
              dayNumber: 1,
              description: 'Her er beskrivelsen',
              isDestination: false,
              imageURL:
                  'https://dynamic-media-cdn.tripadvisor.com/media/photo-o/09/cf/69/07/sydney-harbour.jpg?w=1200&h=-1&s=1'),
          TimelineEvent(
              id: '2',
              type: 'Destination',
              country: 'Fiji',
              startDate: DateTime.utc(1989, 11, 9),
              endDate: DateTime.utc(1989, 11, 9),
              dayNumber: 26,
              description: 'Her er beskrivelsen',
              isDestination: false,
              imageURL:
                  'https://dynamic-media-cdn.tripadvisor.com/media/photo-o/09/cf/69/07/sydney-harbour.jpg?w=1200&h=-1&s=1'),
          TimelineEvent(
              id: '2',
              type: 'Destination',
              country: 'New Zealand',
              startDate: DateTime.utc(1989, 11, 9),
              endDate: DateTime.utc(1989, 11, 9),
              dayNumber: 26,
              description: 'Her er beskrivelsen',
              isDestination: false,
              imageURL:
                  'https://dynamic-media-cdn.tripadvisor.com/media/photo-o/09/cf/69/07/sydney-harbour.jpg?w=1200&h=-1&s=1'),
        ],
        emergencyPhone: '+4542426341',
        flightAway: true,
        flightHome: true)
  ];
}
