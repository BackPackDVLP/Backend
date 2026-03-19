import 'package:backend/models/bureau_offer.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

class TimelineEvent extends Equatable {
  final String id;
  final String type;
  final String country;
  final DateTime startDate;
  final DateTime endDate;
  final int dayNumber;
  final bool isDestination;
  final String imageURL;
  final String description;
  final List<BureauOffer>? bureauOffers;
  final String? accommodation;
  final String? transport;
  final String? transportIcon;
  final String? meals;
  final String? activities;

  const TimelineEvent({
    required this.id,
    required this.type,
    required this.country,
    required this.startDate,
    required this.endDate,
    required this.dayNumber,
    required this.isDestination,
    required this.imageURL,
    required this.description,
    this.accommodation,
    this.transport,
    this.transportIcon,
    this.meals,
    this.activities,
    this.bureauOffers,
  });

  factory TimelineEvent.fromSnapshot(Map<String, dynamic> snap) {
    return TimelineEvent(
      id: snap['id'] ?? '',
      type: snap['type'] ?? '',
      country: snap['country'] ?? '',
      startDate: (snap['startDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      endDate: (snap['endDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      dayNumber: snap['dayNumber'] ?? 0,
      isDestination: snap['isDestination'] ?? false,
      imageURL: snap['imageURL'] ?? '',
      description:
          snap['description'] ?? 'Der er ingen beskrivelse af denne begivenhed',
      bureauOffers: (snap['bureauOffers'] as List?)
              ?.map((e) => BureauOffer.fromSnapshot(e))
              .toList() ??
          [],
      accommodation: snap['accommodation'],
      transport: snap['transport'],
      transportIcon: snap['transportIcon'],
      meals: snap['meals'],
      activities: snap['activities'],
    );
  }

  factory TimelineEvent.fromMap(Map<String, dynamic> map) {
    return TimelineEvent(
      id: map['id'] ?? '',
      type: map['type'] ?? '',
      country: map['country'] ?? '',
      startDate: (map['startDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      endDate: (map['endDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      dayNumber: map['dayNumber'] ?? 0,
      isDestination: map['isDestination'] ?? false,
      imageURL: map['imageURL'] ?? '',
      description: map['description'] ?? '',
      bureauOffers: (map['bureauOffers'] as List?)
          ?.map((e) => BureauOffer.fromSnapshot(e))
          .toList(),
      accommodation: map['accommodation'],
      transport: map['transport'],
      transportIcon: map['transportIcon'],
      meals: map['meals'],
      activities: map['activities'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type,
      'country': country,
      'startDate': Timestamp.fromDate(startDate),
      'endDate': Timestamp.fromDate(endDate),
      'dayNumber': dayNumber,
      'isDestination': isDestination,
      'imageURL': imageURL,
      'description': description,
      'bureauOffers': bureauOffers?.map((e) => e.toJson()).toList(),
      'accommodation': accommodation,
      'transport': transport,
      'transportIcon': transportIcon,
      'meals': meals,
      'activities': activities,
    };
  }

  Map<String, dynamic> toJson() => toMap();

  @override
  List<Object?> get props => [
        id,
        type,
        country,
        startDate,
        endDate,
        dayNumber,
        isDestination,
        imageURL,
        description,
        bureauOffers,
        accommodation,
        transport,
        transportIcon,
        meals,
        activities,
      ];
}
