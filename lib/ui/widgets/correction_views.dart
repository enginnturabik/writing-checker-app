import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/check_result.dart';

/// Small coloured pill naming the error category.
class CategoryChip extends StatelessWidget {
  const CategoryChip({super.key, required this.category, this.severity});

  final String category;
  final String? severity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = categoryColor(category);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            kCategories[category] ?? category,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (severity != null) ...[
          const SizedBox(width: 6),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: severityColor(severity!),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            severity!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// The wrong wording struck through, followed by the fix.
class BeforeAfter extends StatelessWidget {
  const BeforeAfter({
    super.key,
    required this.original,
    required this.correction,
    this.large = false,
  });

  final String original;
  final String correction;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = large ? theme.textTheme.titleMedium : theme.textTheme.bodyLarge;
    final deleted = correction.trim().isEmpty;

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Text(
          original,
          style: style?.copyWith(
            decoration: TextDecoration.lineThrough,
            decorationColor: theme.colorScheme.error,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Icon(Icons.arrow_forward,
            size: 16, color: theme.colorScheme.onSurfaceVariant),
        Text(
          deleted ? '(remove)' : correction,
          style: style?.copyWith(
            color: deleted
                ? theme.colorScheme.onSurfaceVariant
                : const Color(0xFF2E7D52),
            fontWeight: FontWeight.w600,
            fontStyle: deleted ? FontStyle.italic : FontStyle.normal,
          ),
        ),
      ],
    );
  }
}

/// One correction as a tappable card in the list view.
class CorrectionCard extends StatelessWidget {
  const CorrectionCard({
    super.key,
    required this.correction,
    required this.onTap,
    required this.onApply,
  });

  final Correction correction;
  final VoidCallback onTap;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CategoryChip(
                      category: correction.category,
                      severity: correction.severity,
                    ),
                    const SizedBox(height: 8),
                    BeforeAfter(
                      original: correction.original,
                      correction: correction.correction,
                    ),
                    if (correction.explanation.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        correction.explanation,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: correction.applied ? 'Undo this fix' : 'Apply this fix',
                onPressed: onApply,
                icon: Icon(
                  correction.applied
                      ? Icons.check_circle
                      : Icons.check_circle_outline,
                  color: correction.applied
                      ? const Color(0xFF2E7D52)
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full explanation for one correction, opened by tapping a highlight.
class CorrectionSheet extends StatelessWidget {
  const CorrectionSheet({
    super.key,
    required this.correction,
    required this.onApply,
    required this.onDismiss,
  });

  final Correction correction;
  final VoidCallback onApply;
  final VoidCallback onDismiss;

  static Future<void> show(
    BuildContext context, {
    required Correction correction,
    required VoidCallback onApply,
    required VoidCallback onDismiss,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => CorrectionSheet(
        correction: correction,
        onApply: onApply,
        onDismiss: onDismiss,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CategoryChip(
              category: correction.category,
              severity: correction.severity,
            ),
            const SizedBox(height: 14),
            BeforeAfter(
              original: correction.original,
              correction: correction.correction,
              large: true,
            ),
            const SizedBox(height: 16),
            if (correction.explanation.isNotEmpty)
              Text(
                correction.explanation,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
              ),
            if (correction.rule.trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.menu_book_outlined,
                        size: 16, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        correction.rule,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      onDismiss();
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.visibility_off_outlined, size: 18),
                    label: const Text('Ignore'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () {
                      onApply();
                      Navigator.of(context).pop();
                    },
                    icon: Icon(
                      correction.applied ? Icons.undo : Icons.check,
                      size: 18,
                    ),
                    label: Text(correction.applied ? 'Undo fix' : 'Apply fix'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
