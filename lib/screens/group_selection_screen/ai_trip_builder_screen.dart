import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design sketch for a TripIt-style "build a trip from documents" flow.
///
/// Purely a UI mockup — file picking is real (so it feels tangible), but
/// nothing is actually analyzed, uploaded, or written to Firestore. The
/// "extracted" draft is canned data, deliberately showing some fields
/// filled in and others left blank/unknown, since that's the whole point:
/// the AI should only fill what the documents actually support and leave
/// the rest for a human to complete, never guess.
class AiTripBuilderScreen extends StatefulWidget {
  final Color themeColor;

  const AiTripBuilderScreen({super.key, required this.themeColor});

  @override
  State<AiTripBuilderScreen> createState() => _AiTripBuilderScreenState();
}

enum _AnalysisState { idle, analyzing, done }

class _UploadedFile {
  final String name;
  final IconData icon;

  const _UploadedFile(this.name, this.icon);
}

class _DraftField {
  final String label;
  final TextEditingController controller;
  final String source; // which document it was found in, or '' if unknown

  _DraftField(this.label, String initialValue, this.source)
      : controller = TextEditingController(text: initialValue);
}

class _AiTripBuilderScreenState extends State<AiTripBuilderScreen> {
  int _currentStep = 0;
  _AnalysisState _analysisState = _AnalysisState.idle;

  final List<_UploadedFile> _files = [];

  static const _steps = ['Upload', 'Analyse', 'Gennemgå udkast', 'Opret'];

  late final List<_DraftField> _fields = [
    _DraftField('Rejsenavn', '', ''),
    _DraftField('Afrejsedato', '14. sep. 2026', 'Flybillet.pdf'),
    _DraftField('Hjemrejsedato', '21. sep. 2026', 'Flybillet.pdf'),
    _DraftField('Fly ud', 'SK1234 · CPH → FCO · 07:15', 'Flybillet.pdf'),
    _DraftField('Fly hjem', 'SK1235 · FCO → CPH · 21:40', 'Flybillet.pdf'),
    _DraftField('Overnatning', 'Hotel Trastevere, Rom', 'Hotelbekræftelse.pdf'),
    _DraftField('Rejseleder', '', ''),
    _DraftField('Nødtelefonnummer', '', ''),
  ];

  final List<_TimelineDraft> _timeline = [
    _TimelineDraft('Dag 1', 'Ankomst og indkvartering', 'Hotelbekræftelse.pdf'),
    _TimelineDraft('Dag 2–6', '', ''),
    _TimelineDraft('Dag 7', 'Afrejse til lufthavnen', 'Flybillet.pdf'),
  ];

  @override
  void dispose() {
    for (final f in _fields) {
      f.controller.dispose();
    }
    super.dispose();
  }

  Color _onThemeColor(Color color) =>
      color.computeLuminance() < 0.5 ? Colors.white : Colors.black;

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg'],
    );
    if (result == null) return;
    setState(() {
      for (final f in result.files) {
        final ext = (f.extension ?? '').toLowerCase();
        _files.add(_UploadedFile(
          f.name,
          ext == 'pdf' ? Icons.picture_as_pdf_outlined : Icons.image_outlined,
        ));
      }
    });
  }

  void _removeFile(int index) => setState(() => _files.removeAt(index));

  void _analyze() {
    setState(() => _analysisState = _AnalysisState.analyzing);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() => _analysisState = _AnalysisState.done);
      _goTo(2);
    });
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
          _buildSketchBanner(),
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

  Widget _buildSketchBanner() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFF4E5),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.design_services_outlined,
              size: 16, color: Color(0xFF9A6700)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Eksempel — viser hvordan AI kunne bygge en rejse ud fra jeres dokumenter. Analysen herunder er ikke rigtig endnu.',
              style: GoogleFonts.kanit(
                  fontSize: 12,
                  color: const Color(0xFF9A6700),
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
          Text(title,
              style:
                  AppTextStyles.headingBold()),
          const SizedBox(height: AppSpacing.xs),
          Text(subtitle,
              style: AppTextStyles.body(color: Colors.grey[600])),
        ],
      ),
    );
  }

  // Step 1 — Upload -------------------------------------------------------

  Widget _buildUploadStep(Color themeColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Upload rejsens dokumenter',
            'Flybilletter, hotelbekræftelser, programmer — som med TripIt lader I AI\'en læse dem og bygge et udkast til rejsen. Alt den ikke kan finde, efterlades tomt til jer.'),
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
                      Text('Vælg filer (PDF, billeder)',
                          style: GoogleFonts.kanit(
                              fontWeight: FontWeight.w600,
                              color: Colors.black87)),
                      const SizedBox(height: 2),
                      Text('eller træk og slip',
                          style: GoogleFonts.kanit(
                              fontSize: 12, color: Colors.grey[600])),
                    ],
                  ),
                ),
              ),
              if (_files.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                ..._files.asMap().entries.map((entry) {
                  final i = entry.key;
                  final file = entry.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(file.icon, size: 20, color: Colors.grey[600]),
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
      ],
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
        _stepHeading('AI analyserer jeres dokumenter',
            '${_files.length} fil${_files.length == 1 ? '' : 'er'} bliver læst igennem.'),
        _card(
          child: Column(
            children: [
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
          ),
        ),
      ],
    );
  }

  // Step 3 — Review draft ----------------------------------------------------

  Widget _buildReviewStep(Color themeColor) {
    final unknownCount = _fields.where((f) => f.controller.text.isEmpty).length;
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
        Text('Tidslinje-udkast',
            style:
                GoogleFonts.kanit(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        _card(
          child: Column(
            children: _timeline
                .map((t) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 70,
                            child: Text(t.day,
                                style: GoogleFonts.kanit(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                          ),
                          Expanded(
                            child: t.description.isEmpty
                                ? Text('Ukendt — ikke i dokumenterne',
                                    style: GoogleFonts.kanit(
                                        fontSize: 13,
                                        fontStyle: FontStyle.italic,
                                        color: Colors.orange[800]))
                                : Text(t.description,
                                    style: AppTextStyles.body()),
                          ),
                        ],
                      ),
                    ))
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildDraftField(_DraftField field, Color themeColor) {
    final isUnknown = field.controller.text.isEmpty;
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
        helperText: isUnknown ? null : 'Fundet i ${field.source}',
        helperStyle: GoogleFonts.kanit(fontSize: 11, color: Colors.grey[500]),
        labelStyle: GoogleFonts.kanit(color: Colors.grey[600]),
        suffixIcon: isUnknown
            ? Icon(Icons.edit_outlined, size: 18, color: Colors.orange[700])
            : Icon(Icons.check_circle_outline,
                size: 18, color: Colors.green[600]),
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
              for (final field in _fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text(field.label,
                            style: AppTextStyles.body(color: Colors.grey[600])),
                      ),
                      Expanded(
                        child: Text(
                          field.controller.text.isEmpty
                              ? 'Ukendt'
                              : field.controller.text,
                          style: GoogleFonts.kanit(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              fontStyle: field.controller.text.isEmpty
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                              color: field.controller.text.isEmpty
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

    VoidCallback? primaryAction;
    String primaryLabel;

    if (onUploadStep) {
      primaryLabel = 'Analysér med AI';
      primaryAction = _files.isEmpty ? null : _analyze;
    } else if (onAnalyzeStep) {
      primaryLabel = 'Analysér med AI';
      primaryAction =
          _analysisState == _AnalysisState.analyzing ? null : _analyze;
    } else if (isLast) {
      primaryLabel = 'Opret rejse';
      primaryAction = () => Navigator.of(context).pop();
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
          if (!isFirst && !onAnalyzeStep)
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
          if (!isFirst && !onAnalyzeStep) const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: primaryAction,
              style: ElevatedButton.styleFrom(
                backgroundColor: themeColor,
                foregroundColor: _onThemeColor(themeColor),
                disabledBackgroundColor: Colors.grey[300],
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: AppRadii.mdRadius),
              ),
              child: Text(primaryLabel,
                  style: GoogleFonts.kanit(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineDraft {
  final String day;
  final String description;
  final String source;

  _TimelineDraft(this.day, this.description, this.source);
}
