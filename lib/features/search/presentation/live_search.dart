import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/network/clearance/clearance.dart';

/// How long one provider's search waits after the last keystroke.
const Duration kLiveSearchDebounce = Duration(milliseconds: 500);

/// Global search fans out to every extension, so it waits a little longer:
/// a word typed at a normal pace sends one search, not one per syllable.
const Duration kGlobalLiveSearchDebounce = Duration(milliseconds: 700);

/// Han, kana and Hangul: scripts where a single character is a word.
final RegExp _wordCharacter = RegExp(r'[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]');

/// Whether [query] is long enough to search while the user is still typing:
/// two characters, or one in a script where a character is a whole word.
bool isLiveSearchable(String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.runes.length >= 2) return true;
  return _wordCharacter.hasMatch(trimmed);
}

/// One provider's search, run as the user types and kept for Enter.
///
/// Holds the state of one query at a time. A newer query always wins: the
/// older one's request is cancelled where the provider honours a
/// [CancelToken], and its answer is dropped where it does not.
class LiveSearch extends ChangeNotifier {
  LiveSearch({this.debounce = kLiveSearchDebounce});

  final Duration debounce;

  String? _query;
  SkyStreamProvider? _provider;
  bool _isLoading = false;
  bool _failed = false;
  List<MultimediaItem>? _results;
  DateTime? _searchedAt;

  Timer? _timer;
  CancelToken? _token;

  /// Bumped by every new query, so an answer that arrives after the next
  /// query went out can tell it is stale.
  int _generation = 0;
  bool _disposed = false;

  /// The trimmed query the state below belongs to, or null.
  String? get query => _query;

  /// Waiting out the debounce, or searching.
  bool get isLoading => _isLoading;

  /// The results of a finished search for [query]; null until it finished.
  List<MultimediaItem>? get results => _results;

  /// When the request went out, for the bot check it may have met.
  DateTime? get searchedAt => _searchedAt;

  /// Whether this holds [query]'s search with [provider], pending or done.
  bool holds(String query, SkyStreamProvider? provider) =>
      _query != null &&
      _query == query.trim() &&
      identical(_provider, provider);

  /// Whether a search for [query] with [provider] has finished.
  bool hasFinished(String query, SkyStreamProvider? provider) =>
      holds(query, provider) && _results != null;

  /// The field changed: search for [query] once the user pauses, or forget
  /// the last search when it is too short to search for.
  void onQueryChanged(String query, SkyStreamProvider? provider) {
    final trimmed = query.trim();
    if (holds(trimmed, provider)) return;
    _cancel();
    if (provider == null || !isLiveSearchable(trimmed)) {
      final hadState = _query != null;
      _query = null;
      _provider = null;
      _isLoading = false;
      _failed = false;
      _results = null;
      _searchedAt = null;
      if (hadState) _notify();
      return;
    }
    _begin(trimmed, provider);
    final generation = _generation;
    _timer = Timer(debounce, () {
      if (generation == _generation) _run(trimmed, provider, generation);
    });
    _notify();
  }

  /// Enter: search for [query] now, unless this already has it - in flight
  /// or finished. A search that failed is tried again, and so is any when
  /// [force] is set.
  void searchNow(
    String query,
    SkyStreamProvider? provider, {
    bool force = false,
  }) {
    final trimmed = query.trim();
    if (!force && holds(trimmed, provider) && _timer == null && !_failed) {
      return;
    }
    _cancel();
    _begin(trimmed, provider);
    if (provider == null) {
      _isLoading = false;
      _results = const [];
      _notify();
      return;
    }
    _run(trimmed, provider, _generation);
  }

  void _begin(String query, SkyStreamProvider? provider) {
    _query = query;
    _provider = provider;
    _isLoading = true;
    _failed = false;
    _results = null;
    _searchedAt = null;
  }

  Future<void> _run(
    String query,
    SkyStreamProvider provider,
    int generation,
  ) async {
    _timer = null;
    final token = _token = CancelToken();
    final clearance = Clearance.instance;
    _searchedAt = clearance.isReady ? clearance.checks.now : DateTime.now();
    _notify();

    List<MultimediaItem> results;
    var failed = false;
    try {
      results = (await provider.search(query, cancelToken: token)).toList();
    } catch (_) {
      results = const [];
      failed = true;
    }
    if (_disposed || generation != _generation) return;
    _token = null;
    _isLoading = false;
    _failed = failed;
    _results = results;
    _notify();
  }

  /// Drops whatever search is pending or in flight.
  void _cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    final token = _token;
    _token = null;
    if (token != null && !token.isCancelled) token.cancel('Superseded');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _cancel();
    _disposed = true;
    super.dispose();
  }
}
