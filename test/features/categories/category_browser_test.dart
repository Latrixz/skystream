import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/features/categories/category_browser.dart';

import 'category_test_support.dart';

void main() {
  late FakeCategoryProvider provider;
  late CategoryBrowser browser;

  setUp(() {
    provider = FakeCategoryProvider();
    browser = CategoryBrowser(provider: provider, category: series);
  });
  tearDown(() => browser.dispose());

  test('pages in one at a time and stops at the last', () async {
    await browser.refresh();
    expect(browser.items, hasLength(4));
    expect(browser.hasNext, isTrue);
    await browser.loadMore();
    await browser.loadMore();
    expect(browser.items, hasLength(12));
    expect(browser.hasNext, isFalse);
    await browser.loadMore();
    expect(provider.asked.map((a) => a.page), [1, 2, 3]);
  });

  test('a page already on its way is not asked for twice', () async {
    provider.gate = Completer<void>();
    final first = browser.refresh();
    unawaited(browser.loadMore());
    expect(browser.isFirstLoad, isTrue);
    provider.gate!.complete();
    await first;
    expect(provider.asked.map((a) => a.page), [1]);
  });

  test(
    'titles seen before are dropped, and a page of nothing new ends it',
    () async {
      provider.repeats = true;
      await browser.refresh();
      await browser.loadMore();
      expect(browser.items, hasLength(4));
      expect(browser.hasNext, isFalse);
    },
  );

  test('filters, the sort and the search start over from page 1', () async {
    await browser.refresh();
    await browser.loadMore();

    browser.setFilter('region', '韩国');
    await pumpEventQueue();
    final last = provider.asked.last;
    expect((last.category, last.query, last.page), ('4', '', 1));
    expect(last.filters, {'region': '韩国'});
    expect(browser.items.first.title, '4 region=韩国 1.1');
    expect(browser.hasChoices, isTrue);

    browser.setSort('0');
    browser.setQuery('  love ');
    await pumpEventQueue();
    expect(provider.asked.last.filters, {'region': '韩国', 'sort': '0'});
    expect(provider.asked.last.query, 'love');

    // The default sort is no choice at all.
    browser.setSort('2');
    await pumpEventQueue();
    expect(provider.asked.last.filters, {'region': '韩国'});

    browser.reset();
    await pumpEventQueue();
    expect(provider.asked.last.filters, isEmpty);
    expect(browser.hasChoices, isFalse);
    expect(browser.query, 'love', reason: 'reset leaves the search alone');
  });

  test('the same choice again asks for nothing', () async {
    await browser.refresh();
    browser.setQuery('');
    browser.setFilter('region', null);
    await pumpEventQueue();
    expect(provider.asked, hasLength(1));
  });

  test("an answer for what was asked before is dropped", () async {
    provider.gate = Completer<void>();
    unawaited(browser.refresh());
    browser.setFilter('region', '日本');
    provider.gate!.complete();
    await pumpEventQueue();
    expect(browser.items.map((i) => i.title).toSet(), {
      for (var n = 1; n <= 4; n++) '4 region=日本 1.$n',
    });
  });

  test('a failed page keeps what came, and retry asks again', () async {
    await browser.refresh();
    provider.failing.add(2);
    await browser.loadMore();
    expect(browser.error, isNotNull);
    expect(browser.items, hasLength(4));
    // Not asked again on every scroll.
    await browser.loadMore();
    expect(provider.asked.map((a) => a.page), [1, 2]);

    provider.failing.clear();
    await browser.retry();
    expect(browser.error, isNull);
    expect(browser.items, hasLength(8));
  });

  test('categories parse from the contract JSON', () {
    final category = ProviderCategory.fromJson({
      'id': 3,
      'name': '电影',
      'filters': [
        {
          'key': 'genre',
          'name': '类型',
          'options': [
            {'value': '21', 'label': '动作'},
            {'value': '22'},
          ],
        },
        {'key': 'empty', 'name': 'x', 'options': <Object>[]},
      ],
      'sorts': [
        {'value': '2', 'label': '热播'},
      ],
    });
    expect(category.id, '3');
    expect(category.filters.single.options.map((o) => o.label), ['动作', '22']);
    expect(category.sortIn(const {})?.label, '热播');
    expect(
      category.filters.single.chosenIn(const {'genre': '21'})?.label,
      '动作',
    );
    final back = ProviderCategory.fromJson(category.toJson());
    expect(back.toJson(), category.toJson());
  });
}
