import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/focus/text_field_keys.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../../shared/widgets/shimmer_placeholder.dart';
import '../category_browser.dart';
import 'category_option_picker.dart';
import 'category_pill.dart';

/// One of a provider's categories: a search within it, its filters and sort
/// as chips, and its titles in a grid that pages in as it scrolls.
class CategoryScreen extends ConsumerStatefulWidget {
  const CategoryScreen({
    super.key,
    required this.category,
    this.provider,
    this.onOpen,
    this.searchDebounce = const Duration(milliseconds: 450),
  });

  final ProviderCategory category;

  /// The provider whose category this is; the active one when null.
  final SkyStreamProvider? provider;

  /// What a title's tap does; the details screen when null.
  final ValueChanged<MultimediaItem>? onOpen;

  /// How long typing rests before the search runs.
  final Duration searchDebounce;

  @override
  ConsumerState<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends ConsumerState<CategoryScreen> {
  CategoryBrowser? _browser;
  final _scroll = ScrollController();
  final _search = TextEditingController();
  late final FocusNode _searchFocus = FocusNode(
    debugLabel: 'category search',
    onKeyEvent: remoteTextFieldKeys,
  );
  Timer? _debounce;

  /// Within this of the end, the next page is asked for.
  static const double _loadAhead = 900;

  @override
  void initState() {
    super.initState();
    final provider = widget.provider ?? ref.read(activeProviderProvider);
    if (provider != null) {
      _browser = CategoryBrowser(provider: provider, category: widget.category)
        ..addListener(_changed)
        ..refresh();
    }
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _browser
      ?..removeListener(_changed)
      ..dispose();
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // A page that doesn't fill the screen leaves nothing to scroll: ask for
    // the next one straight away.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fillViewport());
  }

  void _fillViewport() {
    final browser = _browser;
    if (!mounted || browser == null || !_scroll.hasClients) return;
    if (browser.items.isEmpty) return;
    if (_scroll.position.maxScrollExtent <= _loadAhead / 3) browser.loadMore();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - _loadAhead) {
      _browser?.loadMore();
    }
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(widget.searchDebounce, () => _runSearch(text));
    setState(() {}); // The clear button.
  }

  void _runSearch(String text) {
    _debounce?.cancel();
    _browser?.setQuery(text);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _clearSearch() {
    _search.clear();
    _runSearch('');
    setState(() {});
  }

  void _open(MultimediaItem item) {
    if (widget.onOpen != null) {
      widget.onOpen!(item);
      return;
    }
    DetailsRoute($extra: DetailsRouteExtra(item: item)).push<void>(context);
  }

  Future<void> _pickFilter(CategoryFilter filter) async {
    final browser = _browser!;
    final pick = await showCategoryOptionPicker(
      context,
      title: filter.name,
      options: filter.options,
      selected: browser.filters[filter.key],
      allLabel: AppLocalizations.of(context)!.all,
    );
    if (pick == null || !mounted) return;
    browser.setFilter(filter.key, pick.value);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _pickSort() async {
    final browser = _browser!;
    final pick = await showCategoryOptionPicker(
      context,
      title: AppLocalizations.of(context)!.categorySort,
      options: widget.category.sorts,
      selected: widget.category.sortIn(browser.filters)?.value,
    );
    if (pick == null || !mounted) return;
    browser.setSort(pick.value);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final gutter = isDesktop
        ? LayoutConstants.dashboardContentPadding
        : LayoutConstants.spacingMd;
    final wide = MediaQuery.sizeOf(context).width >= 760;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: FocusTraversalGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(gutter - 8, 12, gutter, 4),
                  child: Row(
                    children: [
                      _BackButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _Title(
                          category: widget.category,
                          provider: _browser?.provider,
                        ),
                      ),
                      if (wide) ...[
                        const SizedBox(width: 16),
                        SizedBox(
                          width: isDesktop ? 400 : 320,
                          child: _searchField(context),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!wide)
                  Padding(
                    padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
                    child: _searchField(context),
                  ),
                if (_browser != null) _filterBar(context, gutter),
                Expanded(child: _body(context, gutter)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: cs.onSurface.withValues(alpha: 0.10)),
    );
    return TextField(
      key: const ValueKey('category-search'),
      controller: _search,
      focusNode: _searchFocus,
      enabled: _browser != null,
      textInputAction: TextInputAction.search,
      onChanged: _onSearchChanged,
      onSubmitted: _runSearch,
      style: TextStyle(fontSize: context.isDesktop ? 16 : 15),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: cs.onSurface.withValues(alpha: 0.06),
        hintText: l10n.categorySearchHint(widget.category.name),
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: _clearSearch,
              ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: cs.primary, width: 1.5),
        ),
      ),
    );
  }

  Widget _filterBar(BuildContext context, double gutter) {
    final l10n = AppLocalizations.of(context)!;
    final browser = _browser!;
    final category = widget.category;
    final sort = category.sortIn(browser.filters);
    final sortChosen = browser.filters.containsKey(ProviderCategory.sortKey);

    final pills = <Widget>[
      if (sort != null)
        CategoryPill(
          key: const ValueKey('category-sort'),
          label: sort.label,
          leading: Icons.swap_vert_rounded,
          trailing: Icons.expand_more_rounded,
          selected: sortChosen,
          autoFocus: true,
          onTap: _pickSort,
        ),
      for (final (index, filter) in category.filters.indexed)
        CategoryPill(
          key: ValueKey('category-filter-${filter.key}'),
          prefix: '${filter.name}: ',
          label: filter.chosenIn(browser.filters)?.label ?? l10n.all,
          trailing: Icons.expand_more_rounded,
          selected: filter.chosenIn(browser.filters) != null,
          autoFocus: sort == null && index == 0,
          onTap: () => _pickFilter(filter),
        ),
      if (browser.hasChoices)
        CategoryPill(
          key: const ValueKey('category-reset'),
          label: l10n.categoryReset,
          leading: Icons.restart_alt_rounded,
          onTap: () {
            browser.reset();
            if (_scroll.hasClients) _scroll.jumpTo(0);
          },
        ),
    ];
    if (pills.isEmpty) return const SizedBox(height: 8);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 8),
      child: FocusTraversalGroup(
        child: Row(
          children: [
            for (var i = 0; i < pills.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              pills[i],
            ],
          ],
        ),
      ),
    );
  }

  ({double maxExtent, double ratio}) _gridShape(BuildContext context) =>
      context.isDesktop
      ? (maxExtent: 220.0, ratio: 0.55)
      : (maxExtent: 140.0, ratio: 0.55);

  Widget _body(BuildContext context, double gutter) {
    final l10n = AppLocalizations.of(context)!;
    final browser = _browser;
    if (browser == null) {
      return _Message(
        icon: Icons.extension_off_outlined,
        title: l10n.categoryLoadFailed,
      );
    }
    final shape = _gridShape(context);
    final gridPadding = EdgeInsets.fromLTRB(gutter, 8, gutter, 24);
    final delegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: shape.maxExtent,
      childAspectRatio: shape.ratio,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
    );

    if (browser.isFirstLoad) {
      return GridView.builder(
        key: const ValueKey('category-loading'),
        physics: const NeverScrollableScrollPhysics(),
        padding: gridPadding,
        gridDelegate: delegate,
        itemCount: 18,
        itemBuilder: (_, _) => const _ShimmerCard(),
      );
    }
    if (browser.items.isEmpty && browser.error != null) {
      return _Message(
        key: const ValueKey('category-error'),
        icon: Icons.cloud_off_rounded,
        title: l10n.categoryLoadFailed,
        detail: _errorText(browser.error!),
        action: FilledButton.tonalIcon(
          autofocus: true,
          onPressed: browser.retry,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(l10n.retry),
        ),
      );
    }
    if (browser.items.isEmpty) {
      return _Message(
        key: const ValueKey('category-empty'),
        icon: browser.query.isEmpty
            ? Icons.movie_filter_outlined
            : Icons.search_off_rounded,
        title: l10n.categoryEmpty,
        detail: browser.hasChoices || browser.query.isNotEmpty
            ? l10n.categoryEmptyHint
            : null,
        action: browser.hasChoices
            ? CategoryPill(
                label: l10n.categoryReset,
                leading: Icons.restart_alt_rounded,
                onTap: browser.reset,
              )
            : null,
      );
    }

    final width = MediaQuery.sizeOf(context).width - gridPadding.horizontal;
    final columns = (width / (shape.maxExtent + 16)).ceil().clamp(1, 20);
    final items = browser.items;
    // The rest of the last row and one more, while the next page comes.
    final shimmerCount = browser.isLoading
        ? (columns - items.length % columns) % columns + columns
        : 0;

    return CustomScrollView(
      key: const ValueKey('category-grid'),
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: gridPadding.copyWith(bottom: 16),
          sliver: SliverGrid(
            gridDelegate: delegate,
            delegate: SliverChildBuilderDelegate((context, index) {
              if (index >= items.length) return const _ShimmerCard();
              final item = items[index];
              return MultimediaCard(
                key: ValueKey('category-item-${item.url}'),
                imageUrl: item.posterImageUrl,
                imageHeaders: item.headers,
                title: item.title,
                heroTag: 'category_${widget.category.id}_${item.url}',
                onTap: () => _open(item),
              );
            }, childCount: items.length + shimmerCount),
          ),
        ),
        if (browser.error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      l10n.categoryLoadMoreFailed,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(
                    key: const ValueKey('category-retry-more'),
                    onPressed: browser.retry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(l10n.retry),
                  ),
                ],
              ),
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + 16,
          ),
        ),
      ],
    );
  }

  static String _errorText(Object error) {
    final text = '$error'.replaceFirst(
      RegExp(r'^(Exception|Cs3EngineException): ?'),
      '',
    );
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      style: IconButton.styleFrom(
        backgroundColor: cs.onSurface.withValues(alpha: 0.07),
      ),
      icon: const Icon(Icons.arrow_back_rounded),
      onPressed: onPressed,
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.category, required this.provider});

  final ProviderCategory category;
  final SkyStreamProvider? provider;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDesktop = context.isDesktop;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          category.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: isDesktop ? 26 : 21,
            fontWeight: FontWeight.bold,
            color: cs.onSurface,
            letterSpacing: -0.2,
          ),
        ),
        if (provider != null)
          Text(
            provider!.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isDesktop ? 13 : 12,
              color: cs.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// A card's shape while its title is on the way: the poster and a line for the title.
class _ShimmerCard extends StatelessWidget {
  const _ShimmerCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: ShimmerPlaceholder(borderRadius: 12)),
        const SizedBox(height: 10),
        FractionallySizedBox(
          widthFactor: 0.7,
          child: ShimmerPlaceholder(height: 12, borderRadius: 6),
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}

/// The empty and error states: an icon in a soft circle, a heading, a line
/// and an action.
class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.onSurface.withValues(alpha: 0.06),
                ),
                child: Icon(icon, size: 34, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 6),
                Text(
                  detail!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}
