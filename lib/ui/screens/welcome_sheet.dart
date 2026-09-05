import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../state/app_state.dart';
import '../widgets/pickers.dart';

/// Asked once, on first launch: what do you speak, and what are you learning?
///
/// These two answers shape every report, so the app asks up front rather than
/// burying them in settings. Both can be changed later.
class WelcomeSheet extends StatefulWidget {
  const WelcomeSheet({super.key, required this.state});

  final AppState state;

  static Future<void> showIfNeeded(BuildContext context, AppState state) async {
    if (state.hasProfile) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => WelcomeSheet(state: state),
    );
  }

  @override
  State<WelcomeSheet> createState() => _WelcomeSheetState();
}

class _WelcomeSheetState extends State<WelcomeSheet> {
  String? _native;
  String _learning = 'auto';

  Future<void> _pickNative() async {
    final choice = await showOptionSheet<String>(
      context: context,
      title: 'Your native language',
      selected: _native ?? '',
      options: [
        for (final l in kNativeLanguages)
          SheetOption(value: l.code, label: l.name, leading: l.flag),
      ],
      footnote: 'Your feedback will be written in this language, so pick the '
          'one you understand best.',
    );
    if (choice != null) setState(() => _native = choice);
  }

  Future<void> _pickLearning() async {
    final choice = await showOptionSheet<String>(
      context: context,
      title: 'The language you are learning',
      selected: _learning,
      options: [
        for (final l in kLearningLanguages)
          SheetOption(value: l.code, label: l.name, leading: l.flag),
      ],
      footnote: 'Any language works, including ones not listed here.',
    );
    if (choice != null) setState(() => _learning = choice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nativeOption = _native == null ? null : languageOption(_native!);
    final learningOption = languageOption(_learning);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          28,
          24,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Welcome', style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                )),
            const SizedBox(height: 8),
            Text(
              'Two questions, so your feedback arrives in a language you '
              'actually understand.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            _ProfileRow(
              label: 'I speak',
              value: nativeOption?.name ?? 'Choose your native language',
              flag: nativeOption?.flag ?? '💬',
              muted: nativeOption == null,
              onTap: _pickNative,
            ),
            const SizedBox(height: 12),
            _ProfileRow(
              label: 'I am learning',
              value: _learning == 'auto'
                  ? 'Work it out from my writing'
                  : learningOption.name,
              flag: _learning == 'auto' ? '🌐' : learningOption.flag,
              muted: false,
              onTap: _pickLearning,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _native == null
                  ? null
                  : () async {
                      await widget.state.update(
                        nativeLanguage: _native,
                        learningLanguage: _learning,
                      );
                      if (context.mounted) Navigator.of(context).pop();
                    },
              child: const Text('Start checking'),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                'You can change both later in Settings.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.label,
    required this.value,
    required this.flag,
    required this.muted,
    required this.onTap,
  });

  final String label;
  final String value;
  final String flag;
  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Text(flag, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: muted
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.expand_more, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
