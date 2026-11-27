import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/extensions/base_provider.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../sources/presentation/source_sheet_widgets.dart';
import 'category_pill.dart';

/// What a picker answered: the chosen option's value, or null for "all".
class CategoryPick {
  const CategoryPick(this.value);
  final String? value;
}

/// Asks for one of [options], [selected] marked; with [allLabel], an "all"
/// choice first. A bottom sheet on a phone, a dialog elsewhere (desktop, TV).
/// Null when dismissed.
Future<CategoryPick?> showCategoryOptionPicker(
  BuildContext context, {
  required String title,
  required List<CategoryOption> options,
  String? selected,
  String? allLabel,
}) {
  final picker = CategoryOptionPicker(
    title: title,
    options: options,
    selected: selected,
    allLabel: allLabel,
  );
  if (context.isMobile) {
    return showModalBottomSheet<CategoryPick>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      builder: (_) => picker,
    );
  }
  return showDialog<CategoryPick>(
    context: context,
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.55),
    builder: (_) => _PickerDialog(child: picker),
  );
}

/// The picker's content: a heading and the options as pills that wrap.
class CategoryOptionPicker extends StatelessWidget {
  const CategoryOptionPicker({
    super.key,
    required this.title,
    required this.options,
    this.selected,
    this.allLabel,
  });

  final String title;
  final List<CategoryOption> options;
  final String? selected;
  final String? allLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = context.isMobile;
    final anySelected = options.any((o) => o.value == selected);

    Widget pill(String label, String? value, bool isSelected) => CategoryPill(
      key: ValueKey('category-option-${value ?? '*'}'),
      label: label,
      selected: isSelected,
      leading: isSelected ? Icons.check_rounded : null,
      autoFocus: isSelected,
      onTap: () => Navigator.of(context).pop(CategoryPick(value)),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(20, isMobile ? 0 : 20, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!isMobile)
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              // Room for the focus ring, drawn outside each pill.
              padding: const EdgeInsets.all(4),
              child: FocusTraversalGroup(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (allLabel != null) pill(allLabel!, null, !anySelected),
                    for (final option in options)
                      pill(
                        option.label,
                        option.value,
                        option.value == selected,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The frosted panel the picker sits in off a phone, drawn like the app's
/// source sheets ([GlassPalette]) but only as tall as its options.
class _PickerDialog extends StatelessWidget {
  const _PickerDialog({required this.child});

  final Widget child;

  static const double _radius = 28;

  @override
  Widget build(BuildContext context) {
    final palette = GlassPalette.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 620),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius),
            boxShadow: [
              BoxShadow(
                color: palette.paneShadow,
                blurRadius: 50,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.pane,
                  borderRadius: BorderRadius.circular(_radius),
                  border: Border.all(color: palette.edge, width: 0.5),
                ),
                child: Material(type: MaterialType.transparency, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
