import 'package:backend/config/app_colors.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/message_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:backend/screens/group_selection_screen/group_messages_dialog.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

/// Bureau-scoped overview screen, styled like rf-backend's community
/// dashboard but without any community messages/promotions/events —
/// this app has no such concept. The stats grid mirrors the source layout
/// (trip stats, members, and the cross-group message inbox), and below it
/// a preview of upcoming trips and recent messages plus quick actions
/// fill in for the excluded community content.
class DashboardScreen extends StatelessWidget {
  final List<GroupInformation> groups;
  final String agencyCode;
  final Color mainColor;
  final VoidCallback onNavigateToGroups;
  final VoidCallback onNavigateToUsers;
  final VoidCallback onNavigateToTeam;
  final void Function(GroupInformation group) onSelectGroup;
  final VoidCallback onCreateGroup;

  const DashboardScreen({
    super.key,
    required this.groups,
    required this.agencyCode,
    required this.mainColor,
    required this.onNavigateToGroups,
    required this.onNavigateToUsers,
    required this.onNavigateToTeam,
    required this.onSelectGroup,
    required this.onCreateGroup,
  });

  List<GroupInformation> get _trips =>
      groups.where((g) => g.isTemplate != true).toList();

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final trips = _trips;
    final totalTrips = trips.length;
    final upcomingTrips = trips.where((g) => g.departureDate.isAfter(now)).length;
    final activeTrips = trips
        .where((g) => g.departureDate.isBefore(now) && g.returnDate.isAfter(now))
        .length;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.scaffoldGradientStart,
            AppColors.scaffoldGradientEnd,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, 0.5],
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 32),
            _buildStatsGrid(context, totalTrips, upcomingTrips, activeTrips),
            const SizedBox(height: 32),
            _buildQuickActions(context),
            const SizedBox(height: 32),
            LayoutBuilder(builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 800;
              final tripsPreview = _buildTripsPreview(context);
              final messagesPreview = _buildMessagesPreview(context);
              if (isNarrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    tripsPreview,
                    const SizedBox(height: 32),
                    messagesPreview,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: tripsPreview),
                  const SizedBox(width: 24),
                  Expanded(flex: 2, child: messagesPreview),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dashboard',
          style: GoogleFonts.kanit(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: mainColor.withOpacity(0.9),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Velkommen ${FirebaseAuth.instance.currentUser?.displayName ?? FirebaseAuth.instance.currentUser?.email ?? ''}',
          style: GoogleFonts.kanit(
            fontSize: 16,
            color: mainColor.withOpacity(0.8),
          ),
        ),
      ],
    );
  }

  Widget _buildStatsGrid(
      BuildContext context, int totalTrips, int upcomingTrips, int activeTrips) {
    return SizedBox(
      height: 200,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _buildStatCard('Rejser i alt', totalTrips.toString(),
                Icons.groups, Colors.green, onTap: onNavigateToGroups),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _buildStatCard('Kommende rejser', upcomingTrips.toString(),
                Icons.flight_takeoff, Colors.blue, onTap: onNavigateToGroups),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _buildStatCard('Aktive rejser', activeTrips.toString(),
                Icons.beach_access, Colors.orange, onTap: onNavigateToGroups),
          ),
          const SizedBox(width: 16),
          Expanded(child: _buildMembersCard(context)),
          const SizedBox(width: 16),
          Expanded(child: _buildMessagesCard(context)),
        ],
      ),
    );
  }

  List<String> get _groupIds => groups.map((g) => g.groupId).toList();

  void _openMessagesDialog(BuildContext context, {GroupMessage? initialThread}) {
    showDialog(
      context: context,
      builder: (_) => GroupMessagesDialog(
        mainColor: mainColor,
        groups: groups,
        initialThread: initialThread,
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _buildActionButton(
          icon: Icons.add,
          label: 'Ny rejse',
          onTap: onCreateGroup,
        ),
        _buildActionButton(
          icon: Icons.person_add_alt_1,
          label: 'Inviter medarbejder',
          onTap: onNavigateToTeam,
        ),
        _buildActionButton(
          icon: Icons.forum_outlined,
          label: 'Skriv besked',
          onTap: () => _openMessagesDialog(context),
        ),
      ],
    );
  }

  Widget _buildActionButton(
      {required IconData icon, required String label, required VoidCallback onTap}) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: mainColor),
      label: Text(label,
          style: GoogleFonts.kanit(fontWeight: FontWeight.w600, color: Colors.black87)),
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white.withOpacity(0.9),
        side: BorderSide(color: mainColor.withOpacity(0.3)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {VoidCallback? onSeeAll}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title,
            style: GoogleFonts.kanit(
                fontSize: 20, fontWeight: FontWeight.bold, color: mainColor.withOpacity(0.9))),
        if (onSeeAll != null)
          TextButton(
            onPressed: onSeeAll,
            child: Text('Se alle', style: GoogleFonts.kanit(color: mainColor)),
          ),
      ],
    );
  }

  Widget _buildPreviewCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
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
      child: child,
    );
  }

  Widget _buildEmptyPreview(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(text, style: GoogleFonts.kanit(color: Colors.grey[500], fontSize: 14)),
      ),
    );
  }

  Widget _buildTripsPreview(BuildContext context) {
    final now = DateTime.now();
    final upcoming = _trips.where((g) => g.returnDate.isAfter(now)).toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));
    final preview = upcoming.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('Kommende rejser', onSeeAll: onNavigateToGroups),
        const SizedBox(height: 16),
        _buildPreviewCard(
          child: preview.isEmpty
              ? _buildEmptyPreview('Ingen kommende rejser')
              : Column(
                  children: preview.map((group) {
                    final isActive =
                        group.departureDate.isBefore(now) && group.returnDate.isAfter(now);
                    return InkWell(
                      onTap: () => onSelectGroup(group),
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(
                                color: (isActive ? Colors.orange : mainColor).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Column(
                                children: [
                                  Text(DateFormat('dd').format(group.departureDate),
                                      style: GoogleFonts.kanit(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                          color: isActive ? Colors.orange : mainColor)),
                                  Text(
                                      DateFormat('MMM', 'da_DK')
                                          .format(group.departureDate)
                                          .toUpperCase(),
                                      style: GoogleFonts.kanit(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 9,
                                          color: isActive ? Colors.orange : mainColor)),
                                ],
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(group.groupName ?? group.groupId,
                                      style: GoogleFonts.kanit(
                                          fontWeight: FontWeight.w600, color: Colors.black87),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  Text(
                                      isActive
                                          ? 'Rejse i gang'
                                          : '${group.members.length} medlemmer',
                                      style: GoogleFonts.kanit(
                                          fontSize: 12,
                                          color: isActive ? Colors.orange : Colors.grey[600])),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right, color: Colors.grey[400], size: 20),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }

  Widget _buildMessagesPreview(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('Seneste beskeder',
            onSeeAll: () => _openMessagesDialog(context)),
        const SizedBox(height: 16),
        _buildPreviewCard(
          child: StreamBuilder<List<GroupMessage>>(
            stream: context.read<GroupInformationRepository>().streamAllGroupMessages(_groupIds),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                );
              }
              final messages = snapshot.data!.take(5).toList();
              if (messages.isEmpty) {
                return _buildEmptyPreview('Ingen beskeder endnu');
              }
              return Column(
                children: messages.map((msg) {
                  return InkWell(
                    onTap: () => _openMessagesDialog(context, initialThread: msg),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 5, right: 10),
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: msg.isRead ? Colors.transparent : Colors.red,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(msg.title,
                                    style: GoogleFonts.kanit(
                                        fontWeight:
                                            msg.isRead ? FontWeight.normal : FontWeight.bold,
                                        color: Colors.black87),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                Text(msg.content,
                                    style: GoogleFonts.kanit(fontSize: 12, color: Colors.grey[600]),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: mainColor.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(msg.groupId,
                                          style: GoogleFonts.kanit(
                                              fontSize: 9,
                                              color: mainColor,
                                              fontWeight: FontWeight.w600)),
                                    ),
                                    if (msg.timestamp != null) ...[
                                      const SizedBox(width: 6),
                                      Text(DateFormat('dd. MMM HH:mm').format(msg.timestamp!),
                                          style: GoogleFonts.kanit(
                                              fontSize: 10, color: Colors.grey[400])),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMessagesCard(BuildContext context) {
    return StreamBuilder<int>(
      stream: context.read<GroupInformationRepository>().streamUnreadMessageCount(_groupIds),
      builder: (context, snapshot) {
        final unread = snapshot.data ?? 0;
        return InkWell(
          onTap: () => _openMessagesDialog(context),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: BoxDecoration(
              color: unread > 0 ? mainColor.withOpacity(0.1) : Colors.white.withOpacity(0.9),
              borderRadius: BorderRadius.circular(20),
              border: unread > 0 ? Border.all(color: mainColor.withOpacity(0.35), width: 1.5) : null,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.forum_outlined, color: mainColor, size: 28),
                    const Spacer(),
                    if (unread > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$unread',
                          style:
                              GoogleFonts.kanit(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
                Text(
                  'Beskeder',
                  style: GoogleFonts.kanit(fontSize: 14, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color,
      {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(20),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 28),
                if (onTap != null) ...[
                  const Spacer(),
                  Icon(Icons.arrow_forward, size: 14, color: color.withOpacity(0.5)),
                ],
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: GoogleFonts.kanit(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                Text(
                  title,
                  style: GoogleFonts.kanit(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMembersCard(BuildContext context) {
    return StreamBuilder<int>(
      stream: context.read<GroupInformationRepository>().streamUserCount(agencyCode),
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;
        return InkWell(
          onTap: onNavigateToUsers,
          borderRadius: BorderRadius.circular(20),
          child: Container(
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
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.people, color: Colors.purple, size: 28),
                    const Spacer(),
                    Icon(Icons.arrow_forward, size: 14, color: Colors.purple.withOpacity(0.5)),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count.toString(),
                      style: GoogleFonts.kanit(
                          fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                    Text(
                      'Antal medlemmer',
                      style: GoogleFonts.kanit(fontSize: 14, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
