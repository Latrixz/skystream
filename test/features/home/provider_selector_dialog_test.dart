import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/extensions/providers/extensions_controller.dart';
import 'package:skystream/features/home/presentation/home_provider.dart';
import 'package:skystream/features/home/presentation/home_screen.dart';
import 'package:skystream/features/home/presentation/home_state.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Enough rows to overflow the dialog so the list can actually fling.
const int _providerCount = 40;

class _FakeProvider extends SkyStreamProvider {
  final int index;
  final String? _name;
  _FakeProvider(this.index, [this._name]);

  @override
  String get packageName => 'fake.provider.$index';
  @override
  String get name => _name ?? 'Provider $index';
  @override
  String get mainUrl => 'https://fake.test/$index';
  @override
  String get version => '1.0.0';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes =>
      index.isEven ? {ProviderType.movie} : {ProviderType.series};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) => throw UnimplementedError();
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

/// The real notifiers reach for Hive-backed storage on every write; these
/// keep the state transitions and drop the persistence.
class _FakeHomeFilter extends HomeFilter {
  @override
  ProviderType? build() => null;

  @override
  Future<void> setFilter(ProviderType? type) async {
    state = type;
  }
}

class _FakeActiveProvider extends ActiveProvider {
  @override
  SkyStreamProvider? build() => null;

  @override
  Future<void> set(SkyStreamProvider? provider) async {
    state = provider;
  }
}

class _FakeHomeData extends HomeData {
  @override
  HomeState build() => const HomeNoProvider();
}

class _FakeExtensionsController extends ExtensionsController {
  @override
  ExtensionsState build() => const ExtensionsSuccess(
    installedPlugins: [],
    repositories: [],
    availablePlugins: {},
    availableUpdates: {},
  );

  @override
  Future<void> ensureInitialized() async {}
}

class _Host extends StatelessWidget {
  final VoidCallback onClosed;
  final List<SkyStreamProvider>? providers;
  final SkyStreamProvider? activeProvider;
  const _Host({required this.onClosed, this.providers, this.activeProvider});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () async {
          await showProviderSelectorDialog(
            context,
            providers:
                providers ??
                List.generate(_providerCount, (i) => _FakeProvider(i)),
            activeProvider: activeProvider,
          );
          onClosed();
        },
        child: const Text('open'),
      ),
    ),
  );
}

Future<ProviderContainer> _pumpHost(
  WidgetTester tester, {
  required VoidCallback onClosed,
  List<SkyStreamProvider>? providers,
  SkyStreamProvider? activeProvider,
}) async {
  final container = ProviderContainer(
    overrides: [
      homeFilterProvider.overrideWith(_FakeHomeFilter.new),
      activeProviderProvider.overrideWith(_FakeActiveProvider.new),
      homeDataProvider.overrideWith(_FakeHomeData.new),
      extensionsControllerProvider.overrideWith(_FakeExtensionsController.new),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _Host(
          onClosed: onClosed,
          providers: providers,
          activeProvider: activeProvider,
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('closing during a fling survives the exit transition', (
    tester,
  ) async {
    var closed = false;
    await _pumpHost(tester, onClosed: () => closed = true);

    // A disposed ScrollController drops off its positions, so it only bites
    // once a Scrollable re-attaches to it. Every Scrollable does exactly that
    // when the device pixel ratio changes - a window crossing to another
    // display - and the ballistic fling still in flight then notifies the
    // dead controller on the next frame. With the dialog already popped, a
    // controller disposed in `.then` of `showDialog` died right here.
    await tester.fling(find.byType(ListView), const Offset(0, -300), 2000);
    await tester.tap(find.text('Close'));
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 2.0;

    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('filtering then picking a provider selects it and pops', (
    tester,
  ) async {
    var closed = false;
    final container = await _pumpHost(tester, onClosed: () => closed = true);

    // 'None' is the auto-focused row when nothing is active, which is the
    // D-pad landing spot on TV.
    expect(Focus.of(tester.element(find.text('None'))).hasFocus, isTrue);

    await tester.fling(
      find.byType(SingleChildScrollView),
      const Offset(-200, 0),
      1500,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    expect(find.text('None'), findsNothing);
    expect(find.text('Provider 1'), findsNothing);

    // Read while the dialog still watches it: the filter is autoDispose and
    // resets once its last listener goes away with the route.
    expect(container.read(homeFilterProvider), ProviderType.movie);

    await tester.tap(find.text('Provider 2'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(
      container.read(activeProviderProvider)?.packageName,
      'fake.provider.2',
    );
  });

  testWidgets('search narrows by name, ignoring case, CJK included', (
    tester,
  ) async {
    final active = _FakeProvider(1, 'Netflix');
    await _pumpHost(
      tester,
      onClosed: () {},
      providers: [
        _FakeProvider(0, 'Bilibili'),
        active,
        _FakeProvider(2, '爱奇艺 iQIYI'),
        _FakeProvider(3, 'NetMirror'),
      ],
      activeProvider: active,
    );

    // The active provider is marked with the check, not a radio.
    expect(find.byType(Radio<String?>), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'NET');
    await tester.pumpAndSettle();
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('NetMirror'), findsOneWidget);
    expect(find.text('Bilibili'), findsNothing);
    expect(find.text('None'), findsNothing);

    await tester.enterText(find.byType(TextField), '爱奇');
    await tester.pumpAndSettle();
    expect(find.text('爱奇艺 iQIYI'), findsOneWidget);
    expect(find.text('Netflix'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No provider matches "zzz".'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('None'), findsOneWidget);
    expect(find.text('Bilibili'), findsOneWidget);
  });
}
