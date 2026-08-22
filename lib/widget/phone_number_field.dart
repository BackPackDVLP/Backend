import 'package:flutter/material.dart';
import 'package:backend/config/design.dart';
import 'package:google_fonts/google_fonts.dart';

class _Country {
  final String name;
  final String flag;
  final String dialCode;

  const _Country(this.name, this.flag, this.dialCode);
}

// A practical shortlist, not an exhaustive ISO list — Denmark first since
// it's the default, then the countries a Danish travel agency's clientele
// most commonly needs. Anything else is reachable via "Indtast egen
// landekode" in the picker sheet, so this list being incomplete never
// blocks entering a number.
const List<_Country> _kCountries = [
  _Country('Danmark', '🇩🇰', '+45'),
  _Country('Sverige', '🇸🇪', '+46'),
  _Country('Norge', '🇳🇴', '+47'),
  _Country('Island', '🇮🇸', '+354'),
  _Country('Tyskland', '🇩🇪', '+49'),
  _Country('Storbritannien', '🇬🇧', '+44'),
  _Country('USA / Canada', '🇺🇸', '+1'),
  _Country('Holland', '🇳🇱', '+31'),
  _Country('Belgien', '🇧🇪', '+32'),
  _Country('Frankrig', '🇫🇷', '+33'),
  _Country('Spanien', '🇪🇸', '+34'),
  _Country('Italien', '🇮🇹', '+39'),
  _Country('Portugal', '🇵🇹', '+351'),
  _Country('Polen', '🇵🇱', '+48'),
  _Country('Finland', '🇫🇮', '+358'),
  _Country('Østrig', '🇦🇹', '+43'),
  _Country('Schweiz', '🇨🇭', '+41'),
  _Country('Tyrkiet', '🇹🇷', '+90'),
  _Country('Thailand', '🇹🇭', '+66'),
  _Country('De Forenede Arabiske Emirater', '🇦🇪', '+971'),
];

/// A phone-style input split into a country-code picker (flag + dial code,
/// proposed from [_kCountries] with Denmark/+45 as the default, plus a
/// "custom code" entry for anything not in the list) and the local number,
/// combined into one `<code> <number>` string via [onChanged]. Used
/// everywhere a phone or WhatsApp number is entered in the control panel.
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
  String? _flag;

  @override
  void initState() {
    super.initState();
    final trimmed = widget.initialValue.trim();
    final parts = trimmed.split(RegExp(r'\s+'));
    final hasExplicitCode = parts.isNotEmpty && parts.first.startsWith('+');

    if (hasExplicitCode) {
      final code = parts.first;
      _codeController = TextEditingController(text: code);
      _numberController =
          TextEditingController(text: parts.skip(1).join(' '));
      _flag = _flagForDialCode(code);
    } else if (trimmed.isEmpty) {
      _codeController = TextEditingController(text: '+45');
      _numberController = TextEditingController();
      _flag = '🇩🇰';
    } else {
      _codeController = TextEditingController();
      _numberController = TextEditingController(text: trimmed);
      _flag = null;
    }
  }

  String? _flagForDialCode(String code) {
    for (final country in _kCountries) {
      if (country.dialCode == code) return country.flag;
    }
    return null;
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

  Future<void> _openCountryPicker() async {
    String search = '';
    bool showCustom = false;
    final customController = TextEditingController(text: _codeController.text);

    final result = await showModalBottomSheet<_Country?>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            final query = search.trim().toLowerCase();
            final filtered = query.isEmpty
                ? _kCountries
                : _kCountries
                    .where((c) =>
                        c.name.toLowerCase().contains(query) ||
                        c.dialCode.contains(query))
                    .toList();
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text('Vælg landekode', style: AppTextStyles.headingBold()),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    onChanged: (v) => setSheetState(() => search = v),
                    style: GoogleFonts.kanit(fontSize: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Søg land eller kode...',
                      hintStyle: AppTextStyles.body(color: Colors.grey[500]),
                      prefixIcon: const Icon(Icons.search, size: 18),
                      filled: true,
                      fillColor: Colors.grey[50],
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: AppRadii.mdRadius,
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: filtered.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: Text('Ingen match.',
                                style: AppTextStyles.body(color: Colors.grey)),
                          )
                        : ListView(
                            shrinkWrap: true,
                            children: filtered
                                .map((c) => ListTile(
                                      dense: true,
                                      leading: Text(c.flag,
                                          style: const TextStyle(fontSize: 20)),
                                      title: Text(c.name,
                                          style: GoogleFonts.kanit(fontSize: 14)),
                                      trailing: Text(c.dialCode,
                                          style: GoogleFonts.kanit(
                                              fontSize: 14,
                                              color: Colors.grey[600])),
                                      onTap: () =>
                                          Navigator.pop(sheetCtx, c),
                                    ))
                                .toList(),
                          ),
                  ),
                  const Divider(height: 28),
                  if (!showCustom)
                    TextButton.icon(
                      onPressed: () =>
                          setSheetState(() => showCustom = true),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text('Indtast egen landekode',
                          style: GoogleFonts.kanit(fontWeight: FontWeight.w600)),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: customController,
                            autofocus: true,
                            keyboardType: TextInputType.phone,
                            style: GoogleFonts.kanit(fontSize: 14),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '+xxx',
                              filled: true,
                              fillColor: Colors.grey[50],
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 12),
                              border: OutlineInputBorder(
                                borderRadius: AppRadii.mdRadius,
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                widget.focusedBorderColor ?? Colors.black87,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: AppRadii.mdRadius),
                          ),
                          onPressed: () {
                            var code = customController.text.trim();
                            if (code.isEmpty) return;
                            if (!code.startsWith('+')) code = '+$code';
                            Navigator.pop(sheetCtx, _Country('', '', code));
                          },
                          child: const Text('Vælg'),
                        ),
                      ],
                    ),
                ],
              ),
            );
          },
        );
      },
    );

    if (result != null) {
      setState(() {
        _codeController.text = result.dialCode;
        _flag = result.flag.isEmpty ? null : result.flag;
      });
      _emit();
    }
  }

  InputDecoration _decoration({required String label, Widget? prefixIcon}) {
    final fill = widget.fillColor ?? Colors.grey[50];
    final focusColor = widget.focusedBorderColor ?? Colors.grey.shade400;
    return InputDecoration(
      labelText: label,
      labelStyle: AppTextStyles.body(color: Colors.grey[600]),
      prefixIcon: prefixIcon,
      filled: true,
      fillColor: fill,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: AppRadii.mdRadius,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppRadii.mdRadius,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppRadii.mdRadius,
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
            width: 112,
            child: TextField(
              controller: _codeController,
              readOnly: true,
              showCursor: false,
              onTap: _openCountryPicker,
              style: GoogleFonts.kanit(fontSize: 14, fontWeight: FontWeight.w600),
              decoration: _decoration(
                label: 'Kode',
                prefixIcon: Padding(
                  padding: const EdgeInsets.only(left: 10, right: 2),
                  child: Text(_flag ?? '🌐', style: const TextStyle(fontSize: 17)),
                ),
              ).copyWith(
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 34, minHeight: 24),
                suffixIcon: Icon(Icons.keyboard_arrow_down,
                    size: 18, color: Colors.grey[500]),
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 24, minHeight: 24),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
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
