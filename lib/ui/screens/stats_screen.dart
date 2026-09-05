import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../widgets/charts.dart';
import '../widgets/pickers.dart';

/// Longitudinal view: is the writing actually getting better, and which
/// mistakes keep coming back?
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final trend = state.scoreTrend;
    final categories = state.categoryTotals;
    final recurring = state.recurringRules;

    if (state.history.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Progress')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.insights_outlined,
                    size: 64, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text('No progress yet', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'Once you have checked a few pieces, your scores over time '
                  'and your recurring mistakes appear here.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final maxCategory = categories.values.isEmpty
        ? 1
        : categories.values.reduce((a, b) => a > b ? a : b);
    final latest = trend.isEmpty ? 0 : trend.last;
    final first = trend.isEmpty ? 0 : trend.first;
    final delta = latest - first;

    return Scaffold(
      appBar: AppBar(title: const Text('Progress')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  value: '${state.history.length}',
                  label: 'pieces checked',
                  icon: Icons.checklist_rtl,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatTile(
                  value: '${state.totalWordsChecked}',
                  label: 'words marked',
                  icon: Icons.text_fields,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatTile(
                  value: '${state.totalErrorsFound}',
                  label: 'corrections',
                  icon: Icons.spellcheck,
                ),
              ),
            ],
          ),
          const SectionHeader('Overall score over time',
              icon: Icons.show_chart),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Sparkline(values: trend),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        'Latest $latest/100',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (trend.length > 1)
                        Text(
                          delta >= 0
                              ? '+$delta since your first check'
                              : '$delta since your first check',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: delta >= 0
                                ? const Color(0xFF2E7D52)
                                : theme.colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (categories.isNotEmpty) ...[
            const SectionHeader('Mistakes by type', icon: Icons.category_outlined),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Column(
                  children: [
                    for (final e in (categories.entries.toList()
                          ..sort((a, b) => b.value.compareTo(a.value))))
                      StatBar(
                        label: kCategories[e.key] ?? e.key,
                        value: e.value,
                        max: maxCategory,
                        color: categoryColor(e.key),
                        valueLabel: '${e.value}',
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (recurring.isNotEmpty) ...[
            const SectionHeader('Mistakes you keep repeating',
                icon: Icons.repeat),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Column(
                  children: [
                    for (var i = 0; i < recurring.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${i + 1}',
                                style: theme.textTheme.labelMedium,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                recurring[i].key,
                                style: theme.textTheme.bodyLarge,
                              ),
                            ),
                            Text(
                              '${recurring[i].value}x',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'These are the rules that tripped you up most often. Working '
              'through the top two usually moves your score more than anything '
              'else.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.value,
    required this.label,
    required this.icon,
  });

  final String value;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
        child: Column(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            FittedBox(
              child: Text(
                value,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
