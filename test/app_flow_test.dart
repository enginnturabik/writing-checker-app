import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:writing_checker/app.dart';
import 'package:writing_checker/models/account.dart';
import 'package:writing_checker/models/check_request.dart';
import 'package:writing_checker/models/check_result.dart';
import 'package:writing_checker/models/history_entry.dart';
import 'package:writing_checker/services/anthropic_client.dart';
import 'package:writing_checker/services/backend_client.dart';
import 'package:writing_checker/services/local_store.dart';
import 'package:writing_checker/state/app_state.dart';

/// In-memory store so tests never touch the keystore or the file system.
class FakeStore extends LocalStore {
  /// Defaults to a learner who has already been through the welcome sheet, so
  /// tests exercise the main screens rather than onboarding.
  FakeStore({
    this.apiKey = 'sk-ant-test-key-000000000000',
    Map<String, dynamic>? settings,
  }) : settings = settings ??
            {
              'use_own_key': true,
              'native_language': 'tr',
              'learning_language': 'fr',
            };

  String apiKey;
  String? sessionToken;
  Map<String, dynamic> settings;
  List<HistoryEntry> entries = [];

  @override
  Future<String?> readSessionToken() async => sessionToken;

  @override
  Future<void> writeSessionToken(String token) async => sessionToken = token;

  int sessionTokenClears = 0;

  @override
  Future<void> clearSessionToken() async {
    sessionTokenClears++;
    sessionToken = null;
  }

  @override
  Future<String?> readApiKey() async => apiKey.isEmpty ? null : apiKey;

  @override
  Future<void> writeApiKey(String key) async => apiKey = key;

  @override
  Future<void> deleteApiKey() async => apiKey = '';

  @override
  Future<Map<String, dynamic>> readSettings() async => settings;

  @override
  Future<void> writeSettings(Map<String, dynamic> s) async => settings = s;

  @override
  Future<List<HistoryEntry>> readHistory() async => entries;

  @override
  Future<void> writeHistory(List<HistoryEntry> e) async => entries = e;
}

/// Returns a fixed report instead of calling the API.
class FakeClient extends AnthropicClient {
  FakeClient({this.failure});

  final String? failure;
  CheckRequest? lastRequest;

  @override
  Future<CheckResult> check(
    CheckRequest req, {
    required String apiKey,
    void Function(CheckProgress)? onProgress,
  }) async {
    lastRequest = req;
    onProgress?.call(const CheckProgress(charsReceived: 0, stage: 'Marking'));
    if (failure != null) throw ApiException(failure!);

    final result = CheckResult.fromJson({
      'detected_language': 'French',
      'language_code': 'fr',
      'cefr_estimate': 'B1',
      'word_count': 6,
      'summary': 'A solid attempt with two agreement slips.',
      'scores': {
        'grammar': 62,
        'vocabulary': 74,
        'spelling': 88,
        'coherence': 70,
        'style': 66,
        'overall': 71,
      },
      'corrected_text': 'Je suis allee au marche hier.',
      'strengths': ['Clear word order'],
      'priorities': ['Past participle agreement'],
      'next_steps': ['Drill passe compose with etre'],
      'corrections': [
        {
          'id': 'c1',
          'original': 'alle',
          'context_before': 'Je suis ',
          'correction': 'allee',
          'category': 'grammar',
          'severity': 'moderate',
          'explanation': 'With etre the participle agrees with the subject.',
          'rule': 'participle agreement with etre',
        }
      ],
      'vocabulary_upgrades': [
        {
          'original': 'marche',
          'suggestion': 'marche couvert',
          'note': 'More precise.',
        }
      ],
    }, modelId: req.modelId);
    result.locateSpans(req.text);
    return result;
  }

  @override
  void dispose() {}
}

/// Stands in for the server so no HTTP happens in tests.
class FakeBackend extends BackendClient {
  FakeBackend({this.balance = 5, this.failWith});

  int balance;
  Entitlement entitlement = Entitlement.free;
  ApiException? failWith;
  int checksRun = 0;
  int deleteCalls = 0;

  @override
  Future<void> deleteAccount(String token) async {
    deleteCalls++;
    balance = 0;
  }
  String? lastTierId;

  Account _account() => Account(
        token: 'device-token',
        userId: 'user-1',
        balance: balance,
        products: const [
          CreditProduct(id: 'credits_40', credits: 40, priceUsd: 1, label: 'Small top-up'),
          CreditProduct(id: 'credits_120', credits: 120, priceUsd: 3, label: 'Top-up'),
        ],
        plans: const [
          SubscriptionPlan(
            id: 'writer',
            productId: 'sub_writer_monthly',
            creditsPerPeriod: 120,
            period: 'month',
            priceUsd: 3,
            label: 'Writer',
            description: '30 advanced checks a month, or 4 full reports.',
          ),
          SubscriptionPlan(
            id: 'exam',
            productId: 'sub_exam_monthly',
            creditsPerPeriod: 250,
            period: 'month',
            priceUsd: 6,
            label: 'Exam',
            description: '10 full reports a month, or 62 advanced checks.',
          ),
        ],
        tiers: CheckTier.fallbacks,
        limits: AccountLimits.fallback,
        entitlement: entitlement,
      );

  @override
  Future<Account> registerDevice({
    required String installId,
    required String platform,
  }) async =>
      _account();

  @override
  Future<Account> fetchAccount(String token) async => _account();

  @override
  Future<MeteredCheck> check(
    CheckRequest request, {
    required String token,
    required String tierId,
    void Function(CheckProgress)? onProgress,
  }) async {
    checksRun++;
    lastTierId = tierId;
    onProgress?.call(const CheckProgress(charsReceived: 0, stage: 'Marking'));
    if (failWith != null) throw failWith!;

    final result = await FakeClient().check(request, apiKey: 'unused');
    final tier = CheckTier.fallbacks.firstWhere(
      (t) => t.id == tierId,
      orElse: () => CheckTier.fallbackQuick,
    );
    final price = tier.priceFor(hasAttachment: request.hasAttachment);
    balance -= price;
    return MeteredCheck(result: result, balance: balance, creditsSpent: price);
  }

  @override
  void dispose() {}
}

Future<AppState> _pump(
  WidgetTester tester, {
  FakeStore? store,
  FakeClient? client,
  FakeBackend? backend,
}) async {
  // A tall surface so long report and settings lists fit without scrolling.
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final state = AppState(
    store: store ?? FakeStore(),
    client: client ?? FakeClient(),
    backend: backend ?? FakeBackend(),
  );
  await state.load();

  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const WritingCheckerApp(),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('editor shows the composer and marking options', (tester) async {
    await _pump(tester);

    expect(find.text('Writing Checker'), findsOneWidget);
    expect(find.text('Check my writing'), findsOneWidget);
    expect(find.text('🇫🇷 French'), findsOneWidget);
    // The editor is deliberately down to two choices: how thorough, and which
    // language. Everything else the marking works out for itself.
    expect(find.text('Any level'), findsNothing);
    expect(find.text('General'), findsNothing);
    expect(find.text('Normal'), findsNothing);
    // A key is present in the fake store, so the setup banner stays hidden.
    expect(find.text('Add your Anthropic API key'), findsNothing);
  });

  testWidgets('prompts for a key when none is stored', (tester) async {
    await _pump(tester, store: FakeStore(apiKey: ''));

    expect(find.text('Add your Anthropic API key'), findsOneWidget);
  });

  testWidgets('checking a text opens the report', (tester) async {
    final client = FakeClient();
    await _pump(tester, client: client);

    await tester.enterText(
      find.byType(TextField).first,
      'Je suis alle au marche hier.',
    );
    await tester.pump();

    await tester.tap(find.text('Check my writing'));
    await tester.pumpAndSettle();

    // Report header and teacher summary.
    expect(find.text('French'), findsOneWidget);
    expect(find.text('71'), findsOneWidget);
    expect(
      find.text('A solid attempt with two agreement slips.'),
      findsOneWidget,
    );
    expect(find.text('Reads as B1'), findsOneWidget);
    expect(find.text('Fix these first'), findsOneWidget);
    expect(find.text('Past participle agreement'), findsOneWidget);

    // The submission actually reached the client with the chosen options.
    expect(client.lastRequest?.text, contains('Je suis alle'));
    expect(client.lastRequest?.modelId, 'claude-opus-5');
  });

  testWidgets('corrections tab explains a flagged span', (tester) async {
    await _pump(tester);

    await tester.enterText(
      find.byType(TextField).first,
      'Je suis alle au marche hier.',
    );
    await tester.pump();
    await tester.tap(find.text('Check my writing'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Corrections (1)'));
    await tester.pumpAndSettle();

    expect(find.text('0 of 1 applied'), findsOneWidget);

    // Switch to the list view, which exposes the correction as a card.
    await tester.tap(find.byIcon(Icons.list_alt));
    await tester.pumpAndSettle();

    expect(find.text('allee'), findsWidgets);
    expect(
      find.textContaining('participle agrees with the subject'),
      findsOneWidget,
    );

    await tester.tap(find.text('Apply all'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 1 applied'), findsOneWidget);
  });

  testWidgets('a failed check surfaces the error and saves nothing',
      (tester) async {
    final state = await _pump(
      tester,
      client: FakeClient(failure: 'Your API key was rejected.'),
    );

    await tester.enterText(find.byType(TextField).first, 'Bonjour.');
    await tester.pump();
    await tester.tap(find.text('Check my writing'));
    await tester.pumpAndSettle();

    expect(find.text('Your API key was rejected.'), findsOneWidget);
    expect(state.history, isEmpty);
  });

  testWidgets('history and progress fill in after a check', (tester) async {
    await _pump(tester);

    await tester.enterText(
      find.byType(TextField).first,
      'Je suis alle au marche hier.',
    );
    await tester.pump();
    await tester.tap(find.text('Check my writing'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.history_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Je suis alle au marche hier.'), findsOneWidget);
    expect(find.text('Nothing checked yet'), findsNothing);

    await tester.tap(find.byIcon(Icons.insights_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Mistakes you keep repeating'), findsOneWidget);
    expect(find.text('Participle agreement with etre'), findsOneWidget);
  });

  group('learner profile', () {
    testWidgets('asks for both languages on a fresh install', (tester) async {
      await _pump(tester, store: FakeStore(settings: {}));

      expect(find.text('Welcome'), findsOneWidget);
      expect(find.text('I speak'), findsOneWidget);
      expect(find.text('Choose your native language'), findsOneWidget);
      expect(find.text('I am learning'), findsOneWidget);

      // Cannot continue without a native language: it is what feedback is
      // written in.
      final start = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start checking'),
      );
      expect(start.onPressed, isNull);
    });

    testWidgets('saves the profile and lets the learner through',
        (tester) async {
      final store = FakeStore(settings: {});
      final state = await _pump(tester, store: store);

      await tester.tap(find.text('Choose your native language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turkish').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Work it out from my writing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('French').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start checking'));
      await tester.pumpAndSettle();

      expect(find.text('Welcome'), findsNothing);
      expect(state.nativeLanguage, 'tr');
      expect(state.learningLanguage, 'fr');
      expect(store.settings['native_language'], 'tr');
    });

    testWidgets('does not ask again once the profile is set', (tester) async {
      await _pump(tester);
      expect(find.text('Welcome'), findsNothing);
    });

    testWidgets('the profile is editable in settings', (tester) async {
      final state = await _pump(tester);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.text('I speak'), findsOneWidget);
      expect(find.text('Turkish'), findsOneWidget);
      expect(find.text('I am learning'), findsOneWidget);
      expect(find.text('French'), findsOneWidget);
      expect(state.feedbackLanguage, 'tr',
          reason: 'feedback always comes in the mother tongue now');
      expect(find.text('Immersion mode'), findsNothing);
      expect(find.text('Strict marking'), findsNothing);
    });

    testWidgets('carries the old explanation setting over', (tester) async {
      // A user upgrading from the build that only had `explanation_language`.
      final state = await _pump(
        tester,
        store: FakeStore(settings: {
          'use_own_key': true,
          'target_language': 'de',
          'explanation_language': 'tr',
        }),
      );

      expect(state.nativeLanguage, 'tr', reason: 'became the mother tongue');
      expect(state.learningLanguage, 'de');
      expect(find.text('Welcome'), findsNothing);
    });

    testWidgets('the old "same" sentinel still asks for a mother tongue',
        (tester) async {
      final state = await _pump(
        tester,
        store: FakeStore(settings: {
          'use_own_key': true,
          'explanation_language': 'same',
        }),
      );

      // `same` never named a mother tongue, so it still has to be asked for.
      expect(state.hasProfile, isFalse);
      expect(find.text('Welcome'), findsOneWidget);
    });
  });

  group('credit mode', () {
    // The default store in these tests opts into own-key mode; a store with no
    // settings is a fresh install, which is metered.
    FakeStore meteredStore() => FakeStore(
          settings: {'native_language': 'tr', 'learning_language': 'fr'},
        );

    testWidgets('shows the balance and the tier chip', (tester) async {
      await _pump(tester, store: meteredStore(), backend: FakeBackend(balance: 7));

      expect(find.text('7'), findsOneWidget);
      expect(find.text('Quick check'), findsOneWidget);
      // No key prompt: the server holds the key in this mode.
      expect(find.text('Add your Anthropic API key'), findsNothing);
    });

    testWidgets('a check spends credits and updates the balance',
        (tester) async {
      final backend = FakeBackend(balance: 5);
      await _pump(tester, store: meteredStore(), backend: backend);

      await tester.enterText(
        find.byType(TextField).first,
        'Je suis alle au marche hier.',
      );
      await tester.pump();
      await tester.tap(find.text('Check my writing'));
      await tester.pumpAndSettle();

      expect(backend.checksRun, 1);
      expect(backend.lastTierId, 'quick');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('4'), findsOneWidget, reason: 'one credit spent');
    });

    testWidgets('an advanced check costs four credits', (tester) async {
      final backend = FakeBackend(balance: 100);
      await _pump(tester, store: meteredStore(), backend: backend);

      await tester.tap(find.text('Quick check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced check').last);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Bonjour.');
      await tester.pump();
      await tester.tap(find.text('Check my writing'));
      await tester.pumpAndSettle();

      expect(backend.lastTierId, 'advanced');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('96'), findsOneWidget);
    });

    testWidgets('a full report costs twenty-five credits', (tester) async {
      final backend = FakeBackend(balance: 100);
      await _pump(tester, store: meteredStore(), backend: backend);

      await tester.tap(find.text('Quick check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Full report').last);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Bonjour.');
      await tester.pump();
      await tester.tap(find.text('Check my writing'));
      await tester.pumpAndSettle();

      expect(backend.lastTierId, 'report');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('75'), findsOneWidget);
    });

    testWidgets('an empty balance offers a top-up instead of an error',
        (tester) async {
      final backend = FakeBackend(balance: 0)
        ..failWith = OutOfCreditsException(
          'You are out of credits.',
          balance: 0,
          required_: 1,
        );
      await _pump(tester, store: meteredStore(), backend: backend);

      await tester.enterText(find.byType(TextField).first, 'Bonjour.');
      await tester.pump();
      await tester.tap(find.text('Check my writing'));
      await tester.pumpAndSettle();

      expect(find.text('You are out of credits.'), findsOneWidget);
      expect(find.text('Get credits'), findsOneWidget);

      await tester.tap(find.text('Get credits'));
      await tester.pumpAndSettle();

      // The paywall now leads with plans and keeps packs as the overflow.
      expect(find.text('Your plan'), findsOneWidget);
      expect(find.text('Exam'), findsOneWidget);
      expect(find.text('Small top-up'), findsOneWidget);
    });

    testWidgets('warns when the text is over the word limit', (tester) async {
      await _pump(tester, store: meteredStore());

      await tester.enterText(
        find.byType(TextField).first,
        List.filled(700, 'mot').join(' '),
      );
      await tester.pump();

      expect(find.text('over the limit'), findsOneWidget);
    });

    testWidgets('settings hide the model picker in credit mode',
        (tester) async {
      await _pump(tester, store: meteredStore());

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Use my own Anthropic key'), findsOneWidget);
      expect(find.text('Credit balance'), findsOneWidget);
      // The tier decides the model when the server is paying.
      expect(find.text('Model'), findsNothing);
      // With the model tiles hidden and strict marking gone, the heading
      // would otherwise sit above an empty card.
      expect(find.text('Marking'), findsNothing);
    });
  });

  group('theme toggle', () {
    testWidgets('flips the app between light and dark', (tester) async {
      final store = FakeStore(settings: {
        'use_own_key': true,
        'native_language': 'tr',
        'learning_language': 'fr',
        'theme_mode': 'light',
      });
      final state = await _pump(tester, store: store);

      expect(state.themeMode, ThemeMode.light);
      expect(find.byTooltip('Switch to dark mode'), findsOneWidget);

      await tester.tap(find.byTooltip('Switch to dark mode'));
      await tester.pumpAndSettle();

      expect(state.themeMode, ThemeMode.dark);
      expect(
        find.byTooltip('Switch to light mode'),
        findsOneWidget,
        reason: 'the icon offers the next action, not the current state',
      );
    });

    testWidgets('remembers the choice for the next launch', (tester) async {
      final store = FakeStore(settings: {
        'use_own_key': true,
        'native_language': 'tr',
        'learning_language': 'fr',
        'theme_mode': 'light',
      });
      await _pump(tester, store: store);

      await tester.tap(find.byTooltip('Switch to dark mode'));
      await tester.pumpAndSettle();

      expect(store.settings['theme_mode'], 'dark');
    });

    testWidgets('a first tap from system always changes something',
        (tester) async {
      // No theme_mode saved, so the app is following the system, which the
      // test binding reports as light.
      final state = await _pump(tester);
      expect(state.themeMode, ThemeMode.system);

      await tester.tap(find.byTooltip('Switch to dark mode'));
      await tester.pumpAndSettle();

      expect(state.themeMode, ThemeMode.dark);
    });
  });

  group('deleting an account', () {
    FakeStore meteredStore() => FakeStore(
          settings: {'native_language': 'tr', 'learning_language': 'fr'},
        );

    testWidgets('is offered in settings, as both stores require',
        (tester) async {
      await _pump(tester, store: meteredStore(), backend: FakeBackend());

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Delete my account'), findsOneWidget);
    });

    testWidgets('asks first and does nothing when kept', (tester) async {
      final backend = FakeBackend(balance: 7);
      await _pump(tester, store: meteredStore(), backend: backend);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete my account'));
      await tester.pumpAndSettle();

      // The warning has to name what is actually lost.
      expect(find.textContaining('7 remaining credits'), findsOneWidget);

      await tester.tap(find.text('Keep my account'));
      await tester.pumpAndSettle();

      expect(backend.deleteCalls, 0, reason: 'nothing was deleted');
    });

    testWidgets('deletes and clears the saved checks', (tester) async {
      final backend = FakeBackend(balance: 7);
      final store = meteredStore();
      final state = await _pump(tester, store: store, backend: backend);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete my account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(backend.deleteCalls, 1);
      expect(state.history, isEmpty, reason: 'saved checks go with it');
      expect(
        store.sessionTokenClears,
        1,
        reason: 'the old token is a credential for an account that is gone',
      );
      // A fresh registration follows, so the app is usable straight away
      // rather than stranded without an account.
      expect(state.account, isNotNull);
    });
  });

  testWidgets('settings expose the model and key controls', (tester) async {
    await _pump(tester);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Key saved'), findsOneWidget);
    expect(find.text('Claude Opus 5'), findsNothing);
    expect(find.textContaining('Claude Opus 5'), findsWidgets);

    // Switching model rewrites the stored setting.
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Haiku 4.5'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Claude Haiku 4.5'), findsWidgets);
    expect(find.text('Not adjustable on Claude Haiku 4.5'), findsOneWidget);
  });
}
