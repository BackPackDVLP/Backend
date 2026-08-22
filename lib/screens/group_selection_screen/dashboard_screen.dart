import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/message_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:backend/screens/group_selection_screen/group_messages_dialog.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
  // Null when the caller's role lacks the matching permission
  // (trips.create / crm_integration.edit) — the corresponding action is
  // then hidden/disabled rather than just left to fail server-side.
  final VoidCallback? onCreateGroup;
  final VoidCallback? onOpenCrm;

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
    required this.onOpenCrm,
  });

  List<GroupInformation> get _trips =>
      groups.where((g) => g.isTemplate != true).toList();

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final trips = _trips;
    final totalTrips = trips.length;
    final upcomingTrips =
        trips.where((g) => g.departureDate.isAfter(now)).length;
    final activeTrips = trips
        .where(
            (g) => g.departureDate.isBefore(now) && g.returnDate.isAfter(now))
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
        padding: const EdgeInsets.all(AppSpacing.xxl),
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
                  const SizedBox(width: AppSpacing.xxl),
                  Expanded(flex: 2, child: messagesPreview),
                ],
              );
            }),
            _buildCrmSection(context),
          ],
        ),
      ),
    );
  }

  // Only shown once the bureau has actually activated the CRM integration
  // (agencyIntegrations/{agencyCode}.status == 'active') — before that, a
  // half-set-up integration has nothing worth surfacing on the dashboard,
  // and the tile in Bureau-indstillinger is where setup itself lives.
  Widget _buildCrmSection(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('agencyIntegrations')
          .doc(agencyCode)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        if (data == null || data['status'] != 'active') {
          return const SizedBox.shrink();
        }

        final recentEvents = ((data['recentEvents'] as List<dynamic>?) ?? [])
            .cast<Map<String, dynamic>>()
            .reversed
            .take(5)
            .toList();
        final crmTripsCreated =
            _trips.where((g) => g.groupId.startsWith('hubspot_')).length;
        final lastEventAt = recentEvents.isEmpty
            ? null
            : (recentEvents.first['occurredAt'] as Timestamp?)?.toDate();
        // Set by hubspotWebhook the moment it starts building a group from
        // a triggered deal, cleared when that deal is done processing
        // (success or failure) — so this reflects live, in-progress work,
        // not just the completed events in recentEvents.
        final processingDeals =
            ((data['processingDeals'] as List<dynamic>?) ?? [])
                .cast<String>();
        final isProcessing = processingDeals.isNotEmpty;

        return Padding(
          padding: const EdgeInsets.only(top: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader('CRM-integration', onSeeAll: onOpenCrm),
              const SizedBox(height: AppSpacing.lg),
              if (isProcessing) ...[
                _buildCrmProcessingBanner(processingDeals.length),
                const SizedBox(height: AppSpacing.lg),
              ],
              SizedBox(
                height: 200,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _buildStatCard(
                        'Rejser oprettet fra CRM',
                        crmTripsCreated.toString(),
                        Icons.sync_alt,
                        Colors.deepPurple,
                        onTap: onOpenCrm,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: _buildStatCard(
                        'Sidste synkronisering',
                        lastEventAt == null
                            ? 'Ingen endnu'
                            : DateFormat('dd. MMM HH:mm').format(lastEventAt),
                        Icons.hub_outlined,
                        Colors.orange,
                        onTap: onOpenCrm,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Seneste hændelser',
                      style: GoogleFonts.kanit(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: mainColor.withOpacity(0.85))),
                  const SizedBox(height: AppSpacing.md),
                  _buildPreviewCard(
                    child: recentEvents.isEmpty
                        ? _buildEmptyPreview('Ingen hændelser endnu')
                        : Column(
                            children: recentEvents.map((event) {
                              final success = event['success'] == true;
                              final occurredAt =
                                  (event['occurredAt'] as Timestamp?)
                                      ?.toDate();
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                child: Row(
                                  children: [
                                    Icon(
                                      success
                                          ? Icons.check_circle
                                          : Icons.error_outline,
                                      color:
                                          success ? Colors.green : Colors.red,
                                      size: 18,
                                    ),
                                    const SizedBox(width: AppSpacing.md),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                              event['dealName'] as String? ??
                                                  '',
                                              style: GoogleFonts.kanit(
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.black87),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis),
                                          Text(
                                              event['outcome'] as String? ??
                                                  '',
                                              style: GoogleFonts.kanit(
                                                  fontSize: 12,
                                                  color: Colors.grey[600]),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis),
                                        ],
                                      ),
                                    ),
                                    if (occurredAt != null)
                                      Text(
                                          DateFormat('dd. MMM HH:mm')
                                              .format(occurredAt),
                                          style: GoogleFonts.kanit(
                                              fontSize: 10,
                                              color: Colors.grey[400])),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
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
        const SizedBox(height: AppSpacing.sm),
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

  Widget _buildStatsGrid(BuildContext context, int totalTrips,
      int upcomingTrips, int activeTrips) {
    return SizedBox(
      height: 200,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _buildStatCard('Rejser i alt', totalTrips.toString(),
                Icons.groups, Colors.green,
                onTap: onNavigateToGroups),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: _buildStatCard('Kommende rejser', upcomingTrips.toString(),
                Icons.flight_takeoff, Colors.blue,
                onTap: onNavigateToGroups),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: _buildStatCard('Aktive rejser', activeTrips.toString(),
                Icons.beach_access, Colors.orange,
                onTap: onNavigateToGroups),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(child: _buildMembersCard(context)),
          const SizedBox(width: AppSpacing.lg),
          Expanded(child: _buildMessagesCard(context)),
        ],
      ),
    );
  }

  List<String> get _groupIds => groups.map((g) => g.groupId).toList();

  void _openMessagesDialog(BuildContext context,
      {GroupMessage? initialThread}) {
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
        if (onCreateGroup != null)
          _buildActionButton(
            icon: Icons.add,
            label: 'Ny rejse',
            onTap: onCreateGroup!,
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
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: mainColor),
      label: Text(label,
          style: GoogleFonts.kanit(
              fontWeight: FontWeight.w600, color: Colors.black87)),
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
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: mainColor.withOpacity(0.9))),
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
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: AppRadii.lgRadius,
        boxShadow: AppShadows.card,
      ),
      child: child,
    );
  }

  // Shown while hubspotWebhook is actively building one or more groups from
  // triggered deals (agencyIntegrations/{agencyCode}.processingDeals is
  // non-empty) — otherwise a bureau watching this section right after
  // moving a deal into the trigger stage sees nothing happen until the
  // trip suddenly appears, with no feedback in between.
  Widget _buildCrmProcessingBanner(int count) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.deepPurple.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: Colors.deepPurple),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              count == 1
                  ? 'Opretter rejse fra CRM …'
                  : 'Opretter $count rejser fra CRM …',
              style: GoogleFonts.kanit(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.deepPurple[700]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyPreview(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(text,
            style: GoogleFonts.kanit(color: Colors.grey[500], fontSize: 14)),
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
        const SizedBox(height: AppSpacing.lg),
        _buildPreviewCard(
          child: preview.isEmpty
              ? _buildEmptyPreview('Ingen kommende rejser')
              : Column(
                  children: preview.map((group) {
                    final isActive = group.departureDate.isBefore(now) &&
                        group.returnDate.isAfter(now);
                    return InkWell(
                      onTap: () => onSelectGroup(group),
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(
                                color: (isActive ? Colors.orange : mainColor)
                                    .withOpacity(0.1),
                                borderRadius: AppRadii.smRadius,
                              ),
                              child: Column(
                                children: [
                                  Text(
                                      DateFormat('dd')
                                          .format(group.departureDate),
                                      style: GoogleFonts.kanit(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                          color: isActive
                                              ? Colors.orange
                                              : mainColor)),
                                  Text(
                                      DateFormat('MMM', 'da_DK')
                                          .format(group.departureDate)
                                          .toUpperCase(),
                                      style: GoogleFonts.kanit(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 9,
                                          color: isActive
                                              ? Colors.orange
                                              : mainColor)),
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
                                          fontWeight: FontWeight.w600,
                                          color: Colors.black87),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  Text(
                                      isActive
                                          ? 'Rejse i gang'
                                          : '${group.members.length} medlemmer',
                                      style: GoogleFonts.kanit(
                                          fontSize: 12,
                                          color: isActive
                                              ? Colors.orange
                                              : Colors.grey[600])),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right,
                                color: Colors.grey[400], size: 20),
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
        const SizedBox(height: AppSpacing.lg),
        _buildPreviewCard(
          child: StreamBuilder<List<GroupMessage>>(
            stream: context
                .read<GroupInformationRepository>()
                .streamAllGroupMessages(_groupIds),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child:
                      Center(child: CircularProgressIndicator(strokeWidth: 2)),
                );
              }
              final messages = snapshot.data!.take(5).toList();
              if (messages.isEmpty) {
                return _buildEmptyPreview('Ingen beskeder endnu');
              }
              return Column(
                children: messages.map((msg) {
                  return InkWell(
                    onTap: () =>
                        _openMessagesDialog(context, initialThread: msg),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
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
                                color: msg.isRead
                                    ? Colors.transparent
                                    : Colors.red,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(msg.title,
                                    style: GoogleFonts.kanit(
                                        fontWeight: msg.isRead
                                            ? FontWeight.normal
                                            : FontWeight.bold,
                                        color: Colors.black87),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                Text(msg.content,
                                    style: GoogleFonts.kanit(
                                        fontSize: 12, color: Colors.grey[600]),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: AppSpacing.xs),
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
                                      Text(
                                          DateFormat('dd. MMM HH:mm')
                                              .format(msg.timestamp!),
                                          style: GoogleFonts.kanit(
                                              fontSize: 10,
                                              color: Colors.grey[400])),
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
      stream: context
          .read<GroupInformationRepository>()
          .streamUnreadMessageCount(_groupIds),
      builder: (context, snapshot) {
        final unread = snapshot.data ?? 0;
        return InkWell(
          onTap: () => _openMessagesDialog(context),
          borderRadius: AppRadii.lgRadius,
          child: Container(
            decoration: BoxDecoration(
              color: unread > 0
                  ? mainColor.withOpacity(0.1)
                  : Colors.white.withOpacity(0.9),
              borderRadius: AppRadii.lgRadius,
              border: unread > 0
                  ? Border.all(color: mainColor.withOpacity(0.35), width: 1.5)
                  : null,
              boxShadow: AppShadows.card,
            ),
            padding: const EdgeInsets.all(AppSpacing.xl),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: AppRadii.smRadius,
                        ),
                        child: Text(
                          '$unread',
                          style: GoogleFonts.kanit(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
                Text(
                  'Beskeder',
                  style:
                      GoogleFonts.kanit(fontSize: 14, color: Colors.grey[600]),
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
      borderRadius: AppRadii.lgRadius,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.9),
          borderRadius: AppRadii.lgRadius,
          boxShadow: AppShadows.card,
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
                  Icon(Icons.arrow_forward,
                      size: 14, color: color.withOpacity(0.5)),
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

  // Same count as the "Brugere" screen (UsersScreen), which streams
  // `users` docs matching this bureau via streamUserCount — kept as a
  // single source of truth instead of a second, possibly-diverging way of
  // counting members here.
  Widget _buildMembersCard(BuildContext context) {
    return StreamBuilder<int>(
      stream: context
          .read<GroupInformationRepository>()
          .streamUserCount(agencyCode),
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;
        return InkWell(
          onTap: onNavigateToUsers,
          borderRadius: AppRadii.lgRadius,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.9),
              borderRadius: AppRadii.lgRadius,
              boxShadow: AppShadows.card,
            ),
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.people, color: Colors.purple, size: 28),
                    const Spacer(),
                    Icon(Icons.arrow_forward,
                        size: 14, color: Colors.purple.withOpacity(0.5)),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count.toString(),
                      style: GoogleFonts.kanit(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87),
                    ),
                    Text(
                      'Antal medlemmer',
                      style: GoogleFonts.kanit(
                          fontSize: 14, color: Colors.grey[600]),
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
