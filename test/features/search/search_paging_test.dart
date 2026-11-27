import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/features/home/presentation/delegates/home_search_delegate.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
import 'package:skystream/features/search/presentation/search_pager.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/widgets/search_result_section.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/multimedia_card.dart';

/// An extension whose search has [pages] pages of [perPage] titles, "Dune
/// `page.n`"; or, with [paging] off, one list only, as SkyStream plugins'.
class _Paged extends SkyStreamProvider {
  _Paged({this.pages = 3, this.perPage = 2, this.paging = true});

  final int pages;
  final int perPage;
  final bool paging;

  /// Answers page N with page 1's titles: an extension that ignores pages.
  bool repeats = false;

  /// Pages that fail.
  final failing = <int>{};

  /// Pages that wait for [gate].
  Completer<void>? gate;

  /// The pages asked for.
  final asked = <int>[];
  int searches = 0;

  List<MultimediaItem> _page(int page) => [
    for (var n = 1; n <= perPage; n++)
      MultimediaItem(
        title: 'Dune ${repeats ? 1 : page}.$n',
        url: '/dune/${repeats ? 1 : page}/$n',
        posterUrl: '',
      ),
  ];

  @override
  String get name => 'Paged';
  @override
  String get packageName => 'p.paged';
  @override
  String get mainUrl => '';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    searches++;
    return _page(1);
  }

  @override
  Future<SearchPage?> searchPage(
    String query,
    int page, {
    CancelToken? cancelToken,
  }) async {
    if (!paging) return null;
    asked.add(page);
    await gate?.future;
    if (failing.contains(page)) throw Exception('offline');
    return SearchPage(items: _page(page), hasNext: page < pages);
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

class _Manager extends ExtensionManager {
  _Manager(this.plugins);

  final List<SkyStreamProvider> plugins;

  @override
  List<SkyStreamProvider> build() => plugins;
}

class _FakeActiveProvider extends ActiveProvider {
  _FakeActiveProvider(this._initial);

  final SkyStreamProvider? _initial;

  @override
  SkyStreamProvider? build() => _initial;

  @override
  Future<void> set(SkyStreamProvider? provider) async => state = provider;
}

class _FakeStore implements SearchHistoryStore {
  List<String> queries = [];

  @override
  List<String> read() => queries;

  @override
  Future<void> write(List<String> next) async => queries = List.of(next);
}

class _NoSuggestions extends SearchSuggestionController {
  @override
  void onQueryChanged(String query) {}
}

SearchPager _pager(_Paged plugin, {bool hasNext = true}) => SearchPager(
  provider: plugin,
  query: 'dune',
  firstPage: plugin._page(1),
  hasNext: hasNext,
);

List<String> _urls(SearchPager pager) => [
  for (final item in pager.items) item.url,
];

/// Search results past their first page.
void main() {
  group('a pager', () {
    test('adds each next page until the provider has no more', () async {
      final plugin = _Paged();
      final pager = _pager(plugin);
      expect(await pager.loadMore(), 2);
      expect(pager.hasMore, isTrue);
      expect(await pager.loadMore(), 2);
      expect(pager.hasMore, isFalse);
      expect(await pager.loadMore(), 0, reason: 'none follows');
      expect(plugin.asked, [2, 3]);
      expect(_urls(pager), [
        '/dune/1/1',
        '/dune/1/2',
        '/dune/2/1',
        '/dune/2/2',
        '/dune/3/1',
        '/dune/3/2',
      ]);
    });

    test('leaves out what it listed already, and stops at a page with '
        'nothing new', () async {
      final plugin = _Paged(pages: 99)..repeats = true;
      final pager = _pager(plugin);
      expect(await pager.loadMore(), 0);
      expect(pager.hasMore, isFalse);
      expect(_urls(pager), ['/dune/1/1', '/dune/1/2']);
      expect(plugin.asked, [2]);
    });

    test('asks nothing of a first page that was the last', () async {
      final plugin = _Paged();
      final pager = _pager(plugin, hasNext: false);
      expect(await pager.loadMore(), 0);
      expect(plugin.asked, isEmpty);
    });

    test('stops at a failed page, keeping what it has', () async {
      final plugin = _Paged()..failing.add(2);
      final pager = _pager(plugin);
      expect(await pager.loadMore(), 0);
      expect(pager.hasMore, isFalse);
      expect(pager.isLoading, isFalse);
      expect(_urls(pager), ['/dune/1/1', '/dune/1/2']);
    });

    test('stops for a provider that cannot page', () async {
      final pager = _pager(_Paged(paging: false));
      expect(await pager.loadMore(), 0);
      expect(pager.hasMore, isFalse);
    });

    test('asks one page at a time', () async {
      final plugin = _Paged()..gate = Completer<void>();
      final pager = _pager(plugin);
      final first = pager.loadMore();
      expect(pager.isLoading, isTrue);
      expect(await pager.loadMore(), 0);
      plugin.gate!.complete();
      expect(await first, 2);
      expect(plugin.asked, [2]);
    });

    test('drops a page that comes after it was cancelled', () async {
      final plugin = _Paged()..gate = Completer<void>();
      final pager = _pager(plugin);
      final next = pager.loadMore();
      pager.cancel();
      plugin.gate!.complete();
      expect(await next, 0);
      expect(_urls(pager), ['/dune/1/1', '/dune/1/2']);
      expect(pager.hasMore, isFalse);
    });

    test("lists a page's new items as prepare makes them", () async {
      final plugin = _Paged();
      final pager = SearchPager(
        provider: plugin,
        query: 'dune',
        firstPage: const [],
        hasNext: true,
        seen: plugin._page(1).map((item) => item.url),
        prepare: (fresh) async => fresh.take(1).toList(),
      );
      expect(await pager.loadMore(), 1);
      expect(_urls(pager), ['/dune/2/1']);
      expect(pager.hasMore, isTrue, reason: 'the page had new items');
    });
  });

  group('the search tab', () {
    Future<SearchAggregateState> searchFor(
      String query,
      List<SkyStreamProvider> plugins,
    ) async {
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(() => _Manager(plugins)),
          searchQueryProvider.overrideWithValue(query),
        ],
      );
      addTearDown(container.dispose);
      final states = <SearchAggregateState>[];
      container.listen(searchResultsProvider, (_, next) {
        if (next.hasValue) states.add(next.value!);
      }, fireImmediately: true);
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (states.isEmpty || states.last.isLoading) {
        if (DateTime.now().isAfter(end)) throw StateError('timed out');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return states.last;
    }

    test("pages a provider's section, stamped and filtered like its first "
        'page', () async {
      final plugin = _Paged();
      final state = await searchFor('dune', [plugin]);
      final section = state.results.single;
      expect(plugin.searches, 0, reason: 'page 1 came from searchPage');
      final pager = section.pager!;
      expect(await pager.loadMore(), 2);
      expect(pager.items.map((i) => i.provider).toSet(), {'p.paged'});
      expect(pager.items.map((i) => i.title), [
        'Dune 1.1',
        'Dune 1.2',
        'Dune 2.1',
        'Dune 2.2',
      ]);

      // Titles without the query's words stay out, as on page 1.
      final other = await searchFor('arrival', [_Paged()]);
      expect(other.results, isEmpty);
    });

    test('has no pager for a provider that cannot page, or a first page '
        'that was the last', () async {
      final unpaged = _Paged(paging: false);
      final state = await searchFor('dune', [unpaged]);
      expect(state.results.single.pager, isNull);
      expect(state.results.single.results, hasLength(2));
      expect(unpaged.searches, 1);

      final single = await searchFor('dune', [_Paged(pages: 1)]);
      expect(single.results.single.pager, isNull);
    });
  });

  group('screens', () {
    final overrides = [
      generalSettingsProvider.overrideWithValue(const GeneralSettings()),
      searchHistoryStoreProvider.overrideWithValue(_FakeStore()),
      searchSuggestionControllerProvider.overrideWith(_NoSuggestions.new),
    ];

    Widget app(Widget home, {List<Override> extra = const []}) => ProviderScope(
      overrides: [...overrides, ...extra],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData.dark(),
        home: home,
      ),
    );

    List<String> cardTitles(WidgetTester tester) => [
      for (final card in tester.widgetList<MultimediaCard>(
        find.byType(MultimediaCard),
      ))
        card.title,
    ];

    testWidgets("a search row's Show More adds the next page, and focus "
        'waiting there goes on to it', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final plugin = _Paged(pages: 2);
      final pager = _pager(plugin);
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SearchResultSection(
              providerName: plugin.name,
              providerId: plugin.packageName,
              results: plugin._page(1),
              pager: pager,
            ),
          ),
          extra: [extensionManagerProvider.overrideWith(() => _Manager([]))],
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(cardTitles(tester), ['Dune 1.1', 'Dune 1.2']);
      expect(find.text('Show More'), findsOneWidget);

      final more = Focus.of(tester.element(find.text('Show More')));
      more.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(cardTitles(tester), [
        'Dune 1.1',
        'Dune 1.2',
        'Dune 2.1',
        'Dune 2.2',
      ]);
      expect(find.text('Show More'), findsNothing, reason: 'page 2 was last');
      final focused = tester
          .widgetList<MultimediaCard>(find.byType(MultimediaCard))
          .where((card) => card.focusNode?.hasFocus ?? false);
      expect(focused.map((card) => card.title), ['Dune 2.1']);
    });

    testWidgets("Home's search runs on into the next pages as its grid nears "
        'its end, and fills its screen first', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Two titles a page: the grid asks until it scrolls, or the pages end.
      final small = _Paged(pages: 3);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showSearch<void>(
                  context: context,
                  delegate: HomeSearchDelegate(),
                  query: 'dune',
                ),
                child: const Text('open'),
              ),
            ),
          ),
          extra: [
            activeProviderProvider.overrideWith(
              () => _FakeActiveProvider(small),
            ),
          ],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextField));
      await tester.testTextInput.receiveAction(TextInputAction.search);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(small.asked, [1, 2, 3]);
      expect(cardTitles(tester), hasLength(6));
    });

    testWidgets("Home's search asks for page 2 only once scrolled near its "
        'end', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final big = _Paged(pages: 3, perPage: 40);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showSearch<void>(
                  context: context,
                  delegate: HomeSearchDelegate(),
                  query: 'dune',
                ),
                child: const Text('open'),
              ),
            ),
          ),
          extra: [
            activeProviderProvider.overrideWith(() => _FakeActiveProvider(big)),
          ],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextField));
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(big.asked, [1]);

      await tester.drag(find.byType(GridView), const Offset(0, -20000));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(big.asked, [1, 2]);
      await tester.drag(find.byType(GridView), const Offset(0, -20000));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(big.asked, [1, 2, 3]);
    });
  });
}
