import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/logger/app_logger.dart';

/// A provider's search results past their first page, for an endless list of
/// them: see [SkyStreamProvider.searchPage].
///
/// It holds the list, so a row scrolled out of a list and built again shows
/// the pages it had. Pages end when the provider says none follows, when one
/// adds nothing new (a provider that ignores the page number would repeat its
/// first page forever), or when one fails: searching again retries.
class SearchPager extends ChangeNotifier {
  /// [firstPage] is what the list shows of page 1; [seen], the URLs page 1
  /// had, when the list shows only some of them. [prepare] makes a page's new
  /// items into the list's (stamped, filtered); without it they go in as
  /// they are.
  SearchPager({
    required this.provider,
    required this.query,
    required List<MultimediaItem> firstPage,
    required bool hasNext,
    Iterable<String>? seen,
    this.prepare,
  }) : _items = List.of(firstPage),
       _hasMore = hasNext {
    _seen.addAll(seen ?? firstPage.map((item) => item.url));
  }

  final SkyStreamProvider provider;
  final String query;
  final Future<List<MultimediaItem>> Function(List<MultimediaItem> fresh)?
  prepare;

  final List<MultimediaItem> _items;

  /// The URLs listed so far: a provider's pages can overlap.
  final Set<String> _seen = {};

  int _page = 1;
  bool _hasMore;
  bool _isLoading = false;
  bool _closed = false;
  CancelToken? _token;

  /// What the list shows: page 1's, then each page's new ones.
  List<MultimediaItem> get items => List.unmodifiable(_items);

  /// Whether a page may follow.
  bool get hasMore => _hasMore && !_closed;

  bool get isLoading => _isLoading;

  /// The last page asked for.
  int get page => _page;

  /// Asks for the next page, unless one is loading or none follows. Answers
  /// how many items it added to [items].
  Future<int> loadMore() async {
    if (!hasMore || _isLoading) return 0;
    final token = _token = CancelToken();
    final next = _page + 1;
    _isLoading = true;
    notifyListeners();
    try {
      final page = await provider.searchPage(query, next, cancelToken: token);
      if (_closed || token.isCancelled) return 0;
      if (page == null) {
        // This provider can't page its search.
        _hasMore = false;
        return 0;
      }
      final fresh = [
        for (final item in page.items)
          if (_seen.add(item.url)) item,
      ];
      _page = next;
      _hasMore = page.hasNext && fresh.isNotEmpty;
      final shown = prepare == null || fresh.isEmpty
          ? fresh
          : await prepare!(fresh);
      if (_closed || token.isCancelled) return 0;
      _items.addAll(shown);
      return shown.length;
    } catch (error) {
      if (_closed || token.isCancelled) return 0;
      if (error is DioException && error.type == DioExceptionType.cancel) {
        return 0;
      }
      // Not asked again on every scroll; searching again retries.
      talker.warning(
        'Search: ${provider.name} page $next for "$query" failed: $error',
      );
      _hasMore = false;
      return 0;
    } finally {
      if (identical(_token, token)) _token = null;
      _isLoading = false;
      if (!_closed) notifyListeners();
    }
  }

  /// Stops paging: a page on its way is dropped. The search it belongs to
  /// was replaced, or its list closed.
  void cancel() {
    if (_closed) return;
    _closed = true;
    final token = _token;
    if (token != null && !token.isCancelled) token.cancel('Search closed');
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}
