import 'dart:async';

import 'package:backend/config/app_colors.dart';
import 'package:backend/models/agencyInformation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

/// HubSpot CRM integration wizard (generically CRM-labeled — the shell is
/// meant to outlive HubSpot as the only supported backend). Connect (OAuth)
/// → map fields → pick trigger + template → activate → status, wired to
/// the real Cloud Functions (startHubspotOAuth/hubspotOAuthCallback/
/// getHubspotConnectionSummary/fetchHubspotSchema/saveHubspotMapping/
/// hubspotWebhook) described in lib/config/hubspot_integration_notes.md.
class CrmIntegrationScreen extends StatefulWidget {
  final AgencyInformation agencyInfo;

  const CrmIntegrationScreen({super.key, required this.agencyInfo});

  @override
  State<CrmIntegrationScreen> createState() => _CrmIntegrationScreenState();
}

class _BackpackField {
  final String key;
  final String label;
  const _BackpackField(this.key, this.label);
}

// none: plain grey "Snart" treatment. badge: the pill itself is called out
// (amber, bold) but the rest of the chip stays neutral. card: the whole
// chip is called out, not just the badge — used for Attio so it visually
// stands apart from the plain "Snart" placeholders.
enum _CrmHighlight { none, badge, card }

class _CrmOption {
  final String key;
  final String label;
  // Shown on every chip, including HubSpot's — none of them should read as
  // "already connected" in this picker (see _buildCrmSelector).
  final String badge;
  final _CrmHighlight highlight;
  const _CrmOption(this.key, this.label, this.badge,
      {this.highlight = _CrmHighlight.none});
}

class _CrmIntegrationScreenState extends State<CrmIntegrationScreen> {
  static const List<_BackpackField> _dealFields = [
    _BackpackField('groupName', 'Gruppenavn'),
    _BackpackField('departureDate', 'Afrejsedato'),
    _BackpackField('returnDate', 'Hjemrejsedato'),
  ];
  // No 'memberName' here on purpose — HubSpot Contacts don't have a single
  // combined name property (only firstname/lastname), so there's nothing
  // to map it to. Member name is built server-side from firstname+lastname
  // instead — see hubspotWebhook in backpack/functions/src/index.ts.
  static const List<_BackpackField> _contactFields = [
    _BackpackField('memberEmail', 'Medlem – email'),
    _BackpackField('memberPhone', 'Medlem – telefon'),
  ];

  static const _steps = [
    'Forbind',
    'Kortlæg felter',
    'Vælg udløser',
    'Aktivér',
    'Status',
  ];
  static const _stepIcons = [
    Icons.link_rounded,
    Icons.swap_horiz_rounded,
    Icons.bolt_rounded,
    Icons.power_settings_new_rounded,
    Icons.monitor_heart_outlined,
  ];

  int _currentStep = 0;

  // Only 'hubspot' is wired to a real backend, and it stays the only
  // tappable/functional chip below. The rest are shown disabled so the
  // selector reads as "which CRM" rather than a dead-end single-item
  // choice, without claiming any of them is already live for a bureau to
  // just pick and go.
  static const List<_CrmOption> _supportedCrms = [
    _CrmOption('hubspot', 'HubSpot', ''),
    _CrmOption('attio', 'Attio', 'Ikke i din plan',
        highlight: _CrmHighlight.card),
    _CrmOption('pipedrive', 'Pipedrive', 'Snart'),
    _CrmOption('salesforce', 'Salesforce', 'Snart'),
  ];
  String _selectedCrm = 'hubspot';

  bool _isConnectingOAuth = false;
  String? _oauthError;
  bool _isLoadingSummary = false;
  int? _contactCount;
  int? _dealCount;

  bool _isLoadingSchema = false;
  List<Map<String, String>> _dealProperties = [];
  List<Map<String, String>> _contactProperties = [];
  List<Map<String, dynamic>> _pipelines = [];

  List<Map<String, String>> _templates = [];
  String? _selectedPipelineId;
  String? _selectedStageId;
  String? _selectedTemplateGroupId;

  bool _isSaving = false;
  String? _saveError;
  bool _isDisconnecting = false;

  late final Stream<DocumentSnapshot> _integrationStream;

  final Map<String, String?> _fieldMapping = {
    for (final f in [..._dealFields, ..._contactFields]) f.key: null,
  };

  @override
  void initState() {
    super.initState();
    _integrationStream = FirebaseFirestore.instance
        .collection('agencyIntegrations')
        .doc(_agencyCode)
        .snapshots();
    _loadTemplates();
    _restoreSavedMapping();
  }

  String get _agencyCode => widget.agencyInfo.agencyCode;

  String _objectTypeForField(String key) =>
      _dealFields.any((f) => f.key == key) ? 'deal' : 'contact';

  Future<void> _loadTemplates() async {
    final snap = await FirebaseFirestore.instance
        .collection('groups')
        .where('agencyCode', isEqualTo: _agencyCode)
        .where('isTemplate', isEqualTo: true)
        .get();
    if (!mounted) return;
    setState(() {
      _templates = snap.docs
          .map((d) => {
                'id': d.id,
                'name': (d.data()['groupName'] as String?) ?? d.id,
              })
          .toList();
    });
  }

  // Restores a previously saved field mapping/trigger/template — a
  // one-time load at screen-open, distinct from the live connection status
  // (streamed below), which reacts continuously instead.
  Future<void> _restoreSavedMapping() async {
    final doc = await FirebaseFirestore.instance
        .collection('agencyIntegrations')
        .doc(_agencyCode)
        .get();
    if (!mounted || !doc.exists) return;
    final data = doc.data() ?? {};
    setState(() {
      _selectedPipelineId = data['triggerPipelineId'] as String?;
      _selectedStageId = data['triggerStageId'] as String?;
      _selectedTemplateGroupId = data['templateGroupId'] as String?;
      for (final m in (data['fieldMappings'] as List<dynamic>? ?? [])) {
        final map = Map<String, dynamic>.from(m as Map);
        _fieldMapping[map['backpackField'] as String] =
            map['hubspotProperty'] as String?;
      }
    });
  }

  // Kicks off the OAuth flow: gets HubSpot's authorize URL from our
  // backend, then opens it in a new tab. The bureau owner logs into their
  // own HubSpot account and grants access there — never touching a token,
  // a client secret, or HubSpot's developer tooling. This screen doesn't
  // need to do anything else: agencyIntegrations/{agencyCode}'s status
  // flips to 'connected' server-side once they finish, and every part of
  // this wizard already reacts live to that document.
  Future<void> _connectToHubspot() async {
    setState(() {
      _isConnectingOAuth = true;
      _oauthError = null;
    });
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('startHubspotOAuth')
          .call({'agencyCode': _agencyCode});
      final data = result.data as Map<dynamic, dynamic>;
      final authorizeUrl = data['authorizeUrl'] as String?;
      if (authorizeUrl == null) {
        throw Exception('Intet link modtaget fra serveren');
      }
      final launched = await launchUrl(Uri.parse(authorizeUrl),
          mode: LaunchMode.externalApplication);
      if (!launched) {
        throw Exception('Kunne ikke åbne linket');
      }
      if (!mounted) return;
      setState(() => _isConnectingOAuth = false);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _oauthError = e.message ?? 'Kunne ikke starte forbindelsen';
        _isConnectingOAuth = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _oauthError = 'Der skete en fejl';
        _isConnectingOAuth = false;
      });
    }
  }

  Future<void> _loadConnectionSummary() async {
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('getHubspotConnectionSummary')
          .call({'agencyCode': _agencyCode});
      final data = result.data as Map<dynamic, dynamic>;
      if (!mounted) return;
      setState(() {
        _contactCount = (data['contactCount'] as num?)?.toInt() ?? 0;
        _dealCount = (data['dealCount'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      // Non-critical — the connection itself already succeeded server-side;
      // the chip just won't show counts this time.
    }
  }

  Future<void> _loadSchema() async {
    setState(() => _isLoadingSchema = true);
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('fetchHubspotSchema')
          .call({'agencyCode': _agencyCode});
      final data = result.data as Map<dynamic, dynamic>;
      if (!mounted) return;
      setState(() {
        _dealProperties = (data['dealProperties'] as List<dynamic>? ?? [])
            .map((p) => Map<String, String>.from(p as Map))
            .toList();
        _contactProperties = (data['contactProperties'] as List<dynamic>? ?? [])
            .map((p) => Map<String, String>.from(p as Map))
            .toList();
        _pipelines = (data['pipelines'] as List<dynamic>? ?? [])
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList();
        _isLoadingSchema = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingSchema = false);
    }
  }

  Future<void> _saveMapping({required bool activate}) async {
    if (_selectedPipelineId == null ||
        _selectedStageId == null ||
        _selectedTemplateGroupId == null) {
      setState(() => _saveError = 'Vælg pipeline, trin og skabelon først');
      return;
    }
    setState(() {
      _isSaving = true;
      _saveError = null;
    });
    try {
      final fieldMappings =
          _fieldMapping.entries.where((e) => e.value != null).map((e) {
        final objectType = _objectTypeForField(e.key);
        final properties =
            objectType == 'deal' ? _dealProperties : _contactProperties;
        final propertyType = properties.firstWhere(
          (p) => p['name'] == e.value,
          orElse: () => const {},
        )['type'];
        return {
          'backpackField': e.key,
          'hubspotObjectType': objectType,
          'hubspotProperty': e.value,
          // The property's HubSpot type (e.g. "date"/"datetime"), so
          // the webhook can convert its value correctly regardless of
          // which HubSpot field widget was mapped.
          'hubspotFieldType': propertyType,
        };
      }).toList();
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('saveHubspotMapping')
          .call({
        'agencyCode': _agencyCode,
        'fieldMappings': fieldMappings,
        'triggerPipelineId': _selectedPipelineId,
        'triggerStageId': _selectedStageId,
        'templateGroupId': _selectedTemplateGroupId,
        'activate': activate,
      });
      if (!mounted) return;
      setState(() => _isSaving = false);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _saveError = e.message ?? 'Kunne ikke gemme';
        _isSaving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saveError = 'Der skete en fejl';
        _isSaving = false;
      });
    }
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Afbryd forbindelse til HubSpot?',
            style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
        content: Text(
          'Integrationen holder op med at oprette grupper automatisk, indtil I forbinder igen. Jeres kortlægning, udløser og skabelon gemmes.',
          style: GoogleFonts.kanit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuller'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Afbryd', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      unawaited(_disconnectHubspot());
    }
  }

  Future<void> _disconnectHubspot() async {
    setState(() => _isDisconnecting = true);
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('disconnectHubspot')
          .call({'agencyCode': _agencyCode});
      if (!mounted) return;
      setState(() {
        _isDisconnecting = false;
        _contactCount = null;
        _dealCount = null;
        _dealProperties = [];
        _contactProperties = [];
        _pipelines = [];
      });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Forbindelsen er afbrudt')));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _isDisconnecting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.message ?? 'Kunne ikke afbryde forbindelsen')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _isDisconnecting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Der skete en fejl')));
    }
  }

  void _goTo(int step) {
    setState(() => _currentStep = step.clamp(0, _steps.length - 1));
  }

  // Readable text/icon color for content placed on top of a `themeColor`
  // fill. `themeColor` is each agency's own brand color and can be light or
  // dark, so this can't be a fixed value — AppColors.onPrimary doesn't work
  // here since it tracks a separate global that this screen never sets.
  Color _onThemeColor(Color color) =>
      color.computeLuminance() < 0.5 ? Colors.white : Colors.black;

  @override
  Widget build(BuildContext context) {
    final themeColor = AppColors.fromHex(widget.agencyInfo.mainColor);
    final currentUid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F5F7),
      appBar: AppBar(
        title: Text('CRM-integration',
            style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
        backgroundColor: themeColor,
        foregroundColor: _onThemeColor(themeColor),
        elevation: 0,
        centerTitle: true,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        // The caller's own admins/{uid} doc — always readable by them (see
        // firestore.rules), unlike a collection query scoped to just this
        // agencyCode, which a BACKPACK-ADMIN's doc wouldn't match unless
        // they also happened to own *this* bureau directly.
        stream: currentUid == null
            ? const Stream.empty()
            : FirebaseFirestore.instance
                .collection('admins')
                .doc(currentUid)
                .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          final agencyCodes =
              List<String>.from(data?['agencyCodes'] as List? ?? []);
          final isSuperAdmin = agencyCodes.contains('BACKPACK-ADMIN');
          final isOwnerHere =
              data?['role'] == 'owner' && agencyCodes.contains(_agencyCode);
          final canEdit = isSuperAdmin || isOwnerHere;
          if (!canEdit) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline, size: 36, color: Colors.grey[400]),
                    const SizedBox(height: 12),
                    Text(
                      'Kun bureauets ejer kan konfigurere CRM-integrationen.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.kanit(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            );
          }
          return StreamBuilder<DocumentSnapshot>(
            stream: _integrationStream,
            builder: (context, integrationSnapshot) {
              final integrationData =
                  integrationSnapshot.data?.data() as Map<String, dynamic>?;
              final status = integrationData?['status'] as String? ?? 'idle';
              final connected = status == 'connected' || status == 'active';
              final recentEvents =
                  integrationData?['recentEvents'] as List<dynamic>? ?? [];

              // React to the connection completing (possibly in a
              // different browser tab, via the OAuth redirect) by loading
              // the data the later steps need, exactly once per flip. The
              // flag mutations here are plain (no setState) so they're safe
              // during build; the actual loads — which do call setState —
              // are deferred to after this frame finishes.
              if (connected && !_isLoadingSummary && _contactCount == null) {
                _isLoadingSummary = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) unawaited(_loadConnectionSummary());
                });
              }
              if (connected &&
                  !_isLoadingSchema &&
                  _dealProperties.isEmpty &&
                  _contactProperties.isEmpty) {
                _isLoadingSchema = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) unawaited(_loadSchema());
                });
              }

              return Column(
                children: [
                  _buildStatusStrip(themeColor, status),
                  _buildStepIndicator(themeColor),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                                    begin: const Offset(0, 0.02),
                                    end: Offset.zero)
                                .animate(animation),
                            child: child,
                          ),
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(_currentStep),
                          child: _buildStepContent(themeColor,
                              connected: connected,
                              status: status,
                              recentEvents: recentEvents),
                        ),
                      ),
                    ),
                  ),
                  _buildNavButtons(themeColor, connected: connected),
                ],
              );
            },
          );
        },
      ),
    );
  }

  // Slim live status pill — gives at-a-glance context regardless of which
  // step you're on.
  Widget _buildStatusStrip(Color themeColor, String status) {
    late Color color;
    late IconData icon;
    late String label;
    switch (status) {
      case 'active':
        color = Colors.green;
        icon = Icons.check_circle;
        label = 'Integration aktiv';
        break;
      case 'connected':
        color = Colors.orange[700]!;
        icon = Icons.pending_outlined;
        label = 'Forbundet — ikke aktiveret endnu';
        break;
      default:
        color = Colors.grey[500]!;
        icon = Icons.radio_button_unchecked;
        label = 'Ikke forbundet endnu';
    }
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: GoogleFonts.kanit(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: themeColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('HubSpot',
                style: GoogleFonts.kanit(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: themeColor)),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(Color themeColor) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      child: Row(
        children: List.generate(_steps.length, (i) {
          final isActive = i == _currentStep;
          final isDone = i < _currentStep;
          return Expanded(
            child: GestureDetector(
              onTap: () => _goTo(i),
              behavior: HitTestBehavior.opaque,
              child: Column(
                children: [
                  Row(
                    children: [
                      if (i > 0)
                        Expanded(
                          child: Container(
                            height: 2,
                            color: isDone || isActive
                                ? themeColor
                                : Colors.grey[300],
                          ),
                        ),
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDone || isActive ? themeColor : Colors.white,
                          border: Border.all(
                            color: isDone || isActive
                                ? themeColor
                                : Colors.grey[300]!,
                            width: 1.5,
                          ),
                          boxShadow: isActive
                              ? [
                                  BoxShadow(
                                    color: themeColor.withValues(alpha: 0.35),
                                    blurRadius: 8,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: isDone
                            ? const Icon(Icons.check,
                                size: 15, color: Colors.white)
                            : Icon(_stepIcons[i],
                                size: 14,
                                color:
                                    isActive ? Colors.white : Colors.grey[400]),
                      ),
                      if (i < _steps.length - 1)
                        Expanded(
                          child: Container(
                            height: 2,
                            color: isDone ? themeColor : Colors.grey[300],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _steps[i],
                    textAlign: TextAlign.center,
                    style: GoogleFonts.kanit(
                        fontSize: 11,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w400,
                        color: isActive ? Colors.black87 : Colors.grey[500]),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildStepContent(
    Color themeColor, {
    required bool connected,
    required String status,
    required List<dynamic> recentEvents,
  }) {
    switch (_currentStep) {
      case 0:
        return _buildConnectStep(themeColor, connected: connected);
      case 1:
        return _buildMappingStep(themeColor);
      case 2:
        return _buildTriggerStep(themeColor);
      case 3:
        return _buildActivateStep(themeColor,
            connected: connected, status: status);
      default:
        return _buildStatusStep(themeColor,
            status: status, recentEvents: recentEvents);
    }
  }

  Widget _card({required Widget child, EdgeInsetsGeometry? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _stepHeading(String title, String subtitle,
      {IconData? icon, Color? iconColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: (iconColor ?? Colors.grey).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: iconColor ?? Colors.grey[700], size: 20),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.kanit(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: GoogleFonts.kanit(
                        fontSize: 13, color: Colors.grey[600])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Text(text.toUpperCase(),
          style: GoogleFonts.kanit(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: Colors.grey[400])),
    );
  }

  // Step 1 — Connect (OAuth) ---------------------------------------------

  Widget _buildConnectStep(Color themeColor, {required bool connected}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Forbind til jeres CRM',
            'Vælg hvilket CRM I bruger, og log ind for at give BackPack adgang.',
            icon: Icons.link_rounded, iconColor: themeColor),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('CRM-system'),
              _buildCrmSelector(themeColor),
              const SizedBox(height: 20),
              if (connected) ...[
                _statusChip(
                  icon: Icons.check_circle,
                  color: Colors.green,
                  text: _contactCount != null && _dealCount != null
                      ? 'Forbundet — fundet $_contactCount kontakter og $_dealCount aftaler.'
                      : 'Forbundet til HubSpot.',
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _isConnectingOAuth ? null : _connectToHubspot,
                    icon: _isConnectingOAuth
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _onThemeColor(themeColor)))
                        : const Icon(Icons.open_in_new, size: 18),
                    label: Text('Forbind til HubSpot',
                        style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
                      foregroundColor: _onThemeColor(themeColor),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Åbner HubSpot i en ny fane. Log ind og godkend adgangen — denne side opdaterer sig selv, når I er forbundet.',
                  style: GoogleFonts.kanit(
                      fontSize: 11.5, color: Colors.grey[500]),
                ),
                if (_oauthError != null) ...[
                  const SizedBox(height: 14),
                  _statusChip(
                    icon: Icons.error_outline,
                    color: Colors.red,
                    text: _oauthError!,
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  static const Color _highlightBg = Color(0xFFFFF4E5);
  static const Color _highlightBorder = Color(0xFFFFB74D);
  static const Color _highlightText = Color(0xFF9A6700);

  Widget _buildCrmSelector(Color themeColor) {
    // IntrinsicHeight + stretch so every chip matches the tallest one
    // (Attio/Pipedrive/Salesforce's badge line) even though HubSpot's has
    // no badge and would otherwise render shorter.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _supportedCrms.map((c) {
          final isSelected = _selectedCrm == c.key;
          final isEnabled = c.key == 'hubspot';
          final isLast = c.key == _supportedCrms.last.key;
          final isBadgeHighlighted = c.highlight != _CrmHighlight.none;
          final isCardHighlighted = c.highlight == _CrmHighlight.card;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: isLast ? 0 : 10),
              child: GestureDetector(
                onTap: isEnabled
                    ? () => setState(() => _selectedCrm = c.key)
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding:
                      const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? themeColor.withValues(alpha: 0.08)
                        : (isCardHighlighted ? _highlightBg : Colors.grey[50]),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected
                          ? themeColor
                          : (isCardHighlighted
                              ? _highlightBorder
                              : Colors.grey[300]!),
                      width: isSelected || isCardHighlighted ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.hub_rounded,
                          size: 22,
                          color: isCardHighlighted
                              ? _highlightText
                              : (!isEnabled
                                  ? Colors.grey[300]
                                  : (isSelected
                                      ? themeColor
                                      : Colors.grey[500]))),
                      const SizedBox(height: 6),
                      Text(c.label,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.kanit(
                              fontSize: 11,
                              fontWeight: isCardHighlighted
                                  ? FontWeight.w700
                                  : (isSelected
                                      ? FontWeight.w600
                                      : FontWeight.w500),
                              color: isCardHighlighted
                                  ? Colors.black87
                                  : (isEnabled
                                      ? Colors.black87
                                      : Colors.grey[400]))),
                      if (c.badge.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isBadgeHighlighted
                                ? _highlightBg
                                : Colors.grey[200],
                            borderRadius: BorderRadius.circular(20),
                            border: isBadgeHighlighted
                                ? Border.all(color: _highlightBorder, width: 1)
                                : null,
                          ),
                          child: Text(c.badge,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.kanit(
                                  fontSize: 9,
                                  fontWeight: isBadgeHighlighted
                                      ? FontWeight.w700
                                      : FontWeight.normal,
                                  color: isBadgeHighlighted
                                      ? _highlightText
                                      : Colors.grey[500])),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // Step 2 — Field mapping ----------------------------------------------

  Widget _buildMappingStep(Color themeColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Kortlæg felter',
            'Vælg hvilket felt fra HubSpot der skal udfylde hvert BackPack-felt.',
            icon: Icons.swap_horiz_rounded, iconColor: themeColor),
        if (_isLoadingSchema)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator()))
        else ...[
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel('Aftalefelter'),
                for (final field in _dealFields)
                  _buildMappingRow(field, _dealProperties),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel('Kontaktfelter'),
                for (final field in _contactFields)
                  _buildMappingRow(field, _contactProperties),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMappingRow(
      _BackpackField field, List<Map<String, String>> options) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFB),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 128,
              child: Text(field.label,
                  style: GoogleFonts.kanit(
                      fontSize: 13, fontWeight: FontWeight.w500)),
            ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: Colors.grey[200],
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child:
                  Icon(Icons.arrow_forward, size: 12, color: Colors.grey[600]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _fieldMapping[field.key],
                isExpanded: true,
                style: GoogleFonts.kanit(fontSize: 13, color: Colors.black87),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                ),
                hint: Text('Vælg HubSpot-felt',
                    style: GoogleFonts.kanit(
                        fontSize: 13, color: Colors.grey[500])),
                items: options
                    .map((p) => DropdownMenuItem(
                        value: p['name'],
                        child: Text(p['label'] ?? p['name'] ?? '',
                            overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: (value) =>
                    setState(() => _fieldMapping[field.key] = value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Step 3 — Trigger + template ------------------------------------------

  Widget _buildTriggerStep(Color themeColor) {
    final pipeline = _pipelines.firstWhere(
        (p) => p['id'] == _selectedPipelineId,
        orElse: () => const {});
    final stages = (pipeline['stages'] as List<dynamic>? ?? []);
    final selectedTemplateName = _selectedTemplateGroupId == null
        ? null
        : _templates.firstWhere((t) => t['id'] == _selectedTemplateGroupId,
            orElse: () => {'name': _selectedTemplateGroupId!})['name'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Vælg udløser og skabelon',
            'Vælg hvilket trin i jeres HubSpot-pipeline der opretter en ny gruppe, og hvilken af jeres egne skabeloner den skal bygges ud fra.',
            icon: Icons.bolt_rounded, iconColor: themeColor),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('Udløser'),
              Text('Pipeline',
                  style: GoogleFonts.kanit(
                      fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              _buildIdDropdown(
                value: _selectedPipelineId,
                items: _pipelines
                    .map((p) => MapEntry(p['id'] as String,
                        p['label'] as String? ?? p['id'] as String))
                    .toList(),
                onChanged: (v) => setState(() {
                  _selectedPipelineId = v;
                  _selectedStageId = null;
                }),
                hint: 'Vælg pipeline',
              ),
              const SizedBox(height: 16),
              Text('Trin der udløser gruppeoprettelse',
                  style: GoogleFonts.kanit(
                      fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              _buildIdDropdown(
                value: _selectedStageId,
                items: stages
                    .map((s) => MapEntry(s['id'] as String,
                        s['label'] as String? ?? s['id'] as String))
                    .toList(),
                onChanged: (v) => setState(() => _selectedStageId = v),
                hint: 'Vælg trin',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('Skabelon der skal duplikeres'),
              _buildIdDropdown(
                value: _selectedTemplateGroupId,
                items: _templates
                    .map((t) => MapEntry(t['id']!, t['name']!))
                    .toList(),
                onChanged: (v) => setState(() => _selectedTemplateGroupId = v),
                hint: _templates.isEmpty
                    ? 'Ingen skabeloner oprettet endnu'
                    : 'Vælg skabelon',
              ),
              if (selectedTemplateName != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: themeColor.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.copy_all_rounded, size: 16, color: themeColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            'Nye grupper bygges ud fra "$selectedTemplateName"',
                            style: GoogleFonts.kanit(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: themeColor)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // Step 4 — Activate -----------------------------------------------------

  String _triggerSummaryLabel() {
    final pipeline = _pipelines.firstWhere(
        (p) => p['id'] == _selectedPipelineId,
        orElse: () => {'label': _selectedPipelineId});
    final stages = (pipeline['stages'] as List<dynamic>? ?? []);
    final stage = stages.firstWhere((s) => s['id'] == _selectedStageId,
        orElse: () => {'label': _selectedStageId});
    return '${pipeline['label']} → ${stage['label']}';
  }

  Widget _checklistRow(String label, String value, {required bool complete}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            complete ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
            color: complete ? Colors.green : Colors.grey[350],
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 110,
            child: Text(label,
                style:
                    GoogleFonts.kanit(fontSize: 13, color: Colors.grey[600])),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.kanit(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: complete ? Colors.black87 : Colors.grey[400])),
          ),
        ],
      ),
    );
  }

  Widget _buildActivateStep(Color themeColor,
      {required bool connected, required String status}) {
    final mappedCount = _fieldMapping.values.where((v) => v != null).length;
    final allMapped = mappedCount == _fieldMapping.length;
    final hasTrigger = _selectedPipelineId != null && _selectedStageId != null;
    final activated = status == 'active';
    final templateName = _selectedTemplateGroupId == null
        ? 'Ikke valgt'
        : _templates.firstWhere((t) => t['id'] == _selectedTemplateGroupId,
            orElse: () => {'name': _selectedTemplateGroupId!})['name']!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Aktivér integrationen',
            'Gennemgå jeres opsætning, og slå integrationen til.',
            icon: Icons.power_settings_new_rounded, iconColor: themeColor),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _checklistRow(
                  'Forbindelse', connected ? 'Forbundet' : 'Ikke forbundet',
                  complete: connected),
              _checklistRow(
                  'Felter kortlagt', '$mappedCount / ${_fieldMapping.length}',
                  complete: allMapped),
              _checklistRow(
                  'Udløser', hasTrigger ? _triggerSummaryLabel() : 'Ikke valgt',
                  complete: hasTrigger),
              _checklistRow('Skabelon', templateName,
                  complete: _selectedTemplateGroupId != null),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: themeColor.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: themeColor.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Aktivér integration',
                            style: GoogleFonts.kanit(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(
                            'Nye aftaler begynder at oprette grupper automatisk',
                            style: GoogleFonts.kanit(
                                fontSize: 11.5, color: Colors.grey[600])),
                      ],
                    ),
                  ),
                  Switch(
                    value: activated,
                    activeThumbColor: themeColor,
                    onChanged:
                        _isSaving ? null : (v) => _saveMapping(activate: v),
                  ),
                ],
              ),
              if (_isSaving) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
              ],
              if (_saveError != null) ...[
                const SizedBox(height: 12),
                _statusChip(
                    icon: Icons.error_outline,
                    color: Colors.red,
                    text: _saveError!),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // Step 5 — Status ---------------------------------------------------------

  Widget _buildStatusStep(Color themeColor,
      {required String status, required List<dynamic> recentEvents}) {
    final isActive = status == 'active';
    final events = recentEvents.reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Status og fejlfinding',
            'Se seneste hændelser, og fejlfind hvis noget ikke opfører sig som forventet.',
            icon: Icons.monitor_heart_outlined, iconColor: themeColor),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isActive ? Icons.check_circle : Icons.pause_circle_outline,
                    color: isActive ? Colors.green : Colors.grey,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(isActive ? 'Aktiv' : 'Inaktiv',
                      style: GoogleFonts.kanit(
                          fontWeight: FontWeight.w600,
                          color:
                              isActive ? Colors.green[700] : Colors.grey[700])),
                ],
              ),
              const SizedBox(height: 16),
              if (events.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      Icon(Icons.hourglass_empty,
                          size: 26, color: Colors.grey[300]),
                      const SizedBox(height: 8),
                      Text('Ingen hændelser endnu.',
                          style: GoogleFonts.kanit(
                              fontSize: 12, color: Colors.grey[500])),
                    ],
                  ),
                )
              else
                ...events.map((e) {
                  final map = Map<String, dynamic>.from(e as Map);
                  final success = map['success'] == true;
                  final occurredAt =
                      (map['occurredAt'] as Timestamp?)?.toDate();
                  final color = success ? Colors.green : Colors.red;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border(left: BorderSide(color: color, width: 3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          success ? Icons.check_circle : Icons.error,
                          size: 17,
                          color: color,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(map['dealName'] as String? ?? '',
                                  style: GoogleFonts.kanit(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                              Text(map['outcome'] as String? ?? '',
                                  style: GoogleFonts.kanit(
                                      fontSize: 12, color: Colors.grey[600])),
                            ],
                          ),
                        ),
                        if (occurredAt != null)
                          Text(DateFormat('d/M HH:mm').format(occurredAt),
                              style: GoogleFonts.kanit(
                                  fontSize: 11, color: Colors.grey[400])),
                      ],
                    ),
                  );
                }),
              Text('Kun de seneste 20 hændelser vises her.',
                  style:
                      GoogleFonts.kanit(fontSize: 11, color: Colors.grey[400])),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Afbryd forbindelsen',
                  style: GoogleFonts.kanit(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                'Stopper integrationen og fjerner adgangen til jeres HubSpot-konto. Jeres kortlægning, udløser og skabelon gemmes, så I hurtigt kan forbinde igen.',
                style:
                    GoogleFonts.kanit(fontSize: 11.5, color: Colors.grey[600]),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _isDisconnecting ? null : _confirmDisconnect,
                  icon: _isDisconnecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.link_off, size: 18),
                  label: Text('Afbryd forbindelse til HubSpot',
                      style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: BorderSide(color: Colors.red.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Shared helpers ----------------------------------------------------------

  Widget _statusChip(
      {required IconData icon, required Color color, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: GoogleFonts.kanit(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }

  Widget _buildIdDropdown({
    required String? value,
    required List<MapEntry<String, String>> items,
    required ValueChanged<String?> onChanged,
    required String hint,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      style: GoogleFonts.kanit(fontSize: 13, color: Colors.black87),
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.grey[50],
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
      ),
      hint: Text(hint,
          style: GoogleFonts.kanit(fontSize: 13, color: Colors.grey[500])),
      items: items
          .map((e) => DropdownMenuItem(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis)))
          .toList(),
      onChanged: onChanged,
    );
  }

  Widget _buildNavButtons(Color themeColor, {required bool connected}) {
    final isFirst = _currentStep == 0;
    final isLast = _currentStep == _steps.length - 1;
    final canProceed = _currentStep != 0 || connected;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Trin ${_currentStep + 1} af ${_steps.length}',
                style:
                    GoogleFonts.kanit(fontSize: 11, color: Colors.grey[400])),
          ),
          Row(
            children: [
              if (!isFirst)
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _goTo(_currentStep - 1),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('Tilbage',
                        style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                  ),
                ),
              if (!isFirst) const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: isLast
                      ? () => Navigator.of(context).pop()
                      : (canProceed ? () => _goTo(_currentStep + 1) : null),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: themeColor,
                    foregroundColor: _onThemeColor(themeColor),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(isLast ? 'Luk' : 'Næste',
                      style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
