import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A phone-style input split into a small country-code field (e.g. "+45")
/// and the local number, combined into one `<code> <number>` string via
/// [onChanged]. Used everywhere a phone or WhatsApp number is entered in
/// the control panel, so every newly-saved number carries an explicit
/// country code.
///
/// Numbers saved before this field existed have no country code embedded
/// (e.g. "4520304050"). Rather than guess where the code ends and the
/// local number begins, an untouched legacy value is kept verbatim in the
/// number half with the code half left blank, so simply opening and
/// re-saving a record can never silently duplicate or corrupt it.
class PhoneNumberField extends StatefulWidget {
  final String initialValue;
  final String label;
  final IconData icon;
  final Color? iconColor;
  final Color? fillColor;
  final Color? focusedBorderColor;
  final ValueChanged<String> onChanged;

  const PhoneNumberField({
    super.key,
    required this.initialValue,
    required this.label,
    required this.icon,
    this.iconColor,
    this.fillColor,
    this.focusedBorderColor,
    required this.onChanged,
  });

  @override
  State<PhoneNumberField> createState() => _PhoneNumberFieldState();
}

class _PhoneNumberFieldState extends State<PhoneNumberField> {
  late final TextEditingController _codeController;
  late final TextEditingController _numberController;

  @override
  void initState() {
    super.initState();
    final trimmed = widget.initialValue.trim();
    final parts = trimmed.split(RegExp(r'\s+'));
    final hasExplicitCode = parts.isNotEmpty && parts.first.startsWith('+');

    if (hasExplicitCode) {
      _codeController = TextEditingController(text: parts.first);
      _numberController =
          TextEditingController(text: parts.skip(1).join(' '));
    } else if (trimmed.isEmpty) {
      _codeController = TextEditingController(text: '+45');
      _numberController = TextEditingController();
    } else {
      _codeController = TextEditingController();
      _numberController = TextEditingController(text: trimmed);
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _numberController.dispose();
    super.dispose();
  }

  void _emit() {
    final code = _codeController.text.trim();
    final number = _numberController.text.trim();
    if (number.isEmpty) {
      widget.onChanged('');
    } else if (code.isEmpty) {
      widget.onChanged(number);
    } else {
      widget.onChanged('$code $number');
    }
  }

  InputDecoration _decoration({required String label, Widget? prefixIcon}) {
    final fill = widget.fillColor ?? Colors.grey[50];
    final focusColor = widget.focusedBorderColor ?? Colors.grey.shade400;
    return InputDecoration(
      labelText: label,
      labelStyle: GoogleFonts.kanit(fontSize: 13, color: Colors.grey[600]),
      prefixIcon: prefixIcon,
      filled: true,
      fillColor: fill,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: focusColor, width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: TextField(
              controller: _codeController,
              keyboardType: TextInputType.phone,
              style: GoogleFonts.kanit(fontSize: 14),
              onChanged: (_) => _emit(),
              decoration: _decoration(label: 'Kode'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _numberController,
              keyboardType: TextInputType.phone,
              style: GoogleFonts.kanit(fontSize: 14),
              onChanged: (_) => _emit(),
              decoration: _decoration(
                label: widget.label,
                prefixIcon: Icon(widget.icon,
                    size: 19, color: widget.iconColor ?? Colors.grey[500]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
