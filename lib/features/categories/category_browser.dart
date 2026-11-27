import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/domain/entity/multimedia_item.dart';
import '../../core/extensions/base_provider.dart';

/// What the category screen shows of one of a provider's categories: the
/// chosen filters, sort and search, and the titles paged in so far.
///
/// Pages come one at a time, deduplicated by URL (a provider's pages can
/// overlap), and stop at the first that says no page follows, or that adds
/// nothing new (a provider that ignores the page number would repeat its
/// first page forever). Changing a filter, the sort or the search starts over
/// from page 1; an answer for what was asked before is dropped.
class CategoryBrowser extends ChangeNotifier {
  CategoryBrowser({required this.provider, required this.category});

  final SkyStreamProvider provider;
  final ProviderCategory category;

  Map<String, String> _filters = const {};
  String _query = '';
  List<MultimediaItem> _items = const [];
  final Set<String> _seen = {};
  int _page = 0;
  bool _hasNext = true;
  bool _loading = false;
  Object? _error;

  /// Bumped whenever what is asked for changes: answers carry the generation
  /// they were asked in, and older ones are dropped.
  int _generation = 0;
  bool _disposed = false;

  /// The chosen option per filter key, and a sort other than the default
  /// under [ProviderCategory.sortKey].
  Map<String, String> get filters => _filters;
  String get query => _query;
  List<MultimediaItem> get items => _items;
  bool get hasNext => _hasNext;
  bool get isLoading => _loading;

  /// Why the last page failed; cleared by [retry] or any change.
  Object? get error => _error;

  /// The first page is on its way: nothing to show yet.
  bool get isFirstLoad => _loading && _items.isEmpty;

  /// Whether any filter or the sort is off its default ([reset] puts them back).
  bool get hasChoices => _filters.isNotEmpty;

  /// The pages loaded so far.
  int get page => _page;

  /// Chooses [value] for the filter [key]; null for all.
  void setFilter(String key, String? value) {
    final next = Map<String, String>.from(_filters);
    if (value == null || value.isEmpty) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    _apply(filters: next);
  }

  /// Chooses the sort; the default (the category's first) or null clears it.
  void setSort(String? value) {
    final isDefault =
        value == null ||
        (category.sorts.isNotEmpty && category.sorts.first.value == value);
    setFilter(ProviderCategory.sortKey, isDefault ? null : value);
  }

  void setQuery(String query) => _apply(query: query.trim());

  /// Every filter back to all, and the sort to its default.
  void reset() => _apply(filters: const {});

  void _apply({Map<String, String>? filters, String? query}) {
    final nextFilters = filters ?? _filters;
    final nextQuery = query ?? _query;
    if (mapEquals(nextFilters, _filters) && nextQuery == _query) return;
    _filters = Map.unmodifiable(nextFilters);
    _query = nextQuery;
    unawaited(refresh());
  }

  /// Starts over from page 1.
  Future<void> refresh() {
    _generation++;
    _items = const [];
    _seen.clear();
    _page = 0;
    _hasNext = true;
    _loading = false;
    _error = null;
    return loadMore();
  }

  /// The next page, unless one is on its way, the last has come, or the last
  /// failed (see [retry]).
  Future<void> loadMore() async {
    if (_disposed || _loading || !_hasNext || _error != null) return;
    final generation = _generation;
    final page = _page + 1;
    _loading = true;
    _notify();
    try {
      final answer = await provider.getCategoryPage(
        category,
        _filters,
        _query,
        page,
      );
      if (_disposed || generation != _generation) return;
      final fresh = [
        for (final item in answer.items)
          if (item.url.isNotEmpty && _seen.add(item.url)) item,
      ];
      _items = [..._items, ...fresh];
      _page = page;
      _hasNext = answer.hasNext && fresh.isNotEmpty;
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _error = error;
    }
    _loading = false;
    _notify();
  }

  /// Asks again for the page that failed.
  Future<void> retry() {
    _error = null;
    return loadMore();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
