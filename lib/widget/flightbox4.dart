import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

class FlightBox4 extends StatelessWidget {
  final dynamic flight;

  const FlightBox4({super.key, required this.flight});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return GestureDetector(
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
                      flight.originAirportCode,
                      style: TextStyle(
                        fontFamily: GoogleFonts.kanit().fontFamily,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8.0),
                    Expanded(
                      // Changed to Expanded
                      child: Divider(
                        thickness: 1,
                        color: Colors.black45,
                      ),
                    ),
                    SizedBox(width: 8.0),
                    Column(
                      children: [
                        SizedBox(
                          height: 20,
                        ),
                        Transform.rotate(
                          // Rotated icon
                          angle: 90 * (3.141592653589793 / 180),
                          child:
                              Icon(Icons.flight, color: Colors.black, size: 35),
                        ),
                        Text(DateFormat('dd/MM').format(flight.flightDate),
                            style: TextStyle(
                                fontSize: 14,
                                fontFamily: GoogleFonts.kanit().fontFamily))
                      ],
                    ),
                    SizedBox(width: 8.0),
                    Expanded(
                      // Changed to Expanded
                      child: Divider(
                        thickness: 1,
                        color: Colors.black45,
                      ),
                    ),
                    const SizedBox(width: 8.0),
                    Text(
                      flight.destinationAirportCode,
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
                    Text(
                      flight.originCity,
                      style: TextStyle(
                        fontSize: 14,
                        fontFamily: GoogleFonts.kanit().fontFamily,
                      ),
                    ),
                    Text(
                      flight.destinationCity,
                      style: TextStyle(
                        fontSize: 14,
                        fontFamily: GoogleFonts.kanit().fontFamily,
                      ),
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
