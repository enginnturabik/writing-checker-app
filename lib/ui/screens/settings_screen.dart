import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../state/app_state.dart';
import '../widgets/pickers.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const SectionHeader('Languages', icon: Icons.translate),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Text(
                    state.nativeLanguage.isEmpty
                        ? '💬'
                        : languageOption(state.nativeLanguage).flag,
                    style: const TextStyle(fontSize: 24),
                  ),
                  title: const Text('I speak'),
                  subtitle: Text(
                    state.nativeLanguage.isEmpty
                        ? 'Not set yet'
                        : languageOption(state.nativeLanguage).name,
                  ),
                  onTap: () => _pickNative(context, state),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Text(
                    state.learningLanguage == 'auto'
                        ? '🌐'
                        : languageOption(state.learningLanguage).flag,
                    style: const TextStyle(fontSize: 24),
                  ),
                  title: const Text('I am learning'),
                  subtitle: Text(
                    state.learningLanguage == 'auto'
                        ? 'Detected from each piece of writing'
                        : languageOption(state.learningLanguage).name,
                  ),
                  onTap: () => _pickLearning(context, state),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              'Knowing your native language also lets the marking point out '
              'mistakes that speakers of it typically make.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SectionHeader('How checking is paid for',
              icon: Icons.account_balance_wallet_outlined),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.vpn_key_outlined),
                  title: const Text('Use my own Anthropic key'),
                  subtitle: Text(
                    state.useOwnKey
                        ? 'Checks are billed to your Anthropic account. '
                            'Credits are not used.'
                        : 'Off: checks use credits. Turn on only if you have '
                            'your own developer account.',
                  ),
                  value: state.useOwnKey,
                  onChanged: (v) => state.update(useOwnKey: v),
                ),
                if (!state.useOwnKey) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.toll_outlined),
                    title: const Text('Credit balance'),
                    subtitle: Text(
                      state.account == null
                          ? (state.connectionError ?? 'Not connected yet')
                          : '${state.balance} credits',
                    ),
                    trailing: state.account == null
                        ? TextButton(
                            onPressed: () => state.connect(),
                            child: const Text('Connect'),
                          )
                        : TextButton(
                            onPressed: () => state.refreshAccount(),
                            child: const Text('Refresh'),
                          ),
                  ),
                ],
              ],
            ),
          ),
          if (!state.useOwnKey)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Text(
                'In credit mode your writing is sent to the Writing Checker '
                'server, which does the marking and never stores your text.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (state.useOwnKey) ...[
          const SectionHeader('Anthropic API key', icon: Icons.key_outlined),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: Text(state.hasApiKey ? 'Key saved' : 'No key yet'),
                  subtitle: Text(
                    state.hasApiKey
                        ? state.maskedApiKey
                        : 'Needed before anything can be checked',
                  ),
                  trailing: FilledButton.tonal(
                    onPressed: () => _editKey(context, state),
                    child: Text(state.hasApiKey ? 'Change' : 'Add key'),
                  ),
                ),
                if (state.hasApiKey)
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('Remove key from this device'),
                    onTap: () => state.clearApiKey(),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              'The key is held in the device keystore and sent only to '
              'api.anthropic.com. Get one at console.anthropic.com, and set a '
              'monthly spend limit there so a mistake can never cost more than '
              'you intended.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SectionHeader('Spending', icon: Icons.payments_outlined),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '\$${state.lifetimeCost.toStringAsFixed(3)}',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          'across ${state.checksRun} checks',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${state.lifetimeUsage.inputTokens} input and '
                    '${state.lifetimeUsage.outputTokens} output tokens. '
                    'Counted from what the API reports, so it tracks your real '
                    'bill closely, but console.anthropic.com is the authority.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => state.resetSpend(),
                      child: const Text('Reset counter'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ],
          // Only shown for a learner on their own key. In credit mode the tier
          // decides the model, so this whole section would be an empty card.
          if (state.useOwnKey) ...[
            const SectionHeader('Marking', icon: Icons.psychology_outlined),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.auto_awesome_outlined),
                    title: const Text('Model'),
                    subtitle: Text(
                      '${state.model.label} - \$${state.model.inputPerMTok.toStringAsFixed(0)} in / '
                      '\$${state.model.outputPerMTok.toStringAsFixed(0)} out per million tokens',
                    ),
                    onTap: () => _pickModel(context, state),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.tune),
                    title: const Text('Marking depth'),
                    subtitle: Text(state.model.supportsEffort
                        ? '${state.effort} - ${kEffortLevels[state.effort]}'
                        : 'Not adjustable on ${state.model.label}'),
                    enabled: state.model.supportsEffort,
                    onTap: state.model.supportsEffort
                        ? () => _pickEffort(context, state)
                        : null,
                  ),
                ],
              ),
            ),
          ],
          const SectionHeader('Appearance', icon: Icons.palette_outlined),
          Card(
            child: RadioGroup<ThemeMode>(
              groupValue: state.themeMode,
              onChanged: (v) => state.update(themeMode: v),
              child: Column(
                children: [
                  for (final mode in ThemeMode.values)
                    RadioListTile<ThemeMode>(
                      value: mode,
                      title: Text(switch (mode) {
                        ThemeMode.system => 'Match the system',
                        ThemeMode.light => 'Light',
                        ThemeMode.dark => 'Dark',
                      }),
                    ),
                ],
              ),
            ),
          ),
          const SectionHeader('About', icon: Icons.info_outline),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Writing Checker marks writing in any language and explains '
                'every correction the way a teacher would.\n\n'
                'Corrections, scores and level estimates are generated by an '
                'AI model and can be wrong - treat them as a tutor would be '
                'treated, not as a final grade. Your text is sent to the '
                'Anthropic API to be marked, is not stored on our server, and '
                'your saved checks stay on this device.',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ),
          ),
          // Both stores require an app that creates accounts to offer deletion
          // from inside the app, not only from a website.
          const SectionHeader('Your account', icon: Icons.person_outline),
          Card(
            child: ListTile(
              leading: Icon(Icons.delete_forever_outlined,
                  color: theme.colorScheme.error),
              title: Text(
                'Delete my account',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text(
                'Removes your sign-in and any credits, on every device',
              ),
              onTap: () => _confirmDelete(context, state),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editKey(BuildContext context, AppState state) async {
    final controller = TextEditingController(text: state.apiKey);
    final key = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        var obscure = true;
        return StatefulBuilder(
          builder: (context, setInner) => AlertDialog(
            title: const Text('Anthropic API key'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  obscureText: obscure,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'sk-ant-...',
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setInner(() => obscure = !obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Create a key at console.anthropic.com, add credit, and set '
                  'a spend limit while you are there.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, controller.text.trim()),
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );

    if (key != null && key.isNotEmpty) {
      await state.setApiKey(key);
    }
  }

  Future<void> _confirmDelete(BuildContext context, AppState state) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete your account?'),
        content: Text(
          state.balance > 0
              ? 'Your ${state.balance} remaining credits will be lost, and '
                  'saved checks on this phone will be deleted. Anything you '
                  'have paid for cannot be restored afterwards.'
              : 'Your sign-in and saved checks will be deleted. This cannot '
                  'be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep my account'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final deleted = await state.deleteAccount();
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(deleted
            ? 'Your account was deleted.'
            : state.error ?? 'Could not delete the account.'),
      ));
    if (deleted) state.clearError();
  }

  Future<void> _pickModel(BuildContext context, AppState state) async {
    final choice = await showOptionSheet<String>(
      context: context,
      title: 'Marking model',
      selected: state.modelId,
      options: [
        for (final m in kModels)
          SheetOption(value: m.id, label: m.label, subtitle: m.blurb),
      ],
      footnote: 'Opus gives the most teacherly feedback. Haiku costs about a '
          'fifth as much and is fine for spelling and basic grammar drills.',
    );
    if (choice != null) state.update(modelId: choice);
  }

  Future<void> _pickEffort(BuildContext context, AppState state) async {
    final choice = await showOptionSheet<String>(
      context: context,
      title: 'How deeply should it mark?',
      selected: state.effort,
      options: [
        for (final e in kEffortLevels.entries)
          SheetOption(value: e.key, label: e.key, subtitle: e.value),
      ],
      footnote: 'Deeper marking costs more because the model thinks longer.',
    );
    if (choice != null) state.update(effort: choice);
  }

  Future<void> _pickNative(
    BuildContext context,
    AppState state,
  ) async {
    final choice = await showOptionSheet<String>(
      context: context,
      title: 'Your native language',
      selected: state.nativeLanguage,
      options: [
        for (final l in kNativeLanguages)
          SheetOption(value: l.code, label: l.name, leading: l.flag),
      ],
      footnote: 'Your feedback is written in this language.',
    );
    if (choice != null) state.update(nativeLanguage: choice);
  }

  Future<void> _pickLearning(BuildContext context, AppState state) async {
    final choice = await showOptionSheet<String>(
      context: context,
      title: 'The language you are learning',
      selected: state.learningLanguage,
      options: [
        for (final l in kLearningLanguages)
          SheetOption(value: l.code, label: l.name, leading: l.flag),
      ],
      footnote: 'Any language works, including ones not listed here.',
    );
    if (choice != null) state.update(learningLanguage: choice);
  }
}
