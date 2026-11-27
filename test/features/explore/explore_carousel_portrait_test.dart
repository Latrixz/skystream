import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/explore/presentation/widgets/explore_carousel.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Plugin home items (CloudStream's SearchResponse has no backdrop field)
/// carry a poster and no banner. A portrait poster stretched across the wide
/// hero pixelates and crops, so the carousel shows it whole and sharp over a
/// blurred copy of itself instead. Some plugins' horizontal rows hand in
/// landscape stills as posters, though, and those keep the full-bleed banner:
/// the poster's decoded size decides.

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

const _posterUrl = 'https://plugin.test/poster.jpg';

/// An already decoded image of a given size, standing in for the poster.
class _SizedImage extends ImageProvider<_SizedImage> {
  const _SizedImage(this.image);

  final ui.Image image;

  @override
  Future<_SizedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _SizedImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture(ImageInfo(image: image.clone())),
  );
}

Future<void> _probeWith(WidgetTester tester, int width, int height) async {
  final image = await tester.runAsync(
    () => createTestImage(width: width, height: height),
  );
  final provider = _SizedImage(image!);
  ExploreCarousel.debugPosterProbe = (_) => provider;
  addTearDown(image.dispose);
}

void _expectFullBleedPoster(WidgetTester tester) {
  expect(_poster, findsNothing);
  final backdrop = _image(tester, find.byType(CachedNetworkImage).first);
  expect(backdrop.imageUrl, _posterUrl);
  expect(backdrop.fit, BoxFit.cover);
  expect(backdrop.httpHeaders, _headers);
}

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    PosterAspectCache.clear();
  });

  tearDown(() {
    ExploreCarousel.debugPosterProbe = null;
    PosterAspectCache.clear();
    PaintingBinding.instance.imageCache.clear();
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

  group('a portrait poster-only item', () {
    setUp(() => PosterAspectCache.store(_posterUrl, 2 / 3));

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

  group('a poster-only item', () {
    testWidgets('shows only the ambience until the poster\'s shape is known', (
      tester,
    ) async {
      await _pump(tester, _pluginItem(), logicalSize: const Size(1600, 1000));

      expect(_ambience, findsOneWidget);
      expect(_poster, findsNothing);
      expect(find.text('PLUGIN TITLE'), findsOneWidget);
    });

    testWidgets('with a known landscape poster gets the full-bleed banner', (
      tester,
    ) async {
      PosterAspectCache.store(_posterUrl, 16 / 9);
      await _pump(tester, _pluginItem(), logicalSize: const Size(1600, 1000));

      _expectFullBleedPoster(tester);
    });

    testWidgets('with a square poster keeps the framed layout', (tester) async {
      PosterAspectCache.store(_posterUrl, 1.0);
      await _pump(tester, _pluginItem(), logicalSize: const Size(1600, 1000));

      expect(_ambience, findsOneWidget);
      expect(_poster, findsOneWidget);
    });

    testWidgets('reads a landscape shape from the decoded poster', (
      tester,
    ) async {
      await _probeWith(tester, 320, 180);
      await _pump(tester, _pluginItem(), logicalSize: const Size(1600, 1000));
      await tester.pump();

      _expectFullBleedPoster(tester);
      expect(PosterAspectCache.lookup(_posterUrl), closeTo(320 / 180, 1e-9));
    });

    testWidgets('reads a portrait shape from the decoded poster', (
      tester,
    ) async {
      await _probeWith(tester, 200, 300);
      await _pump(tester, _pluginItem(), logicalSize: const Size(1600, 1000));
      await tester.pump();

      expect(_ambience, findsOneWidget);
      expect(_poster, findsOneWidget);
      expect(PosterAspectCache.lookup(_posterUrl), closeTo(200 / 300, 1e-9));
    });
  });
}
