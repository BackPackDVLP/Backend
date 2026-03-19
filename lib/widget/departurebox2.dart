import 'package:backend/config/app_colors.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class DepartureBox2 extends StatelessWidget {
  final GroupInformation information;

  const DepartureBox2({super.key, required this.information});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0, bottom: 8, left: 0, top: 15),
      child: Stack(
        children: [
          Container(
            height: 150,
            width: MediaQuery.of(context).size.width * 0.9,
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: AppColors.panelBackground,
              borderRadius: BorderRadius.circular(10.0),
              //border: Border.all(color: Colors.black, width: 0.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  spreadRadius: 5,
                  blurRadius: 7,
                  offset: const Offset(0, 3), // Adjust for position of shadow
                )
              ],
              image: const DecorationImage(
                image: AssetImage(
                    'assets/images/worldmap.png'), // Replace with your image path
                fit: BoxFit.contain,
                opacity: 0.3,
                // Overlay a dark filter
              ),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(10.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (information.departureDate.year == DateTime.now().year &&
                        information.departureDate.month ==
                            DateTime.now().month &&
                        information.departureDate.day == DateTime.now().day)
                      Text('Rejsen starter i dag',
                          style: GoogleFonts.kanit(
                              fontSize: 20, fontWeight: FontWeight.w300))
                    else if (information.departureDate.isBefore(DateTime.now()))
                      Text(
                          'Gruppen har rejst i ${(DateTime.now().difference(information.departureDate).inDays + 1).abs().toString()} dage',
                          style: GoogleFonts.kanit(
                            fontSize: 20,
                            fontWeight: FontWeight.w300,
                          ))
                    else
                      Text(
                          'Rejsen starter om ${(information.departureDate.difference(DateTime.now()).inDays+1).toString()} dage',
                          style: GoogleFonts.kanit(
                              fontSize: 20, fontWeight: FontWeight.w300)),
                    if ((information.departureDate.isBefore(DateTime.now())) ||
                        (information.departureDate.year ==
                                DateTime.now().year &&
                            information.departureDate.month ==
                                DateTime.now().month &&
                            information.departureDate.day ==
                                DateTime.now().day))
                      Text('Rejsen startede i ${information.departureFrom}')
                    else
                      Text(
                          information.flightAway == false
                              ? 'Rejsen starter i ${information.departureFrom}'
                              : 'Gruppen rejser fra ${information.departureFrom}',
                          style: GoogleFonts.kanit(
                              fontSize: 14, fontWeight: FontWeight.w200)),
                  ],
                ),
              ),
            ),
          ),
          
         
        
        ],
      ),
    );
  }
}
