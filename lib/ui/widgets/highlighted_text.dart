import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/check_result.dart';

/// The submission rendered with every flagged span underlined in its category
/// colour. Tapping a span opens its explanation.
///
/// Spans that were accepted render as the corrected wording in green, so the
/// text visibly repairs itself as the learner works through the report.
class HighlightedText extends StatefulWidget {
  const HighlightedText({
    super.key,
    required this.source,
    required this.corrections,
    required this.onTapCorrection,
    this.selectedId,
    this.textStyle,
  });

  final String source;
  final List<Correction> corrections;
  final void Function(Correction) onTapCorrection;
  final String? selectedId;
  final TextStyle? textStyle;

  @override
  State<HighlightedText> createState() => _HighlightedTextState();
}

class _HighlightedTextState extends State<HighlightedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = widget.textStyle ??
        theme.textTheme.bodyLarge!.copyWith(height: 1.75, fontSize: 17);

    _clearRecognizers();

    final located = widget.corrections
        .where((c) => c.isLocated && !c.dismissed)
        .toList()
      ..sort((a, b) => a.start!.compareTo(b.start!));

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final c in located) {
      if (c.start! < cursor) continue; // overlapping span, already rendered
      if (c.start! > cursor) {
        spans.add(TextSpan(text: widget.source.substring(cursor, c.start!)));
      }

      final color = categoryColor(c.category);
      final isSelected = c.id == widget.selectedId;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onTapCorrection(c);
      _recognizers.add(recognizer);

      if (c.applied) {
        spans.add(TextSpan(
          text: c.correction.isEmpty ? '' : c.correction,
          recognizer: recognizer,
          style: base.copyWith(
            color: const Color(0xFF2E7D52),
            fontWeight: FontWeight.w600,
            backgroundColor: const Color(0xFF2E7D52).withValues(alpha: 0.10),
          ),
        ));
      } else {
        spans.add(TextSpan(
          text: widget.source.substring(c.start!, c.end!),
          recognizer: recognizer,
          style: base.copyWith(
            backgroundColor: color.withValues(alpha: isSelected ? 0.30 : 0.12),
            decoration: TextDecoration.underline,
            decorationColor: color,
            decorationStyle: TextDecorationStyle.wavy,
            decorationThickness: 2,
          ),
        ));
      }

      cursor = c.end!;
    }

    if (cursor < widget.source.length) {
      spans.add(TextSpan(text: widget.source.substring(cursor)));
    }

    // Deliberately not wrapped in a SelectionArea: it swallows the per-span
    // tap recognisers, and tapping a highlight matters more here than dragging
    // a selection. The report offers copy buttons instead.
    return RichText(text: TextSpan(style: base, children: spans));
  }
}
