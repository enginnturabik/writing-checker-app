import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/account.dart';
import '../../services/identity_service.dart';
import '../../state/app_state.dart';
import '../widgets/pickers.dart';

/// Balance, what a check costs, and the credit packs.
///
/// Buying goes through the platform store, and the server credits only a
/// receipt it has verified with Google or Apple. The app never decides how
/// many credits a pack is worth.
class CreditsScreen extends StatelessWidget {
  const CreditsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    if (state.useOwnKey) {
      return Scaffold(
        appBar: AppBar(title: const Text('Credits')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.key_outlined,
                    size: 56, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text('Using your own key', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'Checks are billed straight to your Anthropic account, so '
                  'credits do not apply. Turn this off in Settings to use '
                  'credits instead.',
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

    final cheapest = state.products.isEmpty
        ? null
        : state.products.reduce(
            (a, b) => a.perCheckUsd <= b.perCheckUsd ? a : b,
          );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Credits'),
        actions: [
          if (state.canBuy)
            IconButton(
              tooltip: 'Restore purchases',
              onPressed: () => state.restorePurchases(),
              icon: const Icon(Icons.restore),
            ),
          IconButton(
            tooltip: 'Refresh balance',
            onPressed: () => state.refreshAccount(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (state.purchaseMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                color: theme.colorScheme.primaryContainer,
                child: ListTile(
                  leading: Icon(Icons.check_circle_outline,
                      color: theme.colorScheme.onPrimaryContainer),
                  title: Text(
                    state.purchaseMessage!,
                    style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    color: theme.colorScheme.onPrimaryContainer,
                    onPressed: state.clearPurchaseMessage,
                  ),
                ),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
              child: Column(
                children: [
                  Text(
                    '${state.balance}',
                    style: theme.textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Text(
                    state.balance == 1 ? 'credit left' : 'credits left',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _PlanCard(),
          const _AccountCard(),
          const SectionHeader('Your plan', icon: Icons.workspace_premium),
          if (!state.canBuy)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                'Plans can only be bought from the Play Store or the App '
                'Store, so they are unavailable on this device.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final plan in state.plans)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PlanOption(
                plan: plan,
                current: plan.id == state.entitlement.planId,
              ),
            ),
          const SectionHeader('What a check costs', icon: Icons.receipt_long),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < state.tiers.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    title: Text(state.tiers[i].label),
                    subtitle: Text(state.tiers[i].description),
                    trailing: Text(
                      '${state.tiers[i].credits}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              'Photos and PDFs cost a little extra, because reading a page '
              'takes more work than reading typed text.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SectionHeader('Run out early?', icon: Icons.add_shopping_cart),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text(
              state.canBuy
                  ? 'A one-off top-up adds credits to whatever plan you are '
                      'on. It does not renew.'
                  : 'Credits can only be bought from the Play Store or the '
                      'App Store, so top-ups are unavailable on this device.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final product in state.products)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ProductCard(
                product: product,
                bestValue: product.id == cheapest?.id && state.products.length > 1,
              ),
            ),
          if (state.products.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Could not load the credit packs. Pull to refresh once you '
                  'are back online.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Sign-in prompt, or confirmation that credits are safe.
///
/// This sits above the packs deliberately: the moment before someone spends
/// money is exactly when they should be told how not to lose it.
class _AccountCard extends StatefulWidget {
  const _AccountCard();

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  List<SignInProvider> _available = const [];

  @override
  void initState() {
    super.initState();
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    final state = context.read<AppState>();
    final available = <SignInProvider>[];
    for (final provider in SignInProvider.values) {
      if (await state.supportsSignIn(provider)) available.add(provider);
    }
    if (mounted) setState(() => _available = available);
  }

  Future<void> _signIn(SignInProvider provider) async {
    final state = context.read<AppState>();
    final message = await state.signIn(provider);
    if (!mounted) return;

    final text = message ?? state.error;
    if (text == null) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 5),
      ));
    state.clearError();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final identity = state.account?.identity;

    if (identity != null) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.verified_user_outlined,
              color: theme.colorScheme.primary),
          title: Text('Signed in with ${identity.label}'),
          subtitle: Text(
            identity.email ?? 'Your credits are safe if you reinstall.',
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Keep your credits',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Right now your credits live only on this phone. Sign in and they '
              'follow you to a new device or a reinstall.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            if (_available.isEmpty)
              Text(
                'Sign-in is not available in this build yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final provider in _available)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton.icon(
                    onPressed: state.signingIn ? null : () => _signIn(provider),
                    icon: Icon(
                      provider == SignInProvider.apple
                          ? Icons.apple
                          : Icons.g_mobiledata,
                      size: 22,
                    ),
                    label: Text(provider.label),
                  ),
                ),
            if (state.signingIn)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product, required this.bestValue});

  final CreditProduct product;
  final bool bestValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        product.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (bestValue) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'BEST VALUE',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${product.credits} credits',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              onPressed: state.canBuy && !state.purchasing
                  ? () => state.buy(product)
                  : null,
              child: state.purchasing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(state.priceLabelFor(product)),
            ),
          ],
        ),
      ),
    );
  }
}


/// The plan the user is on, and what it gives them each period.
///
/// Deliberately worded without a number of credits: someone choosing a plan
/// wants to know how many reports they get, not how the billing works.
class _PlanCard extends StatelessWidget {
  const _PlanCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final entitlement = state.entitlement;

    return Card(
      color: entitlement.isFree
          ? null
          : theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  entitlement.isFree ? Icons.person_outline : Icons.verified,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  entitlement.label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              entitlement.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (entitlement.needsAttention) ...[
              const SizedBox(height: 8),
              Text(
                'There is a problem with your payment. Your plan keeps working '
                'while the store retries it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ] else if (!entitlement.isFree && !entitlement.autoRenewing) ...[
              const SizedBox(height: 8),
              Text(
                'Your plan will not renew. You keep everything you have paid '
                'for until it ends.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One plan on the paywall.
class _PlanOption extends StatelessWidget {
  const _PlanOption({required this.plan, required this.current});

  final SubscriptionPlan plan;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Card(
      shape: current
          ? RoundedRectangleBorder(
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    plan.label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  state.priceLabelForPlan(plan),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              plan.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: current || state.purchasing || !state.canBuy
                    ? null
                    : () => state.subscribe(plan),
                child: Text(current ? 'Your current plan' : 'Choose'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
