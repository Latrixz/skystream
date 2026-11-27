import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'category_pill.dart';

/// The active provider's categories (see [SkyStreamProvider.getCategories]);
/// empty for one without them, or with none provider active.
final providerCategoriesProvider = FutureProvider<List<ProviderCategory>>((
  ref,
) async {
  final provider = ref.watch(activeProviderProvider);
  if (provider == null) return const [];
  return provider.getCategories();
});

/// Home's row of category chips, one per category of the active provider; a
/// chip opens the category's own screen. Nothing at all for a provider
/// without categories, and nothing while they load: the row only appears.
class HomeCategoriesRow extends ConsumerWidget {
  const HomeCategoriesRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories =
        ref.watch(providerCategoriesProvider).asData?.value ?? const [];
    if (categories.isEmpty) return const SizedBox.shrink();
    return HomeCategoryChips(
      categories: categories,
      onOpen: (category) =>
          CategoryRoute($extra: CategoryRouteExtra(category: category))
              .push<void>(context),
    );
  }
}

/// The row itself: a heading like home's sections, and the chips under it.
class HomeCategoryChips extends StatelessWidget {
  const HomeCategoryChips({
    super.key,
    required this.categories,
    required this.onOpen,
  });

  final List<ProviderCategory> categories;
  final ValueChanged<ProviderCategory> onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDesktop = context.isDesktop;
    final gutter = isDesktop
        ? LayoutConstants.dashboardContentPadding
        : LayoutConstants.spacingMd;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            LayoutConstants.spacingLg,
            gutter,
            LayoutConstants.spacingSm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.categories,
                style: TextStyle(
                  fontSize: isDesktop ? 24 : 20,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: isDesktop ? 30 : 20,
                height: 3,
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // Room for the focus ring and shadow, which are drawn outside.
          padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 6),
          clipBehavior: Clip.none,
          child: FocusTraversalGroup(
            child: Row(
              children: [
                for (var i = 0; i < categories.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  CategoryPill(
                    key: ValueKey('home-category-${categories[i].id}'),
                    label: categories[i].name,
                    large: true,
                    trailing: Icons.chevron_right_rounded,
                    onTap: () => onOpen(categories[i]),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
