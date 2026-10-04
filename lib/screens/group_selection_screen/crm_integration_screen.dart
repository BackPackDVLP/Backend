import 'dart:async';
import 'package:backend/config/design.dart';

import 'package:backend/config/app_colors.dart';
import 'package:backend/models/agencyInformation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:backend/widget/app_snackbar.dart';

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

// Which HubSpot object a mapped BackPack field, or a rule condition, reads
// from — 'deal', 'contact', or a custom object's objectTypeId. Kept next to
// the property name so the same BackPack field/rule can be re-pointed at a
// different source without losing track of where its value came from.
class _MappedValue {
  final String hubspotObjectType;
  final String hubspotProperty;
  const _MappedValue(this.hubspotObjectType, this.hubspotProperty);
}

// A tab in Step 2's source picker: Deal, Contact, or one bureau-enabled
// custom object.
class _MappingSource {
  final String hubspotObjectType;
  final String label;
  const _MappingSource(this.hubspotObjectType, this.label);
}

class _CustomObjectType {
  final String id;
  final String label;
  const _CustomObjectType(this.id, this.label);
}

// One "IF [property] [operator] [value] THEN template" rule. Mirrors
// TemplateRule/TemplateRuleCondition in backpack/functions/src/index.ts.
class _RuleCondition {
  String? hubspotObjectType;
  String? hubspotProperty;
  String operator;
  // Raw text; comma-separated when operator == 'in', unused for
  // is_not_empty.
  String value;
  _RuleCondition({
    this.hubspotObjectType,
    this.hubspotProperty,
    this.operator = 'equals',
    this.value = '',
  });
}

class _TemplateRule {
  final String id;
  String label;
  _RuleCondition condition;
  String? templateGroupId;
  _TemplateRule({
    required this.id,
    this.label = '',
    _RuleCondition? condition,
    this.templateGroupId,
  }) : condition = condition ?? _RuleCondition();
}

class _CrmIntegrationScreenState extends State<CrmIntegrationScreen> {
  // Group-level BackPack fields — fillable from the Deal or from any
  // enabled custom object (a bureau's departure date might live on a
  // "Booking" custom object rather than the deal itself).
  static const List<_BackpackField> _groupLevelFields = [
    _BackpackField('groupName', 'Gruppenavn'),
    _BackpackField('departureDate', 'Afrejsedato'),
    _BackpackField('returnDate', 'Hjemrejsedato'),
  ];
  // No 'memberName' here on purpose — HubSpot Contacts don't have a single
  // combined name property (only firstname/lastname), so there's nothing
  // to map it to. Member name is built server-side from firstname+lastname
  // instead — see hubspotWebhook in backpack/functions/src/index.ts. Member
  // fields stay Contact-only — members are structurally built from the
  // deal's associated contacts, not from custom objects.
  static const List<_BackpackField> _contactFields = [
    _BackpackField('memberEmail', 'Medlem – email'),
    _BackpackField('memberPhone', 'Medlem – telefon'),
  ];

  static const Map<String, String> _operatorLabels = {
    'equals': 'Er lig med',
    'not_equals': 'Er ikke lig med',
    'in': 'Er en af',
    'is_not_empty': 'Er udfyldt',
  };

  static const _steps = [
    'Forbindelse',
    'Mapping',
    'Udløser',
    'Aktivering',
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
  List<_CustomObjectType> _customObjectTypes = [];

  // Which custom object types the bureau has turned on as a mapping/rule
  // source, and their fetched property lists (fetched lazily, only for
  // enabled types — a portal can have many custom object types a given
  // bureau never uses).
  Set<String> _enabledCustomObjectTypeIds = {};
  final Map<String, List<Map<String, String>>> _customObjectProperties = {};
  final Set<String> _loadingCustomObjectTypeIds = {};
  int _selectedSourceTabIndex = 0;

  List<Map<String, String>> _templates = [];
  String? _selectedPipelineId;
  String? _selectedStageId;
  String? _defaultTemplateGroupId;
  List<_TemplateRule> _templateRules = [];

  // 'notes' (default) preserves the original hardcoded behavior — every
  // Note attachment on the deal. 'property' pulls from one specific
  // HubSpot property instead (_documentSourceProperty).
  String _documentSourceMode = 'notes';
  _MappedValue? _documentSourceProperty;
  // Off by default — see the warning copy in _buildMessageSyncCard for why.
  bool _messageSyncEnabled = false;
  // Off by default — two-way HubSpot Conversations Inbox sync, separate
  // mechanism/scope from _messageSyncEnabled above. See the warning copy in
  // _buildConversationSyncCard for the privacy trade-off.
  bool _conversationSyncEnabled = false;

  bool _isSaving = false;
  String? _saveError;
  bool _isDisconnecting = false;

  late final Stream<DocumentSnapshot> _integrationStream;

  final Map<String, _MappedValue?> _fieldMapping = {
    for (final f in [..._groupLevelFields, ..._contactFields]) f.key: null,
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

  String _newRuleId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_templateRules.length}';

  List<Map<String, String>> _propertiesForSource(String hubspotObjectType) {
    if (hubspotObjectType == 'deal') return _dealProperties;
    if (hubspotObjectType == 'contact') return _contactProperties;
    return _customObjectProperties[hubspotObjectType] ??
        const <Map<String, String>>[];
  }

  String _customObjectLabel(String id) {
    return _customObjectTypes
        .firstWhere((t) => t.id == id, orElse: () => _CustomObjectType(id, id))
        .label;
  }

  String _sourceLabel(String hubspotObjectType) {
    if (hubspotObjectType == 'deal') return 'Aftale';
    if (hubspotObjectType == 'contact') return 'Kontakt';
    return _customObjectLabel(hubspotObjectType);
  }

  List<_MappingSource> _mappingSources() {
    return [
      const _MappingSource('deal', 'Aftale'),
      const _MappingSource('contact', 'Kontakt'),
      for (final id in _enabledCustomObjectTypeIds)
        _MappingSource(id, _customObjectLabel(id)),
    ];
  }

  String _propertyLabelFor(String? hubspotObjectType, String? hubspotProperty) {
    if (hubspotObjectType == null || hubspotProperty == null) return '?';
    final match = _propertiesForSource(hubspotObjectType)
        .firstWhere((p) => p['name'] == hubspotProperty,
            orElse: () => {'label': hubspotProperty});
    return match['label'] ?? hubspotProperty;
  }

  // Flat "{source} · {property}" option list spanning every currently-
  // available source (Deal, Contact, every enabled custom object) — an
  // optional filter narrows it (e.g. to "file" fieldType properties for
  // the document-source picker). Shared by the rule builder's condition
  // dropdown and the document-source property picker.
  List<MapEntry<String, String>> _sourcePropertyOptions(
      {bool Function(Map<String, String>)? filter}) {
    final entries = <MapEntry<String, String>>[];
    void addFrom(String hubspotObjectType, String sourceLabel,
        List<Map<String, String>> properties) {
      for (final p in properties) {
        final name = p['name'];
        if (name == null) continue;
        if (filter != null && !filter(p)) continue;
        entries.add(MapEntry(
            '$hubspotObjectType::$name', '$sourceLabel · ${p['label'] ?? name}'));
      }
    }

    addFrom('deal', 'Aftale', _dealProperties);
    addFrom('contact', 'Kontakt', _contactProperties);
    for (final id in _enabledCustomObjectTypeIds) {
      addFrom(id, _customObjectLabel(id),
          _customObjectProperties[id] ?? const <Map<String, String>>[]);
    }
    return entries;
  }

  // Unlike Step 2's field mappings, a rule condition can reference *any*
  // HubSpot property (e.g. a routing-only field like "referenceCode" that
  // never fills a BackPack field at all).
  List<MapEntry<String, String>> _ruleConditionPropertyOptions() =>
      _sourcePropertyOptions();

  // Narrowed to "file" fieldType properties for the document-source
  // picker — falls back to every property if none are typed "file" so the
  // UI doesn't dead-end on an unverified HubSpot type-name assumption.
  List<MapEntry<String, String>> _fileTypePropertyOptions() {
    final fileOnly = _sourcePropertyOptions(filter: (p) => p['type'] == 'file');
    return fileOnly.isNotEmpty ? fileOnly : _sourcePropertyOptions();
  }

  String _ruleSummary(_TemplateRule rule) {
    final propLabel = _propertyLabelFor(
        rule.condition.hubspotObjectType, rule.condition.hubspotProperty);
    final templateName = rule.templateGroupId == null
        ? '?'
        : _templates.firstWhere((t) => t['id'] == rule.templateGroupId,
            orElse: () => {'name': rule.templateGroupId!})['name']!;
    switch (rule.condition.operator) {
      case 'not_equals':
        return 'HVIS $propLabel ≠ ${rule.condition.value} → $templateName';
      case 'in':
        return 'HVIS $propLabel er en af [${rule.condition.value}] → $templateName';
      case 'is_not_empty':
        return 'HVIS $propLabel er udfyldt → $templateName';
      default:
        return 'HVIS $propLabel = ${rule.condition.value} → $templateName';
    }
  }

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

  // Restores a previously saved field mapping/trigger/template rules — a
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
      // Falls back to the legacy flat `templateGroupId` for any doc saved
      // before rule-based template selection existed.
      _defaultTemplateGroupId =
          (data['defaultTemplateGroupId'] ?? data['templateGroupId'])
              as String?;
      _enabledCustomObjectTypeIds =
          List<String>.from(data['customObjectTypeIds'] as List? ?? [])
              .toSet();
      for (final m in (data['fieldMappings'] as List<dynamic>? ?? [])) {
        final map = Map<String, dynamic>.from(m as Map);
        final backpackField = map['backpackField'] as String?;
        final hubspotObjectType = map['hubspotObjectType'] as String?;
        final hubspotProperty = map['hubspotProperty'] as String?;
        if (backpackField == null ||
            hubspotObjectType == null ||
            hubspotProperty == null) {
          continue;
        }
        _fieldMapping[backpackField] =
            _MappedValue(hubspotObjectType, hubspotProperty);
      }
      _templateRules = (data['templateRules'] as List<dynamic>? ?? [])
          .map((r) {
            final map = Map<String, dynamic>.from(r as Map);
            final condition =
                Map<String, dynamic>.from(map['condition'] as Map? ?? {});
            final rawValue = condition['value'];
            return _TemplateRule(
              id: map['id'] as String? ?? _newRuleId(),
              label: map['label'] as String? ?? '',
              condition: _RuleCondition(
                hubspotObjectType: condition['hubspotObjectType'] as String?,
                hubspotProperty: condition['hubspotProperty'] as String?,
                operator: condition['operator'] as String? ?? 'equals',
                value: rawValue is List
                    ? rawValue.join(', ')
                    : (rawValue as String? ?? ''),
              ),
              templateGroupId: map['templateGroupId'] as String?,
            );
          })
          .toList();
      final documentSource =
          Map<String, dynamic>.from(data['documentSource'] as Map? ?? {});
      _documentSourceMode = documentSource['mode'] as String? ?? 'notes';
      final docSourceObjectType = documentSource['hubspotObjectType'] as String?;
      final docSourceProperty = documentSource['hubspotProperty'] as String?;
      _documentSourceProperty =
          (docSourceObjectType != null && docSourceProperty != null)
              ? _MappedValue(docSourceObjectType, docSourceProperty)
              : null;
      _messageSyncEnabled = data['messageSyncEnabled'] as bool? ?? false;
      _conversationSyncEnabled =
          data['conversationSyncEnabled'] as bool? ?? false;
    });
    if (_enabledCustomObjectTypeIds.isNotEmpty) {
      unawaited(_loadCustomObjectProperties(_enabledCustomObjectTypeIds.toList()));
    }
  }

  // Fetches property lists for one or more custom object types — called
  // when a bureau turns on a custom object as a source, and once at
  // restore-time for any already-enabled ones. Skips types whose
  // properties are already cached.
  Future<void> _loadCustomObjectProperties(List<String> objectTypeIds) async {
    final toFetch = objectTypeIds
        .where((id) => !_customObjectProperties.containsKey(id))
        .toList();
    if (toFetch.isEmpty) return;
    setState(() => _loadingCustomObjectTypeIds.addAll(toFetch));
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('fetchHubspotObjectProperties')
          .call({'agencyCode': _agencyCode, 'objectTypeIds': toFetch});
      final data = result.data as Map<dynamic, dynamic>;
      final properties = Map<String, dynamic>.from(data['properties'] as Map? ?? {});
      if (!mounted) return;
      setState(() {
        for (final id in toFetch) {
          _customObjectProperties[id] =
              (properties[id] as List<dynamic>? ?? [])
                  .map((p) => Map<String, String>.from(p as Map))
                  .toList();
        }
        _loadingCustomObjectTypeIds.removeAll(toFetch);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingCustomObjectTypeIds.removeAll(toFetch));
    }
  }

  void _toggleCustomObjectType(String id) {
    setState(() {
      if (_enabledCustomObjectTypeIds.contains(id)) {
        _enabledCustomObjectTypeIds.remove(id);
        // Clear any field mappings sourced from this type — otherwise
        // they'd silently point at a source no longer offered anywhere in
        // the UI.
        for (final key in _fieldMapping.keys.toList()) {
          if (_fieldMapping[key]?.hubspotObjectType == id) {
            _fieldMapping[key] = null;
          }
        }
        if (_selectedSourceTabIndex >= _mappingSources().length) {
          _selectedSourceTabIndex = 0;
        }
      } else {
        _enabledCustomObjectTypeIds.add(id);
        unawaited(_loadCustomObjectProperties([id]));
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
        _customObjectTypes = (data['customObjectTypes'] as List<dynamic>? ?? [])
            .map((c) {
              final map = Map<String, dynamic>.from(c as Map);
              return _CustomObjectType(map['id'] as String,
                  map['label'] as String? ?? map['id'] as String);
            })
            .toList();
        _isLoadingSchema = false;
      });
      if (_enabledCustomObjectTypeIds.isNotEmpty) {
        unawaited(_loadCustomObjectProperties(_enabledCustomObjectTypeIds.toList()));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingSchema = false);
    }
  }

  Future<void> _saveMapping({required bool activate}) async {
    if (_selectedPipelineId == null ||
        _selectedStageId == null ||
        _defaultTemplateGroupId == null) {
      setState(
          () => _saveError = 'Vælg pipeline, trin og standardskabelon først');
      return;
    }
    final incompleteRule = _templateRules.any((r) =>
        r.condition.hubspotObjectType == null ||
        r.condition.hubspotProperty == null ||
        r.templateGroupId == null);
    if (incompleteRule) {
      setState(() =>
          _saveError = 'Udfyld alle skabelonregler, eller fjern ufuldstændige regler');
      return;
    }
    if (_documentSourceMode == 'property' && _documentSourceProperty == null) {
      setState(() => _saveError = 'Vælg et HubSpot-felt som dokumentkilde');
      return;
    }
    setState(() {
      _isSaving = true;
      _saveError = null;
    });
    try {
      final fieldMappings =
          _fieldMapping.entries.where((e) => e.value != null).map((e) {
        final mapped = e.value!;
        final properties = _propertiesForSource(mapped.hubspotObjectType);
        final propertyType = properties.firstWhere(
          (p) => p['name'] == mapped.hubspotProperty,
          orElse: () => const {},
        )['type'];
        return {
          'backpackField': e.key,
          'hubspotObjectType': mapped.hubspotObjectType,
          'hubspotProperty': mapped.hubspotProperty,
          // The property's HubSpot type (e.g. "date"/"datetime"), so
          // the webhook can convert its value correctly regardless of
          // which HubSpot field widget was mapped.
          'hubspotFieldType': propertyType,
        };
      }).toList();
      final templateRules = _templateRules
          .map((r) => {
                'id': r.id,
                if (r.label.isNotEmpty) 'label': r.label,
                'condition': {
                  'hubspotObjectType': r.condition.hubspotObjectType,
                  'hubspotProperty': r.condition.hubspotProperty,
                  'operator': r.condition.operator,
                  'value': r.condition.operator == 'in'
                      ? r.condition.value
                          .split(',')
                          .map((v) => v.trim())
                          .where((v) => v.isNotEmpty)
                          .toList()
                      : r.condition.value,
                },
                'templateGroupId': r.templateGroupId,
              })
          .toList();
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('saveHubspotMapping')
          .call({
        'agencyCode': _agencyCode,
        'fieldMappings': fieldMappings,
        'customObjectTypeIds': _enabledCustomObjectTypeIds.toList(),
        'triggerPipelineId': _selectedPipelineId,
        'triggerStageId': _selectedStageId,
        'templateRules': templateRules,
        'defaultTemplateGroupId': _defaultTemplateGroupId,
        'documentSource': {
          'mode': _documentSourceMode,
          if (_documentSourceProperty != null)
            'hubspotObjectType': _documentSourceProperty!.hubspotObjectType,
          if (_documentSourceProperty != null)
            'hubspotProperty': _documentSourceProperty!.hubspotProperty,
        },
        'messageSyncEnabled': _messageSyncEnabled,
        'conversationSyncEnabled': _conversationSyncEnabled,
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
      showAppSnackbar(context, 'Forbindelsen er afbrudt');
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _isDisconnecting = false);
      showErrorSnackbar(context, e.message ?? 'Kunne ikke afbryde forbindelsen');
    } catch (e) {
      if (!mounted) return;
      setState(() => _isDisconnecting = false);
      showErrorSnackbar(context, 'Der skete en fejl');
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
                    const SizedBox(height: AppSpacing.md),
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
                      padding: const EdgeInsets.all(AppSpacing.xl),
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
              borderRadius: AppRadii.lgRadius,
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

  // Page switcher, not a progress timeline — no connecting lines between
  // steps, each one is its own tappable pill (same visual language as
  // _buildSourceTabs in Step 2), scrollable so it never has to squeeze
  // icon+label into an equal-width segment the way the old line-and-circle
  // layout did.
  Widget _buildStepIndicator(Color themeColor) {
    // No enclosing white bar — that flat, square-cornered strip is what
    // read as "hard-cornered" regardless of how rounded the pills inside
    // it were. The pills float directly on the scaffold's grey background
    // instead, each one a soft rounded card defined by a shadow rather
    // than a border.
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: List.generate(_steps.length, (i) {
            final isActive = i == _currentStep;
            return Padding(
              padding: EdgeInsets.only(right: i == _steps.length - 1 ? 0 : 8),
              child: GestureDetector(
                onTap: () => _goTo(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: isActive ? themeColor : Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: isActive
                            ? themeColor.withValues(alpha: 0.3)
                            : Colors.black.withValues(alpha: 0.06),
                        blurRadius: isActive ? 10 : 6,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_stepIcons[i],
                          size: 15,
                          color: isActive
                              ? _onThemeColor(themeColor)
                              : Colors.grey[500]),
                      const SizedBox(width: 6),
                      Text(_steps[i],
                          style: GoogleFonts.kanit(
                              fontSize: 12.5,
                              fontWeight:
                                  isActive ? FontWeight.w700 : FontWeight.w500,
                              color: isActive
                                  ? _onThemeColor(themeColor)
                                  : Colors.grey[700])),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
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

  Widget _card({Key? key, required Widget child, EdgeInsetsGeometry? padding}) {
    return Container(
      key: key,
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: AppRadii.lgRadius,
        boxShadow: AppShadows.card,
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
                borderRadius: AppRadii.mdRadius,
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: iconColor ?? Colors.grey[700], size: 20),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: AppTextStyles.headingBold()),
                const SizedBox(height: AppSpacing.xs),
                Text(subtitle,
                    style: AppTextStyles.body(color: Colors.grey[600])),
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
              const SizedBox(height: AppSpacing.xl),
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
                          borderRadius: AppRadii.mdRadius),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Åbner HubSpot i en ny fane. Log ind og godkend adgangen — denne side opdaterer sig selv, når I er forbundet.',
                  style: AppTextStyles.caption(color: Colors.grey[500]),
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
                            borderRadius: AppRadii.lgRadius,
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
    final sources = _mappingSources();
    if (_selectedSourceTabIndex >= sources.length) _selectedSourceTabIndex = 0;
    final selectedSource = sources[_selectedSourceTabIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Kortlæg felter',
            'Vælg hvilket HubSpot-felt — fra aftalen, en kontakt, eller et custom object — der skal udfylde hvert BackPack-felt.',
            icon: Icons.swap_horiz_rounded, iconColor: themeColor),
        if (_isLoadingSchema)
          _mappingSkeleton()
        else ...[
          if (_customObjectTypes.isNotEmpty) ...[
            _sectionLabel('Custom objects som datakilde'),
            _buildCustomObjectPicker(themeColor),
            const SizedBox(height: 18),
          ],
          _buildSourceTabs(themeColor, sources),
          const SizedBox(height: AppSpacing.md),
          _buildSourceMappingContent(selectedSource),
          const SizedBox(height: AppSpacing.xl),
          _buildDocumentSourceCard(themeColor),
          const SizedBox(height: AppSpacing.lg),
          _buildMessageSyncCard(themeColor),
          const SizedBox(height: AppSpacing.lg),
          _buildConversationSyncCard(themeColor),
        ],
      ],
    );
  }

  Widget _buildModeToggle({
    required String value,
    required List<MapEntry<String, String>> options,
    required Color themeColor,
    required ValueChanged<String> onChanged,
  }) {
    return Row(
      children: [
        for (final opt in options)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: opt.key == options.last.key ? 0 : 8),
              child: GestureDetector(
                onTap: () => onChanged(opt.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                  decoration: BoxDecoration(
                    color: value == opt.key
                        ? themeColor.withValues(alpha: 0.1)
                        : Colors.grey[50],
                    borderRadius: AppRadii.smRadius,
                    border: Border.all(
                        color: value == opt.key ? themeColor : Colors.grey[300]!,
                        width: value == opt.key ? 1.5 : 1),
                  ),
                  child: Text(opt.value,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.kanit(
                          fontSize: 12,
                          fontWeight:
                              value == opt.key ? FontWeight.w600 : FontWeight.w500,
                          color:
                              value == opt.key ? Colors.black87 : Colors.grey[600])),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDocumentSourceCard(Color themeColor) {
    final propertyKey = _documentSourceProperty != null
        ? '${_documentSourceProperty!.hubspotObjectType}::${_documentSourceProperty!.hubspotProperty}'
        : null;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel('Dokumenter'),
          Text(
              'Vælg hvor jeres rejsedokumenter (billetter, bekræftelser mv.) skal hentes fra — eller slå det fra, hvis I ikke vil importere dokumenter automatisk.',
              style: AppTextStyles.caption()),
          const SizedBox(height: AppSpacing.md),
          _buildModeToggle(
            value: _documentSourceMode,
            themeColor: themeColor,
            options: const [
              MapEntry('disabled', 'Deaktiveret'),
              MapEntry('notes', 'HubSpot Notes'),
              MapEntry('property', 'Bestemt felt'),
            ],
            onChanged: (v) => setState(() => _documentSourceMode = v),
          ),
          if (_documentSourceMode == 'property') ...[
            const SizedBox(height: AppSpacing.md),
            _buildIdDropdown(
              value: propertyKey,
              items: _fileTypePropertyOptions(),
              onChanged: (v) {
                if (v == null) return;
                final parts = v.split('::');
                setState(() {
                  _documentSourceProperty =
                      _MappedValue(parts.first, parts.sublist(1).join('::'));
                });
              },
              hint: 'Vælg HubSpot-felt',
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMessageSyncCard(Color themeColor) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: _messageSyncEnabled ? themeColor.withValues(alpha: 0.06) : Colors.white,
        borderRadius: AppRadii.lgRadius,
        border: Border.all(
            color: _messageSyncEnabled
                ? themeColor.withValues(alpha: 0.3)
                : Colors.grey[200]!),
        boxShadow: AppShadows.card,
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
                    Text('Beskeder fra HubSpot',
                        style: GoogleFonts.kanit(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                        'Hver HubSpot-note på en aftale bliver til en besked, rejsende kan se i appen, når deres gruppe findes.',
                        style: AppTextStyles.caption()),
                  ],
                ),
              ),
              Switch(
                value: _messageSyncEnabled,
                activeThumbColor: themeColor,
                onChanged: (v) => setState(() => _messageSyncEnabled = v),
              ),
            ],
          ),
          if (_messageSyncEnabled) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.08),
                borderRadius: AppRadii.smRadius,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange[800]),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                        'Alle notes bliver sendt — også interne, der ikke er skrevet til rejsende. Skriv kun i HubSpot-notes det er okay rejsende ser.',
                        style: GoogleFonts.kanit(
                            fontSize: 11, color: Colors.orange[900])),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Separate mechanism/scope from _buildMessageSyncCard above: this syncs
  // HubSpot's actual Conversations Inbox (a staff reply there, and a
  // traveler's own comment back), not the deal Notes timeline.
  Widget _buildConversationSyncCard(Color themeColor) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: _conversationSyncEnabled
            ? themeColor.withValues(alpha: 0.06)
            : Colors.white,
        borderRadius: AppRadii.lgRadius,
        border: Border.all(
            color: _conversationSyncEnabled
                ? themeColor.withValues(alpha: 0.3)
                : Colors.grey[200]!),
        boxShadow: AppShadows.card,
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
                    Text('To-vejs samtale via HubSpot Inbox',
                        style: GoogleFonts.kanit(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                        'Skriv til en rejsende direkte fra jeres HubSpot Inbox — det dukker op som en besked i appen. Svarer den rejsende, sender vi det tilbage til samme samtale i HubSpot.',
                        style: AppTextStyles.caption()),
                  ],
                ),
              ),
              Switch(
                value: _conversationSyncEnabled,
                activeThumbColor: themeColor,
                onChanged: (v) => setState(() => _conversationSyncEnabled = v),
              ),
            ],
          ),
          if (_conversationSyncEnabled) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.08),
                borderRadius: AppRadii.smRadius,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: Colors.orange[800]),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                        'En rejsendes svar bliver synligt for hele deres rejsegruppe i appen, ligesom andre kommentarer — ikke kun for jer. Skriv kun i HubSpot Inbox det er okay hele gruppen ser.',
                        style: GoogleFonts.kanit(
                            fontSize: 11, color: Colors.orange[900])),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _mappingSkeleton() {
    Widget bar(double width) => Container(
          width: width,
          height: 12,
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(6),
          ),
        );
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          bar(120),
          const SizedBox(height: AppSpacing.sm),
          for (int i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFFAFAFB),
                  borderRadius: AppRadii.mdRadius,
                  border: Border.all(color: Colors.grey[200]!),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCustomObjectPicker(Color themeColor) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _customObjectTypes.map((t) {
        final enabled = _enabledCustomObjectTypeIds.contains(t.id);
        return GestureDetector(
          onTap: () => _toggleCustomObjectType(t.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: enabled ? themeColor.withValues(alpha: 0.1) : Colors.grey[50],
              borderRadius: AppRadii.lgRadius,
              border: Border.all(
                  color: enabled ? themeColor : Colors.grey[300]!,
                  width: enabled ? 1.5 : 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(enabled ? Icons.check_circle : Icons.add_circle_outline,
                    size: 15, color: enabled ? themeColor : Colors.grey[400]),
                const SizedBox(width: 6),
                Text(t.label,
                    style: GoogleFonts.kanit(
                        fontSize: 12.5,
                        fontWeight:
                            enabled ? FontWeight.w600 : FontWeight.w500,
                        color: enabled ? Colors.black87 : Colors.grey[600])),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSourceTabs(Color themeColor, List<_MappingSource> sources) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < sources.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i == sources.length - 1 ? 0 : 8),
              child: GestureDetector(
                onTap: () => setState(() => _selectedSourceTabIndex = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: _selectedSourceTabIndex == i
                        ? themeColor
                        : Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                        color: _selectedSourceTabIndex == i
                            ? themeColor
                            : Colors.grey[300]!),
                    boxShadow: _selectedSourceTabIndex == i
                        ? [
                            BoxShadow(
                              color: themeColor.withValues(alpha: 0.25),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(sources[i].label,
                      style: GoogleFonts.kanit(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _selectedSourceTabIndex == i
                              ? _onThemeColor(themeColor)
                              : Colors.grey[700])),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceMappingContent(_MappingSource source) {
    if (source.hubspotObjectType == 'contact') {
      return _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel('Kontaktfelter'),
            for (final field in _contactFields)
              _buildMappingRow(field, _contactProperties, source.hubspotObjectType),
          ],
        ),
      );
    }

    final isCustomObject = source.hubspotObjectType != 'deal';
    if (isCustomObject &&
        _loadingCustomObjectTypeIds.contains(source.hubspotObjectType)) {
      return _card(
        child: const Padding(
          padding: EdgeInsets.all(AppSpacing.xxl),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final options = isCustomObject
        ? (_customObjectProperties[source.hubspotObjectType] ??
            const <Map<String, String>>[])
        : _dealProperties;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(isCustomObject ? '${source.label} · felter' : 'Aftalefelter'),
          if (isCustomObject && options.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                  'Ingen felter fundet for ${source.label} på jeres HubSpot-konto.',
                  style: GoogleFonts.kanit(fontSize: 12, color: Colors.grey[500])),
            )
          else
            for (final field in _groupLevelFields)
              _buildMappingRow(field, options, source.hubspotObjectType),
        ],
      ),
    );
  }

  Widget _buildMappingRow(_BackpackField field,
      List<Map<String, String>> options, String sourceObjectType) {
    final current = _fieldMapping[field.key];
    final isMappedHere = current?.hubspotObjectType == sourceObjectType;
    final mappedElsewhereLabel =
        current != null && !isMappedHere ? _sourceLabel(current.hubspotObjectType) : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFB),
          borderRadius: AppRadii.mdRadius,
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                  child: Icon(Icons.arrow_forward,
                      size: 12, color: Colors.grey[600]),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: isMappedHere ? current!.hubspotProperty : null,
                    isExpanded: true,
                    style:
                        AppTextStyles.body(),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                    hint: Text(
                        mappedElsewhereLabel != null
                            ? 'Ikke fra $mappedElsewhereLabel'
                            : 'Vælg HubSpot-felt',
                        style: AppTextStyles.body(color: Colors.grey[500])),
                    items: options
                        .map((p) => DropdownMenuItem(
                            value: p['name'],
                            child: Text(p['label'] ?? p['name'] ?? '',
                                overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: (value) => setState(() {
                      _fieldMapping[field.key] = value == null
                          ? null
                          : _MappedValue(sourceObjectType, value);
                    }),
                  ),
                ),
              ],
            ),
            if (mappedElsewhereLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 136),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 12, color: Colors.grey[400]),
                    const SizedBox(width: AppSpacing.xs),
                    Text('Kortlagt fra $mappedElsewhereLabel',
                        style: GoogleFonts.kanit(
                            fontSize: 10.5, color: Colors.grey[500])),
                  ],
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
              const SizedBox(height: AppSpacing.lg),
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
        const SizedBox(height: AppSpacing.xl),
        _sectionLabel('Skabelonregler'),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
              'Regler afprøves i rækkefølge — den første der matcher aftalen bruges. Ingen match falder tilbage til standardskabelonen nedenfor.',
              style: AppTextStyles.caption()),
        ),
        if (_templateRules.isEmpty)
          _card(
            child: Column(
              children: [
                Icon(Icons.rule_rounded, size: 26, color: Colors.grey[300]),
                const SizedBox(height: AppSpacing.sm),
                Text('Ingen regler endnu — alle aftaler bruger standardskabelonen.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.kanit(fontSize: 12, color: Colors.grey[500])),
              ],
            ),
          )
        else
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorder: (oldIndex, newIndex) => setState(() {
              if (newIndex > oldIndex) newIndex -= 1;
              final item = _templateRules.removeAt(oldIndex);
              _templateRules.insert(newIndex, item);
            }),
            children: [
              for (int i = 0; i < _templateRules.length; i++)
                _buildRuleCard(i, themeColor),
            ],
          ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () =>
                setState(() => _templateRules.add(_TemplateRule(id: _newRuleId()))),
            icon: Icon(Icons.add, size: 18, color: themeColor),
            label: Text('Tilføj regel',
                style: GoogleFonts.kanit(
                    fontWeight: FontWeight.w600, color: themeColor)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: themeColor.withValues(alpha: 0.4)),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape:
                  RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        _buildDefaultTemplateCard(),
      ],
    );
  }

  Widget _buildRuleCard(int index, Color themeColor) {
    final rule = _templateRules[index];
    final propertyOptions = _ruleConditionPropertyOptions();
    final propertyKey =
        rule.condition.hubspotObjectType != null && rule.condition.hubspotProperty != null
            ? '${rule.condition.hubspotObjectType}::${rule.condition.hubspotProperty}'
            : null;
    final isReady = propertyKey != null && rule.templateGroupId != null;

    return _card(
      key: ValueKey(rule.id),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                    color: themeColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text('${index + 1}',
                    style: GoogleFonts.kanit(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: themeColor)),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('Regel ${index + 1}',
                    style: GoogleFonts.kanit(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              ReorderableDragStartListener(
                index: index,
                child: Icon(Icons.drag_indicator, size: 18, color: Colors.grey[400]),
              ),
              const SizedBox(width: AppSpacing.xs),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _templateRules.removeAt(index)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ruleFieldLabel('HVIS'),
          const SizedBox(height: 6),
          _buildIdDropdown(
            value: propertyKey,
            items: propertyOptions,
            onChanged: (v) {
              if (v == null) return;
              final parts = v.split('::');
              setState(() {
                rule.condition.hubspotObjectType = parts.first;
                rule.condition.hubspotProperty = parts.sublist(1).join('::');
              });
            },
            hint: 'Vælg HubSpot-felt',
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: _buildIdDropdown(
                  value: rule.condition.operator,
                  items: _operatorLabels.entries
                      .map((e) => MapEntry(e.key, e.value))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => rule.condition.operator = v ?? 'equals'),
                  hint: 'Vælg',
                ),
              ),
              if (rule.condition.operator != 'is_not_empty') ...[
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    key: ValueKey('${rule.id}-value'),
                    initialValue: rule.condition.value,
                    style: AppTextStyles.body(),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.grey[50],
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      hintText: rule.condition.operator == 'in'
                          ? 'fx TEST1234, TEST5678'
                          : 'Værdi',
                      hintStyle:
                          GoogleFonts.kanit(fontSize: 12, color: Colors.grey[400]),
                      border: OutlineInputBorder(
                        borderRadius: AppRadii.smRadius,
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                    ),
                    onChanged: (v) => rule.condition.value = v,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Icon(Icons.arrow_downward_rounded, size: 14, color: Colors.grey[400]),
              const SizedBox(width: 6),
              _ruleFieldLabel('SÅ BRUG SKABELON'),
            ],
          ),
          const SizedBox(height: 6),
          _buildIdDropdown(
            value: rule.templateGroupId,
            items: _templates.map((t) => MapEntry(t['id']!, t['name']!)).toList(),
            onChanged: (v) => setState(() => rule.templateGroupId = v),
            hint: _templates.isEmpty
                ? 'Ingen skabeloner oprettet endnu'
                : 'Vælg skabelon',
          ),
          if (isReady) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: themeColor.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_ruleSummary(rule),
                  style: GoogleFonts.kanit(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: themeColor)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _ruleFieldLabel(String text) => Text(text,
      style: GoogleFonts.kanit(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Colors.grey[400]));

  Widget _buildDefaultTemplateCard() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.flag_outlined, size: 16, color: Colors.grey[600]),
              const SizedBox(width: 6),
              Text('STANDARDSKABELON',
                  style: GoogleFonts.kanit(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: Colors.grey[500])),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text('Bruges når ingen af reglerne ovenfor matcher aftalen.',
              style: AppTextStyles.caption()),
          const SizedBox(height: 10),
          _buildIdDropdown(
            value: _defaultTemplateGroupId,
            items: _templates.map((t) => MapEntry(t['id']!, t['name']!)).toList(),
            onChanged: (v) => setState(() => _defaultTemplateGroupId = v),
            hint: _templates.isEmpty
                ? 'Ingen skabeloner oprettet endnu'
                : 'Vælg standardskabelon',
          ),
        ],
      ),
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
                    AppTextStyles.body(color: Colors.grey[600])),
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
    final defaultTemplateName = _defaultTemplateGroupId == null
        ? 'Ikke valgt'
        : _templates.firstWhere((t) => t['id'] == _defaultTemplateGroupId,
            orElse: () => {'name': _defaultTemplateGroupId!})['name']!;
    final rulesComplete = _templateRules.every((r) =>
        r.condition.hubspotObjectType != null &&
        r.condition.hubspotProperty != null &&
        r.templateGroupId != null);

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
              _checklistRow(
                  'Regler',
                  _templateRules.isEmpty
                      ? 'Ingen regler (kun standard)'
                      : '${_templateRules.length} regel${_templateRules.length == 1 ? '' : 'er'}',
                  complete: rulesComplete),
              _checklistRow('Standardskabelon', defaultTemplateName,
                  complete: _defaultTemplateGroupId != null),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.xl),
          decoration: BoxDecoration(
            color: themeColor.withValues(alpha: 0.07),
            borderRadius: AppRadii.lgRadius,
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
                            style: AppTextStyles.caption()),
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
                const SizedBox(height: AppSpacing.md),
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
                  const SizedBox(width: AppSpacing.sm),
                  Text(isActive ? 'Aktiv' : 'Inaktiv',
                      style: GoogleFonts.kanit(
                          fontWeight: FontWeight.w600,
                          color:
                              isActive ? Colors.green[700] : Colors.grey[700])),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              if (events.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      Icon(Icons.hourglass_empty,
                          size: 26, color: Colors.grey[300]),
                      const SizedBox(height: AppSpacing.sm),
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
                      borderRadius: AppRadii.smRadius,
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
        const SizedBox(height: AppSpacing.lg),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Afbryd forbindelsen',
                  style: GoogleFonts.kanit(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Stopper integrationen og fjerner adgangen til jeres HubSpot-konto. Jeres kortlægning, udløser og skabelon gemmes, så I hurtigt kan forbinde igen.',
                style:
                    AppTextStyles.caption(),
              ),
              const SizedBox(height: AppSpacing.md),
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
                        borderRadius: AppRadii.mdRadius),
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
        borderRadius: AppRadii.mdRadius,
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppSpacing.sm),
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
      style: AppTextStyles.body(),
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.grey[50],
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: AppRadii.smRadius,
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
      ),
      hint: Text(hint,
          style: AppTextStyles.body(color: Colors.grey[500])),
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
                          borderRadius: AppRadii.mdRadius),
                    ),
                    child: Text('Tilbage',
                        style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                  ),
                ),
              if (!isFirst) const SizedBox(width: AppSpacing.md),
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
                        borderRadius: AppRadii.mdRadius),
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
