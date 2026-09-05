import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/check_result.dart';
import '../../models/history_entry.dart';
import '../../state/app_state.dart';
import '../widgets/charts.dart';
import '../widgets/correction_views.dart';
import '../widgets/highlighted_text.dart';
import '../widgets/pickers.dart';

/// The marked-up report for one submission.
class ResultScreen extends StatefulWidget {
  const ResultScreen({super.key, required this.entryId});

  final String entryId;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final entry = state.entryById(widget.entryId);

    if (entry == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This check is no longer saved.')),
      );
    }

    final result = entry.result;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(result.detectedLanguage),
          actions: [
            IconButton(
              tooltip: 'Share feedback',
              onPressed: () => _share(entry),
              icon: const Icon(Icons.ios_share),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => _menu(v, state, entry),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'copy_corrected',
                  child: Text('Copy corrected text'),
                ),
                PopupMenuItem(
                  value: 'copy_original',
                  child: Text('Copy original text'),
                ),
                PopupMenuItem(value: 'delete', child: Text('Delete this check')),
              ],
            ),
          ],
          bottom: TabBar(
            tabs: [
              const Tab(text: 'Feedback'),
              Tab(text: 'Corrections (${result.active.length})'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _FeedbackTab(entry: entry),
            _CorrectionsTab(
              entry: entry,
              selectedId: _selectedId,
              onSelect: (id) => setState(() => _selectedId = id),
            ),
          ],
        ),
      ),
    );
  }

  void _menu(String value, AppState state, HistoryEntry entry) {
    switch (value) {
      case 'copy_corrected':
        Clipboard.setData(ClipboardData(text: entry.result.correctedText));
        _toast('Corrected text copied.');
      case 'copy_original':
        Clipboard.setData(ClipboardData(text: entry.sourceText));
        _toast('Original text copied.');
      case 'delete':
        state.deleteEntry(entry.id);
        Navigator.of(context).pop();
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _share(HistoryEntry entry) {
    final r = entry.result;
    final buf = StringBuffer()
      ..writeln('Writing Checker feedback')
      ..writeln('${r.detectedLanguage} - ${r.cefrEstimate} - '
          'overall ${r.scores.overall}/100')
      ..writeln()
      ..writeln(r.summary)
      ..writeln()
      ..writeln('Corrected text:')
      ..writeln(r.correctedText);

    if (r.active.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('Corrections:');
      for (final c in r.active) {
        buf.writeln('- ${c.original} -> ${c.correction}: ${c.explanation}');
      }
    }

    SharePlus.instance.share(ShareParams(text: buf.toString()));
  }
}

// --- Feedback tab -----------------------------------------------------------

class _FeedbackTab extends StatelessWidget {
  const _FeedbackTab({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = entry.result;
    final counts = r.countsByCategory;
    final maxCount =
        counts.values.isEmpty ? 1 : counts.values.reduce((a, b) => a > b ? a : b);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                ScoreRing(score: r.scores.overall, caption: 'OVERALL'),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Pill(
                        icon: Icons.school_outlined,
                        text: 'Reads as ${r.cefrEstimate}',
                      ),
                      const SizedBox(height: 8),
                      _Pill(
                        icon: Icons.spellcheck,
                        text: '${r.active.length} '
                            '${r.active.length == 1 ? "correction" : "corrections"}',
                      ),
                      const SizedBox(height: 8),
                      _Pill(
                        icon: Icons.text_fields,
                        text: '${r.wordCount} words',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (r.summary.isNotEmpty) ...[
          const SectionHeader('What your teacher says',
              icon: Icons.record_voice_over_outlined),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                r.summary,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
              ),
            ),
          ),
        ],
        const SectionHeader('Scores', icon: Icons.equalizer_outlined),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Column(
              children: [
                for (final e in r.scores.asMap.entries)
                  StatBar(
                    label: e.key,
                    value: e.value,
                    max: 100,
                    color: scoreColor(e.value),
                    valueLabel: '${e.value}',
                  ),
              ],
            ),
          ),
        ),
        if (counts.isNotEmpty) ...[
          const SectionHeader('Where the mistakes are',
              icon: Icons.pie_chart_outline),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(
                children: [
                  for (final e in (counts.entries.toList()
                        ..sort((a, b) => b.value.compareTo(a.value))))
                    StatBar(
                      label: kCategories[e.key] ?? e.key,
                      value: e.value,
                      max: maxCount,
                      color: categoryColor(e.key),
                      valueLabel: '${e.value}',
                    ),
                ],
              ),
            ),
          ),
        ],
        if (r.strengths.isNotEmpty)
          _BulletCard(
            title: 'What you did well',
            icon: Icons.thumb_up_outlined,
            color: const Color(0xFF2E7D52),
            items: r.strengths,
          ),
        if (r.priorities.isNotEmpty)
          _BulletCard(
            title: 'Fix these first',
            icon: Icons.priority_high,
            color: const Color(0xFFD1495B),
            items: r.priorities,
          ),
        if (r.vocabulary.isNotEmpty) ...[
          const SectionHeader('Stronger word choices',
              icon: Icons.auto_awesome_outlined),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Column(
                children: [
                  for (var i = 0; i < r.vocabulary.length; i++) ...[
                    if (i > 0) const Divider(height: 18),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        BeforeAfter(
                          original: r.vocabulary[i].original,
                          correction: r.vocabulary[i].suggestion,
                        ),
                        if (r.vocabulary[i].note.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            r.vocabulary[i].note,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        if (r.nextSteps.isNotEmpty)
          _BulletCard(
            title: 'What to practise next',
            icon: Icons.trending_up,
            color: const Color(0xFF3D7DCA),
            items: r.nextSteps,
          ),
        const SizedBox(height: 24),
        Center(
          child: Text(
            '${modelById(r.modelId).label} - '
            '${r.usage.inputTokens + r.usage.outputTokens} tokens - '
            '\$${modelById(r.modelId).costFor(inputTokens: r.usage.inputTokens, outputTokens: r.usage.outputTokens).toStringAsFixed(4)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: theme.textTheme.bodyMedium),
        ),
      ],
    );
  }
}

class _BulletCard extends StatelessWidget {
  const _BulletCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.items,
  });

  final String title;
  final IconData icon;
  final Color color;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title, icon: icon),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 7),
                        width: 7,
                        height: 7,
                        decoration:
                            BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          items[i],
                          style:
                              theme.textTheme.bodyLarge?.copyWith(height: 1.45),
                        ),
                      ),
                    ],
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

// --- Corrections tab --------------------------------------------------------

class _CorrectionsTab extends StatefulWidget {
  const _CorrectionsTab({
    required this.entry,
    required this.selectedId,
    required this.onSelect,
  });

  final HistoryEntry entry;
  final String? selectedId;
  final void Function(String?) onSelect;

  @override
  State<_CorrectionsTab> createState() => _CorrectionsTabState();
}

class _CorrectionsTabState extends State<_CorrectionsTab> {
  bool _listView = false;
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final result = widget.entry.result;

    final visible = result.active
        .where((c) => _filter == 'all' || c.category == _filter)
        .toList();

    final appliedCount = result.active.where((c) => c.applied).length;

    return Column(
      children: [
        _Toolbar(
          listView: _listView,
          filter: _filter,
          categories: result.countsByCategory,
          onToggleView: () => setState(() => _listView = !_listView),
          onFilter: (f) => setState(() => _filter = f),
        ),
        Expanded(
          child: result.active.isEmpty
              ? _NothingToFix(theme: theme)
              : (_listView
                  ? ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => CorrectionCard(
                        correction: visible[i],
                        onTap: () => _openSheet(state, visible[i]),
                        onApply: () => _toggleApply(state, visible[i]),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
                      children: [
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: HighlightedText(
                              source: widget.entry.sourceText,
                              corrections: result.corrections,
                              selectedId: widget.selectedId,
                              onTapCorrection: (c) {
                                widget.onSelect(c.id);
                                _openSheet(state, c);
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Tap any underlined part to see what is wrong and why.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    )),
        ),
        if (result.active.isNotEmpty)
          _ApplyBar(
            appliedCount: appliedCount,
            total: result.active.length,
            onApplyAll: () {
              for (final c in result.active) {
                c.applied = true;
              }
              state.saveHistory();
              setState(() {});
            },
            onCopy: () {
              final text = appliedCount == 0
                  ? result.correctedText
                  : result.applyAccepted(widget.entry.sourceText);
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard.')),
                );
            },
          ),
      ],
    );
  }

  void _toggleApply(AppState state, Correction c) {
    c.applied = !c.applied;
    state.saveHistory();
    setState(() {});
  }

  Future<void> _openSheet(AppState state, Correction c) async {
    await CorrectionSheet.show(
      context,
      correction: c,
      onApply: () => _toggleApply(state, c),
      onDismiss: () {
        c.dismissed = true;
        state.saveHistory();
        setState(() {});
      },
    );
    if (mounted) widget.onSelect(null);
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.listView,
    required this.filter,
    required this.categories,
    required this.onToggleView,
    required this.onFilter,
  });

  final bool listView;
  final String filter;
  final Map<String, int> categories;
  final VoidCallback onToggleView;
  final void Function(String) onFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FilterPill(
                    label: 'All',
                    selected: filter == 'all',
                    onTap: () => onFilter('all'),
                  ),
                  for (final e in (categories.entries.toList()
                        ..sort((a, b) => b.value.compareTo(a.value))))
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _FilterPill(
                        label: '${kCategories[e.key] ?? e.key} ${e.value}',
                        color: categoryColor(e.key),
                        selected: filter == e.key,
                        onTap: () => onFilter(e.key),
                      ),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: listView ? 'Show marked-up text' : 'Show as a list',
            onPressed: onToggleView,
            icon: Icon(listView ? Icons.article_outlined : Icons.list_alt),
          ),
        ],
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;
    return Material(
      color: selected ? c.withValues(alpha: 0.16) : Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? c : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: selected ? c : theme.colorScheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _ApplyBar extends StatelessWidget {
  const _ApplyBar({
    required this.appliedCount,
    required this.total,
    required this.onApplyAll,
    required this.onCopy,
  });

  final int appliedCount;
  final int total;
  final VoidCallback onApplyAll;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$appliedCount of $total applied',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Copy'),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: appliedCount == total ? null : onApplyAll,
              child: const Text('Apply all'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NothingToFix extends StatelessWidget {
  const _NothingToFix({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_outlined,
                size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('No corrections', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Nothing needed fixing in this piece. Read the feedback tab for '
              'what to work on next.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
