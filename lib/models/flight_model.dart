import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

class FlightModel extends Equatable {
  final String originCity;
  final String destinationCity;
  final String flightIdentifier;
  final DateTime flightDate;
  final String carrierCode;
  final String originAirportCode;
  final String destinationAirportCode;

  const FlightModel({
    required this.originCity,
    required this.destinationCity,
    required this.flightIdentifier,
    required this.flightDate,
    required this.carrierCode,
    required this.originAirportCode,
    required this.destinationAirportCode,
  });

  factory FlightModel.fromSnapshot(Map<String, dynamic> snap) {
    return FlightModel(
      originCity: snap['originCity'] as String? ?? '',
      destinationCity: snap['destinationCity'] as String? ??
          '', // Handle potential null values
      flightIdentifier: snap['flightIdentifier'] as String? ?? '0',
      // Try to parse as int, default to 0 if parsin fails
      flightDate: (snap['flightDate'] as Timestamp?)?.toDate() ??
          DateTime.now(), // Handle potential null values
      carrierCode: snap['carrierCode'] as String? ?? '',
      originAirportCode: snap['originAirportCode'] as String? ?? '',
      destinationAirportCode: snap['destinationAirportCode'] as String? ?? '',
    );
  }

  @override
  List<Object?> get props => [
        originCity,
        destinationCity,
        flightIdentifier,
        flightDate,
        carrierCode,
        originAirportCode,
        destinationAirportCode
      ];

  static List<FlightModel> flightModel = [
    FlightModel(
        originCity: 'Billund',
        destinationCity: 'Los Angeles',
        flightIdentifier: '01012425',
        flightDate: DateTime.utc(1989, 11, 9),
        carrierCode: 'DL',
        originAirportCode: 'BIL',
        destinationAirportCode: 'LAX'),
  ];
}
