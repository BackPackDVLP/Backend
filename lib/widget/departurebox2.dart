import 'package:backend/config/app_colors.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class DepartureBox2 extends StatelessWidget {
  final GroupInformation information;

  const DepartureBox2({super.key, required this.information});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isToday = information.departureDate.year == now.year &&
        information.departureDate.month == now.month &&
        information.departureDate.day == now.day;
    final hasDeparted = information.departureDate.isBefore(now);

    final String headline;
    if (isToday) {
      headline = 'Rejsen starter i dag';
    } else if (hasDeparted) {
      final days = (now.difference(information.departureDate).inDays + 1).abs();
      headline = 'Gruppen har rejst i $days dage';
    } else {
      final days = information.departureDate.difference(now).inDays + 1;
      headline = 'Rejsen starter om $days dage';
    }

    final String subtitle;
    if (hasDeparted || isToday) {
      subtitle = 'Rejsen startede i ${information.departureFrom}';
    } else {
      subtitle = information.flightAway == false
          ? 'Rejsen starter i ${information.departureFrom}'
          : 'Gruppen rejser fra ${information.departureFrom}';
    }

    return Padding(
      padding: const EdgeInsets.only(right: 8.0, bottom: 8, top: 15),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.9),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.flight_takeoff, color: AppColors.primary, size: 26),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    headline,
                    style: GoogleFonts.kanit(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: GoogleFonts.kanit(fontSize: 13, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
