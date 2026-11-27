import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../search/presentation/live_search.dart';
import '../../../search/presentation/search_history_provider.dart';
import '../../../search/presentation/search_provider.dart';
import '../../../search/presentation/widgets/search_suggestion_row.dart';
import '../../../../shared/focus/text_field_keys.dart';

import 'package:skystream/shared/widgets/multimedia_card.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/check_line.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../../../../core/utils/responsive_breakpoints.dart';

/// Opens Home's search over [context], and disposes its delegate once the
/// search has closed: nothing else would take its key handler away again.
Future<void> showHomeSearch(BuildContext context) {
  final delegate = HomeSearchDelegate();
  return showSearch<void>(
    context: context,
    delegate: delegate,
    useRootNavigator: false,
    maintainState: true,
  ).whenComplete(delegate.dispose);
}

class HomeSearchDelegate extends SearchDelegate<void> {
  final String? initialQuery;

  /// Where a D-pad press down from the search field lands.
  final FocusNode _firstSuggestionFocusNode = FocusNode();
  final FocusNode _firstResultFocusNode = FocusNode();

  /// The first card of the results shown while typing, for when there are
  /// no recents or suggestions above it to land on first.
  final FocusNode _firstLiveResultFocusNode = FocusNode();

  /// The active provider's search for what is in the field, run as the user
  /// types and picked up by Enter rather than sent again.
  final LiveSearch _live = LiveSearch();

  /// The search page this delegate was built into - see [buildLeading].
  BuildContext? _page;

  HomeSearchDelegate({this.initialQuery})
    : super(
        searchFieldLabel: 'Search movies, series...',
        searchFieldStyle: null,
      ) {
    if (initialQuery != null) {
      query = initialQuery!;
    }
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  /// Moves focus off the search field and into the list below it.
  ///
  /// A global handler rather than a key callback on the field, because the
  /// field belongs to [SearchDelegate] and cannot be reached to have one
  /// attached. It has to be global for a second reason too: an EditableText
  /// swallows arrow keys for its own cursor, so directional traversal never
  /// sees the press and focus would stay in the field forever.
  ///
  /// The rest of what [remoteTextFieldKeys] does for a field, done here for
  /// the same reason: while a keyboard is up the keys are its own - a
  /// television's walks its letter grid with the arrows - and Select, OK on a
  /// remote, brings back a keyboard put away with Back.
  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent || !searchFieldHoldsFocus(_page)) return false;
    final field = FocusManager.instance.primaryFocus!;
    if (deferToSoftKeyboard(field)) return false;

    if (event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return reopenTextFieldKeyboard(field, event) == KeyEventResult.handled;
    }
    // Only to a row in the tree. One that is not yet keeps the request and
    // takes the focus whenever it is built - out of the field, mid-word.
    for (final row in [
      _firstSuggestionFocusNode,
      _firstLiveResultFocusNode,
      _firstResultFocusNode,
    ]) {
      if (row.parent != null && row.canRequestFocus) {
        row.requestFocus();
        return true;
      }
    }
    return false;
  }

  /// Called by [showHomeSearch] as the search closes, while its page is still
  /// fading out with these nodes and the base class's field in it: the key
  /// handler goes at once, the rest once the page has gone.
  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    whenSearchPageGone(_page, () {
      _firstSuggestionFocusNode.dispose();
      _firstResultFocusNode.dispose();
      _firstLiveResultFocusNode.dispose();
      _live.dispose();
      super.dispose();
    });
  }

  @override
  ThemeData appBarTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        toolbarHeight: 70,
      ),
      inputDecorationTheme: InputDecorationTheme(
        hintStyle: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        border: InputBorder.none,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: theme.colorScheme.primary,
        selectionColor: theme.colorScheme.primary.withValues(alpha: 0.3),
      ),
      textTheme: theme.textTheme.copyWith(
        titleMedium: TextStyle(
          color: theme.colorScheme.onSurface,
          fontSize: 18,
        ),
      ),
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () {
            query = '';
            showSuggestions(context);
          },
        ),
      const SizedBox(width: 8),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    // The search page's own context, on every build of it.
    _page = context;
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    if (query.isEmpty) return const SizedBox.shrink();
    return _HomeSearchResults(
      query: query,
      live: _live,
      firstItemFocusNode: _firstResultFocusNode,
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    // No empty-query guard: an empty field is precisely when the recent
    // searches are the only thing there is to show.
    return _HomeSearchSuggestions(
      query: query,
      live: _live,
      firstItemFocusNode: _firstSuggestionFocusNode,
      firstResultFocusNode: _firstLiveResultFocusNode,
      onSelect: (val) {
        query = val;
        showResults(context);
      },
    );
  }
}

/// At most this many suggestion strings above the results shown while
/// typing, so the results themselves stay on screen.
const int _kLiveSuggestionLimit = 3;

class _HomeSearchSuggestions extends ConsumerStatefulWidget {
  final String query;
  final LiveSearch live;
  final void Function(String) onSelect;
  final FocusNode? firstItemFocusNode;

  /// For the first result card, when no row sits above it.
  final FocusNode? firstResultFocusNode;

  const _HomeSearchSuggestions({
    required this.query,
    required this.live,
    required this.onSelect,
    this.firstItemFocusNode,
    this.firstResultFocusNode,
  });

  @override
  ConsumerState<_HomeSearchSuggestions> createState() =>
      _HomeSearchSuggestionsState();
}

class _HomeSearchSuggestionsState
    extends ConsumerState<_HomeSearchSuggestions> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onQueryChanged();
    });
  }

  @override
  void didUpdateWidget(covariant _HomeSearchSuggestions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      Future.microtask(() {
        if (mounted) _onQueryChanged();
      });
    }
  }

  /// The suggestion strings, and the live search: both wait out their own
  /// debounce, and both drop what the previous query asked for.
  void _onQueryChanged() {
    ref
        .read(searchSuggestionControllerProvider.notifier)
        .onQueryChanged(widget.query);
    widget.live.onQueryChanged(widget.query, _providerFor(widget.query));
  }

  /// The provider to search [query] with, or null when it is too short to
  /// search for as it is typed - and then the provider is not even looked
  /// up, so an empty field touches nothing but the recents.
  SkyStreamProvider? _providerFor(String query) =>
      isLiveSearchable(query) ? ref.read(activeProviderProvider) : null;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.live,
      builder: (context, _) => _buildList(context),
    );
  }

  Widget _buildList(BuildContext context) {
    final searchState = ref.watch(searchSuggestionControllerProvider);
    final history = ref.watch(searchHistoryProvider);
    final live = widget.live;
    final trimmed = widget.query.trim();
    final provider = _providerFor(trimmed);
    final searchable = provider != null;
    // A keystroke reaches the live search a moment after this build, and
    // until then it still holds the previous query: that one's results are
    // not this one's, so this one counts as on its way.
    final held = searchable && live.holds(trimmed, provider);
    final liveLoading = searchable && (!held || live.isLoading);
    final liveResults = held ? live.results : null;
    final noResults = liveResults != null && liveResults.isEmpty;
    final hasResults = liveResults != null && liveResults.isNotEmpty;

    // An empty field gets the full recents list; once the user is typing,
    // only a few, because the suggestions and results underneath are what
    // they are typing towards.
    final recents = matchingSearchHistory(
      history,
      trimmed,
      limit: trimmed.isEmpty
          ? kSearchHistoryEmptyFieldLimit
          : kSearchHistoryTypingLimit,
    );
    var suggestions = withoutDuplicatedHistory(
      searchState.suggestions,
      recents,
    );
    if (searchable && suggestions.length > _kLiveSuggestionLimit) {
      suggestions = suggestions.take(_kLiveSuggestionLimit).toList();
    }
    final isLoading =
        liveLoading || (searchState.isLoading && liveResults == null);

    final noResultsLine = Text(
      AppLocalizations.of(context)!.noResultsFound,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
      ),
    );

    if (recents.isEmpty && suggestions.isEmpty && !isLoading && !hasResults) {
      // Nothing typed, or too little to search for, and nothing searched
      // before: the field's own hint is the whole message. "No results" is
      // only ever said of a search that ran and came back empty.
      if (!noResults) return const SizedBox.shrink();
      return Center(child: noResultsLine);
    }

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          sliver: SliverList.list(
            children: [
              SearchHistorySection(
                queries: recents,
                // The first row overall takes the node, whether it is a
                // recent or - with no history - the first suggestion.
                firstItemFocusNode: recents.isNotEmpty
                    ? widget.firstItemFocusNode
                    : null,
                onSelect: widget.onSelect,
                onRemove: (query) =>
                    ref.read(searchHistoryProvider.notifier).remove(query),
              ),
              for (final (index, suggestion) in suggestions.indexed)
                SearchSuggestionRow(
                  key: ValueKey('search-suggestion-$suggestion'),
                  text: suggestion,
                  icon: Icons.search_rounded,
                  focusNode: (index == 0 && recents.isEmpty)
                      ? widget.firstItemFocusNode
                      : null,
                  trailingIcon: Icons.north_west_rounded,
                  onTap: () => widget.onSelect(suggestion),
                  onTrailingTap: () => widget.onSelect(suggestion),
                ),
            ],
          ),
        ),
        // Kept below the recents rather than replacing the screen: the
        // recents are already on the glass and should not flicker away every
        // time a keystroke starts a new search.
        if (isLoading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppLoadingIndicator(
                      color: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.5),
                    ),
                    if (held && live.searchedAt != null)
                      CheckLine(
                        source: provider.checkSource,
                        since: live.searchedAt,
                        offerVerify: true,
                      ),
                  ],
                ),
              ),
            ),
          )
        else if (noResults)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(child: noResultsLine),
            ),
          )
        else if (hasResults)
          _resultsGrid(
            context,
            items: liveResults,
            heroPrefix: 'live_search_${provider?.packageName}',
            firstItemFocusNode: widget.firstResultFocusNode,
            onOpen: (item) {
              // A result opened is a search the user made, as much as Enter.
              unawaited(ref.read(searchHistoryProvider.notifier).add(trimmed));
              DetailsRoute($extra: DetailsRouteExtra(item: item))
                  .push<void>(context);
            },
          ),
      ],
    );
  }
}

/// [items] as a grid of poster cards: the results shown while typing and
/// the ones Enter shows look the same.
Widget _resultsGrid(
  BuildContext context, {
  required List<MultimediaItem> items,
  required String heroPrefix,
  required void Function(MultimediaItem) onOpen,
  FocusNode? firstItemFocusNode,
}) {
  final isLarge = MediaQuery.of(context).size.width > 600;
  final maxExtent = isLarge ? 200.0 : 130.0;

  return SliverPadding(
    padding: const EdgeInsets.all(16),
    sliver: SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxExtent,
        childAspectRatio: 2 / 3.2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return MultimediaCard(
          key: ValueKey(item.url),
          focusNode: index == 0 ? firstItemFocusNode : null,
          imageUrl: AppImageFallbacks.poster(item.posterUrl, label: item.title),
          title: item.title,
          heroTag: '${heroPrefix}_${item.url}_$index',
          onTap: () => onOpen(item),
        );
      },
    ),
  );
}

class _HomeSearchResults extends ConsumerStatefulWidget {
  final String query;
  final LiveSearch live;
  final FocusNode? firstItemFocusNode;

  const _HomeSearchResults({
    required this.query,
    required this.live,
    this.firstItemFocusNode,
  });

  @override
  ConsumerState<_HomeSearchResults> createState() => _HomeSearchResultsState();
}

class _HomeSearchResultsState extends ConsumerState<_HomeSearchResults> {
  @override
  void initState() {
    super.initState();
    _performSearch();
  }

  @override
  void didUpdateWidget(covariant _HomeSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      _performSearch();
    }
  }

  /// Searches for the query - unless the live search already has it, in
  /// flight or done, which Enter then just shows. [force] searches again
  /// all the same, for a check that has cleared.
  void _performSearch({bool force = false}) {
    // Recorded on the way into the search, not on the way out: a query that
    // returned nothing is still one the user made and may want back. Once
    // the current build is over: the first search starts in initState, and
    // a provider - or the live search's listeners - changed while widgets
    // build is an error.
    final history = ref.read(searchHistoryProvider.notifier);
    final query = widget.query.trim();
    final provider = ref.read(activeProviderProvider);
    unawaited(
      Future.microtask(() {
        if (!force) history.add(query);
        if (mounted) widget.live.searchNow(query, provider, force: force);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.live,
      builder: (context, _) => _buildResults(context),
    );
  }

  Widget _buildResults(BuildContext context) {
    final provider = ref.read(activeProviderProvider);
    final live = widget.live;
    final held = live.holds(widget.query, provider);
    final results = held ? live.results : null;

    if (results == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppLoadingIndicator(),
            // No search again here when it clears: the request waiting on
            // the check carries on by itself.
            CheckLine(
              source: provider?.checkSource,
              since: held ? live.searchedAt : null,
              offerVerify: true,
            ),
          ],
        ),
      );
    }

    if (results.isEmpty) {
      // Size question, asked of the size: a 960 dp television clears the
      // tablet breakpoint like any other big window.
      final isWidescreen = context.isTabletOrLarger;
      final imageWidth = isWidescreen ? 320.0 : 200.0;
      final nativeFont = Theme.of(context).textTheme.bodyLarge?.fontFamily;

      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            CheckLine(
              source: provider?.checkSource,
              since: live.searchedAt,
              offerVerify: true,
              onCleared: () => _performSearch(force: true),
            ),
            Text(
              'No Results Found',
              style: TextStyle(
                fontFamily: nativeFont,
                fontSize: 16.0,
                fontWeight: FontWeight.w400,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Image.asset(
              'assets/images/no_results.png',
              fit: BoxFit.contain,
              width: imageWidth,
              // Source is 1613x1929 — 11.9 MB decoded — for an illustration
              // shown at 320 logical px at most. 640 covers 2x density.
              cacheWidth: 640,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            ),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        _resultsGrid(
          context,
          items: results,
          heroPrefix: 'search_${provider?.packageName}',
          firstItemFocusNode: widget.firstItemFocusNode,
          onOpen: (item) =>
              DetailsRoute($extra: DetailsRouteExtra(item: item))
                  .push<void>(context),
        ),
      ],
    );
  }
}
