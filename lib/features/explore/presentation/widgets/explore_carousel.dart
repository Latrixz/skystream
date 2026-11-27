import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../../../core/router/app_router.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/utils/image_utils.dart';
import '../../../../core/utils/layout_constants.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../../core/domain/entity/multimedia_item.dart';

/// Lightweight controller for the hero carousel.
/// API-compatible with the old CarouselSliderController (nextPage/previousPage).
class HeroCarouselController {
  VoidCallback? onNextPage;
  VoidCallback? onPreviousPage;

  void nextPage({Duration? duration, Curve? curve}) => onNextPage?.call();
  void previousPage({Duration? duration, Curve? curve}) =>
      onPreviousPage?.call();
}

class ExploreCarousel extends ConsumerStatefulWidget {
  final List<MultimediaItem> movies;
  final ScrollController? scrollController;
  final void Function(MultimediaItem)? onTap;
  final VoidCallback? onNavigateUp;

  /// Called once after initState with the internal [HeroCarouselController]
  /// so the parent can drive prev/next from an external UI (e.g. header arrows).
  final void Function(HeroCarouselController controller)? onControllerReady;

  const ExploreCarousel({
    super.key,
    required this.movies,
    this.scrollController,
    this.onTap,
    this.onNavigateUp,
    this.onControllerReady,
  });

  /// Tests: the image a poster-only slide reads its shape from, in place of
  /// the network one.
  @visibleForTesting
  static ImageProvider Function(MultimediaItem movie)? debugPosterProbe;

  @override
  ConsumerState<ExploreCarousel> createState() => _ExploreCarouselState();
}

/// The shape of a poster-only item's poster, once its image has decoded.
enum _PosterShape { unknown, portrait, landscape }

/// Width over height of the posters [_PosterShapeProbe] has decoded, by URL,
/// so a revisit or a swipe back lays its slide out right from the first frame.
@visibleForTesting
abstract final class PosterAspectCache {
  static const int _capacity = 256;

  // Insertion-ordered: the first key is the least recently stored.
  static final Map<String, double> _aspects = {};

  static double? lookup(String url) => _aspects[url];

  static void store(String url, double aspect) {
    _aspects.remove(url);
    _aspects[url] = aspect;
    if (_aspects.length > _capacity) _aspects.remove(_aspects.keys.first);
  }

  static void clear() => _aspects.clear();
}

/// Builds a poster-only slide for its poster's [_PosterShape]: [image]'s
/// first frame gives the size, recorded in [PosterAspectCache] under [url].
/// [_PosterShape.unknown] while it loads, and if it fails.
class _PosterShapeProbe extends StatefulWidget {
  const _PosterShapeProbe({
    required this.url,
    required this.image,
    required this.builder,
  });

  final String url;
  final ImageProvider image;
  final Widget Function(BuildContext context, _PosterShape shape) builder;

  @override
  State<_PosterShapeProbe> createState() => _PosterShapeProbeState();
}

class _PosterShapeProbeState extends State<_PosterShapeProbe> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  _PosterShape _shape = _PosterShape.unknown;

  static _PosterShape _shapeOf(double aspect) =>
      aspect >= _ExploreCarouselState._landscapeMinAspect
      ? _PosterShape.landscape
      : _PosterShape.portrait;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_PosterShapeProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.image != widget.image) {
      _resolve();
    }
  }

  void _resolve() {
    final known = PosterAspectCache.lookup(widget.url);
    if (known != null) {
      _stopListening();
      _shape = _shapeOf(known);
      return;
    }
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (_listener != null && stream.key == _stream?.key) return;
    _stopListening();
    _shape = _PosterShape.unknown;
    _stream = stream;
    _listener = ImageStreamListener(
      _onImage,
      // The slide's own images show the failure; the probe just stays unsure.
      onError: (_, _) => _stopListening(),
    );
    stream.addListener(_listener!);
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    final image = info.image;
    final aspect = image.height > 0 ? image.width / image.height : 0.0;
    info.dispose();
    _stopListening();
    if (aspect <= 0) return;
    PosterAspectCache.store(widget.url, aspect);
    if (!mounted) return;
    setState(() => _shape = _shapeOf(aspect));
  }

  void _stopListening() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _shape);
}

// Intents used by the carousel's keyboard shortcuts. Defined at file scope so
// they're const-constructible and stable across rebuilds.
class _CarouselUpIntent extends Intent {
  const _CarouselUpIntent();
}

class _CarouselPrevIntent extends Intent {
  const _CarouselPrevIntent();
}

class _CarouselNextIntent extends Intent {
  const _CarouselNextIntent();
}

class _ExploreCarouselState extends ConsumerState<ExploreCarousel>
    with TickerProviderStateMixin {
  final ValueNotifier<int> _currentIndexNotifier = ValueNotifier<int>(0);
  final HeroCarouselController _heroCarouselController =
      HeroCarouselController();
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0.0);
  // Single anchor focus node so the carousel acts as ONE focus target on TV/
  // keyboard. Otherwise each slide is independently focusable and pages cause
  // focus to drop into the next row when slides unmount.
  final FocusNode _carouselFocusNode = FocusNode(debugLabel: 'carousel_anchor');
  bool _isFocusHighlighted = false;
  // True while the carousel occupies any visible viewport. Drives autoPlay
  // so the 5s slide loop pauses when the user scrolls past it — eliminates
  // off-screen frame work and the resulting battery / raster drain.
  bool _isVisibleOnScreen = true;

  // Crossfade + scale transition
  late final AnimationController _transitionController;
  late final Animation<double> _transitionAnimation;
  int _currentSlide = 0;
  int? _previousSlide;
  bool _isTransitioning = false;

  // Progress bar fill — also serves as the auto-advance timer (5s).
  late final AnimationController _fillController;

  @override
  void initState() {
    super.initState();

    _transitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _transitionAnimation = CurvedAnimation(
      parent: _transitionController,
      curve: Curves.fastOutSlowIn,
    );
    _transitionController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _isTransitioning = false;
          _previousSlide = null;
        });
      }
    });

    _fillController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
      // A clock, not an animation. On the default behaviour Flutter runs a
      // controller at 5% of its duration while the platform asks for
      // animations to be removed - Android's "Animation off" transition scale,
      // and the fast animation modes some phones map onto it - and the
      // five-second dwell became a quarter of a second. The slide transition
      // above may still collapse under that setting; the dwell may not.
      animationBehavior: AnimationBehavior.preserve,
    );
    _fillController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        _goToNextSlide();
      }
    });

    _heroCarouselController.onNextPage = _goToNextSlide;
    _heroCarouselController.onPreviousPage = _goToPreviousSlide;

    widget.scrollController?.addListener(_onParentScroll);
    // Expose the internal controller to the parent so header arrows can
    // drive carousel navigation. Deferred to post-frame to avoid calling
    // setState on an ancestor while the widget tree is still building.
    if (widget.onControllerReady != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onControllerReady!(_heroCarouselController);
      });
    }

    _fillController.forward();
  }

  void _goToNextSlide() {
    if (widget.movies.length <= 1) return;
    final next = (_currentSlide + 1) % widget.movies.length;
    _startTransitionTo(next);
  }

  void _goToPreviousSlide() {
    if (widget.movies.length <= 1) return;
    final prev =
        (_currentSlide - 1 + widget.movies.length) % widget.movies.length;
    _startTransitionTo(prev);
  }

  void _startTransitionTo(int nextIndex) {
    if (_isTransitioning || nextIndex == _currentSlide || !mounted) return;
    setState(() {
      _previousSlide = _currentSlide;
      _currentSlide = nextIndex;
      _isTransitioning = true;
    });
    _currentIndexNotifier.value = nextIndex;
    _transitionController.forward(from: 0.0);
    _restartFill();
  }

  void _restartFill() {
    _fillController.reset();
    if (_isVisibleOnScreen) {
      _fillController.forward();
    }
  }

  void _onParentScroll() {
    // Always update — do NOT gate on _isVisibleOnScreen. Earlier we tried
    // to skip rebuilds while the carousel was off-screen, but that left
    // _scrollOffset frozen at a stale value; when the user scrolled back
    // up, syncing the offset on visibility-change caused a visible snap
    // (VisibilityDetector throttles, so the catch-up frame lands after
    // the user has already scrolled past it). The rebuild cost here is
    // negligible — Transform/RenderTransform reuses its RenderObject, the
    // CachedNetworkImage is cache-hit, and the whole carousel page is
    // wrapped in a RepaintBoundary so off-screen rebuilds don't ripple.
    if (widget.scrollController!.hasClients) {
      _scrollOffset.value = widget.scrollController!.offset;
    }
  }

  void _activateCurrent() {
    final movie = widget.movies[_currentSlide];
    if (widget.onTap != null) {
      widget.onTap!(movie);
    } else {
      _navigateToDetails(context, movie);
    }
  }

  @override
  void dispose() {
    _transitionController.dispose();
    _fillController.dispose();
    widget.scrollController?.removeListener(_onParentScroll);
    _scrollOffset.dispose();
    _currentIndexNotifier.dispose();
    _carouselFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.movies.isEmpty) return const SizedBox.shrink();

    final size = MediaQuery.sizeOf(context);
    final heroHeight = size.height * 0.60;
    // The wide hero layout is a size decision. A television reports 960 dp,
    // which is already past this 900 dp breakpoint, so the device clause that
    // used to be OR-ed in here could never change the answer for one.
    final isDesktop =
        size.width > LayoutConstants.exploreCarouselDesktopBreakpoint;

    return VisibilityDetector(
      key: const Key('explore-carousel-visibility'),
      // Visibility is still tracked — but only to gate the 5s auto-advance
      // timer (so we don't fire page transitions for an audience that
      // isn't watching). Parallax offset updates ignore this flag; see
      // [_onParentScroll] for the rationale.
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0.1;
        if (visible != _isVisibleOnScreen && mounted) {
          setState(() => _isVisibleOnScreen = visible);
          if (visible) {
            _fillController.forward();
          } else {
            _fillController.stop();
          }
        }
      },
      child: FocusableActionDetector(
        focusNode: _carouselFocusNode,
        // Only auto-focus on TV where D-pad is the primary input. On desktop
        // we skip autofocus so the focus ring doesn't appear on app launch
        // (Flutter defaults to 'traditional' highlight mode until a mouse
        // event arrives, which would show the ring immediately).
        autofocus: false,
        mouseCursor: SystemMouseCursors.click,
        // Arrow keys are wired as explicit Shortcuts/Actions at this level so
        // they fire when _carouselFocusNode has focus. Using a nested
        // Focus(onKeyEvent:) for arrows is unreliable here — that child Focus
        // is a descendant of _carouselFocusNode, and key events only propagate
        // UP from the focused node, so the child's handler never runs. Worse,
        // unhandled arrow keys fall through to Flutter's default ScrollAction
        // which then scrolls the outer vertical CustomScrollView — exactly the
        // "Right pages carousel AND scrolls page vertically" bug we saw.
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): _CarouselUpIntent(),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _CarouselPrevIntent(),
          SingleActivator(LogicalKeyboardKey.arrowRight): _CarouselNextIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activateCurrent();
              return null;
            },
          ),
          _CarouselUpIntent: CallbackAction<_CarouselUpIntent>(
            onInvoke: (_) {
              widget.onNavigateUp?.call();
              return null;
            },
          ),
          _CarouselPrevIntent: CallbackAction<_CarouselPrevIntent>(
            onInvoke: (_) {
              _goToPreviousSlide();
              return null;
            },
          ),
          _CarouselNextIntent: CallbackAction<_CarouselNextIntent>(
            onInvoke: (_) {
              _goToNextSlide();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (show) =>
            setState(() => _isFocusHighlighted = show),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            if (details.primaryVelocity == null) return;
            if (details.primaryVelocity! < -300) {
              _goToNextSlide();
            } else if (details.primaryVelocity! > 300) {
              _goToPreviousSlide();
            }
          },
          child: isDesktop
              ? RepaintBoundary(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      LayoutConstants.dashboardContentPadding,
                      LayoutConstants.spacingSm,
                      LayoutConstants.dashboardContentPadding,
                      0,
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: _isFocusHighlighted
                            ? Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 2.5,
                              )
                            : null,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: SizedBox(
                          height: heroHeight,
                          child: _buildCarouselStack(
                            heroHeight,
                            isDesktop: isDesktop,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : Padding(
                  padding: EdgeInsets.zero,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      border: _isFocusHighlighted
                          ? Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 2.5,
                            )
                          : null,
                    ),
                    child: SizedBox(
                      height: heroHeight,
                      child: _buildCarouselStack(
                        heroHeight,
                        isDesktop: isDesktop,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Custom carousel with crossfade + scale transition
  // Entry: scale 0.8→1, opacity 0→1  |  Exit: scale 1→1.2, opacity 1→0  |  400ms
  // ---------------------------------------------------------------------------

  Widget _buildCarouselStack(double height, {required bool isDesktop}) {
    return Stack(
      children: [
        // Previous slide (exiting) — only during transition
        if (_isTransitioning && _previousSlide != null)
          AnimatedBuilder(
            animation: _transitionAnimation,
            builder: (context, _) {
              final t = _transitionAnimation.value;
              return Opacity(
                opacity: 1.0 - t,
                child: Transform.scale(
                  scale: 1.0 + 0.2 * t,
                  child: _buildSlideForIndex(
                    height,
                    _previousSlide!,
                    isDesktop: isDesktop,
                  ),
                ),
              );
            },
          ),

        // Current slide (entering or static)
        _isTransitioning
            ? AnimatedBuilder(
                animation: _transitionAnimation,
                builder: (context, _) {
                  final t = _transitionAnimation.value;
                  return Opacity(
                    opacity: t,
                    child: Transform.scale(
                      scale: 0.8 + 0.2 * t,
                      child: _buildSlideForIndex(
                        height,
                        _currentSlide,
                        isDesktop: isDesktop,
                      ),
                    ),
                  );
                },
              )
            : _buildSlideForIndex(height, _currentSlide, isDesktop: isDesktop),

        // Progress bar indicators
        if (widget.movies.length > 1)
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: RepaintBoundary(child: _buildProgressIndicators()),
          ),
      ],
    );
  }

  Widget _buildProgressIndicators() {
    return ValueListenableBuilder<int>(
      valueListenable: _currentIndexNotifier,
      builder: (context, currentIndex, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final entry in widget.movies.asMap().entries)
              _ProgressDot(
                key: ValueKey('hcd_${entry.key}'),
                isActive: currentIndex == entry.key,
                fillController: _fillController,
              ),
          ],
        );
      },
    );
  }

  Widget _buildSlideForIndex(
    double height,
    int index, {
    required bool isDesktop,
  }) {
    final movie = widget.movies[index];
    if (widget.scrollController == null) {
      return _buildStaticItem(context, movie, height, isDesktop: isDesktop);
    }
    return _buildCarouselItem(context, movie, height, isDesktop: isDesktop);
  }

  void _navigateToDetails(BuildContext context, MultimediaItem movie) {
    // Standardize media type mapping (prevents TMDB ID collisions)
    final String mediaType = movie.tmdbMediaType;

    TmdbDetailsRoute(
      movieId: movie.id,
      mediaType: mediaType,
      heroTag: 'hero_${movie.id}',
      source: movie.source,
    ).push<void>(context);
  }

  Widget _buildCarouselItem(
    BuildContext context,
    MultimediaItem movie,
    double height, {
    bool isDesktop = false,
  }) {
    final theme = Theme.of(context);
    final scaffoldColor = theme.scaffoldBackgroundColor;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (widget.onTap != null) {
          widget.onTap!(movie);
        } else {
          _navigateToDetails(context, movie);
        }
      },
      child: RepaintBoundary(
        child: ValueListenableBuilder<double>(
          valueListenable: _scrollOffset,
          builder: (context, scrollOffset, child) {
            final parallaxOffset = scrollOffset * 0.1;
            final contentOffset = -scrollOffset * 0.2;
            final opacity = (1.0 - (scrollOffset / (height * 0.5))).clamp(
              0.0,
              1.0,
            );

            return _buildSlideBase(
              context: context,
              movie: movie,
              height: height,
              isDesktop: isDesktop,
              parallaxOffset: parallaxOffset,
              contentOffset: contentOffset,
              opacity: opacity,
              scaffoldColor: scaffoldColor,
              theme: theme,
            );
          },
        ),
      ),
    );
  }

  Widget _buildStaticItem(
    BuildContext context,
    MultimediaItem movie,
    double height, {
    bool isDesktop = false,
  }) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (widget.onTap != null) {
          widget.onTap!(movie);
        } else {
          _navigateToDetails(context, movie);
        }
      },
      child: _buildSlideBase(
        context: context,
        movie: movie,
        height: height,
        isDesktop: isDesktop,
        parallaxOffset: 0,
        contentOffset: 0,
        opacity: 1.0,
        scaffoldColor: theme.scaffoldBackgroundColor,
        theme: theme,
      ),
    );
  }

  Widget _buildSlideBase({
    required BuildContext context,
    required MultimediaItem movie,
    required double height,
    required bool isDesktop,
    required double parallaxOffset,
    required double contentOffset,
    required double opacity,
    required Color scaffoldColor,
    required ThemeData theme,
  }) {
    if (!_isPosterOnly(movie)) {
      return _buildBannerSlide(
        context: context,
        movie: movie,
        isDesktop: isDesktop,
        parallaxOffset: parallaxOffset,
        contentOffset: contentOffset,
        opacity: opacity,
        scaffoldColor: scaffoldColor,
        theme: theme,
      );
    }

    // A poster and no banner: the poster's own shape picks the layout. Some
    // plugins' horizontal home rows hand landscape stills in as posters, and
    // those want the full-bleed banner, not the framed portrait one.
    return _PosterShapeProbe(
      url: movie.posterUrl,
      image:
          ExploreCarousel.debugPosterProbe?.call(movie) ??
          _ambienceImage(movie),
      builder: (context, shape) => switch (shape) {
        _PosterShape.landscape => _buildBannerSlide(
          context: context,
          movie: movie,
          isDesktop: isDesktop,
          parallaxOffset: parallaxOffset,
          contentOffset: contentOffset,
          opacity: opacity,
          scaffoldColor: scaffoldColor,
          theme: theme,
          // The blurred decode is already in memory: the sharp one fades in
          // over it rather than over a flat placeholder.
          placeholder: _buildAmbience(movie, theme),
        ),
        _PosterShape.portrait || _PosterShape.unknown => _buildPortraitSlide(
          context: context,
          movie: movie,
          height: height,
          isDesktop: isDesktop,
          parallaxOffset: parallaxOffset,
          contentOffset: contentOffset,
          opacity: opacity,
          scaffoldColor: scaffoldColor,
          theme: theme,
          // Until the shape is known, the ambience alone: a framed poster
          // that turns out to be landscape would flash in and out.
          showPoster: shape == _PosterShape.portrait,
        ),
      },
    );
  }

  /// The full-width backdrop slide: [MultimediaItem.backdropImageUrl] (the
  /// banner, else the poster) covering the hero. [placeholder] stands in
  /// while it loads; a flat surface by default.
  Widget _buildBannerSlide({
    required BuildContext context,
    required MultimediaItem movie,
    required bool isDesktop,
    required double parallaxOffset,
    required double contentOffset,
    required double opacity,
    required Color scaffoldColor,
    required ThemeData theme,
    Widget? placeholder,
  }) {
    final imageUrl = movie.backdropImageUrl;
    final title = movie.title;

    const bleed = 60.0;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Background Image
          Positioned(
            top: -bleed + parallaxOffset,
            bottom: -bleed - parallaxOffset,
            left: 0,
            right: 0,
            // The box is the slide plus its parallax bleed, and it is not the
            // window: the wide layout pads the carousel, so only the
            // constraints know how big this backdrop is actually painted.
            // They are stable while a slide is up — parallax moves `top` and
            // `bottom` by the same amount, so the height does not change —
            // which matters because a decode bound that changed per frame
            // would be a new image-cache key per frame.
            child: LayoutBuilder(
              builder: (context, constraints) => CachedNetworkImage(
                imageUrl: imageUrl,
                httpHeaders: movie.headers,
                fit: BoxFit.cover,
                // TV and desktop fetch `original` backdrops (tmdb_config.dart
                // :78-80) — 1920x1080 at best, 3840x2160 for popular titles,
                // i.e. 8.3-33 MB decoded each, seven of them cycling every
                // 5 s against a 50 MB image cache. Bound to what is painted.
                memCacheWidth: ImageUtils.coverDecodeWidth(
                  context,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  sourceAspectRatio: ImageUtils.backdropAspectRatio,
                ),
                placeholder: (context, url) =>
                    placeholder ??
                    Container(color: theme.colorScheme.surfaceContainerHighest),
                errorWidget: (_, _, _) =>
                    ThumbnailErrorPlaceholder(label: title, isBackdrop: true),
              ),
            ),
          ),

          // 2. Parallax Gradients
          Positioned(
            top: -bleed + parallaxOffset,
            bottom: -bleed - parallaxOffset,
            left: 0,
            right: 0,
            child: _buildParallaxGradient(isDesktop: isDesktop),
          ),

          // 2.5. Fixed Bottom Feather (eased page transition scrim)
          _buildBottomFeather(scaffoldColor),

          // 3. Content
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Transform.translate(
              offset: Offset(0, contentOffset),
              child: opacity >= 0.999
                  ? _buildCarouselContent(
                      isDesktop: isDesktop,
                      movie: movie,
                      theme: theme,
                      context: context,
                    )
                  : Opacity(
                      opacity: opacity,
                      child: _buildCarouselContent(
                        isDesktop: isDesktop,
                        movie: movie,
                        theme: theme,
                        context: context,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParallaxGradient({required bool isDesktop}) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDesktop
              ? [
                  Colors.black.withValues(alpha: 0.2),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.45),
                  Colors.black.withValues(alpha: 0.75),
                ]
              : [
                  Colors.black.withValues(alpha: 0.3),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.4),
                  Colors.black.withValues(alpha: 0.8),
                ],
          stops: isDesktop
              ? const [0.0, 0.35, 0.75, 1.0]
              : const [0.0, 0.4, 0.6, 1.0],
        ),
      ),
    );
  }

  Widget _buildBottomFeather(Color scaffoldColor) {
    return Positioned(
      bottom: -1,
      left: 0,
      right: 0,
      height: 120,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                scaffoldColor.withValues(alpha: 0.0),
                scaffoldColor.withValues(alpha: 0.15),
                scaffoldColor.withValues(alpha: 0.45),
                scaffoldColor.withValues(alpha: 0.8),
                scaffoldColor,
              ],
              stops: const [0.0, 0.5, 0.75, 0.9, 1.0],
            ),
          ),
        ),
      ),
    );
  }

  /// Decode width of the blurred ambience behind a portrait-only slide. The
  /// blur throws the detail away, so a thumbnail is all it needs, and the
  /// blur pass runs over that small texture instead of a full-size poster.
  static const int _ambienceDecodeWidth = 160;

  /// Blur radius of that ambience, in logical pixels.
  static const double _ambienceBlurSigma = 28;

  /// Posters at least this much wider than tall get the full-bleed banner
  /// rather than the framed portrait layout.
  static const double _landscapeMinAspect = 1.2;

  /// An item with a poster and no banner: plugin home items (CloudStream's
  /// SearchResponse has no backdrop field) and the odd TMDB title without a
  /// backdrop. Stretching a portrait poster across the wide hero both
  /// pixelates and crops it, so these slides go through [_PosterShapeProbe].
  static bool _isPosterOnly(MultimediaItem movie) {
    final banner = movie.bannerUrl?.trim() ?? '';
    return banner.isEmpty && movie.posterUrl.trim().isNotEmpty;
  }

  /// The ambience's image, exactly as its [CachedNetworkImage] builds it, so
  /// the shape probe shares that image's download and decode.
  static ImageProvider _ambienceImage(MultimediaItem movie) =>
      ResizeImage.resizeIfNeeded(
        _ambienceDecodeWidth,
        null,
        CachedNetworkImageProvider(movie.posterUrl, headers: movie.headers),
      );

  /// The poster, blurred: the backdrop of a portrait slide, and what a
  /// landscape poster's banner fades in over.
  Widget _buildAmbience(MultimediaItem movie, ThemeData theme) {
    return RepaintBoundary(
      child: ImageFiltered(
        key: const ValueKey('portrait-banner-ambience'),
        imageFilter: ImageFilter.blur(
          sigmaX: _ambienceBlurSigma,
          sigmaY: _ambienceBlurSigma,
        ),
        child: CachedNetworkImage(
          imageUrl: movie.posterUrl,
          httpHeaders: movie.headers,
          fit: BoxFit.cover,
          memCacheWidth: _ambienceDecodeWidth,
          placeholder: (context, url) =>
              Container(color: theme.colorScheme.surfaceContainerHighest),
          errorWidget: (context, url, error) =>
              Container(color: theme.colorScheme.surfaceContainerHighest),
        ),
      ),
    );
  }

  /// The slide for a portrait (or square) poster-only item: the poster,
  /// blurred and darkened, fills the hero as ambience, and the poster itself
  /// sits sharp at its own aspect ratio — to the right of the text on the
  /// wide layout, above the centred text on the narrow one. Without
  /// [showPoster], the ambience and the text alone.
  Widget _buildPortraitSlide({
    required BuildContext context,
    required MultimediaItem movie,
    required double height,
    required bool isDesktop,
    required double parallaxOffset,
    required double contentOffset,
    required double opacity,
    required Color scaffoldColor,
    required ThemeData theme,
    required bool showPoster,
  }) {
    const bleed = 60.0;

    Widget fade(Widget child) =>
        opacity >= 0.999 ? child : Opacity(opacity: opacity, child: child);

    final content = _buildCarouselContent(
      isDesktop: isDesktop,
      movie: movie,
      theme: theme,
      context: context,
    );

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Blurred poster ambience
          Positioned(
            top: -bleed + parallaxOffset,
            bottom: -bleed - parallaxOffset,
            left: 0,
            right: 0,
            child: _buildAmbience(movie, theme),
          ),

          // 2. Parallax Gradients, over a flat dim: unlike a backdrop, the
          // ambience is the poster's own colours at full strength, and the
          // gradient's clear middle band would leave it loud behind the text.
          Positioned(
            top: -bleed + parallaxOffset,
            bottom: -bleed - parallaxOffset,
            left: 0,
            right: 0,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.35),
              child: _buildParallaxGradient(isDesktop: isDesktop),
            ),
          ),

          // 2.5. Fixed Bottom Feather (eased page transition scrim)
          _buildBottomFeather(scaffoldColor),

          // 3. Content
          if (isDesktop)
            // Text on the left where it always is, the poster on the right.
            Positioned(
              left: 24,
              right: 48,
              top: 32,
              bottom: 48,
              child: Transform.translate(
                offset: Offset(0, contentOffset),
                child: fade(
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: content,
                        ),
                      ),
                      if (showPoster) ...[
                        const SizedBox(width: 32),
                        LayoutBuilder(
                          builder: (context, constraints) => _buildSharpPoster(
                            context,
                            movie,
                            height: constraints.maxHeight,
                            maxWidth: constraints.maxHeight,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            )
          else
            // Centred text at the bottom, as before, with the poster above.
            Positioned(
              left: 24,
              right: 24,
              bottom: 48,
              child: Transform.translate(
                offset: Offset(0, contentOffset),
                child: fade(
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final posterHeight = height * 0.42;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // A landscape phone leaves no room above the text;
                          // the ambience alone still beats a stretched poster.
                          if (showPoster && posterHeight >= 140) ...[
                            _buildSharpPoster(
                              context,
                              movie,
                              height: posterHeight,
                              maxWidth: constraints.maxWidth,
                            ),
                            const SizedBox(height: LayoutConstants.spacingLg),
                          ],
                          content,
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The poster at its natural aspect ratio, [height] tall (narrower than
  /// [maxWidth] for anything taller than it is wide), with rounded corners and
  /// a soft shadow that hug the image rather than its box.
  Widget _buildSharpPoster(
    BuildContext context,
    MultimediaItem movie, {
    required double height,
    required double maxWidth,
  }) {
    if (!height.isFinite || height <= 0) return const SizedBox.shrink();
    final radius = BorderRadius.circular(14);
    return SizedBox(
      height: height,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: CachedNetworkImage(
          key: const ValueKey('portrait-banner-poster'),
          imageUrl: movie.posterUrl,
          httpHeaders: movie.headers,
          // Contain is height-driven here, so the height is the bound.
          memCacheHeight: (height * View.of(context).devicePixelRatio).round(),
          // The image sizes itself: a tight height and a loose width make
          // RenderImage take the source's aspect ratio, so the clip and the
          // shadow below land on the poster's own edges.
          imageBuilder: (context, imageProvider) => DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Image(image: imageProvider, fit: BoxFit.contain),
            ),
          ),
          placeholder: (context, url) => const SizedBox.shrink(),
          errorWidget: (context, url, error) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildCarouselContent({
    required bool isDesktop,
    required MultimediaItem movie,
    required ThemeData theme,
    required BuildContext context,
  }) {
    final logoUrl = movie.logoUrl;
    final title = movie.title;
    final year = movie.year?.toString() ?? '';
    final genres = movie.tags?.join(' • ') ?? '';
    final provider = movie.provider;

    String? type;
    final mType = movie.mediaType.toLowerCase();
    if (mType == 'movie') {
      type = "Movie";
    } else if (mType == 'series' || mType == 'tv') {
      type = "TV Show";
    } else if (mType == 'anime') {
      type = "Anime";
    } else if (mType == 'livestream') {
      type = "Live Stream";
    } else {
      type = mType.isNotEmpty
          ? mType[0].toUpperCase() + mType.substring(1)
          : null;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isDesktop
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        if (logoUrl != null)
          Padding(
            padding: const EdgeInsets.only(bottom: LayoutConstants.spacingLg),
            child: _buildLogo(logoUrl, title, isDesktop: isDesktop),
          )
        else
          _buildTitleFallback(title, isDesktop: isDesktop),
        Wrap(
          alignment: isDesktop ? WrapAlignment.start : WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8.0,
          runSpacing: 4.0,
          children: [
            if (provider != null && provider.isNotEmpty) ...[
              _buildMiniBadge(
                context,
                provider.toUpperCase(),
                isProvider: true,
              ),
            ],
            if (type != null) ...[_buildMiniBadge(context, type.toUpperCase())],
            if (genres.isNotEmpty) ...[
              Text(
                genres,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ],
            if (year.isNotEmpty) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.calendar_today_rounded,
                    size: 10,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    year,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildLogo(String logoUrl, String title, {bool isDesktop = false}) {
    if (logoUrl.toLowerCase().endsWith('.svg')) {
      return SvgPicture.network(
        logoUrl,
        height: 140,
        width: 300,
        fit: BoxFit.contain,
        placeholderBuilder: (context) =>
            const SizedBox(height: 140, width: 300),
        errorBuilder: (context, error, stackTrace) =>
            _buildTitleFallback(title, isDesktop: isDesktop),
      );
    }
    return CachedNetworkImage(
      imageUrl: logoUrl,
      height: 140,
      width: 300,
      fit: BoxFit.contain,
      alignment: Alignment.bottomCenter,
      placeholder: (context, url) => const SizedBox(height: 140, width: 300),
      errorWidget: (context, url, error) =>
          _buildTitleFallback(title, isDesktop: isDesktop),
    );
  }

  Widget _buildTitleFallback(String title, {bool isDesktop = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LayoutConstants.spacingXs),
      child: Text(
        title.toUpperCase(),
        textAlign: isDesktop ? TextAlign.left : TextAlign.center,
        maxLines: isDesktop ? 2 : 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 40,
          fontFamily: 'RobotoCondensed',
          fontWeight: FontWeight.w900,
          letterSpacing: 1.0,
          shadows: [Shadow(color: Colors.black, blurRadius: 10)],
        ),
      ),
    );
  }

  Widget _buildMiniBadge(
    BuildContext context,
    String label, {
    bool isProvider = false,
  }) {
    final theme = Theme.of(context);
    final color = isProvider
        ? theme.colorScheme.primary
        : theme.colorScheme.secondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// A single progress dot whose width animates with spring physics.
///
/// When [isActive] toggles the dot springs between inactive (11 px) and active
/// (35 px) width. The active dot also renders a fill bar driven by
/// [fillController] that grows from 0 % → 100 % over the auto-advance interval.
///
/// Each dot manages its own [AnimationController] for the spring width
/// transition — only two dots tick per toggle. The fill bar is a separate
/// [AnimatedBuilder] that exists only on the active dot, so per-frame fill
/// rebuilds are limited to exactly one dot.
class _ProgressDot extends StatefulWidget {
  final bool isActive;
  final AnimationController fillController;

  const _ProgressDot({
    super.key,
    required this.isActive,
    required this.fillController,
  });

  @override
  State<_ProgressDot> createState() => _ProgressDotState();
}

class _ProgressDotState extends State<_ProgressDot>
    with SingleTickerProviderStateMixin {
  static const double _activeWidth = 35.0;
  static const double _inactiveWidth = 11.0;
  static const double _height = 4.0;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _controller.value = widget.isActive ? 1.0 : 0.0;
  }

  @override
  void didUpdateWidget(_ProgressDot old) {
    super.didUpdateWidget(old);
    if (widget.isActive != old.isActive) {
      _animateToTarget();
    }
  }

  void _animateToTarget() {
    _controller.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 300, damping: 30),
        _controller.value,
        widget.isActive ? 1.0 : 0.0,
        0,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final width = _inactiveWidth + (_activeWidth - _inactiveWidth) * t;

        return Container(
          width: width,
          height: _height,
          margin: const EdgeInsets.symmetric(horizontal: 3.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            color: Colors.white.withValues(alpha: widget.isActive ? 0.3 : 0.2),
          ),
          child: widget.isActive
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: AnimatedBuilder(
                    animation: widget.fillController,
                    builder: (context, _) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: _activeWidth * widget.fillController.value,
                          height: _height,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      );
                    },
                  ),
                )
              : null,
        );
      },
    );
  }
}
