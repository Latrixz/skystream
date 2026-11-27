import '../domain/entity/multimedia_item.dart';

/// One choice of a [CategoryFilter] or a category's sort: the [value] the
/// provider is given back, and the [label] shown.
class CategoryOption {
  const CategoryOption({required this.value, required this.label});

  factory CategoryOption.fromJson(Map<String, dynamic> json) {
    final value = '${json['value'] ?? ''}';
    final label = json['label'] as String?;
    return CategoryOption(
      value: value,
      label: label == null || label.isEmpty ? value : label,
    );
  }

  final String value;
  final String label;

  Map<String, dynamic> toJson() => {'value': value, 'label': label};

  @override
  bool operator ==(Object other) =>
      other is CategoryOption && other.value == value && other.label == label;

  @override
  int get hashCode => Object.hash(value, label);
}

/// A filter of a category (a genre, a region, a year): its options leave out
/// "all", which is the filter left unset.
class CategoryFilter {
  const CategoryFilter({
    required this.key,
    required this.name,
    required this.options,
  });

  factory CategoryFilter.fromJson(Map<String, dynamic> json) => CategoryFilter(
    key: '${json['key'] ?? ''}',
    name: json['name'] as String? ?? '${json['key'] ?? ''}',
    options: _options(json['options']),
  );

  /// What the provider knows the filter by, the key of its choice in
  /// [SkyStreamProvider.getCategoryPage]'s filters.
  final String key;
  final String name;
  final List<CategoryOption> options;

  /// The option chosen in [filters], or null for all.
  CategoryOption? chosenIn(Map<String, String> filters) {
    final value = filters[key];
    if (value == null) return null;
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'options': [for (final option in options) option.toJson()],
  };
}

/// A section of a provider's catalogue to browse (Movies, TV Series, ...),
/// with its own filters and sorts. See [SkyStreamProvider.getCategories].
class ProviderCategory {
  const ProviderCategory({
    required this.id,
    required this.name,
    this.filters = const [],
    this.sorts = const [],
  });

  factory ProviderCategory.fromJson(Map<String, dynamic> json) =>
      ProviderCategory(
        id: '${json['id'] ?? ''}',
        name: json['name'] as String? ?? '',
        filters: [
          for (final filter in (json['filters'] as List?) ?? const [])
            if (filter is Map)
              CategoryFilter.fromJson(Map<String, dynamic>.from(filter)),
        ].where((f) => f.key.isNotEmpty && f.options.isNotEmpty).toList(),
        sorts: _options(json['sorts']),
      );

  /// The key the chosen sort travels under in
  /// [SkyStreamProvider.getCategoryPage]'s filters.
  static const String sortKey = 'sort';

  final String id;
  final String name;
  final List<CategoryFilter> filters;

  /// The orders the category can be listed in; the first is the default.
  final List<CategoryOption> sorts;

  /// The sort chosen in [filters], or the default.
  CategoryOption? sortIn(Map<String, String> filters) {
    final value = filters[sortKey];
    for (final sort in sorts) {
      if (sort.value == value) return sort;
    }
    return sorts.isEmpty ? null : sorts.first;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'filters': [for (final filter in filters) filter.toJson()],
    'sorts': [for (final sort in sorts) sort.toJson()],
  };
}

List<CategoryOption> _options(Object? raw) => [
  for (final option in (raw as List?) ?? const [])
    if (option is Map && option['value'] != null)
      CategoryOption.fromJson(Map<String, dynamic>.from(option)),
];

/// One page of a category's titles, and whether a page follows.
class CategoryPage {
  const CategoryPage({required this.items, required this.hasNext});

  static const CategoryPage empty = CategoryPage(items: [], hasNext: false);

  final List<MultimediaItem> items;
  final bool hasNext;
}
