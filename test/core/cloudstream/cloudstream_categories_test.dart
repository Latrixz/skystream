/// A CloudStream provider's categories go through the engine's `categories` and `categoryPage`.
library;

import 'package:cs3_engine/cs3_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_models.dart';
import 'package:skystream/core/cloudstream/cloudstream_provider.dart';
import 'package:skystream/core/extensions/base_provider.dart';

void main() {
  late _CategoryEngine engine;

  CloudStreamProvider provider() => CloudStreamProvider(
    plugin: const CsInstalledPlugin(
      info: CsPluginInfo(
        internalName: 'Kubb',
        name: 'Kubb',
        url: '',
        repositoryUrl: '',
      ),
      filePath: '/plugins/Kubb.cs3',
    ),
    pluginKey: 'repo/Kubb',
    info: const CsProviderInfo(name: '酷播 Kubb'),
    host: _Host(engine),
  );

  setUp(() => engine = _CategoryEngine());

  test("categories are the extension's, asked for once", () async {
    final kubb = provider();
    final categories = await kubb.getCategories();
    expect(categories.map((c) => (c.id, c.name)), [('3', '电影'), ('4', '电视剧')]);
    expect(categories.first.filters.single.name, '地区');
    expect(categories.first.filters.single.options.map((o) => o.label), [
      '韩国',
      'Japan',
    ]);
    expect(categories.first.sorts.map((s) => s.label), ['热播', '最新添加']);
    await kubb.getCategories();
    expect(engine.categoryCalls, 1);
    expect(engine.plugins.single, '/plugins/Kubb.cs3');
  });

  test('an extension without categories has none', () async {
    engine.supported = false;
    expect(await provider().getCategories(), isEmpty);
  });

  test(
    "a failure is no categories, and they're asked for again next time",
    () async {
      engine.failing = true;
      final kubb = provider();
      expect(await kubb.getCategories(), isEmpty);
      engine.failing = false;
      expect(await kubb.getCategories(), hasLength(2));
      expect(engine.categoryCalls, 2);
    },
  );

  test('a page is asked for with its filters, query and page, its items mapped as search results', () async {
    final kubb = provider();
    final category = (await kubb.getCategories())[1];
    final page = await kubb.getCategoryPage(
      category,
      const {'region': '韩国', 'sort': '0'},
      'love',
      2,
    );
    final asked = engine.pages.single;
    expect((asked.category, asked.query, asked.page), ('4', 'love', 2));
    expect(asked.filters, {'region': '韩国', 'sort': '0'});
    final item = page.items.single;
    expect(item.title, '铁拳教育');
    expect(item.url, 'https://www.kubb.tv/play/1');
    expect(item.posterUrl, 'https://static.kubb.tv/1.jpg');
    expect(item.headers, {'Referer': 'https://www.kubb.tv/'});
    expect(
      item.provider,
      kubb.packageName,
      reason: 'details opens it with this provider',
    );
    expect(page.hasNext, isTrue);
  });

  test("a page's failure is the caller's", () async {
    final kubb = provider();
    final category = (await kubb.getCategories()).first;
    engine.failing = true;
    await expectLater(
      kubb.getCategoryPage(category, const {}, '', 1),
      throwsA(isA<Cs3EngineException>()),
    );
  });

  test('other providers have no categories', () async {
    final plain = _Plain();
    expect(await plain.getCategories(), isEmpty);
    final page = await plain.getCategoryPage(
      const ProviderCategory(id: '1', name: 'x'),
      const {},
      '',
      1,
    );
    expect(page.items, isEmpty);
    expect(page.hasNext, isFalse);
  });
}

class _Plain extends SkyStreamProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Host extends CloudStreamEngineHost {
  _Host(this.running);

  final Cs3Engine running;

  @override
  Future<T> run<T>(
    String path,
    Future<T> Function(Cs3Engine engine) call, {
    String kind = 'call',
    String? provider,
    String mainUrl = '',
    String? pluginUrl,
  }) => call(running);
}

class _CategoryEngine implements Cs3Engine {
  bool supported = true;
  bool failing = false;
  int categoryCalls = 0;
  final plugins = <String?>[];
  final pages =
      <
        ({String category, Map<String, String> filters, String query, int page})
      >[];

  @override
  Future<Map<String, dynamic>> categories(
    String provider, {
    String? plugin,
  }) async {
    categoryCalls++;
    plugins.add(plugin);
    if (failing) throw Cs3EngineException('java.io.IOException', 'offline');
    if (!supported) return {'supported': false, 'categories': <Object>[]};
    return {
      'supported': true,
      'categories': [
        {
          'id': '3',
          'name': '电影',
          'filters': [
            {
              'key': 'region',
              'name': '地区',
              'options': [
                {'value': '韩国', 'label': '韩国'},
                {'value': '日本', 'label': 'Japan'},
              ],
            },
          ],
          'sorts': [
            {'value': '2', 'label': '热播'},
            {'value': '0', 'label': '最新添加'},
          ],
        },
        {'id': '4', 'name': '电视剧', 'filters': <Object>[], 'sorts': <Object>[]},
        {'id': '', 'name': 'no id'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> categoryPage(
    String provider,
    String category, {
    Map<String, String> filters = const {},
    String query = '',
    int page = 1,
    String? plugin,
  }) async {
    pages.add((category: category, filters: filters, query: query, page: page));
    if (failing) {
      throw Cs3EngineException('java.lang.IllegalStateException', 'site down');
    }
    return {
      'items': [
        {
          'name': '铁拳教育',
          'url': 'https://www.kubb.tv/play/1',
          'type': 'TvSeries',
          'posterUrl': 'https://static.kubb.tv/1.jpg',
          'posterHeaders': {'Referer': 'https://www.kubb.tv/'},
        },
      ],
      'hasNext': true,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
