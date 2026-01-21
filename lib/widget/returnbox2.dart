import 'package:backend/models/group_information_model.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class ReturnBox2 extends StatelessWidget {
  final GroupInformation information;

  const ReturnBox2({super.key, required this.information});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0, right: 0, left: 0),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (information.returnDate.isBefore(DateTime.now()))
                Text('Din rejse er slut',
                    style: GoogleFonts.kanit(
                        fontSize: 20, fontWeight: FontWeight.w500))
              else
                Text(
                    'Rejsen slutter om ${information.returnDate.difference(DateTime.now()).inDays.toString()} dage',
                    style: GoogleFonts.kanit(
                        fontSize: 20, fontWeight: FontWeight.w500)),
              Text(
                  information.flightHome == false
                      ? 'Rejsen slutter i ${information.returnTo}'
                      : 'Du lander i ${information.returnTo}',
                  style: GoogleFonts.kanit(
                      fontSize: 14, fontWeight: FontWeight.w200)),
            ],
          ),
        ),
      ),
    );
  }
}
