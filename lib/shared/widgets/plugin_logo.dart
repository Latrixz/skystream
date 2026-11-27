import 'package:flutter/material.dart';

/// A plugin's or provider's logo: its icon from [url], rounded, or a tile with
/// the first letter of [name] while it loads, when it fails, or when there is
/// no icon at all.
class PluginLogo extends StatelessWidget {
  const PluginLogo({
    super.key,
    required this.url,
    required this.name,
    this.size = 40,
  });

  final String? url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(size / 4);
    final trimmed = name.trim();
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        borderRadius: radius,
      ),
      child: Text(
        // Characters, not code units: a name may start with an emoji or any
        // other letter outside the BMP.
        trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase(),
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(color: cs.primary, fontWeight: FontWeight.bold),
      ),
    );
    final icon = url;
    if (icon == null || icon.isEmpty) return fallback;
    final cacheSize = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: radius,
      child: Image.network(
        icon,
        width: size,
        height: size,
        cacheWidth: cacheSize,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }
}
