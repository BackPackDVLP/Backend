import 'package:equatable/equatable.dart';

class BureauOffer extends Equatable {
  final String offerName;
  final String description;
  final String imageURL;
  final String teaser;
  final String? price;

  const BureauOffer(
      {required this.offerName,
      required this.description,
      required this.imageURL,
      required this.teaser,
      this.price});

  factory BureauOffer.fromSnapshot(Map<String, dynamic> snap) {
    return BureauOffer(
      offerName: snap['offerName'] ?? '',
      description: snap['description'] ?? '',
      imageURL: snap['imageURL'] ?? '',
      teaser: snap['teaser'] ?? '',
      price: snap['price'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'offerName': offerName,
      'description': description,
      'imageURL': imageURL,
      'teaser': teaser,
      'price': price,
    };
  }

  Map<String, dynamic> toJson() => toMap();
  
  @override
  List<Object?> get props => [
        offerName,
        description,
        imageURL,
      ];
}
