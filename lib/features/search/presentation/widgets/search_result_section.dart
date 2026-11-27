import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../../cloudstream/presentation/cloudstream_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/core/utils/responsive_breakpoints.dart';

import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/router/app_router.dart';
import 'package:skystream/core/utils/image_fallbacks.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/cards_wrapper.dart';
import 'package:skystream/shared/widgets/desktop_scroll_wrapper.dart';
import 'package:skystream/shared/widgets/loading_indicator.dart';
import 'package:skystream/shared/widgets/multimedia_card.dart';

import '../search_pager.dart';
import '../search_sources.dart';
import 'search_source_tag.dart';
import 'stamp_in_label.dart';
import 'bouncy_entry_animation.dart';

class SearchResultSection extends ConsumerStatefulWidget {
  final String providerName;
  final String providerId;
  final List<MultimediaItem> results;
  final FocusNode? firstCardFocusNode;

  /// The system the section comes from, which its tag names.
  final SearchSourceKind kind;

  /// Opens the section's results in their own system's pages; without one,
  /// they open on the details page.
  final SearchSource? source;

  /// The provider's next pages: the row then lists the pager's items, and
  /// ends in a Show More card while more may follow.
  final SearchPager? pager;

  SearchResultSection({
    super.key,
    required this.providerName,
    required this.providerId,
    required this.results,
    this.firstCardFocusNode,
    SearchSourceKind? kind,
    this.source,
    this.pager,
  }) : kind =
           kind ??
           (CloudStreamBadge.isCloudStream(providerId)
               ? SearchSourceKind.cloudstream
               : SearchSourceKind.skystream);

  @override
  ConsumerState<SearchResultSection> createState() =>
      _SearchResultSectionState();
}

class _SearchResultSectionState extends ConsumerState<SearchResultSection> {
  final ScrollController _scrollController = ScrollController();

  /// The Show More card's.
  final FocusNode _moreFocusNode = FocusNode(debugLabel: 'search-show-more');

  /// The card focus goes to once a page it was waiting on at Show More has
  /// come: the page's first, or the row's last when it brought none.
  final FocusNode _landingFocusNode = FocusNode(debugLabel: 'search-landing');
  int? _landingIndex;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    widget.pager?.addListener(_onPage);
  }

  @override
  void didUpdateWidget(covariant SearchResultSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.pager, widget.pager)) {
      oldWidget.pager?.removeListener(_onPage);
      widget.pager?.addListener(_onPage);
      _landingIndex = null;
    }
  }

  @override
  void dispose() {
    // The pager stays the search's: the row, scrolled back into the list,
    // shows its pages again.
    widget.pager?.removeListener(_onPage);
    _scrollController.dispose();
    _moreFocusNode.dispose();
    _landingFocusNode.dispose();
    super.dispose();
  }

  void _onPage() {
    if (mounted) setState(() {});
  }

  /// Near the row's end, its next page: scrolling, or walking the cards with
  /// the D-pad, runs on into it.
  void _onScroll() {
    final pager = widget.pager;
    if (pager == null || !pager.hasMore || pager.isLoading) return;
    final position = _scrollController.position;
    if (position.extentAfter < position.viewportDimension / 2) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    final pager = widget.pager;
    if (pager == null) return;
    final before = pager.items.length;
    await pager.loadMore();
    if (!mounted || !identical(pager, widget.pager)) return;
    // A row still short of its end (the page's titles didn't match the
    // query) asks on.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) _onScroll();
    });
    // Focus waiting at Show More goes on to what the page brought.
    if (!_moreFocusNode.hasFocus) return;
    final count = pager.items.length;
    if (count > before || !pager.hasMore) {
      setState(() => _landingIndex = count > before ? before : count - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _landingFocusNode.context != null) {
          _landingFocusNode.requestFocus();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pager = widget.pager;
    final items = pager?.items ?? widget.results;
    if (items.isEmpty) return const SizedBox.shrink();
    final showMore = pager != null && (pager.hasMore || pager.isLoading);

    final isLarge = context.isTabletOrLarger;
    // Matching MediaHorizontalList/ContinueWatchingSection dimensions
    final double listHeight = isLarge ? 350.0 : 230.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with Blue Accent Style
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StampInLabel(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.providerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: isLarge ? 24 : 20,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                          _buildDebugTag(context, ref),
                          const SizedBox(width: 8),
                          SearchSourceTag(widget.kind),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: isLarge ? 30 : 20,
                      height: 3,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        SizedBox(
          height: listHeight,
          child: DesktopScrollWrapper(
            controller: _scrollController,
            child: Builder(
              builder: (context) {
                final double cardWidth = isLarge ? 200.0 : 130.0;
                final double spacing = isLarge ? 24.0 : 12.0;

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length + (showMore ? 1 : 0),
                  itemExtent: cardWidth + spacing,
                  clipBehavior: Clip.none,
                  itemBuilder: (context, rIndex) {
                    if (rIndex >= items.length) {
                      return Padding(
                        padding: EdgeInsets.only(right: spacing),
                        child: _ShowMoreCard(
                          focusNode: _moreFocusNode,
                          isLoading: pager!.isLoading,
                          onTap: () => unawaited(_loadMore()),
                        ),
                      );
                    }
                    final item = items[rIndex];
                    final uniqueTag =
                        'search_${widget.providerId}_${item.url}_$rIndex';

                    return Padding(
                      padding: EdgeInsets.only(right: spacing),
                      child: BouncyEntryAnimation(
                        delay: Duration(milliseconds: rIndex * 50),
                        child: MultimediaCard(
                          key: ValueKey(item.url),
                          imageUrl: AppImageFallbacks.poster(
                            item.posterUrl,
                            label: item.title,
                          ),
                          title: item.title,
                          heroTag: uniqueTag,
                          focusNode: rIndex == 0
                              ? widget.firstCardFocusNode
                              : rIndex == _landingIndex
                              ? _landingFocusNode
                              : null,
                          onTap: () {
                            final source = widget.source;
                            if (source != null) {
                              unawaited(source.open(context, item));
                              return;
                            }
                            DetailsRoute(
                              $extra: DetailsRouteExtra(item: item),
                            ).push<void>(context);
                          },
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDebugTag(BuildContext context, WidgetRef ref) {
    bool isDebug = false;
    try {
      final manager = ref.read(extensionManagerProvider.notifier);
      final p = manager.getAllProviders().firstWhere(
        (p) => p.packageName == widget.providerId,
      );
      if (p.isDebug) {
        isDebug = true;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('SearchResultSection._buildDebugTag: $e');
    }

    if (!isDebug) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.red,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'DEBUG',
          style: TextStyle(
            fontSize: 10,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// The end of a row with more pages: asks for the next, and shows it coming.
/// Focusable like the cards, so the D-pad and Tab reach it.
class _ShowMoreCard extends StatelessWidget {
  const _ShowMoreCard({
    required this.focusNode,
    required this.isLoading,
    required this.onTap,
  });

  final FocusNode focusNode;
  final bool isLoading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = AppLocalizations.of(context)!.showMore;
    return Semantics(
      button: true,
      label: label,
      child: CardsWrapper(
        focusNode: focusNode,
        scaleFactor: 1.05,
        onTap: isLoading ? () {} : onTap,
        child: Container(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: isLoading
              ? const AppLoadingIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 32,
                      color: colors.primary,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
