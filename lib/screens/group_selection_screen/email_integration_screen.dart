import 'package:backend/config/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design sketch for a generic "send from our own e-mail" integration.
///
/// Purely a UI mockup — nothing here talks to Firestore, Cloud Functions,
/// or any real mail server. It exists so the flow (connect → sender details
/// → pick which messages use it → activate → monitor) can be reviewed
/// before any backend work is scoped. Deliberately provider-agnostic (plain
/// SMTP fields), same spirit as CrmIntegrationScreen.
class EmailIntegrationScreen extends StatefulWidget {
  final Color themeColor;

  const EmailIntegrationScreen({super.key, required this.themeColor});

  @override
  State<EmailIntegrationScreen> createState() => _EmailIntegrationScreenState();
}

enum _ConnectionState { idle, testing, success }

class _EmailIntegrationScreenState extends State<EmailIntegrationScreen> {
  int _currentStep = 0;

  final _emailController = TextEditingController();
  final _smtpHostController = TextEditingController();
  final _smtpPortController = TextEditingController(text: '587');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  _ConnectionState _connectionState = _ConnectionState.idle;

  final _senderNameController = TextEditingController();
  final _replyToController = TextEditingController();

  bool _activated = false;

  static const _steps = [
    'Forbind',
    'Afsender',
    'Vælg beskeder',
    'Aktivér',
    'Status',
  ];

  final Map<String, bool> _messageTriggers = {
    'Velkomstbesked ved oprettelse af rejse': true,
    'Påmindelse før afrejse': true,
    'Kvittering ved SOS/nødopkald': false,
    'Beskeder sendt fra rejseleder i appen': false,
  };

  @override
  void dispose() {
    _emailController.dispose();
    _smtpHostController.dispose();
    _smtpPortController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _senderNameController.dispose();
    _replyToController.dispose();
    super.dispose();
  }

  Color _onThemeColor(Color color) =>
      color.computeLuminance() < 0.5 ? Colors.white : Colors.black;

  void _testConnection() {
    setState(() => _connectionState = _ConnectionState.testing);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => _connectionState = _ConnectionState.success);
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
        title: Text('E-mail-integration',
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
              padding: const EdgeInsets.all(20),
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
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Eksempel — viser hvordan en e-mail-integration fungerer. Ikke forbundet til en rigtig e-mailkonto endnu.',
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
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: circleColor,
                        ),
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

  Widget _buildStepContent(Color themeColor) {
    switch (_currentStep) {
      case 0:
        return _buildConnectStep(themeColor);
      case 1:
        return _buildSenderStep(themeColor);
      case 2:
        return _buildMessagesStep(themeColor);
      case 3:
        return _buildActivateStep(themeColor);
      default:
        return _buildStatusStep(themeColor);
    }
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
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

  Widget _stepHeading(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  GoogleFonts.kanit(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(subtitle,
              style: GoogleFonts.kanit(fontSize: 13, color: Colors.grey[600])),
        ],
      ),
    );
  }

  // Step 1 — Connect ---------------------------------------------------

  Widget _buildConnectStep(Color themeColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Forbind jeres e-mail',
            'Indtast serveroplysningerne for jeres e-mailkonto (SMTP), så BackPack kan sende rejsebeskeder fra jeres egen adresse i stedet for en fælles BackPack-adresse.'),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTextField(
                controller: _emailController,
                label: 'Afsender-adresse',
                icon: Icons.alternate_email,
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildTextField(
                      controller: _smtpHostController,
                      label: 'SMTP-server',
                      icon: Icons.dns_outlined,
                      helperText: 'F.eks. smtp.jeresudbyder.dk',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTextField(
                      controller: _smtpPortController,
                      label: 'Port',
                      icon: Icons.numbers,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _buildTextField(
                controller: _usernameController,
                label: 'Brugernavn',
                icon: Icons.person_outline,
              ),
              const SizedBox(height: 14),
              _buildTextField(
                controller: _passwordController,
                label: 'Adgangskode / app-adgangskode',
                icon: Icons.vpn_key_outlined,
                obscure: true,
                helperText:
                    'Gemmes krypteret og vises aldrig i klar tekst igen.',
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  onPressed: _connectionState == _ConnectionState.testing
                      ? null
                      : _testConnection,
                  icon: _connectionState == _ConnectionState.testing
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: _onThemeColor(themeColor)))
                      : const Icon(Icons.wifi_tethering, size: 18),
                  label: Text('Test forbindelse',
                      style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: themeColor,
                    foregroundColor: _onThemeColor(themeColor),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              if (_connectionState == _ConnectionState.success) ...[
                const SizedBox(height: 14),
                _statusChip(
                  icon: Icons.check_circle,
                  color: Colors.green,
                  text: 'Forbindelse oprettet — testmail afsendt uden fejl.',
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // Step 2 — Sender details --------------------------------------------

  Widget _buildSenderStep(Color themeColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Afsenderoplysninger',
            'Sådan vil beskederne fremstå for modtageren.'),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTextField(
                controller: _senderNameController,
                label: 'Afsendernavn',
                icon: Icons.badge_outlined,
                helperText: 'F.eks. jeres bureaunavn — vises som "Fra".',
              ),
              const SizedBox(height: 14),
              _buildTextField(
                controller: _replyToController,
                label: 'Svar-til adresse (valgfri)',
                icon: Icons.reply_outlined,
                keyboardType: TextInputType.emailAddress,
                helperText:
                    'Hvis den skal være anderledes end afsenderadressen.',
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.visibility_outlined,
                        size: 18, color: Colors.grey[500]),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Forhåndsvisning: "${_senderNameController.text.isEmpty ? 'Jeres Bureau' : _senderNameController.text}" <${_emailController.text.isEmpty ? 'kontakt@jeresbureau.dk' : _emailController.text}>',
                        style: GoogleFonts.kanit(
                            fontSize: 12, color: Colors.grey[700]),
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

  // Step 3 — Which messages use this address -----------------------------

  Widget _buildMessagesStep(Color themeColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Vælg beskeder',
            'Vælg hvilke af BackPacks automatiske beskeder der skal sendes fra jeres egen adresse.'),
        _card(
          child: Column(
            children: _messageTriggers.keys.map((label) {
              return CheckboxListTile(
                value: _messageTriggers[label],
                onChanged: (v) =>
                    setState(() => _messageTriggers[label] = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                activeColor: themeColor,
                title: Text(label,
                    style: GoogleFonts.kanit(
                        fontSize: 13, fontWeight: FontWeight.w500)),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // Step 4 — Activate -----------------------------------------------------

  Widget _buildActivateStep(Color themeColor) {
    final activeTriggerCount = _messageTriggers.values.where((v) => v).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading('Aktivér integrationen',
            'Gennemgå jeres opsætning, og slå integrationen til.'),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _summaryRow(
                  'Afsender-adresse',
                  _emailController.text.isEmpty
                      ? 'Ikke udfyldt'
                      : _emailController.text),
              _summaryRow(
                  'Forbindelse',
                  _connectionState == _ConnectionState.success
                      ? 'Testet ✔'
                      : 'Ikke testet endnu'),
              _summaryRow(
                  'Afsendernavn',
                  _senderNameController.text.isEmpty
                      ? 'Ikke udfyldt'
                      : _senderNameController.text),
              _summaryRow('Beskeder valgt',
                  '$activeTriggerCount / ${_messageTriggers.length}'),
              const Divider(height: 28),
              Row(
                children: [
                  Expanded(
                    child: Text('Aktivér integration',
                        style: GoogleFonts.kanit(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  Switch(
                    value: _activated,
                    activeThumbColor: themeColor,
                    onChanged: (v) => setState(() => _activated = v),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Step 5 — Status ---------------------------------------------------------

  Widget _buildStatusStep(Color themeColor) {
    final events = [
      (
        'Velkomstbesked — Familietur til Rom',
        'Leveret',
        true,
        'for 5 minutter siden'
      ),
      (
        'Påmindelse før afrejse — Firmatur, Nordsøen A/S',
        'Leveret',
        true,
        'i går kl. 08:03'
      ),
      (
        'Velkomstbesked — Ukendt modtager',
        'Afvist af modtagers server',
        false,
        'i går kl. 07:58'
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeading(
            'Status og fejlfinding',
            _activated
                ? 'Integrationen er aktiv. Herunder ses de seneste udsendte beskeder.'
                : 'Integrationen er ikke aktiveret endnu — eksempel på hvordan afsendelseslog vil se ud.'),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _activated
                        ? Icons.check_circle
                        : Icons.pause_circle_outline,
                    color: _activated ? Colors.green : Colors.grey,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(_activated ? 'Aktiv' : 'Inaktiv',
                      style: GoogleFonts.kanit(
                          fontWeight: FontWeight.w600,
                          color: _activated
                              ? Colors.green[700]
                              : Colors.grey[700])),
                ],
              ),
              const SizedBox(height: 16),
              ...events.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          e.$3 ? Icons.check_circle : Icons.error,
                          size: 18,
                          color: e.$3 ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.$1,
                                  style: GoogleFonts.kanit(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                              Text(e.$2,
                                  style: GoogleFonts.kanit(
                                      fontSize: 12, color: Colors.grey[600])),
                            ],
                          ),
                        ),
                        Text(e.$4,
                            style: GoogleFonts.kanit(
                                fontSize: 11, color: Colors.grey[400])),
                      ],
                    ),
                  )),
              Text('Kun de seneste 20 udsendelser vises her.',
                  style:
                      GoogleFonts.kanit(fontSize: 11, color: Colors.grey[400])),
            ],
          ),
        ),
      ],
    );
  }

  // Shared helpers ----------------------------------------------------------

  Widget _summaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label,
                style:
                    GoogleFonts.kanit(fontSize: 13, color: Colors.grey[600])),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.kanit(
                    fontSize: 13, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

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

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscure = false,
    TextInputType? keyboardType,
    String? helperText,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: GoogleFonts.kanit(),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        helperStyle: GoogleFonts.kanit(fontSize: 11),
        labelStyle: GoogleFonts.kanit(color: Colors.grey[600]),
        prefixIcon: Icon(icon, color: Colors.grey[400], size: 20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.darkGreen, width: 2),
        ),
        filled: true,
        fillColor: Colors.grey[50],
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  Widget _buildNavButtons(Color themeColor) {
    final isFirst = _currentStep == 0;
    final isLast = _currentStep == _steps.length - 1;
    return Container(
      padding: const EdgeInsets.all(16),
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
                  : () => _goTo(_currentStep + 1),
              style: ElevatedButton.styleFrom(
                backgroundColor: themeColor,
                foregroundColor: _onThemeColor(themeColor),
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
    );
  }
}
