import 'package:backend/config/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20.0)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
          maxWidth: MediaQuery.of(context).size.width * 0.6,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Vælg billede',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              TextField(
                
                controller: _searchController,
                decoration: InputDecoration(
                  enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.black),
                        )
                    ,
                  hintText: 'Søg efter by, land, natur...',
                  filled: true,
                  fillColor: AppColors.chipBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search, color: Colors.black54),
                    onPressed: () => _searchImages(_searchController.text),
                  ),
                ),
                onSubmitted: _searchImages,
              ),
              const SizedBox(height: 16),
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

                              return GestureDetector(
                                onTap: () {
                                  widget.onImageSelected(image['urls']['regular']);
                                  Navigator.pop(context);
                                },
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(12.0),
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
                                        child: Text(
                                          'Photo by $photographerName on Unsplash',
                                          style: const TextStyle(color: Colors.white, fontSize: 10),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                  ],
                                ),
                              );
                            },
                          ),
              ),
              const SizedBox(height: 16),
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
