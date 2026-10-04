import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/packinglist_model.dart';
import 'package:backend/models/timeline_event_model.dart';
import 'package:backend/widget/timelineDialog.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:backend/widget/app_snackbar.dart';

/// "Build a trip from documents" — a bureau uploads flight tickets, hotel
/// confirmations etc. (plus an explicit start/end date and, optionally,
/// exactly one link), a server-side Cloud Function (`analyzeTripDocuments`)
/// asks Gemini to draft a timeline *strictly* from that content, and the
/// bureau reviews/edits the draft before it becomes a real trip. The AI
/// never fetches anything itself beyond what's uploaded here plus the one
/// linked page — see analyzeTripDocuments in backpack/functions/src/index.ts
/// for how that's enforced server-side.
class AiTripBuilderScreen extends StatefulWidget {
  final Color themeColor;
  final String agencyCode;
  final String bureauName;

  const AiTripBuilderScreen({
    super.key,
    required this.themeColor,
    required this.agencyCode,
    required this.bureauName,
  });

  @override
  State<AiTripBuilderScreen> createState() => _AiTripBuilderScreenState();
}

enum _AnalysisState { idle, analyzing, done }

const int _maxFiles = 8;

// Combined size cap for PDFs/images, which are all sent inline in one
// Vertex AI request — mirrors AI_TRIP_BUILDER_MAX_INLINE_BYTES in
// backpack/functions/src/index.ts. Spreadsheets are converted to text
// server-side and don't count.
const int _maxInlineBytes = 14 * 1024 * 1024;

bool _isSpreadsheet(String filename) => const ['xlsx', 'xls', 'csv']
    .contains(filename.split('.').last.toLowerCase());

// Labels of the free-text review fields, also used to read them back in
// _createGroup. Dates and the two flight switches have their own state.
const _fTripName = 'Rejsenavn';
const _fGroupId = 'Gruppe ID';

class _DraftField {
  final String label;
  final TextEditingController controller;
  final String source; // which document it was found in, or '' if manual

  _DraftField(this.label, String initialValue, this.source)
      : controller = TextEditingController(text: initialValue);
}

/// Stands in for the not-yet-created trip when TimelineDialog runs in draft
/// mode — it only reads these three (dynamically). mapEnabled is on so the
/// dialog shows the address field and resolves map coordinates for it,
/// which are kept on the event for when the bureau turns the map on.
class _DraftTripContext {
  _DraftTripContext(this.agencyCode);
  final String agencyCode;
  final String groupId = '';
  final bool mapEnabled = true;
}

/// A reviewed date or flight switch plus the document the AI found it in
/// ('' when it wasn't found and the value is a default).
class _Sourced<T> {
  T value;
  final String source;
  _Sourced(this.value, this.source);
}

class _AiTripBuilderScreenState extends State<AiTripBuilderScreen> {
  int _currentStep = 0;
  _AnalysisState _analysisState = _AnalysisState.idle;
  String? _errorMessage;
  bool _isCreating = false;
  bool _groupCreated = false;

  final List<PlatformFile> _pickedFiles = [];
  DateTime? _startDate;
  DateTime? _endDate;
  final TextEditingController _linkController = TextEditingController();
  String? _scratchBasePath;

  List<_DraftField> _fields = [];
  _Sourced<DateTime>? _departure;
  _Sourced<DateTime>? _return;
  _Sourced<bool> _flightAway = _Sourced(false, '');
  _Sourced<bool> _flightHome = _Sourced(false, '');
  // The draft timeline, editable on the review step via TimelineDialog's
  // draft mode. id/dayNumber are finalised in _buildTimelineEvents.
  List<TimelineEvent> _timeline = [];
  List<String> _conflicts = [];

  static const _steps = ['Upload', 'Analyse', 'Gennemgå udkast', 'Opret'];

  @override
  void dispose() {
    for (final f in _fields) {
      f.controller.dispose();
    }
    _linkController.dispose();
    _cleanupScratchFilesIfAbandoned();
    super.dispose();
  }

  // Best-effort cleanup if the bureau navigates away without creating the
  // trip — scratch uploads are meant to be temporary. Fire-and-forget since
  // dispose() can't be awaited; a failure here just leaves an orphaned
  // scratch file, not a data-integrity problem.
  void _cleanupScratchFilesIfAbandoned() {
    if (_groupCreated || _scratchBasePath == null) return;
    for (final f in _pickedFiles) {
      FirebaseStorage.instance
          .ref()
          .child('$_scratchBasePath/${f.name}')
          .delete()
          .catchError((_) {});
    }
  }

  Color _onThemeColor(Color color) =>
      color.computeLuminance() < 0.5 ? Colors.white : Colors.black;

  String? _contentTypeFor(String filename) {
    const map = {
      'pdf': 'application/pdf',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'xls': 'application/vnd.ms-excel',
      'csv': 'text/csv',
    };
    return map[filename.split('.').last.toLowerCase()];
  }

  IconData _iconFor(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (['png', 'jpg', 'jpeg'].contains(ext)) return Icons.image_outlined;
    return Icons.table_chart_outlined;
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'xlsx', 'xls', 'csv'],
    );
    if (result == null) return;
    var skippedForSize = false;
    setState(() {
      for (final f in result.files) {
        if (f.bytes == null) continue;
        if (!_isSpreadsheet(f.name) &&
            _inlineBytes + f.size > _maxInlineBytes) {
          skippedForSize = true;
          continue;
        }
        // Files are stored under their name (scratch folder and the trip's
        // documents), so two different files called e.g. "billet.pdf"
        // would overwrite each other — give the newcomer a unique name.
        final name = _uniqueName(f.name);
        _pickedFiles.add(name == f.name
            ? f
            : PlatformFile(name: name, size: f.size, bytes: f.bytes));
      }
      if (_pickedFiles.length > _maxFiles) {
        _pickedFiles.removeRange(_maxFiles, _pickedFiles.length);
        showWarningSnackbar(context, 'Højst $_maxFiles filer ad gangen');
      }
    });
    if (skippedForSize && mounted) {
      showWarningSnackbar(context,
          'PDF\'er og billeder må samlet fylde højst ${_maxInlineBytes ~/ (1024 * 1024)} MB — nogle filer blev ikke tilføjet');
    }
  }

  int get _inlineBytes => _pickedFiles
      .where((f) => !_isSpreadsheet(f.name))
      .fold(0, (total, f) => total + f.size);

  String _uniqueName(String name) {
    final taken = _pickedFiles.map((f) => f.name).toSet();
    if (!taken.contains(name)) return name;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var n = 2;
    while (taken.contains('$base ($n)$ext')) {
      n++;
    }
    return '$base ($n)$ext';
  }

  void _removeFile(int index) => setState(() => _pickedFiles.removeAt(index));

  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final initial = isStart
        ? (_startDate ?? now)
        : (_endDate ?? _startDate?.add(const Duration(days: 7)) ?? now);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
        if (_endDate != null && !_endDate!.isAfter(picked)) {
          _endDate = null;
        }
      } else {
        _endDate = picked;
      }
    });
  }

  bool get _linkLooksValid {
    final text = _linkController.text.trim();
    if (text.isEmpty) return true;
    final uri = Uri.tryParse(text);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  String get _analysisSubtitle {
    final hasLink = _linkController.text.trim().isNotEmpty;
    if (_pickedFiles.isEmpty) return 'Det linkede program bliver læst igennem.';
    final files =
        '${_pickedFiles.length} fil${_pickedFiles.length == 1 ? '' : 'er'}';
    return hasLink
        ? '$files og det linkede program bliver læst igennem.'
        : '$files bliver læst igennem.';
  }

  // Files, a link, or both — a public trip page alone is enough to analyse.
  bool get _canAnalyze =>
      (_pickedFiles.isNotEmpty || _linkController.text.trim().isNotEmpty) &&
      _startDate != null &&
      _endDate != null &&
      _endDate!.isAfter(_startDate!) &&
      _linkLooksValid;

  String _slugify(String input) {
    final trimmed = input.trim();
    var slug = trimmed
        .toLowerCase()
        .replaceAll('æ', 'ae')
        .replaceAll('ø', 'oe')
        .replaceAll('å', 'aa')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) slug = 'rejse';
    final suffix =
        DateTime.now().millisecondsSinceEpoch.toString().substring(7);
    return '$slug-$suffix';
  }

  String? _fieldValue(dynamic draft, String key) {
    final field = draft[key];
    if (field is Map) return field['value'] as String?;
    return null;
  }

  String? _fieldSource(dynamic draft, String key) {
    final field = draft[key];
    if (field is Map) return field['source'] as String?;
    return null;
  }

  String? _optional(Object? v) =>
      v is String && v.trim().isNotEmpty ? v.trim() : null;

  /// An AI date if it's a valid ÅÅÅÅ-MM-DD, else [fallback] (the date
  /// picked on the upload step) with no source.
  _Sourced<DateTime> _sourcedDate(
      dynamic draft, String key, DateTime fallback) {
    final parsed = DateTime.tryParse(_fieldValue(draft, key) ?? '');
    if (parsed == null) return _Sourced(fallback, '');
    return _Sourced(DateTime(parsed.year, parsed.month, parsed.day),
        _fieldSource(draft, key) ?? '');
  }

  /// An AI yes/no, or false with no source when not evident.
  _Sourced<bool> _sourcedBool(dynamic draft, String key) {
    final field = draft[key];
    if (field is Map && field['value'] is bool) {
      return _Sourced(
          field['value'] as bool, (field['source'] as String?) ?? '');
    }
    return _Sourced(false, '');
  }

  void _populateFromDraft(Map<Object?, Object?> draft) {
    for (final f in _fields) {
      f.controller.dispose();
    }

    final tripName = _fieldValue(draft, 'tripName') ?? '';

    final newFields = [
      _DraftField(_fTripName, tripName, _fieldSource(draft, 'tripName') ?? ''),
      _DraftField(_fGroupId, _slugify(tripName), ''),
    ];

    final rawTimeline = (draft['timeline'] as List?) ?? [];
    final newTimeline = rawTimeline
        .whereType<Map>()
        .map((raw) {
          try {
            return TimelineEvent(
              id: '',
              type: (raw['title'] as String?) ?? '',
              description: (raw['description'] as String?) ?? '',
              startDate: DateTime.parse(raw['startDate'] as String),
              endDate: DateTime.parse(raw['endDate'] as String),
              dayNumber: 0,
              isDestination: false,
              country: _optional(raw['country']) ?? '',
              // Full street address/venue when the documents give one —
              // what the map geocodes.
              address: _optional(raw['address']),
              accommodation: _optional(raw['accommodation']),
              transport: _optional(raw['transport']),
              transportIcon: _optional(raw['transportIcon']),
              meals: _optional(raw['meals']),
              activities: _optional(raw['activities']),
              // Unsplash landscape photo picked server-side from the
              // entry's own content (analyzeTripDocuments →
              // attachUnsplashImages); '' if none.
              imageURL: (raw['imageUrl'] as String?) ?? '',
            );
          } catch (_) {
            return null;
          }
        })
        .whereType<TimelineEvent>()
        .toList();

    final newConflicts =
        ((draft['conflicts'] as List?) ?? []).map((e) => e.toString()).toList();

    setState(() {
      _fields = newFields;
      _departure = _sourcedDate(draft, 'departureDate', _startDate!);
      _return = _sourcedDate(draft, 'returnDate', _endDate!);
      _flightAway = _sourcedBool(draft, 'flightAway');
      _flightHome = _sourcedBool(draft, 'flightHome');
      _timeline = newTimeline;
      _conflicts = newConflicts;
    });
  }

  Future<void> _analyze() async {
    _goTo(1);
    setState(() {
      _analysisState = _AnalysisState.analyzing;
      _errorMessage = null;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception('Ikke logget ind');

      final sessionId = DateTime.now().millisecondsSinceEpoch.toString();
      final basePath =
          'aiTripBuilderScratch/${widget.agencyCode}/$uid/$sessionId';
      _scratchBasePath = basePath;

      final filePaths = <String>[];
      for (final f in _pickedFiles) {
        final path = '$basePath/${f.name}';
        await FirebaseStorage.instance.ref().child(path).putData(
              f.bytes!,
              SettableMetadata(contentType: _contentTypeFor(f.name)),
            );
        filePaths.add(path);
      }

      final linkUrl = _linkController.text.trim();
      final callable =
          FirebaseFunctions.instanceFor(region: 'europe-west1').httpsCallable(
        'analyzeTripDocuments',
        options: HttpsCallableOptions(timeout: const Duration(minutes: 3)),
      );
      final result = await callable.call(<String, dynamic>{
        'agencyCode': widget.agencyCode,
        'filePaths': filePaths,
        'startDate': DateFormat('yyyy-MM-dd').format(_startDate!),
        'endDate': DateFormat('yyyy-MM-dd').format(_endDate!),
        if (linkUrl.isNotEmpty) 'linkUrl': linkUrl,
      });

      final draft = result.data['draft'] as Map<Object?, Object?>;
      _populateFromDraft(draft);

      if (!mounted) return;
      setState(() => _analysisState = _AnalysisState.done);
      _goTo(2);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _analysisState = _AnalysisState.idle;
        _errorMessage = 'Analysen fejlede: ${e.toString()}';
      });
    }
  }

  Future<void> _moveScratchFilesToGroupDocuments(String groupId) async {
    for (final f in _pickedFiles) {
      if (f.bytes == null) continue;
      try {
        await FirebaseStorage.instance
            .ref()
            .child('$groupId/documents/${f.name}')
            .putData(f.bytes!,
                SettableMetadata(contentType: _contentTypeFor(f.name)));
      } catch (_) {
        // Best-effort — a copy failure shouldn't block trip creation.
      }
    }
    if (_scratchBasePath != null) {
      for (final f in _pickedFiles) {
        try {
          await FirebaseStorage.instance
              .ref()
              .child('$_scratchBasePath/${f.name}')
              .delete();
        } catch (_) {}
      }
    }
  }

  String _field(String label) =>
      _fields.firstWhere((f) => f.label == label).controller.text.trim();

  void _showError(String message) {
    showErrorSnackbar(context, message);
  }

  Future<void> _pickReviewDate({required bool isDeparture}) async {
    final current = isDeparture ? _departure! : _return!;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current.value,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() {
      // A hand-picked date no longer comes from a document.
      if (isDeparture) {
        _departure = _Sourced(picked, '');
      } else {
        _return = _Sourced(picked, '');
      }
    });
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static int _tripDayOf(DateTime date, DateTime departure) {
    final day = _dateOnly(date).difference(_dateOnly(departure)).inDays + 1;
    return day < 1 ? 1 : day;
  }

  /// "12. maj" or "12. – 15. maj · 4 dage" — so multi-day events read as
  /// one span, matching the material.
  String _eventDateRange(TimelineEvent t) {
    final start = _dateOnly(t.startDate);
    final end = _dateOnly(t.endDate);
    final dayFmt = DateFormat('d. MMM', 'da_DK');
    if (start == end) return dayFmt.format(start);
    final days = end.difference(start).inDays + 1;
    return '${dayFmt.format(start)} – ${dayFmt.format(end)} · $days dage';
  }

  List<TimelineEvent> _buildTimelineEvents(DateTime departure) {
    if (_timeline.isEmpty) {
      return [
        TimelineEvent(
          id: 'template_1',
          type: 'Fx. Ankomst',
          country: '',
          startDate: departure,
          endDate: departure.add(const Duration(days: 1)),
          dayNumber: 1,
          isDestination: false,
          imageURL: '',
          description: 'Skriv her en beskrivelse af begivenheden',
        ),
      ];
    }
    return _timeline.asMap().entries.map((entry) {
      final i = entry.key;
      final t = entry.value;
      return TimelineEvent(
        id: 'ai_$i',
        type: t.type.isNotEmpty ? t.type : 'Begivenhed ${i + 1}',
        country: t.country,
        address: _nonEmpty(t.address),
        latitude: t.latitude,
        longitude: t.longitude,
        startDate: t.startDate,
        endDate: t.endDate,
        // The trip day the event starts on (a 3-day stay starting on day
        // 4 is day 4, not "the 2nd event").
        dayNumber: _tripDayOf(t.startDate, departure),
        isDestination: t.isDestination,
        imageURL: t.imageURL,
        description: t.description.isNotEmpty
            ? t.description
            : 'Skriv her en beskrivelse af begivenheden',
        bureauOffers: t.bureauOffers,
        accommodation: _nonEmpty(t.accommodation),
        transport: _nonEmpty(t.transport),
        transportIcon: t.transportIcon,
        meals: _nonEmpty(t.meals),
        activities: _nonEmpty(t.activities),
      );
    }).toList();
  }

  // TimelineDialog saves untouched optional fields as '' — treat those as
  // "not set", same as the AI's nulls.
  static String? _nonEmpty(String? v) =>
      v != null && v.trim().isNotEmpty ? v : null;

  /// Opens the trip editor's own TimelineDialog in draft mode: edits (or a
  /// new event when [index] is null) land in [_timeline] instead of
  /// Firestore, since the trip isn't created until "Opret rejse".
  Future<void> _editTimelineEvent(int? index) async {
    await showDialog(
      context: context,
      builder: (_) => TimelineDialog(
        event: index == null ? null : _timeline[index],
        groupInformation: _DraftTripContext(widget.agencyCode),
        onDraftSave: (event) => setState(() {
          if (index == null) {
            _timeline.add(event);
          } else {
            _timeline[index] = event;
          }
          _timeline.sort((a, b) => a.startDate.compareTo(b.startDate));
        }),
        onDraftDelete: index == null
            ? null
            : () => setState(() => _timeline.removeAt(index)),
      ),
    );
  }

  Future<void> _createGroup() async {
    final groupName = _field(_fTripName);
    final groupId = _field(_fGroupId);
    if (groupName.isEmpty || groupId.isEmpty) {
      _showError('Udfyld rejsenavn og gruppe-ID');
      return;
    }
    // Firestore document IDs can't contain "/" (it would address a
    // sub-path instead) and "." / ".." are reserved.
    if (groupId.contains('/') || groupId == '.' || groupId == '..') {
      _showError('Gruppe-ID må ikke indeholde "/"');
      return;
    }

    final departure = _departure!.value;
    final returnDate = _return!.value;
    if (returnDate.isBefore(departure)) {
      _showError('Hjemrejsedatoen ligger før afrejsedatoen');
      return;
    }

    setState(() => _isCreating = true);
    try {
      final timelineEvents = _buildTimelineEvents(departure);

      final group = GroupInformation(
        groupId: groupId,
        id: "1",
        groupName: groupName,
        coupons: [],
        bureauName: widget.bureauName,
        agencyCode: widget.agencyCode,
        departureDate: departure,
        returnDate: returnDate,
        members: [],
        // Guides and emergency phone are added later from the trip's own
        // page — deliberately not part of the AI draft.
        guides: [],
        timelineEvents: timelineEvents,
        packinglistCategories: [
          PackinglistCategories(
            iconName: 'text_box_multiple_outline',
            categoryName: 'Dokumenter',
            items: const ['Pas', 'Lokal valuta', 'Rejseforsikring'],
          ),
        ],
        flightAway: _flightAway.value,
        flightHome: _flightHome.value,
        emergencyPhone: '',
        departureFrom: '',
        returnTo: '',
        isTemplate: false,
        mapEnabled: false,
      );

      // Create-only: a transaction so an ID that's already taken (by any
      // bureau's trip) is refused instead of silently overwriting it.
      final groupRef =
          FirebaseFirestore.instance.collection('groups').doc(group.groupId);
      final created =
          await FirebaseFirestore.instance.runTransaction<bool>((tx) async {
        if ((await tx.get(groupRef)).exists) return false;
        tx.set(groupRef, {
          'groupId': group.groupId,
          'coupons': group.coupons?.map((e) => e.toMap()).toList(),
          'id': group.groupId,
          'groupName': group.groupName,
          'bureauName': group.bureauName,
          'agencyCode': group.agencyCode,
          'departureDate': group.departureDate,
          'returnDate': group.returnDate,
          'members': group.members.map((e) => e.toMap()).toList(),
          'guides': group.guides.map((e) => e.toMap()).toList(),
          'timelineEvents': group.timelineEvents.map((e) => e.toMap()).toList(),
          'packinglistCategories':
              group.packinglistCategories.map((e) => e.toMap()).toList(),
          'flightAway': group.flightAway,
          'flightHome': group.flightHome,
          'emergencyPhone': group.emergencyPhone,
          'departureFrom': group.departureFrom,
          'returnTo': group.returnTo,
          'isTemplate': group.isTemplate,
          'mapEnabled': group.mapEnabled,
        });
        return true;
      });
      if (!created) {
        if (mounted) {
          setState(() => _isCreating = false);
          _showError('Gruppe-ID "$groupId" er allerede i brug — vælg et andet');
        }
        return;
      }

      await _moveScratchFilesToGroupDocuments(group.groupId);

      final agencyDoc = await FirebaseFirestore.instance
          .collection('agency')
          .doc(widget.agencyCode)
          .get();
      final standardMessage = agencyDoc.data()?['standardMessage'] as String?;
      final standardMessageTitle =
          agencyDoc.data()?['standardMessageTitle'] as String? ?? 'Velkommen';
      if (standardMessage != null && standardMessage.isNotEmpty) {
        await groupRef.collection('messages').add({
          'title': standardMessageTitle,
          'content': standardMessage,
          'timestamp': FieldValue.serverTimestamp(),
        });
      }

      _groupCreated = true;
      if (mounted) Navigator.of(context).pop(group);
    } catch (e) {
      if (mounted) {
        setState(() => _isCreating = false);
        _showError('Fejl: $e');
      }
    }
  }

  void _goTo(int step) {
    setState(() => _currentStep = step.clamp(0, _steps.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = widget.themeColor;

    return Scaffold(
      backgroundColor: AppColors.scaffoldGradientStart,
      appBar: AppBar(
        title: Text('Byg rejse med AI',
            style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
        backgroundColor: themeColor,
        foregroundColor: _onThemeColor(themeColor),
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
          _buildDisclaimerBanner(),
          _buildStepIndicator(themeColor),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: _buildStepContent(themeColor),
            ),
          ),
          _buildNavButtons(themeColor),
        ],
      ),
    );
  }

  Widget _buildDisclaimerBanner() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFEFF6FF),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, size: 16, color: Color(0xFF1E5AA8)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'AI\'en bruger kun de uploadede dokumenter og evt. det ene link du angiver — den søger ikke selv på nettet. Kun stemningsbilleder til tidslinjen hentes fra Unsplash.',
              style: GoogleFonts.kanit(
                  fontSize: 12,
                  color: const Color(0xFF1E5AA8),
                  fontWeight: FontWeight.w500),
            ),
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
          final circleColor =
              isDone || isActive ? themeColor : Colors.grey[300]!;
          return Expanded(
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
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: circleColor),
                      alignment: Alignment.center,
                      child: isDone
                          ? const Icon(Icons.check,
                              size: 14, color: Colors.white)
                          : Text('${i + 1}',
                              style: GoogleFonts.kanit(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: isActive
                                      ? Colors.white
                                      : Colors.grey[600])),
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
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isActive ? Colors.black87 : Colors.grey[500]),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildStepContent(Color themeColor) {
    switch (_currentStep) {
      case 0:
        return _buildUploadStep(themeColor);
      case 1:
        return _buildAnalyzeStep(themeColor);
      case 2:
        return _buildReviewStep(themeColor);
      default:
        return _buildCreateStep(themeColor);
    }
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: AppRadii.lgRadius,
        boxShadow: AppShadows.card,
      ),
      child: child,
    );
  }

  Widget _stepHeading(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTextStyles.headingBold()),
          const SizedBox(height: AppSpacing.xs),
          Text(subtitle, style: AppTextStyles.body(color: Colors.grey[600])),
        ],
      ),
    );
  }

  // Step 1 — Upload -------------------------------------------------------

  Widget _buildUploadStep(Color themeColor) {
    final dateFormat = DateFormat('dd. MMM yyyy', 'da_DK');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Upload rejsens dokumenter',
            'Flybilletter, hotelbekræftelser, programmer — AI\'en læser dem og bygger et udkast til rejsen. Alt den ikke kan finde, efterlades tomt til jer.'),
        _card(
          child: Column(
            children: [
              InkWell(
                onTap: _pickFiles,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  decoration: BoxDecoration(
                    color: themeColor.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: themeColor.withValues(alpha: 0.3),
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.cloud_upload_outlined,
                          size: 32, color: themeColor),
                      const SizedBox(height: 10),
                      Text('Vælg filer (PDF, billeder, Excel, CSV)',
                          style: GoogleFonts.kanit(
                              fontWeight: FontWeight.w600,
                              color: Colors.black87)),
                      const SizedBox(height: 2),
                      Text('op til $_maxFiles filer',
                          style: GoogleFonts.kanit(
                              fontSize: 12, color: Colors.grey[600])),
                    ],
                  ),
                ),
              ),
              if (_pickedFiles.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                ..._pickedFiles.asMap().entries.map((entry) {
                  final i = entry.key;
                  final file = entry.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(_iconFor(file.name),
                            size: 20, color: Colors.grey[600]),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(file.name,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.body()),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => _removeFile(i),
                          color: Colors.grey[500],
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Rejseperiode',
            style:
                GoogleFonts.kanit(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        _card(
          child: Row(
            children: [
              Expanded(
                child: _dateTile(
                  label: 'Startdato',
                  value: _startDate == null
                      ? null
                      : dateFormat.format(_startDate!),
                  onTap: () => _pickDate(isStart: true),
                  themeColor: themeColor,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _dateTile(
                  label: 'Slutdato',
                  value: _endDate == null ? null : dateFormat.format(_endDate!),
                  onTap: () => _pickDate(isStart: false),
                  themeColor: themeColor,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
            _pickedFiles.isEmpty
                ? 'Link (påkrævet uden filer)'
                : 'Link (valgfrit)',
            style:
                GoogleFonts.kanit(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _linkController,
                onChanged: (_) => setState(() {}),
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: 'https://...',
                  prefixIcon: const Icon(Icons.link),
                  errorText: _linkLooksValid ? null : 'Ugyldigt link',
                  border: OutlineInputBorder(borderRadius: AppRadii.mdRadius),
                  filled: true,
                  fillColor: Colors.grey[50],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'AI\'en henter kun indholdet fra denne ene side — ikke resten af hjemmesiden.',
                style: GoogleFonts.kanit(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dateTile({
    required String label,
    required String? value,
    required VoidCallback onTap,
    required Color themeColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.mdRadius,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: AppRadii.mdRadius,
          border: Border.all(color: Colors.grey[300]!),
          color: Colors.grey[50],
        ),
        child: Row(
          children: [
            Icon(Icons.calendar_today_outlined, size: 16, color: themeColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: GoogleFonts.kanit(
                          fontSize: 11, color: Colors.grey[600])),
                  Text(value ?? 'Vælg dato',
                      style: GoogleFonts.kanit(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: value == null
                              ? Colors.grey[400]
                              : Colors.black87)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Step 2 — Analyzing ------------------------------------------------------

  Widget _buildAnalyzeStep(Color themeColor) {
    final tasks = [
      'Læser dokumenter',
      'Genkender fly- og hoteloplysninger',
      'Bygger tidslinje',
      'Markerer felter der mangler',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('AI analyserer jeres dokumenter', _analysisSubtitle),
        _card(
          child: Column(
            children: [
              if (_errorMessage != null) ...[
                Icon(Icons.error_outline, size: 32, color: Colors.red[400]),
                const SizedBox(height: 10),
                Text(_errorMessage!,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.kanit(
                        fontSize: 13, color: Colors.red[700])),
                const SizedBox(height: 8),
                Text('Tryk "Analysér med AI" for at prøve igen.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.kanit(
                        fontSize: 12, color: Colors.grey[600])),
              ] else ...[
                if (_analysisState != _AnalysisState.done)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: CircularProgressIndicator(color: themeColor),
                  ),
                const SizedBox(height: AppSpacing.sm),
                ...tasks.map((t) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Icon(
                            _analysisState == _AnalysisState.done
                                ? Icons.check_circle
                                : Icons.hourglass_empty,
                            size: 18,
                            color: _analysisState == _AnalysisState.done
                                ? Colors.green
                                : Colors.grey[400],
                          ),
                          const SizedBox(width: 10),
                          Text(t, style: AppTextStyles.body()),
                        ],
                      ),
                    )),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // Step 3 — Review draft ----------------------------------------------------

  Widget _buildReviewStep(Color themeColor) {
    final unknownCount =
        _fields.where((f) => f.controller.text.isEmpty).length +
            [_departure, _return, _flightAway, _flightHome]
                .where((f) => f == null || f.source.isEmpty)
                .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading(
            'Gennemgå udkast',
            unknownCount == 0
                ? 'AI\'en fandt alle felter i dokumenterne.'
                : '$unknownCount felt${unknownCount == 1 ? '' : 'er'} blev ikke fundet i dokumenterne — udfyld dem manuelt, eller lad dem stå tomme og ret rejsen senere.'),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final field in _fields) ...[
                _buildDraftField(field, themeColor),
                const SizedBox(height: 14),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        _buildTravelCard(themeColor),
        if (_conflicts.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text('Datokonflikter — tjek manuelt',
              style:
                  GoogleFonts.kanit(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF4E5),
              borderRadius: AppRadii.lgRadius,
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _conflicts
                  .map((c) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('• $c',
                            style: GoogleFonts.kanit(
                                fontSize: 12, color: const Color(0xFF9A6700))),
                      ))
                  .toList(),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: Text('Tidslinje-udkast',
                  style: GoogleFonts.kanit(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            TextButton.icon(
              onPressed: () => _editTimelineEvent(null),
              icon: Icon(Icons.add, size: 18, color: themeColor),
              label: Text('Tilføj begivenhed',
                  style: GoogleFonts.kanit(color: themeColor)),
            ),
          ],
        ),
        Text('Tryk på en begivenhed for at rette den.',
            style: GoogleFonts.kanit(fontSize: 12, color: Colors.grey[600])),
        const SizedBox(height: 10),
        _card(
          child: _timeline.isEmpty
              ? Text('Ingen tidslinje fundet i dokumenterne',
                  style: GoogleFonts.kanit(
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                      color: Colors.grey[500]))
              : Column(
                  children: [
                    for (var i = 0; i < _timeline.length; i++)
                      _buildTimelineRow(i, themeColor),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildTimelineRow(int index, Color themeColor) {
    final t = _timeline[index];
    final address = _nonEmpty(t.address);
    return InkWell(
      onTap: () => _editTimelineEvent(index),
      borderRadius: AppRadii.mdRadius,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (t.imageURL.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  t.imageURL,
                  width: 64,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const SizedBox(width: 64, height: 40),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.type.isNotEmpty ? t.type : 'Uden titel',
                      style: GoogleFonts.kanit(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(
                    [
                      _eventDateRange(t),
                      if (t.country.isNotEmpty) t.country,
                    ].join(' · '),
                    style: GoogleFonts.kanit(
                        fontSize: 12, color: Colors.grey[600]),
                  ),
                  if (address != null)
                    Row(
                      children: [
                        Icon(Icons.place_outlined,
                            size: 13, color: Colors.grey[500]),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(address,
                              style: GoogleFonts.kanit(
                                  fontSize: 12, color: Colors.grey[600])),
                        ),
                      ],
                    ),
                  const SizedBox(height: 4),
                  t.description.isEmpty
                      ? Text('Ukendt — ikke i dokumenterne',
                          style: GoogleFonts.kanit(
                              fontSize: 13,
                              fontStyle: FontStyle.italic,
                              color: Colors.orange[800]))
                      : Text(t.description, style: AppTextStyles.body()),
                  ..._eventDetails(t),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.edit_outlined, size: 18, color: Colors.grey[500]),
          ],
        ),
      ),
    );
  }

  static const _transportIcons = {
    'car': Icons.directions_car,
    'bus': Icons.directions_bus,
    'train': Icons.train,
    'flight': Icons.flight,
    'ferry': Icons.directions_boat,
    'walk': Icons.directions_walk,
    'motorcycle': Icons.motorcycle_outlined,
  };

  /// The event's own accommodation/transport/meals/activities, one row
  /// each, only for the ones the documents mentioned.
  List<Widget> _eventDetails(TimelineEvent t) {
    final transport = _nonEmpty(t.transport);
    final accommodation = _nonEmpty(t.accommodation);
    final meals = _nonEmpty(t.meals);
    final activities = _nonEmpty(t.activities);
    final rows = <(IconData, String, String)>[
      if (transport != null)
        (
          _transportIcons[t.transportIcon] ?? Icons.commute,
          'Transport',
          transport
        ),
      if (accommodation != null)
        (Icons.hotel_outlined, 'Overnatning', accommodation),
      if (meals != null) (Icons.restaurant, 'Måltider', meals),
      if (activities != null)
        (Icons.local_activity_outlined, 'Aktiviteter', activities),
    ];
    return [
      for (final (icon, label, value) in rows)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: Colors.grey[600]),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: '$label: ',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(text: value),
                  ]),
                  style: GoogleFonts.kanit(fontSize: 12, color: Colors.black87),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _sourceNote(String source) {
    final found = source.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 2),
      child: Text(
        found ? 'Fundet i $source' : 'Ikke fundet i dokumenterne — tjek selv',
        style: GoogleFonts.kanit(
          fontSize: 11,
          color: found ? Colors.grey[500] : Colors.orange[700],
          fontStyle: found ? FontStyle.normal : FontStyle.italic,
        ),
      ),
    );
  }

  Widget _flightSwitch({
    required IconData icon,
    required String label,
    required String onText,
    required String offText,
    required _Sourced<bool> field,
    required Color themeColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: themeColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: GoogleFonts.kanit(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(field.value ? onText : offText,
                      style: GoogleFonts.kanit(
                          fontSize: 12, color: Colors.grey[600])),
                ],
              ),
            ),
            Switch(
              value: field.value,
              activeThumbColor: themeColor,
              onChanged: (v) => setState(() => field.value = v),
            ),
          ],
        ),
        _sourceNote(field.source),
      ],
    );
  }

  Widget _buildTravelCard(Color themeColor) {
    final dateFormat = DateFormat('dd. MMM yyyy', 'da_DK');
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _dateTile(
                      label: 'Afrejsedato',
                      value: dateFormat.format(_departure!.value),
                      onTap: () => _pickReviewDate(isDeparture: true),
                      themeColor: themeColor,
                    ),
                    _sourceNote(_departure!.source),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _dateTile(
                      label: 'Hjemrejsedato',
                      value: dateFormat.format(_return!.value),
                      onTap: () => _pickReviewDate(isDeparture: false),
                      themeColor: themeColor,
                    ),
                    _sourceNote(_return!.source),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          // Same switches and wording as the trip editor (detailsscreen):
          // they only decide whether the trip starts/ends with a shared
          // flight from the home country or at the destination.
          _flightSwitch(
            icon: Icons.flight_takeoff,
            label: 'Afrejse',
            onText: 'Flyver samlet fra lufthavnen i hjemlandet',
            offText: 'Rejsen starter på destinationen',
            field: _flightAway,
            themeColor: themeColor,
          ),
          const SizedBox(height: AppSpacing.md),
          _flightSwitch(
            icon: Icons.flight_land,
            label: 'Hjemrejse',
            onText: 'Lander samlet i lufthavnen i hjemlandet',
            offText: 'Rejsen slutter på destinationen',
            field: _flightHome,
            themeColor: themeColor,
          ),
        ],
      ),
    );
  }

  Widget _buildDraftField(_DraftField field, Color themeColor) {
    final isUnknown = field.controller.text.isEmpty;
    final hasSource = !isUnknown && field.source.isNotEmpty;
    return TextFormField(
      controller: field.controller,
      style: AppTextStyles.body(),
      decoration: InputDecoration(
        labelText: field.label,
        hintText: isUnknown ? 'Ikke fundet — udfyld manuelt' : null,
        hintStyle: GoogleFonts.kanit(
            fontSize: 12,
            color: Colors.orange[700],
            fontStyle: FontStyle.italic),
        helperText: hasSource ? 'Fundet i ${field.source}' : null,
        helperStyle: GoogleFonts.kanit(fontSize: 11, color: Colors.grey[500]),
        labelStyle: GoogleFonts.kanit(color: Colors.grey[600]),
        suffixIcon: isUnknown
            ? Icon(Icons.edit_outlined, size: 18, color: Colors.orange[700])
            : (hasSource
                ? Icon(Icons.check_circle_outline,
                    size: 18, color: Colors.green[600])
                : null),
        filled: true,
        fillColor:
            isUnknown ? Colors.orange.withValues(alpha: 0.05) : Colors.grey[50],
        border: OutlineInputBorder(
          borderRadius: AppRadii.mdRadius,
          borderSide: BorderSide(
              color: isUnknown
                  ? Colors.orange.withValues(alpha: 0.4)
                  : Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadii.mdRadius,
          borderSide: BorderSide(
              color: isUnknown
                  ? Colors.orange.withValues(alpha: 0.4)
                  : Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadii.mdRadius,
          borderSide: BorderSide(color: AppColors.darkGreen, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  // Step 4 — Create -----------------------------------------------------------

  List<(String, String)> get _summaryRows {
    final dateFormat = DateFormat('dd. MMM yyyy', 'da_DK');
    return [
      for (final field in _fields) (field.label, field.controller.text),
      ('Afrejsedato', dateFormat.format(_departure!.value)),
      ('Hjemrejsedato', dateFormat.format(_return!.value)),
      (
        'Afrejse',
        _flightAway.value
            ? 'Flyver samlet fra hjemlandet'
            : 'Starter på destinationen'
      ),
      (
        'Hjemrejse',
        _flightHome.value ? 'Flyver samlet hjem' : 'Slutter på destinationen'
      ),
      ('Tidslinje', '${_timeline.length} begivenheder'),
    ];
  }

  Widget _buildCreateStep(Color themeColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Klar til at oprette',
            'Rejsen oprettes med de felter I lige har gennemgået. Tomme felter kan udfyldes senere fra rejsens egen side.'),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, value) in _summaryRows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text(label,
                            style: AppTextStyles.body(color: Colors.grey[600])),
                      ),
                      Expanded(
                        child: Text(
                          value.isEmpty ? 'Ukendt' : value,
                          style: GoogleFonts.kanit(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              fontStyle: value.isEmpty
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                              color: value.isEmpty
                                  ? Colors.grey[500]
                                  : Colors.black87),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // Shared helpers ------------------------------------------------------------

  Widget _buildNavButtons(Color themeColor) {
    final isFirst = _currentStep == 0;
    final isLast = _currentStep == _steps.length - 1;
    final onUploadStep = _currentStep == 0;
    final onAnalyzeStep = _currentStep == 1;
    final isAnalyzing = _analysisState == _AnalysisState.analyzing;

    VoidCallback? primaryAction;
    String primaryLabel;

    if (onUploadStep) {
      primaryLabel = 'Analysér med AI';
      primaryAction = _canAnalyze ? _analyze : null;
    } else if (onAnalyzeStep) {
      primaryLabel = 'Analysér med AI';
      primaryAction = isAnalyzing ? null : _analyze;
    } else if (isLast) {
      primaryLabel = 'Opret rejse';
      primaryAction = _isCreating ? null : _createGroup;
    } else {
      primaryLabel = 'Næste';
      primaryAction = () => _goTo(_currentStep + 1);
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
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
      child: Row(
        children: [
          if (!isFirst && !isAnalyzing)
            Expanded(
              child: OutlinedButton(
                onPressed: () => _goTo(_currentStep - 1),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape:
                      RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
                ),
                child: Text('Tilbage',
                    style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
              ),
            ),
          if (!isFirst && !isAnalyzing) const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: primaryAction,
              style: ElevatedButton.styleFrom(
                backgroundColor: themeColor,
                foregroundColor: _onThemeColor(themeColor),
                disabledBackgroundColor: Colors.grey[300],
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
              ),
              child: _isCreating
                  ? SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: _onThemeColor(themeColor)),
                    )
                  : Text(primaryLabel,
                      style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
