import 'dart:async';

import 'package:dio/dio.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';

/// 电视剧, with a region filter and two sorts.
const series = ProviderCategory(
  id: '4',
  name: '电视剧',
  filters: [
    CategoryFilter(
      key: 'region',
      name: '地区',
      options: [
        CategoryOption(value: '韩国', label: '韩国'),
        CategoryOption(value: '日本', label: '日本'),
      ],
    ),
    CategoryFilter(
      key: 'year',
      name: '年份',
      options: [CategoryOption(value: '2025', label: '2025')],
    ),
  ],
  sorts: [
    CategoryOption(value: '2', label: '热播'),
    CategoryOption(value: '0', label: '最新添加'),
  ],
);

/// A provider whose categories have [pages] pages of [perPage] titles, each
/// named for what it was asked ("4 region=韩国 q=love 2.1").
class FakeCategoryProvider extends SkyStreamProvider {
  FakeCategoryProvider({
    this.pages = 3,
    this.perPage = 4,
    this.categories = const [series],
  });

  final int pages;
  final int perPage;
  final List<ProviderCategory> categories;

  /// Every page asked for.
  final asked =
      <
        ({String category, Map<String, String> filters, String query, int page})
      >[];

  /// Pages that fail (until removed).
  final failing = <int>{};

  /// Answers every page with page 1's titles: a provider that ignores pages.
  bool repeats = false;

  /// No titles at all.
  bool empty = false;

  /// Pages wait for this, when set.
  Completer<void>? gate;

  static String describe(Map<String, String> filters, String query) => [
    for (final entry in filters.entries) '${entry.key}=${entry.value}',
    if (query.isNotEmpty) 'q=$query',
  ].join(' ');

  @override
  Future<CategoryPage> getCategoryPage(
    ProviderCategory category,
    Map<String, String> filters,
    String query,
    int page,
  ) async {
    asked.add((
      category: category.id,
      filters: Map.of(filters),
      query: query,
      page: page,
    ));
    await gate?.future;
    if (failing.contains(page)) throw Exception('offline');
    if (empty) return CategoryPage.empty;
    final shown = repeats ? 1 : page;
    final label = describe(filters, query);
    return CategoryPage(
      items: [
        for (var n = 1; n <= perPage; n++)
          MultimediaItem(
            title: '${category.id} $label $shown.$n'.replaceAll('  ', ' '),
            url: '/${category.id}/$label/$shown/$n',
            posterUrl: '',
            headers: const {'Referer': 'https://site.invalid/'},
          ),
      ],
      hasNext: page < pages,
    );
  }

  @override
  Future<List<ProviderCategory>> getCategories() async => categories;

  @override
  String get name => 'Fake Kubb';
  @override
  String get packageName => 'test.categories';
  @override
  String get mainUrl => '';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['zh'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.series};
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const [];
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}
