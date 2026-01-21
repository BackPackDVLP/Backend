import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math' as math;
import 'package:intl/intl.dart';
import 'package:backend/models/flight_model.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:dotted_dashed_line/dotted_dashed_line.dart';

class FlightBox3 extends StatefulWidget {
  final FlightModel flight;

  const FlightBox3({super.key, required this.flight});

  @override
  State<FlightBox3> createState() => _FlightBoxState();
}

class _FlightBoxState extends State<FlightBox3> {
  String _departureTime = 'Indlæser...';
  String _arrivalTime = 'Indlæser...';
  String _arrivalDate = '';
  String _status = 'Loading...';
  String _gate = 'Gate ikke annonceret';

  @override
  void initState() {
    super.initState();
    _fetchFlightDetails();
  }

  Future<void> _fetchFlightDetails() async {
    const apiKey =
        'I5KidZTEq131ZucHT9rRFIfbH4D8PezC'; // Replace with your actual API key
    const apiSecret = 'jIlfSGLrvEXmhbKd'; // Replace with your actual API secret
    final url = Uri.parse(
        'https://test.api.amadeus.com/v2/schedule/flights?carrierCode=${widget.flight.carrierCode}&flightNumber=${widget.flight.flightIdentifier.toString()}&scheduledDepartureDate=${DateFormat('yyyy-MM-dd').format(widget.flight.flightDate)}');
    final headers = {
      'Authorization': 'Bearer ${await getAccessToken(apiKey, apiSecret)}',
    };

    final response = await http.get(url, headers: headers);
    print('Status Code: ${response.statusCode}');
    print('Response Body: ${response.body}');

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final departureTimeString = data['data']?[0]?['flightPoints']?[0]
          ?['departure']?['timings']?[0]?['value'] as String?;
      final arrivalTimeString = data['data']?[0]?['flightPoints']?[1]
          ?['arrival']?['timings']?[0]?['value'] as String?;
      final delayMinutes = data['data']?[0]?['delay'] ?? 0;
      final gate = data['data']?[0]?['flightPoints']?[0]?['departure']?['gate']
          ?['mainGate'] as String?; // Default to 0 if missing

      if (departureTimeString != null) {
        DateTime departureTime =
            DateFormat("yyyy-MM-dd'T'HH:mmZZZZ").parse(departureTimeString);
        _departureTime = DateFormat('HH:mm').format(departureTime);
      } else {
        _departureTime = 'N/A';
      }

      if (arrivalTimeString != null) {
        DateTime arrivalTime =
            DateFormat("yyyy-MM-dd'T'HH:mmZZZZ").parse(arrivalTimeString);
        _arrivalTime = DateFormat('HH:mm').format(arrivalTime);
        _arrivalDate = DateFormat('dd/MM').format(arrivalTime);
      } else {
        _arrivalTime = 'N/A';
      }

      if (gate != null) {
        setState(() {
          _gate = gate; // Assuming you have a String _gate variable
        });
      } else {
        // Handle the case where gate information is not available
        setState(() {
          _gate = 'N/A'; // Or any other appropriate message
        });
      }

      // Set status based on delay
      setState(() {
        if (delayMinutes == 0) {
          _status = 'On time';
        } else {
          _status = 'Delayed by $delayMinutes min';
        }
      });
    } else {
      setState(() {
        _departureTime = 'Error';
        _arrivalTime = 'Error';
        _status = 'Error';
      });
    }
  }

  Future<String> getAccessToken(String apiKey, String apiSecret) async {
    final url =
        Uri.parse('https://test.api.amadeus.com/v1/security/oauth2/token');
    final headers = {'Content-Type': 'application/x-www-form-urlencoded'};
    final body =
        'grant_type=client_credentials&client_id=$apiKey&client_secret=$apiSecret';

    final response = await http.post(url, headers: headers, body: body);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['access_token'] as String;
    } else {
      throw Exception('Failed to get access token');
    }
  }

  void _showFlightDetailsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor:
            const Color.fromARGB(255, 184, 165, 151), // Background color
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.0), // Rounded corners
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: Flight Details + Status Tag
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Flydetaljer',
                    style: TextStyle(
                      fontFamily: GoogleFonts.kanit().fontFamily,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  // Status Tag
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _status.contains('On time')
                          ? Colors.green.shade100
                          : Colors.orange.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _status.contains('On time') ? 'On time' : _status,
                      style: TextStyle(
                        fontFamily: GoogleFonts.kanit().fontFamily,
                        color: _status.contains('On time')
                            ? Colors.green
                            : Colors.orange,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Flight Information Row
              _buildFlightRow(
                origin: widget.flight.originAirportCode,
                originCity: widget.flight.originCity,
                departureTime: _departureTime,
                destination: widget.flight.destinationAirportCode,
                destinationCity: widget.flight.destinationCity,
                arrivalTime: _arrivalTime,
              ),
              const SizedBox(height: 16),

              // Flight Number, Gate, Date, Travel Time
              _buildDetailInfo(
                flightNumber:
                    '${widget.flight.carrierCode} ${widget.flight.flightIdentifier}',
                date:
                    DateFormat('EEEE, MMM dd').format(widget.flight.flightDate),
                gate: _gate, // Replace with actual gate if available
                travelTime: '12 hours, 23 min', // Replace if dynamic
              ),
            ],
          ),
        ),
      ),
    );
  }

// Flight Row with Cities and Times
  Widget _buildFlightRow({
    required String origin,
    required String originCity,
    required String departureTime,
    required String destination,
    required String destinationCity,
    required String arrivalTime,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Origin Column
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              origin, // Airport code
              style: TextStyle(
                fontFamily: GoogleFonts.kanit().fontFamily,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            Text(
              originCity, // City name
              style: TextStyle(
                fontFamily: GoogleFonts.kanit().fontFamily,
                fontSize: 14,
                color: Colors.black54,
              ),
            ),
            Text(
              departureTime, // Departure time
              style: TextStyle(
                fontFamily: GoogleFonts.kanit().fontFamily,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ],
        ),

        // Airplane Icon
        Transform.rotate(
          angle: math.pi / 2, // Rotate 90 degrees clockwise
          child: const Icon(
            Icons.flight,
            color: Colors.black,
            size: 50,
          ),
        ),

        // Destination Column
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              destination, // Airport code
              style: TextStyle(
                fontFamily: GoogleFonts.kanit().fontFamily,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            Text(
              destinationCity, // City name
              style: TextStyle(
                fontFamily: GoogleFonts.kanit().fontFamily,
                fontSize: 14,
                color: Colors.black54,
              ),
            ),
            Text(
              arrivalTime, // Arrival time
              style: TextStyle(
                fontFamily: GoogleFonts.kanit().fontFamily,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ],
    );
  }

// Flight Details Row
  Widget _buildDetailInfo({
    required String flightNumber,
    required String date,
    required String gate,
    required String travelTime,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDetailRow('Fly:', flightNumber),
        _buildDetailRow('Gate:', gate),
        _buildDetailRow('Dato:', date),
        _buildDetailRow('Rejsetid:', travelTime),
      ],
    );
  }

// Custom Row Builder
  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: GoogleFonts.kanit().fontFamily,
              fontSize: 14,
              color: Colors.black54,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontFamily: GoogleFonts.kanit().fontFamily,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return GestureDetector(
      onTap: () => _showFlightDetailsDialog(context),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Container(
          width: screenWidth * 0.9,
          decoration: BoxDecoration(
            color: const Color.fromARGB(223, 239, 224, 213),
            borderRadius: BorderRadius.circular(12.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                spreadRadius: 2,
                blurRadius: 6,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 16.0, horizontal: 20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      widget.flight.originAirportCode,
                      style: TextStyle(
                        fontFamily: GoogleFonts.kanit().fontFamily,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8.0),
                    const Expanded(
                      child: DottedDashedLine(
                        width: double.infinity,
                        height: 0,
                        axis: Axis.horizontal,
                      ),
                    ),
                    const SizedBox(width: 8.0),
                    Column(
                      children: [
                         Icon(MdiIcons.airplane,
                            color: Colors.blue, size: 24),
                        Text(
                          '${widget.flight.carrierCode}${widget.flight.flightIdentifier}',
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: GoogleFonts.kanit().fontFamily,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: _status.contains('On time')
                                  ? Colors.green.shade100
                                  : Colors.orange.shade100,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _status.contains('On time') ? 'On time' : _status,
                              style: TextStyle(
                                color: _status.contains('On time')
                                    ? Colors.green
                                    : Colors.orange,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 8.0),
                    const Expanded(
                      child: DottedDashedLine(
                        width: double.infinity,
                        height: 0,
                        axis: Axis.horizontal,
                      ),
                    ),
                    const SizedBox(width: 8.0),
                    Text(
                      widget.flight.destinationAirportCode,
                      style: TextStyle(
                        fontFamily: GoogleFonts.kanit().fontFamily,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16.0),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.flight.originCity,
                          style: TextStyle(
                            fontSize: 14,
                            fontFamily: GoogleFonts.kanit().fontFamily,
                          ),
                        ),
                        Text(
                          '${DateFormat('dd/MM').format(widget.flight.flightDate)} kl. $_departureTime',
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: GoogleFonts.kanit().fontFamily,
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          widget.flight.destinationCity,
                          style: TextStyle(
                            fontSize: 14,
                            fontFamily: GoogleFonts.kanit().fontFamily,
                          ),
                        ),
                        if (_arrivalDate.isNotEmpty &&
                            _arrivalDate !=
                                DateFormat('dd/MM')
                                    .format(widget.flight.flightDate))
                          Text(
                            '$_arrivalDate kl. $_arrivalTime',
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: GoogleFonts.kanit().fontFamily,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
