import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../blocs/groupinformation/groupinformation_bloc.dart';
import 'timelineDialog.dart'; // Import for date formatting

class TimelineEventBox extends StatelessWidget {
  final TimelineEvent event;
  final GroupInformation groupInformation;
  final GroupInformationRepository repository;

  const TimelineEventBox({
    super.key,
    required this.event,
    required this.groupInformation,
    required this.repository,
  });

  @override
  Widget build(BuildContext context) {
    final String rawUrl = event.imageURL.trim();
    final String processedUrl =
        rawUrl.replaceAll(RegExp(r'[\r\n]'), '').replaceAll(' ', '%20');
    final Uri? uri = Uri.tryParse(processedUrl);
    final bool isValidUrl = uri != null &&
        uri.isAbsolute &&
        (uri.scheme == 'http' || uri.scheme == 'https');

    return Padding(
      padding: const EdgeInsets.only(right: 8.0, bottom: 8, top: 8, left: 13),
      child: SizedBox(
        width: 200,
        child: GestureDetector(
          onTap: () async {
            await showDialog(
              context: context,
              builder: (BuildContext context) {
                return TimelineDialog(
                    event: event, groupInformation: groupInformation, repository: repository,);
              },
            );
            // After the dialog is closed, trigger a refresh of the group information.
            if (context.mounted) {
              context.read<GroupInformationBloc>().add(LoadGroupInformationById(groupId: groupInformation.groupId));
            }
          },
          child: Container(
            width: MediaQuery.of(context).size.width * 0.9,
            height: 150,
            decoration: BoxDecoration(
            
          
              borderRadius: BorderRadius.circular(10.0),
              color: Colors.grey[300], // Fallback farve
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  spreadRadius: 5,
                  blurRadius: 7,
                  offset: const Offset(0, 3), // Adjust for position of shadow
                )
              ],
            ),
            child: Stack(
              children: [
                if (isValidUrl)
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10.0),
                      child: Image.network(
                        processedUrl,
                        fit: BoxFit.cover,
                        color: Colors.black.withOpacity(0.2),
                        colorBlendMode: BlendMode.darken,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return const Center(child: CircularProgressIndicator());
                        },
                        errorBuilder: (context, error, stackTrace) {
                          print('Error loading image: $error\nStacktrace: $stackTrace');
                          return const Center(child: Icon(Icons.broken_image, color: Colors.grey));
                        },
                      ),
                    ),
                  ),
                // Tekst indhold
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Text(event.type,
                          style: GoogleFonts.kanit(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w500)),
                      Text(
                        style: GoogleFonts.kanit(color: Colors.white),
                        event.startDate
                                    .difference(groupInformation.departureDate)
                                    .inDays
                                    .toString() ==
                                event.endDate
                                    .difference(groupInformation.departureDate)
                                    .inDays
                                    .toString()
                            ? 'Dag ${event.startDate.difference(groupInformation.departureDate).inDays.toString()}'
                            : 'Dag ${event.startDate.difference(groupInformation.departureDate).inDays.toString()} - ${event.endDate.difference(groupInformation.departureDate).inDays.toString()}',
                      ),
                      const Spacer(), // Skubber bunden ned
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(event.country,
                                style: GoogleFonts.kanit(color: Colors.white)),
                          ),
                          Text(
                              event.startDate
                                          .difference(
                                              groupInformation.departureDate)
                                          .inDays
                                          .toString() ==
                                      event.endDate
                                          .difference(
                                              groupInformation.departureDate)
                                          .inDays
                                          .toString()
                                  ? DateFormat('dd/MM').format(event.startDate)
                                  : '${DateFormat('dd/MM').format(event.startDate)} - ${DateFormat('dd/MM').format(event.endDate)}',
                              style: GoogleFonts.kanit(color: Colors.white)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
