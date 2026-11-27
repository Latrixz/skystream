import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/features/home/presentation/delegates/home_search_delegate.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
import 'package:skystream/features/search/presentation/live_search.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/search_screen.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/loading_indicator.dart';

/// A provider whose searches are answered by the test, one at a time.
class _Plugin extends SkyStreamProvider {
  final List<String> queries = [];
  final List<CancelToken?> tokens = [];
  final List<Completer<List<MultimediaItem>>> pending = [];

  /// Answers the [index]th search with [titles].
  void answer(int index, List<String> titles) => pending[index].complete([
    for (final title in titles)
      MultimediaItem(
        title: title,
        url: 'https://a.example/$title',
        posterUrl: '',
        provider: packageName,
      ),
  ]);

  @override
  String get name => 'A';
  @override
  String get packageName => 'p.a';
  @override
  String get mainUrl => '';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};
  @override
  Future<List<MultimediaItem>> search(String q, {CancelToken? cancelToken}) {
    queries.add(q);
    tokens.add(cancelToken);
    final completer = Completer<List<MultimediaItem>>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

class _FakeActiveProvider extends ActiveProvider {
  _FakeActiveProvider(this._initial);

  final SkyStreamProvider? _initial;

  @override
  SkyStreamProvider? build() => _initial;

  @override
  Future<void> set(SkyStreamProvider? provider) async {
    state = provider;
  }
}

class _FakeStore implements SearchHistoryStore {
  List<String> queries = [];

  @override
  List<String> read() => queries;

  @override
  Future<void> write(List<String> next) async {
    queries = List<String>.from(next);
  }
}

/// The cards' settings, without the storage behind them.
class _Settings extends GeneralSettingsNotifier {
  @override
  GeneralSettings build() => const GeneralSettings();
}

/// No suggestion strings, and no request for them.
class _NoSuggestions extends SearchSuggestionController {
  @override
  void onQueryChanged(String query) {}
}

void main() {
  group('isLiveSearchable', () {
    test('wants two characters, or one that is a word by itself', () {
      expect(isLiveSearchable(''), isFalse);
      expect(isLiveSearchable('   '), isFalse);
      expect(isLiveSearchable('d'), isFalse);
      expect(isLiveSearchable(' d '), isFalse);
      expect(isLiveSearchable('du'), isTrue);
      expect(isLiveSearchable('愛'), isTrue);
      expect(isLiveSearchable('あ'), isTrue);
      expect(isLiveSearchable('사'), isTrue);
    });
  });

  group('LiveSearch', () {
    testWidgets('searches once, for the last query, after the pause', (
      tester,
    ) async {
      final plugin = _Plugin();
      final live = LiveSearch();
      addTearDown(live.dispose);

      live.onQueryChanged('du', plugin);
      await tester.pump(const Duration(milliseconds: 200));
      live.onQueryChanged('dun', plugin);
      await tester.pump(const Duration(milliseconds: 200));
      live.onQueryChanged('dune', plugin);
      expect(live.isLoading, isTrue);

      await tester.pump(const Duration(milliseconds: 499));
      expect(plugin.queries, isEmpty);

      await tester.pump(const Duration(milliseconds: 1));
      expect(plugin.queries, ['dune']);
    });

    testWidgets('a newer query wins over one still in flight', (tester) async {
      final plugin = _Plugin();
      final live = LiveSearch();
      addTearDown(live.dispose);

      live.onQueryChanged('dun', plugin);
      await tester.pump(kLiveSearchDebounce);
      expect(plugin.queries, ['dun']);

      live.onQueryChanged('dune', plugin);
      expect(plugin.tokens[0]!.isCancelled, isTrue);
      await tester.pump(kLiveSearchDebounce);
      expect(plugin.queries, ['dun', 'dune']);

      plugin.answer(1, ['Dune']);
      await tester.pump();
      // The older one, answering late anyway, is dropped.
      plugin.answer(0, ['Dunkirk']);
      await tester.pump();

      expect(live.query, 'dune');
      expect(live.results!.map((i) => i.title), ['Dune']);
    });

    testWidgets('has no results until a search finished', (tester) async {
      final plugin = _Plugin();
      final live = LiveSearch();
      addTearDown(live.dispose);

      live.onQueryChanged('zzz', plugin);
      expect(live.hasFinished('zzz', plugin), isFalse);
      await tester.pump(kLiveSearchDebounce);
      expect(live.hasFinished('zzz', plugin), isFalse);

      plugin.answer(0, []);
      await tester.pump();
      expect(live.hasFinished('zzz', plugin), isTrue);
      expect(live.results, isEmpty);
    });

    testWidgets('Enter takes over the pending search, and reuses a finished '
        'one', (tester) async {
      final plugin = _Plugin();
      final live = LiveSearch();
      addTearDown(live.dispose);

      live.onQueryChanged('dune', plugin);
      live.searchNow('dune', plugin);
      expect(plugin.queries, ['dune']);
      // The debounce it took over does not send a second one.
      await tester.pump(kLiveSearchDebounce * 2);
      expect(plugin.queries, ['dune']);

      plugin.answer(0, ['Dune']);
      await tester.pump();
      live.searchNow('dune ', plugin);
      expect(plugin.queries, ['dune']);
      expect(live.results!.single.title, 'Dune');
    });

    testWidgets('a query too short to search clears the last one', (
      tester,
    ) async {
      final plugin = _Plugin();
      final live = LiveSearch();
      addTearDown(live.dispose);

      live.onQueryChanged('du', plugin);
      live.onQueryChanged('d', plugin);
      await tester.pump(kLiveSearchDebounce * 2);
      expect(plugin.queries, isEmpty);
      expect(live.query, isNull);
      expect(live.isLoading, isFalse);
    });
  });

  group('home search', () {
    Future<_FakeStore> open(WidgetTester tester, _Plugin plugin) async {
      final store = _FakeStore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeProviderProvider.overrideWith(
              () => _FakeActiveProvider(plugin),
            ),
            searchHistoryStoreProvider.overrideWithValue(store),
            searchSuggestionControllerProvider.overrideWith(_NoSuggestions.new),
            generalSettingsProvider.overrideWith(_Settings.new),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.light(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showSearch<void>(
                      context: context,
                      delegate: HomeSearchDelegate(),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return store;
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('shows the results while typing, without Enter', (
      tester,
    ) async {
      final plugin = _Plugin();
      final store = await open(tester, plugin);

      await type(tester, 'dune');
      expect(plugin.queries, isEmpty);
      expect(find.byType(AppLoadingIndicator), findsWidgets);

      await tester.pump(kLiveSearchDebounce);
      expect(plugin.queries, ['dune']);

      plugin.answer(0, ['Dune', 'Dune: Part Two']);
      await tester.pump();
      await tester.pump();
      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('Dune: Part Two'), findsOneWidget);
      // Typing is not a search the user made: only Enter, or opening a
      // result, records it.
      expect(store.queries, isEmpty);
    });

    testWidgets('says "no results" only once a search came back empty', (
      tester,
    ) async {
      final plugin = _Plugin();
      await open(tester, plugin);
      final noResults = find.text('No results found.');

      // Too short to search for: nothing is said at all.
      await type(tester, 'z');
      await tester.pump(kLiveSearchDebounce);
      expect(plugin.queries, isEmpty);
      expect(noResults, findsNothing);

      await type(tester, 'zzz');
      expect(noResults, findsNothing);
      await tester.pump(kLiveSearchDebounce);
      expect(noResults, findsNothing);

      plugin.answer(0, []);
      await tester.pump();
      await tester.pump();
      expect(noResults, findsOneWidget);

      // A new query takes the line away until its own search is done.
      await type(tester, 'zzzz');
      expect(noResults, findsNothing);
      await tester.pump(kLiveSearchDebounce);
      expect(noResults, findsNothing);
    });

    testWidgets('a result for an older query never shows for a newer one', (
      tester,
    ) async {
      final plugin = _Plugin();
      await open(tester, plugin);

      await type(tester, 'dun');
      await tester.pump(kLiveSearchDebounce);
      await type(tester, 'dune');
      await tester.pump(kLiveSearchDebounce);
      expect(plugin.queries, ['dun', 'dune']);

      plugin.answer(0, ['Dunkirk']);
      await tester.pump();
      await tester.pump();
      expect(find.text('Dunkirk'), findsNothing);

      plugin.answer(1, ['Dune']);
      await tester.pump();
      await tester.pump();
      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('Dunkirk'), findsNothing);
    });

    testWidgets('Enter shows the results the live search already has, '
        'without searching again', (tester) async {
      final plugin = _Plugin();
      final store = await open(tester, plugin);

      await type(tester, 'dune');
      await tester.pump(kLiveSearchDebounce);
      plugin.answer(0, ['Dune']);
      await tester.pump();
      await tester.pump();

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(plugin.queries, ['dune']);
      expect(find.text('Dune'), findsOneWidget);
      expect(store.queries, ['dune']);
    });

    testWidgets('Enter before the pause searches at once, and only once', (
      tester,
    ) async {
      final plugin = _Plugin();
      await open(tester, plugin);

      await type(tester, 'dune');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();
      expect(plugin.queries, ['dune']);

      await tester.pump(kLiveSearchDebounce * 2);
      expect(plugin.queries, ['dune']);

      plugin.answer(0, ['Dune']);
      await tester.pump();
      await tester.pump();
      expect(find.text('Dune'), findsOneWidget);
    });

    testWidgets('down from the field lands on the first result', (
      tester,
    ) async {
      final plugin = _Plugin();
      await open(tester, plugin);

      await type(tester, 'dune');
      await tester.pump(kLiveSearchDebounce);
      plugin.answer(0, ['Dune']);
      await tester.pump();
      await tester.pump();

      // The keyboard put away, as a remote's Back does.
      tester.testTextInput.hide();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      final focused = FocusManager.instance.primaryFocus!;
      expect(focused.context, isNotNull);
      expect(
        find.ancestor(
          of: find.byWidgetPredicate(
            (w) => w is Focus && w.focusNode == focused,
          ),
          matching: find.byType(SliverGrid),
        ),
        findsOneWidget,
      );
    });
  });

  group('global search', () {
    Future<List<String>> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final searched = <String>[];
      final container = ProviderContainer(
        overrides: [
          searchHistoryStoreProvider.overrideWithValue(_FakeStore()),
          searchSuggestionControllerProvider.overrideWith(_NoSuggestions.new),
          searchResultsProvider.overrideWith((ref) {
            final query = ref.watch(searchQueryProvider);
            if (query.isNotEmpty) searched.add(query);
            return Stream.value(const SearchAggregateState());
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.light(),
            home: const SearchScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return searched;
    }

    testWidgets('searches every provider after the longer pause', (
      tester,
    ) async {
      final searched = await open(tester);

      await tester.enterText(find.byType(TextField), 'du');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), 'dune');
      await tester.pump(kGlobalLiveSearchDebounce - kLiveSearchDebounce);
      await tester.pump(kLiveSearchDebounce - const Duration(milliseconds: 1));
      expect(searched, isEmpty);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(searched, ['dune']);
    });

    testWidgets('Enter after the live search does not search again', (
      tester,
    ) async {
      final searched = await open(tester);

      await tester.enterText(find.byType(TextField), 'dune');
      await tester.pump(kGlobalLiveSearchDebounce);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(searched, ['dune']);
    });

    testWidgets('Enter before the pause searches once', (tester) async {
      final searched = await open(tester);

      await tester.enterText(find.byType(TextField), 'dune');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(kGlobalLiveSearchDebounce * 2);
      expect(searched, ['dune']);
    });

    testWidgets('does not say "no results" for the query still being typed', (
      tester,
    ) async {
      await open(tester);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('No Results Found'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pump();
      expect(find.text('No Results Found'), findsNothing);

      await tester.pump(kGlobalLiveSearchDebounce);
      await tester.pumpAndSettle();
      expect(find.text('No Results Found'), findsOneWidget);
    });
  });
}
