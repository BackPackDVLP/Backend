import 'package:backend/config/app_colors.dart';
import 'package:backend/config/design.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';

// Unsplash API guidelines: every attribution link must carry these UTM
// parameters, with utm_source = the application name registered at
// unsplash.com/developers.
const _unsplashUtm = 'utm_source=BackPack&utm_medium=referral';

String _withUnsplashUtm(String url) =>
    '$url${url.contains('?') ? '&' : '?'}$_unsplashUtm';

class UnsplashImagePicker extends StatefulWidget {
  final Function(String) onImageSelected; // returns the image URL

  const UnsplashImagePicker({super.key, required this.onImageSelected});

  @override
  State<UnsplashImagePicker> createState() => _UnsplashImagePickerState();
}

class _UnsplashImagePickerState extends State<UnsplashImagePicker> {
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _images = [];
  bool _loading = false;

  Future<void> _searchImages(String query) async {
    setState(() => _loading = true);

    final url = Uri.parse(
        'https://api.unsplash.com/search/photos?query=$query&per_page=30&client_id=8m8d1MlhP25S-ksIYEsYI7Ymi5dApA7gSc5C-WjyKS0');

    final response = await http.get(url);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      setState(() => _images = data['results']);
    } else {
      print('Error fetching images: ${response.statusCode}');
    }

    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.panelBackground,
      shape: RoundedRectangleBorder(borderRadius: AppRadii.lgRadius),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
          maxWidth: MediaQuery.of(context).size.width * 0.6,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Vælg billede',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              TextField(
                
                controller: _searchController,
                decoration: InputDecoration(
                  enabledBorder: OutlineInputBorder(
                          borderRadius: AppRadii.mdRadius,
                          borderSide: BorderSide(color: Colors.black),
                        )
                    ,
                  hintText: 'Søg efter by, land, natur...',
                  filled: true,
                  fillColor: AppColors.chipBackground,
                  border: OutlineInputBorder(
                    borderRadius: AppRadii.mdRadius,
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search, color: Colors.black54),
                    onPressed: () => _searchImages(_searchController.text),
                  ),
                ),
                onSubmitted: _searchImages,
              ),
              const SizedBox(height: AppSpacing.lg),
              Expanded(
                child: _loading
                    ? Center(child: CircularProgressIndicator(color: Colors.brown[400]))
                    : _images.isEmpty
                        ? Center(
                            child: Text(
                              'Indtast et søgeord for at finde billeder.',
                              style: TextStyle(color: Colors.brown[800], fontSize: 16),
                            ),
                          )
                        : GridView.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
                            itemCount: _images.length,
                            itemBuilder: (context, index) {
                              final image = _images[index];
                              final imageUrl = image['urls']['small'];
                              final photographerName = image['user']['name'] ?? 'Unsplash User';
                              final photographerUrl =
                                  image['user']?['links']?['html'] as String? ??
                                      'https://unsplash.com';

                              return GestureDetector(
                                onTap: () {
                                  widget.onImageSelected(image['urls']['regular']);
                                  Navigator.pop(context);
                                },
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius: AppRadii.mdRadius,
                                      child: Image.network(imageUrl, fit: BoxFit.cover),
                                    ),
                                    Positioned( // Attribution overlay
                                      bottom: 0,
                                      left: 0,
                                      right: 0,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 6.0),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.5),
                                          borderRadius: const BorderRadius.only(
                                            bottomLeft: Radius.circular(12.0),
                                            bottomRight: Radius.circular(12.0),
                                          ),
                                        ),
                                        child: _UnsplashAttribution(
                                          photographerName: photographerName,
                                          photographerUrl: photographerUrl,
                                        ),
                                      ),
                                    )
                                  ],
                                ),
                              );
                            },
                          ),
              ),
              const SizedBox(height: AppSpacing.lg),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Annuller', style: TextStyle(color: Colors.brown[800], fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Photo by [name] on Unsplash", with the photographer's name linking to
/// their Unsplash profile and "Unsplash" to unsplash.com — the attribution
/// format Unsplash requires for production API access. The links have
/// their own tap handlers, so clicking one opens the page instead of
/// selecting the photo.
class _UnsplashAttribution extends StatelessWidget {
  const _UnsplashAttribution({
    required this.photographerName,
    required this.photographerUrl,
  });

  final String photographerName;
  final String photographerUrl;

  static const _style = TextStyle(color: Colors.white, fontSize: 10);

  // Danish genitive: "Annie Spratt" → "Annie Spratts", but a name
  // already ending in s/x/z just gets an apostrophe ("Hans'").
  String get _possessive {
    final lower = photographerName.toLowerCase();
    return lower.endsWith('s') || lower.endsWith('x') || lower.endsWith('z')
        ? "$photographerName'"
        : '${photographerName}s';
  }

  Widget _link(String text, String url, {String? tooltip}) {
    final link = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse(_withUnsplashUtm(url)),
            mode: LaunchMode.externalApplication),
        child: Text(
          text,
          style: _style.copyWith(
            decoration: TextDecoration.underline,
            decorationColor: Colors.white,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    return tooltip == null ? link : Tooltip(message: tooltip, child: link);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text('Photo by ', style: _style),
        Flexible(
          child: _link(photographerName, photographerUrl,
              tooltip: 'Gå til $_possessive side på Unsplash'),
        ),
        const Text(' on ', style: _style),
        _link('Unsplash', 'https://unsplash.com/'),
      ],
    );
  }
}
