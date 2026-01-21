import 'package:equatable/equatable.dart';

class Coupon extends Equatable {
  final String couponName;
  final String description;
  final String imageURL;
  final String link;

  const Coupon(
      {required this.couponName,
      required this.description,
      required this.imageURL,
      required this.link});

  factory Coupon.fromSnapshot(Map<String, dynamic> snap) {
    return Coupon(
      couponName: snap['couponName'] ?? '',
      description: snap['description'] ?? '',
      imageURL: snap['imageURL'] ?? '',
      link: snap['link'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'couponName': couponName,
      'description': description,
      'imageURL': imageURL,
      'link': link,
    };
  }
Map<String, dynamic> toJson() => toMap();

  @override
  List<Object?> get props => [
        couponName,
        description,
        imageURL,
        link,
      ];
}
