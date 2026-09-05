import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../models/account.dart';
import '../models/check_request.dart';
import '../models/check_result.dart';
import '../models/history_entry.dart';
import '../services/anthropic_client.dart';
import '../services/backend_client.dart';
import '../services/identity_service.dart';
import '../services/local_store.dart';
import '../services/purchase_service.dart';

/// Single source of truth for settings, saved checks and the running check.
class AppState extends ChangeNotifier {
  AppState({
    LocalStore? store,
    AnthropicClient? client,
    BackendClient? backend,
    IdentityService? identity,
    PurchaseService? purchases,
  })  : _store = store ?? LocalStore(),
        _client = client ?? AnthropicClient(),
        _backend = backend ?? BackendClient(),
        _identity = identity ?? IdentityService(),
        _purchases = purchases ?? PurchaseService();

  final LocalStore _store;
  final AnthropicClient _client;
  final BackendClient _backend;
  final IdentityService _identity;
  final PurchaseService _purchases;

  // --- Settings ------------------------------------------------------------

  String _apiKey = '';
  String _modelId = kDefaultModelId;
  String _effort = kDefaultEffort;
  /// The learner profile: what they speak, and what they are learning.
  /// Empty native language means the profile has never been set.
  String _nativeLanguage = '';
  String _learningLanguage = 'auto';
  ThemeMode _themeMode = ThemeMode.system;

  /// Advanced escape hatch: mark through the user's own Anthropic key instead
  /// of spending credits. Nothing is metered in this mode.
  bool _useOwnKey = false;
  String _tierId = 'quick';

  String get apiKey => _apiKey;
  bool get hasApiKey => _apiKey.trim().isNotEmpty;
  String get modelId => _modelId;
  ClaudeModel get model => modelById(_modelId);
  String get effort => _effort;
  String get nativeLanguage => _nativeLanguage;
  String get learningLanguage => _learningLanguage;

  /// False until the learner has told us their mother tongue, which the
  /// welcome sheet asks for on first launch.
  bool get hasProfile => _nativeLanguage.isNotEmpty;

  /// The language feedback is written in.
  String get feedbackLanguage => _nativeLanguage;
  ThemeMode get themeMode => _themeMode;

  /// Flips between light and dark.
  ///
  /// [current] is the brightness actually on screen, so that starting from
  /// `system` the first tap changes something visible rather than picking the
  /// mode the device was already using. The three-way choice, including
  /// following the system, stays in Settings.
  Future<void> toggleTheme(Brightness current) => update(
        themeMode:
            current == Brightness.dark ? ThemeMode.light : ThemeMode.dark,
      );
  bool get useOwnKey => _useOwnKey;
  String get tierId => _tierId;

  /// True when checks are metered in credits rather than billed to the user's
  /// own key. Everything about the paywall keys off this.
  bool get isMetered => !_useOwnKey;

  /// Masked form for the settings screen, so the key is never shown in full.
  String get maskedApiKey {
    if (_apiKey.length < 12) return '••••••••';
    return '${_apiKey.substring(0, 7)}...${_apiKey.substring(_apiKey.length - 4)}';
  }

  // --- Session ------------------------------------------------------------

  bool _ready = false;
  bool get ready => _ready;

  Account? _account;
  Account? get account => _account;

  int get balance => _account?.balance ?? 0;
  List<CreditProduct> get products => _account?.products ?? const [];

  /// Plans the user can subscribe to. Empty until the catalogue arrives.
  List<SubscriptionPlan> get plans => _account?.purchasablePlans ?? const [];

  /// What the user is entitled to right now. Free until told otherwise.
  Entitlement get entitlement => _account?.entitlement ?? Entitlement.free;

  bool get isSubscribed => !entitlement.isFree;
  AccountLimits get limits => _account?.limits ?? AccountLimits.fallback;

  List<CheckTier> get tiers =>
      _account?.tiers.isNotEmpty == true
          ? _account!.tiers
          : CheckTier.fallbacks;

  CheckTier get tier => tiers.firstWhere(
        (t) => t.id == _tierId,
        orElse: () => CheckTier.fallbackQuick,
      );

  /// Set when the device could not reach the server at startup. The app still
  /// works for reading saved reports, so this is a banner and not a blocker.
  String? _connectionError;
  String? get connectionError => _connectionError;

  bool get needsSetup => _useOwnKey ? !hasApiKey : _account == null;

  int priceOfNextCheck({required bool hasAttachment}) =>
      tier.priceFor(hasAttachment: hasAttachment);

  List<HistoryEntry> _history = [];
  List<HistoryEntry> get history => List.unmodifiable(_history);

  TokenUsage _lifetimeUsage = const TokenUsage();
  double _lifetimeCost = 0;
  int _checksRun = 0;

  TokenUsage get lifetimeUsage => _lifetimeUsage;
  double get lifetimeCost => _lifetimeCost;
  int get checksRun => _checksRun;

  Future<void> load() async {
    _apiKey = await _store.readApiKey() ?? '';
    final s = await _store.readSettings();
    _modelId = (s['model_id'] as String?) ?? kDefaultModelId;
    if (!kModels.any((m) => m.id == _modelId)) _modelId = kDefaultModelId;
    _effort = (s['effort'] as String?) ?? kDefaultEffort;

    // Migration: the old build stored `target_language` plus an
    // `explanation_language` that could be the sentinel `same`. A stored
    // explanation language was, in practice, the user telling us their mother
    // tongue, so it carries over as exactly that.
    _learningLanguage = (s['learning_language'] as String?) ??
        (s['target_language'] as String?) ??
        'auto';
    final storedNative = (s['native_language'] as String?) ??
        (s['explanation_language'] as String?);
    _nativeLanguage =
        (storedNative == null || storedNative == 'same') ? '' : storedNative;
    _themeMode = ThemeMode.values.firstWhere(
      (m) => m.name == (s['theme_mode'] as String? ?? 'system'),
      orElse: () => ThemeMode.system,
    );
    _lifetimeCost = (s['lifetime_cost'] as num?)?.toDouble() ?? 0;
    _checksRun = (s['checks_run'] as num?)?.toInt() ?? 0;
    _lifetimeUsage = TokenUsage(
      inputTokens: (s['lifetime_input'] as num?)?.toInt() ?? 0,
      outputTokens: (s['lifetime_output'] as num?)?.toInt() ?? 0,
    );
    _useOwnKey = (s['use_own_key'] as bool?) ?? false;
    _tierId = (s['tier_id'] as String?) ?? 'quick';
    _installId = (s['install_id'] as String?) ?? '';
    _history = await _store.readHistory();

    // The UI can render as soon as local data is loaded; the network call
    // below only fills in the balance.
    _ready = true;
    notifyListeners();

    if (isMetered) await connect();
  }

  String _installId = '';

  /// Registers the device with the server and picks up balance and catalogue.
  /// Safe to call repeatedly; the trial grant is idempotent server-side.
  Future<void> connect() async {
    if (_installId.isEmpty) {
      _installId = const Uuid().v4();
      await _persistSettings();
    }

    _connectionError = null;
    notifyListeners();

    try {
      final existing = await _store.readSessionToken();
      if (existing != null && existing.isNotEmpty) {
        _account = await _backend.fetchAccount(existing);
      } else {
        final account = await _backend.registerDevice(
          installId: _installId,
          platform: _platformName,
        );
        await _store.writeSessionToken(account.token);
        _account = account;
      }
    } on ApiException catch (e) {
      // A stale or rejected token means re-registering, once.
      if (e.statusCode == 401) {
        try {
          final account = await _backend.registerDevice(
            installId: _installId,
            platform: _platformName,
          );
          await _store.writeSessionToken(account.token);
          _account = account;
          _connectionError = null;
          notifyListeners();
          await _startPurchases();
          return;
        } catch (_) {
          // Fall through to the generic message below.
        }
      }
      _connectionError = e.message;
    } catch (_) {
      _connectionError = 'Could not reach the server.';
    }

    notifyListeners();

    // Only once an account exists: a receipt is credited to a user, and the
    // catalogue names the products the store is asked about.
    if (_account != null) await _startPurchases();
  }

  /// Refreshes the balance after a purchase or a check.
  Future<void> refreshAccount() async {
    final token = _account?.token;
    if (token == null) return;
    try {
      _account = await _backend.fetchAccount(token);
      notifyListeners();
    } catch (_) {
      // Balance display can go stale without breaking anything.
    }
  }

  bool _signingIn = false;
  bool get signingIn => _signingIn;

  /// Signs in with Google or Apple so the balance survives a reinstall.
  ///
  /// Returns a message worth showing when credits were recovered or carried
  /// across, and null when nothing notable happened. Cancellation is silent.
  Future<String?> signIn(SignInProvider provider) async {
    final token = _account?.token;
    if (token == null || _signingIn) return null;

    _signingIn = true;
    _error = null;
    notifyListeners();

    try {
      final idToken = await _identity.tokenFor(provider);
      final result = await _backend.linkIdentity(
        token: token,
        provider: provider.wireName,
        idToken: idToken,
      );

      // The token may now address a different account, so it has to be stored
      // before anything else uses it.
      await _store.writeSessionToken(result.token);
      _account = _account!.copyWith(
        token: result.token,
        balance: result.balance,
        identity: result.identity,
      );

      if (result.merged) {
        return result.carriedCredits > 0
            ? 'Welcome back. Your ${result.balance} credits are restored, '
                'including ${result.carriedCredits} carried over from this device.'
            : 'Welcome back. Your ${result.balance} credits are restored.';
      }
      return 'Signed in. Your credits are safe if you reinstall.';
    } on SignInException catch (e) {
      if (!e.cancelled) _error = e.message;
      return null;
    } on ApiException catch (e) {
      _error = e.message;
      return null;
    } finally {
      _signingIn = false;
      notifyListeners();
    }
  }

  Future<bool> supportsSignIn(SignInProvider provider) =>
      _identity.supports(provider);

  // --- Buying credits ------------------------------------------------------

  bool _purchasing = false;
  bool get purchasing => _purchasing;

  /// Set when a purchase finishes, so the paywall can say what happened.
  String? _purchaseMessage;
  String? get purchaseMessage => _purchaseMessage;

  void clearPurchaseMessage() {
    _purchaseMessage = null;
    notifyListeners();
  }

  /// The store's own localised price, when the store gave us one. Falls back
  /// to the server's USD figure, which is only ever an approximation of what
  /// the user is actually charged.
  String priceLabelFor(CreditProduct product) =>
      _purchases.detailsFor(product.id)?.price ??
      '\$${product.priceUsd.toStringAsFixed(2)}';

  bool get canBuy => _purchases.supported && !useOwnKey;

  /// Begins listening for store receipts. Safe to call on every launch: the
  /// service ignores repeat calls, and replayed receipts are idempotent on the
  /// server.
  Future<void> _startPurchases() async {
    if (!_purchases.supported) return;
    _purchases.events.listen(_onPurchaseEvent);
    await _purchases.start(
      verify: _creditReceipt,
      productIds: {
        ...products.map((p) => p.id),
        for (final plan in plans)
          if (plan.productId != null) plan.productId!,
      },
      subscriptionIds: {
        for (final plan in plans)
          if (plan.productId != null) plan.productId!,
      },
    );
    notifyListeners();
  }

  Future<void> buy(CreditProduct product) async {
    if (_purchasing) return;
    _purchasing = true;
    _purchaseMessage = null;
    _error = null;
    notifyListeners();
    await _purchases.buy(product.id);
  }

  /// Starts a subscription. The store answers on the purchase stream, so this
  /// returns as soon as the sheet is open, not when the payment completes.
  Future<void> subscribe(SubscriptionPlan plan) async {
    final productId = plan.productId;
    if (_purchasing || productId == null) return;
    _purchasing = true;
    _purchaseMessage = null;
    _error = null;
    notifyListeners();
    await _purchases.buy(productId);
  }

  /// The store's localised price for a plan, falling back to the server's USD
  /// figure. Only the store's own figure is what the user is actually charged.
  String priceLabelForPlan(SubscriptionPlan plan) {
    final productId = plan.productId;
    final details = productId == null ? null : _purchases.detailsFor(productId);
    return details?.price ?? '\$${plan.priceUsd.toStringAsFixed(2)}';
  }

  Future<void> restorePurchases() async {
    _purchaseMessage = null;
    await _purchases.restore();
  }

  void _onPurchaseEvent(PurchaseEvent event) {
    switch (event.outcome) {
      case PurchaseOutcome.pending:
        _purchasing = true;
      case PurchaseOutcome.cancelled:
        _purchasing = false;
      case PurchaseOutcome.failed:
        _purchasing = false;
        _error = event.message;
      case PurchaseOutcome.credited:
        _purchasing = false;
        _purchaseMessage = event.credited > 0
            ? '${event.credited} credits added. Thank you.'
            : 'That purchase was already on your account.';
    }
    notifyListeners();
  }

  /// Hands a store receipt to the server, which decides the credits. Returns
  /// null when the server did not confirm, which leaves the receipt pending so
  /// the store replays it rather than the user losing what they paid for.
  Future<int?> _creditReceipt({
    required String productId,
    required String purchaseToken,
    required bool isSubscription,
  }) async {
    final token = _account?.token;
    if (token == null) return null;
    try {
      if (isSubscription) {
        final result = await _backend.submitSubscription(
          token: token,
          platform: _platformName,
          productId: productId,
          purchaseToken: purchaseToken,
        );
        _account = _account!.copyWith(
          balance: result.balance,
          entitlement: result.entitlement,
        );
        notifyListeners();
        return result.granted;
      }

      final result = await _backend.submitPurchase(
        token: token,
        platform: _platformName,
        productId: productId,
        purchaseToken: purchaseToken,
      );
      _account = _account!.copyWith(balance: result.balance);
      notifyListeners();
      return result.credited;
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
      return null;
    }
  }

  static String get _platformName {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'windows';
  }

  Future<void> _persistSettings() => _store.writeSettings({
        'model_id': _modelId,
        'effort': _effort,
        'native_language': _nativeLanguage,
        'learning_language': _learningLanguage,
        'theme_mode': _themeMode.name,
        'lifetime_cost': _lifetimeCost,
        'checks_run': _checksRun,
        'lifetime_input': _lifetimeUsage.inputTokens,
        'lifetime_output': _lifetimeUsage.outputTokens,
        'use_own_key': _useOwnKey,
        'tier_id': _tierId,
        'install_id': _installId,
      });

  Future<void> setApiKey(String key) async {
    _apiKey = key.trim();
    await _store.writeApiKey(_apiKey);
    notifyListeners();
  }

  Future<void> clearApiKey() async {
    _apiKey = '';
    await _store.deleteApiKey();
    notifyListeners();
  }

  Future<void> update({
    String? modelId,
    String? effort,
    String? nativeLanguage,
    String? learningLanguage,
    ThemeMode? themeMode,
    bool? useOwnKey,
    String? tierId,
  }) async {
    final switchingToMetered = useOwnKey == false && _useOwnKey;
    _useOwnKey = useOwnKey ?? _useOwnKey;
    _tierId = tierId ?? _tierId;
    _modelId = modelId ?? _modelId;
    _effort = effort ?? _effort;
    _nativeLanguage = nativeLanguage ?? _nativeLanguage;
    _learningLanguage = learningLanguage ?? _learningLanguage;
    _themeMode = themeMode ?? _themeMode;
    notifyListeners();
    await _persistSettings();

    // Turning metering back on needs a balance to show.
    if (switchingToMetered && _account == null) await connect();
  }

  // --- Running a check ----------------------------------------------------

  CheckProgress? _progress;
  CheckProgress? get progress => _progress;

  String? _error;
  String? get error => _error;

  /// Set when the last failure was an empty balance, so the UI can offer a
  /// top-up instead of a generic retry.
  bool _outOfCredits = false;
  bool get outOfCredits => _outOfCredits;

  bool _running = false;
  bool get running => _running;

  /// Runs a check and, on success, saves it to history and updates the meter.
  Future<HistoryEntry?> runCheck({
    required String text,
    Attachment? attachment,
  }) async {
    if (_running) return null;
    _running = true;
    _error = null;
    _outOfCredits = false;
    _progress = const CheckProgress(charsReceived: 0, stage: 'Starting');
    notifyListeners();

    final request = CheckRequest(
      text: text,
      learningLanguage: _learningLanguage,
      // A learner who skipped the welcome sheet still needs feedback in
      // something; English is the safest fallback.
      nativeLanguage: _nativeLanguage.isEmpty ? 'en' : _nativeLanguage,
      modelId: _modelId,
      effort: _effort,
      attachment: attachment,
    );

    try {
      void reportProgress(CheckProgress p) {
        _progress = p;
        notifyListeners();
      }

      final CheckResult result;
      if (_useOwnKey) {
        result = await _client.check(
          request,
          apiKey: _apiKey,
          onProgress: reportProgress,
        );
      } else {
        final token = _account?.token;
        if (token == null) {
          throw ApiException(
            'Not connected to the server yet. Check your connection and '
            'try again.',
          );
        }
        final metered = await _backend.check(
          request,
          token: token,
          tierId: _tierId,
          onProgress: reportProgress,
        );
        result = metered.result;
        _account = _account!.copyWith(balance: metered.balance);
      }

      // For a photo or PDF the checked text is the transcription the model
      // produced, so the report anchors to the corrected text instead.
      final sourceText = text.trim().isNotEmpty ? text : result.correctedText;

      final entry = HistoryEntry(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        createdAt: DateTime.now(),
        title: HistoryEntry.titleFrom(
          sourceText,
          attachment?.fileName ?? 'Untitled check',
        ),
        sourceText: sourceText,
        result: result,
        targetLanguage: result.languageCode.isNotEmpty
            ? result.languageCode
            : _learningLanguage,
      );

      _history = [entry, ..._history];
      _checksRun += 1;
      // Only meaningful when the user is paying Anthropic directly. In metered
      // mode the server absorbs the token cost and reports credits instead.
      if (_useOwnKey) {
        _lifetimeUsage = _lifetimeUsage.merge(result.usage);
        _lifetimeCost += model.costFor(
          inputTokens: result.usage.inputTokens,
          outputTokens: result.usage.outputTokens,
        );
      }

      _running = false;
      _progress = null;
      notifyListeners();

      await _store.writeHistory(_history);
      await _persistSettings();
      return entry;
    } on OutOfCreditsException catch (e) {
      _error = e.message;
      _outOfCredits = true;
      _account = _account?.copyWith(balance: e.balance);
    } on ApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Something went wrong: $e';
    }

    _running = false;
    _progress = null;
    notifyListeners();
    return null;
  }

  void cancelCheck() {
    if (!_running) return;
    if (_useOwnKey) {
      _client.cancel();
    } else {
      _backend.cancel();
    }
  }

  void clearError() {
    _error = null;
    _outOfCredits = false;
    notifyListeners();
  }

  // --- History ------------------------------------------------------------

  HistoryEntry? entryById(String id) {
    for (final e in _history) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Persists in-place edits such as accepting or dismissing a correction.
  Future<void> saveHistory() async {
    notifyListeners();
    await _store.writeHistory(_history);
  }

  Future<void> deleteEntry(String id) async {
    _history = _history.where((e) => e.id != id).toList();
    notifyListeners();
    await _store.writeHistory(_history);
  }

  Future<void> clearHistory() async {
    _history = [];
    notifyListeners();
    await _store.writeHistory(_history);
  }

  Future<void> resetSpend() async {
    _lifetimeCost = 0;
    _checksRun = 0;
    _lifetimeUsage = const TokenUsage();
    notifyListeners();
    await _persistSettings();
  }

  // --- Derived stats ------------------------------------------------------

  /// Error counts per category across every saved check.
  Map<String, int> get categoryTotals {
    final out = <String, int>{};
    for (final e in _history) {
      e.result.countsByCategory.forEach((k, v) => out[k] = (out[k] ?? 0) + v);
    }
    return out;
  }

  /// The mistakes that keep coming back, most frequent first.
  List<MapEntry<String, int>> get recurringRules {
    final counts = <String, int>{};
    for (final e in _history) {
      for (final c in e.result.active) {
        final rule = c.rule.trim();
        if (rule.isEmpty) continue;
        final key = rule[0].toUpperCase() + rule.substring(1);
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    final list = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list.take(8).toList();
  }

  /// Overall scores oldest-first, for the progress line.
  List<int> get scoreTrend =>
      _history.reversed.map((e) => e.result.scores.overall).toList();

  int get totalErrorsFound =>
      _history.fold(0, (sum, e) => sum + e.result.active.length);

  int get totalWordsChecked =>
      _history.fold(0, (sum, e) => sum + e.result.wordCount);

  @override
  void dispose() {
    _client.dispose();
    _backend.dispose();
    super.dispose();
  }
}
