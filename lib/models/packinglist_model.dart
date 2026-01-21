import 'package:equatable/equatable.dart';

class PackinglistCategories extends Equatable {
  final String categoryName;
  final List<String> items;
  final String iconName;

  const PackinglistCategories({
    required this.categoryName,
    required this.items,
    required this.iconName,
  });

  factory PackinglistCategories.fromSnapshot(Map<String, dynamic> snap) {
    return PackinglistCategories(
      categoryName: snap['categoryName'] ?? '',
      items: (snap['items'] as List? ?? [])
          .map((item) => item.toString())
          .toList(),
      iconName: snap['iconName'] ?? 'mdiHelpBoxMultiple',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'categoryName': categoryName,
      'items': items,
      'iconName': iconName,
    };
  }

  Map<String, dynamic> toJson() => toMap();

  @override
  List<Object?> get props => [
        categoryName,
        items,
        iconName,
      ];

  static List<PackinglistCategories> packinglistCategories = [
    const PackinglistCategories(
      iconName: 'question_mark',
      categoryName: 'Need to have',
      items: ['Sko', 'Hansker', 'Rygsæk'],
    ),
  ];
}
