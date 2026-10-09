import 'package:backend/models/group_information_model.dart';
import 'package:backend/config/design.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import 'package:cached_network_image/cached_network_image.dart';
import '../blocs/groupinformation/groupinformation_bloc.dart';
import 'timelineDialog.dart'; // Import for date formatting

class TimelineEventBox extends StatelessWidget {
  final TimelineEvent event;
  final GroupInformation groupInformation;
  final GroupInformationRepository repository;
  // TimelineDialog (opened on tap) is a fully editable form with no
  // read-only mode of its own — rather than build a parallel view-only
  // rendering of it, tapping is simply disabled for staff without
  // `trips.edit`. The card itself already surfaces the type/day/country/
  // date at a glance.
  final bool canEdit;

  const TimelineEventBox({
    super.key,
    required this.event,
    required this.groupInformation,
    required this.repository,
    this.canEdit = true,
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
        width: 375,
        child: GestureDetector(
          onTap: !canEdit
              ? null
              : () async {
                  await showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return TimelineDialog(
                        event: event,
                        groupInformation: groupInformation,
                        repository: repository,
                      );
                    },
                  );
                  // After the dialog is closed, refresh the group information in place.
                  if (context.mounted) {
                    context.read<GroupInformationBloc>().add(
                        RefreshGroupInformationById(
                            groupId: groupInformation.groupId));
                  }
                },
          child: Container(
            width: MediaQuery.of(context).size.width * 0.9,
            height: 150,
            decoration: BoxDecoration(
              borderRadius: AppRadii.smRadius,
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
                      borderRadius: AppRadii.smRadius,
                      child: CachedNetworkImage(
                        imageUrl: processedUrl,
                        fit: BoxFit.cover,
                        // The box only ever renders at ~375x150 logical
                        // pixels, but source photos can be full-resolution
                        // camera shots (10+ MP). Without capping the decode
                        // size, every one of these in the timeline decodes
                        // at full resolution into memory, which is what
                        // makes scrolling a long timeline janky.
                        memCacheWidth:
                            (375 * MediaQuery.of(context).devicePixelRatio)
                                .round(),
                        memCacheHeight:
                            (150 * MediaQuery.of(context).devicePixelRatio)
                                .round(),
                        fadeInDuration: const Duration(milliseconds: 150),
                        placeholder: (context, url) =>
                            const Center(child: CircularProgressIndicator()),
                        errorWidget: (context, url, error) {
                          print('Error loading image: $error');
                          return const Center(
                              child:
                                  Icon(Icons.broken_image, color: Colors.grey));
                        },
                      ),
                    ),
                  ),
                // Overlay for darkening the image
                if (isValidUrl)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: AppRadii.smRadius,
                        color: Colors.black.withOpacity(0.2),
                      ),
                    ),
                  ),
                // Tekst indhold
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
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
