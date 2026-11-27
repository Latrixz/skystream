import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/features/categories/presentation/category_option_picker.dart';
import 'package:skystream/features/categories/presentation/category_screen.dart';
import 'package:skystream/features/categories/presentation/home_categories_row.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/multimedia_card.dart';

import 'category_test_support.dart';

/// Posters' shimmer never stops, so pumpAndSettle can't be used: a second of frames instead.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late FakeCategoryProvider provider;
  final opened = <MultimediaItem>[];

  setUp(() {
    provider = FakeCategoryProvider();
    opened.clear();
  });

  Widget app(Widget home, {Size size = const Size(1280, 900)}) => ProviderScope(
    overrides: [
      generalSettingsProvider.overrideWithValue(const GeneralSettings()),
    ],
    child: MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );

  Future<void> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        CategoryScreen(
          category: series,
          provider: provider,
          onOpen: opened.add,
          searchDebounce: const Duration(milliseconds: 300),
        ),
        size: size,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  List<String> cardTitles(WidgetTester tester) => tester
      .widgetList<MultimediaCard>(find.byType(MultimediaCard))
      .map((c) => c.title)
      .toList();

  testWidgets(
    'shows the first page as posters with their headers, and opens a title',
    (tester) async {
      await pumpScreen(tester);
      expect(find.text('电视剧'), findsOneWidget);
      expect(find.text('Fake Kubb'), findsOneWidget);
      final card = tester.widget<MultimediaCard>(
        find.byType(MultimediaCard).first,
      );
      expect(card.title, '4 1.1');
      expect(card.imageHeaders, {'Referer': 'https://site.invalid/'});
      await tester.tap(find.byType(MultimediaCard).first);
      expect(opened.single.url, '/4//1/1');
    },
  );

  testWidgets('pages in as the grid scrolls, and stops at the last page', (
    tester,
  ) async {
    await pumpScreen(tester, size: const Size(800, 600));
    // Page 1 doesn't fill the screen: page 2 follows by itself.
    await settle(tester);
    final before = provider.asked.length;
    expect(before, greaterThanOrEqualTo(2));
    for (var i = 0; i < 6; i++) {
      await tester.drag(
        find.byKey(const ValueKey('category-grid')),
        const Offset(0, -2000),
      );
      await settle(tester);
    }
    expect(provider.asked.map((a) => a.page), [1, 2, 3]);
    expect(
      cardTitles(tester).toSet(),
      hasLength(cardTitles(tester).length),
      reason: 'no title twice',
    );
  });

  testWidgets(
    'a filter chip opens its options, and a choice reloads from page 1',
    (tester) async {
      await pumpScreen(tester);
      expect(
        find.text('地区: All', findRichText: true),
        findsOneWidget,
        reason: 'filters start at all',
      );
      expect(find.text('年份: All', findRichText: true), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('category-filter-region')));
      await settle(tester);
      expect(find.byType(CategoryOptionPicker), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('category-option-韩国')));
      await settle(tester);

      final filtered = provider.asked
          .where((a) => a.filters['region'] == '韩国')
          .toList();
      expect(filtered.first.page, 1, reason: 'starts over from page 1');
      expect(provider.asked.last.filters, {'region': '韩国'});
      expect(cardTitles(tester).first, '4 region=韩国 1.1');
      // The chip says what was chosen, and Reset appears.
      expect(find.text('地区: 韩国', findRichText: true), findsOneWidget);
      expect(find.byKey(const ValueKey('category-reset')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('category-sort')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('category-option-0')));
      await settle(tester);
      expect(provider.asked.last.filters, {'region': '韩国', 'sort': '0'});
      expect(find.text('最新添加'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('category-reset')));
      await settle(tester);
      expect(provider.asked.last.filters, isEmpty);
      expect(find.byKey(const ValueKey('category-reset')), findsNothing);
    },
  );

  testWidgets('the picker works from the keyboard', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('category-filter-region')));
    await settle(tester);
    // "All" is chosen, so it has focus; the next option is a Tab away.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(provider.asked.last.filters, {'region': '韩国'});
  });

  testWidgets(
    'the search waits for typing to rest, then searches the category',
    (tester) async {
      await pumpScreen(tester);
      final asked = provider.asked.length;
      await tester.enterText(
        find.byKey(const ValueKey('category-search')),
        'lo',
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const ValueKey('category-search')),
        'love',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(provider.asked.length, asked, reason: 'not while typing');
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      final searched = provider.asked.where((a) => a.query.isNotEmpty).toList();
      // Only the rested text, from page 1 (later pages fill the screen).
      expect(searched.map((a) => a.query).toSet(), {'love'});
      expect(searched.first.page, 1);
      expect(cardTitles(tester).first, '4 q=love 1.1');
    },
  );

  testWidgets('says when nothing matches, with a way back', (tester) async {
    provider.empty = true;
    await pumpScreen(tester);
    await settle(tester);
    expect(find.byKey(const ValueKey('category-empty')), findsOneWidget);
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('a failed first page offers a retry', (tester) async {
    provider.failing.add(1);
    await pumpScreen(tester);
    await settle(tester);
    expect(find.byKey(const ValueKey('category-error')), findsOneWidget);
    provider.failing.clear();
    await tester.tap(find.text('Retry'));
    await settle(tester);
    expect(find.byKey(const ValueKey('category-error')), findsNothing);
    expect(cardTitles(tester), isNotEmpty);
  });

  testWidgets('shimmer while the first page comes', (tester) async {
    provider.gate = null;
    await tester.pumpWidget(
      app(
        CategoryScreen(
          category: series,
          provider: provider,
          onOpen: opened.add,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('category-loading')), findsOneWidget);
    await settle(tester);
    expect(find.byKey(const ValueKey('category-loading')), findsNothing);
  });

  testWidgets("home's chips are the categories, and a chip opens its own", (
    tester,
  ) async {
    final chosen = <ProviderCategory>[];
    await tester.pumpWidget(
      app(
        Scaffold(
          body: HomeCategoryChips(
            categories: const [
              series,
              ProviderCategory(id: '3', name: '电影'),
            ],
            onOpen: chosen.add,
          ),
        ),
      ),
    );
    expect(find.text('Categories'), findsOneWidget);
    expect(find.text('电视剧'), findsOneWidget);
    await tester.tap(find.text('电影'));
    expect(chosen.single.id, '3');
  });
}
