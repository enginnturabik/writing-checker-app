import 'package:flutter/material.dart';

class SheetOption<T> {
  const SheetOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.leading,
    this.trailing,
  });

  final T value;
  final String label;
  final String? subtitle;
  final String? leading;
  final String? trailing;
}

/// One consistent single-select bottom sheet for every choice in the app.
Future<T?> showOptionSheet<T>({
  required BuildContext context,
  required String title,
  required List<SheetOption<T>> options,
  required T selected,
  String? footnote,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (context, i) {
                    final o = options[i];
                    final isSelected = o.value == selected;
                    return ListTile(
                      leading: o.leading == null
                          ? null
                          : Text(o.leading!,
                              style: const TextStyle(fontSize: 22)),
                      title: Text(o.label),
                      subtitle: o.subtitle == null ? null : Text(o.subtitle!),
                      trailing: isSelected
                          ? Icon(Icons.check_circle,
                              color: theme.colorScheme.primary)
                          : (o.trailing == null
                              ? null
                              : Text(o.trailing!,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ))),
                      onTap: () => Navigator.of(context).pop(o.value),
                    );
                  },
                ),
              ),
              if (footnote != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Text(
                    footnote,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

/// Compact label + value button used for the marking options row.
class OptionChip extends StatelessWidget {
  const OptionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasised = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = emphasised
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Material(
      color: emphasised
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(color: fg),
              ),
              Icon(Icons.expand_more, size: 16, color: fg),
            ],
          ),
        ),
      ),
    );
  }
}

/// Section header used across the result and settings screens.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.icon});

  final String title;
  final Widget? trailing;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
