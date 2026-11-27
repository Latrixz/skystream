import 'package:flutter/material.dart';

import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/cards_wrapper.dart';

/// The pill every category control is drawn as: home's category chips, the
/// category screen's filter and sort chips, and the options of their pickers.
///
/// Focus is [CardsWrapper]'s, so a remote and a keyboard reach and press it
/// like any card; [selected] wears the accent.
class CategoryPill extends StatelessWidget {
  const CategoryPill({
    super.key,
    required this.label,
    required this.onTap,
    this.prefix,
    this.leading,
    this.trailing,
    this.selected = false,
    this.autoFocus = false,
    this.focusNode,
    this.large = false,
  });

  final String label;
  final VoidCallback onTap;

  /// A muted part before the label ("Region: " before "Korea").
  final String? prefix;
  final IconData? leading;
  final IconData? trailing;
  final bool selected;
  final bool autoFocus;
  final FocusNode? focusNode;

  /// Home's chips: a little taller and bolder than the filter bar's.
  final bool large;

  static const BorderRadius radius = BorderRadius.all(Radius.circular(50));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDesktop = context.isDesktop;
    final fontSize = large
        ? (isDesktop ? 16.0 : 14.0)
        : (isDesktop ? 14.0 : 13.0);
    final iconSize = fontSize + 3;
    final content = selected
        ? cs.onSurface
        : cs.onSurface.withValues(alpha: 0.82);
    final muted = cs.onSurface.withValues(alpha: 0.55);

    return Semantics(
      button: true,
      selected: selected,
      child: CardsWrapper(
        onTap: onTap,
        autoFocus: autoFocus,
        focusNode: focusNode,
        borderRadius: radius,
        scaleFactor: 1.04,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.symmetric(
            horizontal: large ? (isDesktop ? 22 : 18) : (isDesktop ? 16 : 14),
            vertical: large ? (isDesktop ? 12 : 10) : (isDesktop ? 9 : 8),
          ),
          decoration: BoxDecoration(
            borderRadius: radius,
            color: selected
                ? cs.primary.withValues(alpha: 0.18)
                : cs.onSurface.withValues(alpha: 0.07),
            border: Border.all(
              color: selected
                  ? cs.primary.withValues(alpha: 0.75)
                  : cs.onSurface.withValues(alpha: 0.12),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                Icon(
                  leading,
                  size: iconSize,
                  color: selected ? cs.primary : muted,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (prefix != null)
                        TextSpan(
                          text: prefix,
                          style: TextStyle(
                            color: muted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      TextSpan(text: label),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fontSize,
                    color: content,
                    fontWeight: large || selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 4),
                Icon(trailing, size: iconSize, color: muted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
