import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/explore/presentation/widgets/explore_carousel.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Plugin home items (CloudStream's SearchResponse has no backdrop field)
/// carry a portrait poster and no banner. Stretched across the wide hero that
/// poster pixelates and crops, so the carousel shows it whole and sharp over
/// a blurred copy of itself instead.

const _headers = {'Referer': 'https://plugin.test/'};

MultimediaItem _pluginItem() => MultimediaItem(
  title: 'Plugin Title',
  url: 'https://plugin.test/show',
  posterUrl: 'https://plugin.test/poster.jpg',
  contentType: MultimediaContentType.series,
  headers: _headers,
);

MultimediaItem _bannerItem() => MultimediaItem(
  title: 'Banner Title',
  url: 'https://tmdb.test/movie',
  posterUrl: 'https://tmdb.test/poster.jpg',
  bannerUrl: 'https://tmdb.test/backdrop.jpg',
  contentType: MultimediaContentType.movie,
);

final _ambience = find.byKey(const ValueKey('portrait-banner-ambience'));
final _poster = find.byKey(const ValueKey('portrait-banner-poster'));

Future<void> _pump(
  WidgetTester tester,
  MultimediaItem item, {
  required Size logicalSize,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logicalSize;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: ExploreCarousel(movies: [item])),
      ),
    ),
  );
  // Never settle: the slide auto-advance controller keeps running.
  await tester.pump();
}

CachedNetworkImage _image(WidgetTester tester, Finder finder) =>
    tester.widget<CachedNetworkImage>(finder);

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  tearDown(() {
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    );
  });

  testWidgets('an item with a banner keeps the full-bleed backdrop', (
    tester,
  ) async {
    await _pump(tester, _bannerItem(), logicalSize: const Size(1600, 1000));

    expect(_ambience, findsNothing);
    expect(_poster, findsNothing);
    final backdrop = _image(tester, find.byType(CachedNetworkImage).first);
    expect(backdrop.imageUrl, 'https://tmdb.test/backdrop.jpg');
    expect(backdrop.fit, BoxFit.cover);
  });

  group('a portrait-only item', () {
    testWidgets('blurs a small decode of its poster behind the slide, with '
        'its headers', (tester) async {
      await _pump(tester, _pluginItem(), logicalSize: const Size(1600, 1000));

      expect(_ambience, findsOneWidget);
      final ambience = _image(
        tester,
        find.descendant(
          of: _ambience,
          matching: find.byType(CachedNetworkImage),
        ),
      );
      expect(ambience.imageUrl, 'https://plugin.test/poster.jpg');
      expect(ambience.fit, BoxFit.cover);
      expect(ambience.memCacheWidth, lessThanOrEqualTo(200));
      expect(ambience.httpHeaders, _headers);

      final poster = _image(tester, _poster);
      expect(poster.imageUrl, 'https://plugin.test/poster.jpg');
      expect(poster.httpHeaders, _headers);
      expect(poster.memCacheHeight, isNotNull);
    });

    testWidgets('puts the sharp poster right of the text on the wide layout', (
      tester,
    ) async {
      await _pump(tester, _pluginItem(), logicalSize: const Size(1600, 1000));

      final title = tester.getRect(find.text('PLUGIN TITLE'));
      final poster = tester.getRect(_poster);
      expect(poster.left, greaterThan(title.right));
      expect(poster.right, greaterThan(800));
    });

    testWidgets('puts the sharp poster above the centred text on a phone', (
      tester,
    ) async {
      await _pump(tester, _pluginItem(), logicalSize: const Size(411, 915));

      final title = tester.getRect(find.text('PLUGIN TITLE'));
      final poster = tester.getRect(_poster);
      expect(poster.bottom, lessThanOrEqualTo(title.top));
      expect(poster.center.dx, closeTo(411 / 2, 1));
      expect(poster.top, greaterThan(0));
    });

    testWidgets('drops the sharp poster where a landscape phone has no room', (
      tester,
    ) async {
      await _pump(tester, _pluginItem(), logicalSize: const Size(800, 380));

      expect(_ambience, findsOneWidget);
      expect(_poster, findsNothing);
    });
  });
}
