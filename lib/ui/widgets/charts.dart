import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Big circular overall score, the first thing shown on a report.
class ScoreRing extends StatelessWidget {
  const ScoreRing({
    super.key,
    required this.score,
    required this.caption,
    this.size = 132,
  });

  final int score;
  final String caption;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = scoreColor(score);
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: score / 100),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => CustomPaint(
          painter: _RingPainter(
            progress: value,
            color: color,
            track: theme.colorScheme.surfaceContainerHighest,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${(value * 100).round()}',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  caption,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
  });

  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 11.0;
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (math.min(size.width, size.height) - stroke) / 2;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;

    final valuePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawCircle(center, radius, trackPaint);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      valuePaint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}

/// Labelled horizontal bar, used for both sub-scores and error counts.
class StatBar extends StatelessWidget {
  const StatBar({
    super.key,
    required this.label,
    required this.value,
    required this.max,
    required this.color,
    this.valueLabel,
  });

  final String label;
  final num value;
  final num max;
  final Color color;
  final String? valueLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fraction),
              duration: const Duration(milliseconds: 550),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: v,
                  minHeight: 9,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              valueLabel ?? '$value',
              textAlign: TextAlign.right,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Overall-score trend across saved checks.
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, this.height = 90});

  final List<int> values;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (values.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'Check a second piece of writing to see your trend.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparkPainter(
          values: values,
          line: theme.colorScheme.primary,
          fill: theme.colorScheme.primary.withValues(alpha: 0.14),
          grid: theme.colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.values,
    required this.line,
    required this.fill,
    required this.grid,
  });

  final List<int> values;
  final Color line;
  final Color fill;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    // Fixed 0-100 scale: a rescaled axis would make small gains look dramatic.
    final dx = size.width / (values.length - 1);
    Offset pointAt(int i) =>
        Offset(i * dx, size.height - (values[i] / 100) * size.height);

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final y in [0.25, 0.5, 0.75]) {
      canvas.drawLine(
        Offset(0, size.height * y),
        Offset(size.width, size.height * y),
        gridPaint,
      );
    }

    final path = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(pointAt(i).dx, pointAt(i).dy);
    }

    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = fill);

    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );

    final dot = Paint()..color = line;
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(pointAt(i), 3, dot);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.values != values;
}
