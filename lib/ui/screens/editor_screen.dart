import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../core/constants.dart';
import '../../models/check_request.dart';
import '../../services/anthropic_client.dart';
import '../../services/document_loader.dart';
import '../../state/app_state.dart';
import '../widgets/pickers.dart';
import 'credits_screen.dart';
import 'result_screen.dart';
import 'welcome_sheet.dart';

/// Where the learner writes, imports or photographs a piece of writing and
/// sets how it should be marked.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _textController = TextEditingController();
  final _loader = DocumentLoader();

  Attachment? _attachment;

  @override
  void initState() {
    super.initState();
    _textController.addListener(() => setState(() {}));

    // Ask for the learner profile before anything else on a fresh install.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WelcomeSheet.showIfNeeded(context, context.read<AppState>());
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  // --- Import paths --------------------------------------------------------

  Future<void> _handleLoad(Future<LoadedDocument?> Function() action) async {
    try {
      final doc = await action();
      if (doc == null || doc.isEmpty) return;
      if (!mounted) return;
      setState(() {
        if (doc.text != null) {
          _textController.text = doc.text!;
          _attachment = null;
        } else {
          _attachment = doc.attachment;
        }
      });
    } on DocumentLoadException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('That file could not be imported.');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      _toast('The clipboard is empty.');
      return;
    }
    setState(() => _textController.text = text);
  }

  void _showImportMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Import a document'),
              subtitle: const Text('.txt, .docx or .pdf'),
              onTap: () {
                Navigator.pop(sheetContext);
                _handleLoad(_loader.pickFile);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Photograph handwriting'),
              subtitle: const Text('Snap a page and it will be read for you'),
              onTap: () {
                Navigator.pop(sheetContext);
                _handleLoad(() => _loader.pickImage(fromCamera: true));
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose a photo'),
              onTap: () {
                Navigator.pop(sheetContext);
                _handleLoad(() => _loader.pickImage(fromCamera: false));
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste from clipboard'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pasteFromClipboard();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // --- Option pickers ------------------------------------------------------

  Future<void> _pickLanguage(AppState state) async {
    final choice = await showOptionSheet<String>(
      context: context,
      title: 'The language you are learning',
      selected: state.learningLanguage,
      options: [
        for (final l in kLearningLanguages)
          SheetOption(value: l.code, label: l.name, leading: l.flag),
      ],
      footnote: 'This is the language your writing should be in. Any language '
          'works, including ones not listed here.',
    );
    if (choice != null) state.update(learningLanguage: choice);
  }

  Future<void> _pickTier(AppState state) async {
    final choice = await showOptionSheet<String>(
      context: context,
      title: 'How thorough should the marking be?',
      selected: state.tierId,
      options: [
        for (final t in state.tiers)
          SheetOption(
            value: t.id,
            label: t.label,
            subtitle: t.description,
            trailing: '${t.credits} cr',
          ),
      ],
      footnote: 'A deep check costs more credits but reads your writing the '
          'way an examiner would.',
    );
    if (choice != null) state.update(tierId: choice);
  }

  // --- Run -----------------------------------------------------------------

  void _openCredits() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const CreditsScreen()),
    );
  }

  Future<void> _runCheck(AppState state) async {
    FocusScope.of(context).unfocus();

    if (state.useOwnKey && !state.hasApiKey) {
      openSettings(context);
      return;
    }
    if (state.isMetered && state.account == null) {
      await state.connect();
      if (!mounted) return;
      if (state.account == null) {
        _toast(state.connectionError ?? 'Could not reach the server.');
        return;
      }
    }

    final text = _textController.text;
    if (text.trim().isEmpty && _attachment == null) {
      _toast('Write, paste or import something to check first.');
      return;
    }

    final entry = await state.runCheck(
      text: text,
      attachment: _attachment,
    );

    if (!mounted) return;

    if (entry == null) {
      final error = state.error;
      if (error != null) {
        // Running out of credits is a normal state, not a failure: send the
        // user to the top-up screen rather than to settings.
        final outOfCredits = state.outOfCredits;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text(error),
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: outOfCredits
                  ? 'Get credits'
                  : (state.useOwnKey ? 'Settings' : 'Retry'),
              onPressed: () {
                if (outOfCredits) {
                  _openCredits();
                } else if (state.useOwnKey) {
                  openSettings(context);
                } else {
                  _runCheck(state);
                }
              },
            ),
          ));
        state.clearError();
      }
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ResultScreen(entryId: entry.id)),
    );
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final text = _textController.text;

    final estimate = AnthropicClient.estimate(
      text: text,
      modelId: state.modelId,
      hasAttachment: _attachment != null,
    );
    final words = text.trim().isEmpty
        ? 0
        : text.trim().split(RegExp(r'\s+')).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Writing Checker'),
        actions: [
          if (state.isMetered)
            _BalancePill(balance: state.balance, onTap: _openCredits),
          const _ThemeToggle(),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => openSettings(context),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                children: [
                  if (state.useOwnKey && !state.hasApiKey)
                    const _ApiKeyBanner(),
                  if (state.isMetered && state.connectionError != null)
                    _ConnectionBanner(
                      message: state.connectionError!,
                      onRetry: state.connect,
                    ),
                  _OptionsRow(
                    state: state,
                    onLanguage: () => _pickLanguage(state),
                    onTier: () => _pickTier(state),
                  ),
                  const SizedBox(height: 12),
                  if (_attachment != null) ...[
                    _AttachmentChip(
                      attachment: _attachment!,
                      onRemove: () => setState(() => _attachment = null),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                      child: TextField(
                        controller: _textController,
                        maxLines: null,
                        minLines: 10,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          hintText: _attachment != null
                              ? 'Optional: add notes about the attached file.'
                              : 'Write here, or import a file, or photograph '
                                  'a handwritten page.',
                          hintStyle: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _BottomBar(
              words: words,
              costLabel: state.isMetered
                  ? _creditLabel(
                      state.priceOfNextCheck(hasAttachment: _attachment != null),
                    )
                  : (estimate.cost < 0.01
                      ? 'under 1 cent'
                      : '~\$${estimate.cost.toStringAsFixed(3)}'),
              costTooltip: state.isMetered
                  ? 'Credits this check will use'
                  : 'Estimated cost of this check on your API key',
              overLimit: state.isMetered &&
                  words > state.limits.maxWordsFor(state.tierId),
              running: state.running,
              progress: state.progress,
              onImport: _showImportMenu,
              onCheck: () => _runCheck(state),
              onCancel: state.cancelCheck,
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionsRow extends StatelessWidget {
  const _OptionsRow({
    required this.state,
    required this.onLanguage,
    required this.onTier,
  });

  final AppState state;
  final VoidCallback onLanguage;
  final VoidCallback onTier;

  @override
  Widget build(BuildContext context) {
    final lang = languageOption(state.learningLanguage);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (state.isMetered) ...[
            OptionChip(
              icon: Icons.auto_awesome,
              label: state.tier.label,
              emphasised: state.tierId != 'quick',
              onTap: onTier,
            ),
            const SizedBox(width: 8),
          ],
          OptionChip(
            icon: Icons.translate,
            label: state.learningLanguage == 'auto'
                ? 'Auto language'
                : '${lang.flag} ${lang.name}',
            onTap: onLanguage,
          ),
        ],
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment, required this.onRemove});

  final Attachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isImage = attachment.kind == AttachmentKind.image;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Icon(
              isImage ? Icons.image_outlined : Icons.picture_as_pdf_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attachment.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    isImage
                        ? '${attachment.sizeLabel} - will be read from the image'
                        : '${attachment.sizeLabel} - the PDF will be read directly',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: onRemove,
              tooltip: 'Remove attachment',
            ),
          ],
        ),
      ),
    );
  }
}

/// Light/dark switch in the app bar.
///
/// The icon shows the mode you would move to, not the one you are in, so the
/// button reads as an action rather than a status.
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
      onPressed: () =>
          context.read<AppState>().toggleTheme(Theme.of(context).brightness),
      icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
    );
  }
}

/// Credit balance in the app bar, tappable to top up.
class _BalancePill extends StatelessWidget {
  const _BalancePill({required this.balance, required this.onTap});

  final int balance;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = balance <= 0;
    final fg = empty
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onPrimaryContainer;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Material(
        color: empty
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.toll_outlined, size: 16, color: fg),
                const SizedBox(width: 6),
                Text(
                  '$balance',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w700,
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

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(
            children: [
              Icon(Icons.cloud_off_outlined,
                  color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApiKeyBanner extends StatelessWidget {
  const _ApiKeyBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => openSettings(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.key_outlined,
                    color: theme.colorScheme.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Add your Anthropic API key',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Checking needs a key. It is stored only on this device.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    color: theme.colorScheme.onPrimaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _creditLabel(int credits) =>
    credits == 1 ? '1 credit' : '$credits credits';

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.words,
    required this.costLabel,
    required this.costTooltip,
    required this.overLimit,
    required this.running,
    required this.progress,
    required this.onImport,
    required this.onCheck,
    required this.onCancel,
  });

  final int words;
  final String costLabel;
  final String costTooltip;
  final bool overLimit;
  final bool running;
  final CheckProgress? progress;
  final VoidCallback onImport;
  final VoidCallback onCheck;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running && progress != null) ...[
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${progress!.stage}...',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                TextButton(onPressed: onCancel, child: const Text('Cancel')),
              ],
            ),
            const SizedBox(height: 8),
          ] else
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text(
                    '$words words',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: overLimit
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: overLimit ? FontWeight.w700 : null,
                    ),
                  ),
                  if (overLimit) ...[
                    const SizedBox(width: 6),
                    Text(
                      'over the limit',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const Spacer(),
                  Tooltip(
                    message: costTooltip,
                    child: Text(
                      costLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              IconButton.filledTonal(
                onPressed: running ? null : onImport,
                icon: const Icon(Icons.add),
                tooltip: 'Import or photograph',
                style: IconButton.styleFrom(
                  minimumSize: const Size(50, 50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: running ? null : onCheck,
                  icon: const Icon(Icons.auto_awesome, size: 20),
                  label: Text(running ? 'Checking...' : 'Check my writing'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
