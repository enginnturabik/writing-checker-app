/// A credit pack as the server defines it. The app never decides prices or
/// credit amounts, it only displays what the server sends.
class CreditProduct {
  const CreditProduct({
    required this.id,
    required this.credits,
    required this.priceUsd,
    required this.label,
  });

  final String id;
  final int credits;
  final double priceUsd;
  final String label;

  factory CreditProduct.fromJson(Map<String, dynamic> j) => CreditProduct(
        id: (j['id'] ?? '').toString(),
        credits: (j['credits'] as num?)?.toInt() ?? 0,
        priceUsd: (j['priceUsd'] as num?)?.toDouble() ?? 0,
        label: (j['label'] ?? '').toString(),
      );

  /// Cost per check in this pack, for the "best value" hint.
  double get perCheckUsd => credits == 0 ? 0 : priceUsd / credits;
}

/// How thorough a check is, and what it costs in credits.
class CheckTier {
  const CheckTier({
    required this.id,
    required this.credits,
    required this.attachmentSurcharge,
    required this.label,
    required this.description,
  });

  final String id;
  final int credits;
  final int attachmentSurcharge;
  final String label;
  final String description;

  int priceFor({required bool hasAttachment}) =>
      credits + (hasAttachment ? attachmentSurcharge : 0);

  factory CheckTier.fromJson(Map<String, dynamic> j) => CheckTier(
        id: (j['id'] ?? 'quick').toString(),
        credits: (j['credits'] as num?)?.toInt() ?? 1,
        attachmentSurcharge: (j['attachmentSurcharge'] as num?)?.toInt() ?? 0,
        label: (j['label'] ?? 'Check').toString(),
        description: (j['description'] ?? '').toString(),
      );

  /// Shown only until the server's own catalogue arrives. The server is the
  /// authority on what a check costs; these keep the picker usable offline.
  static const fallbackQuick = CheckTier(
    id: 'quick',
    credits: 1,
    attachmentSurcharge: 1,
    label: 'Quick check',
    description: 'Spelling, grammar and word choice, each mistake explained.',
  );

  static const fallbackAdvanced = CheckTier(
    id: 'advanced',
    credits: 4,
    attachmentSurcharge: 1,
    label: 'Advanced check',
    description:
        'Adds phrasing, register and the mistakes your first language causes.',
  );

  static const fallbackReport = CheckTier(
    id: 'report',
    credits: 25,
    attachmentSurcharge: 2,
    label: 'Full report',
    description:
        'Exam-level marking: structure, idiom, a model rewrite and what to '
        'study next.',
  );

  static const fallbacks = [fallbackQuick, fallbackAdvanced, fallbackReport];
}


/// A subscription plan as the server defines it. Like every other price in
/// this file, the app displays it and never decides it.
class SubscriptionPlan {
  const SubscriptionPlan({
    required this.id,
    required this.productId,
    required this.creditsPerPeriod,
    required this.period,
    required this.priceUsd,
    required this.label,
    required this.description,
  });

  final String id;

  /// Null on the free plan, which is granted rather than bought.
  final String? productId;
  final int creditsPerPeriod;

  /// `week` or `month`.
  final String period;
  final double priceUsd;
  final String label;

  /// Written for someone who has never heard of a token. This is the line the
  /// paywall shows, so it says "10 full reports a month", not "250 credits".
  final String description;

  bool get isFree => productId == null;

  factory SubscriptionPlan.fromJson(Map<String, dynamic> j) => SubscriptionPlan(
        id: (j['id'] ?? '').toString(),
        productId: j['productId'] as String?,
        creditsPerPeriod: (j['creditsPerPeriod'] as num?)?.toInt() ?? 0,
        period: (j['period'] ?? 'month').toString(),
        priceUsd: (j['priceUsd'] as num?)?.toDouble() ?? 0,
        label: (j['label'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
      );
}

/// What the user is currently entitled to. Falls back to the free plan on its
/// own once a paid period lapses, so the app never has to handle "expired" as
/// a separate state.
class Entitlement {
  const Entitlement({
    required this.planId,
    required this.label,
    required this.status,
    required this.autoRenewing,
    required this.creditsPerPeriod,
    required this.description,
    this.expiresAt,
  });

  final String planId;
  final String label;

  /// `active`, `grace` or `expired`.
  final String status;
  final bool autoRenewing;
  final int creditsPerPeriod;
  final String description;
  final DateTime? expiresAt;

  bool get isFree => planId == 'free';

  /// True while the store is retrying a failed payment. Access continues, but
  /// it is worth telling the user before it lapses.
  bool get needsAttention => status == 'grace';

  static const free = Entitlement(
    planId: 'free',
    label: 'Free',
    status: 'expired',
    autoRenewing: false,
    creditsPerPeriod: 5,
    description: '5 quick checks every week, or one advanced check.',
  );

  factory Entitlement.fromJson(Map<String, dynamic> j) => Entitlement(
        planId: (j['planId'] ?? 'free').toString(),
        label: (j['label'] ?? 'Free').toString(),
        status: (j['status'] ?? 'expired').toString(),
        autoRenewing: j['autoRenewing'] == true,
        creditsPerPeriod: (j['creditsPerPeriod'] as num?)?.toInt() ?? 0,
        description: (j['description'] ?? '').toString(),
        expiresAt: (j['expiresAt'] as num?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((j['expiresAt'] as num).toInt()),
      );
}

/// Submission limits, so the app can warn before the server rejects.
class AccountLimits {
  const AccountLimits({
    required this.maxWordsStandard,
    required this.maxWordsDeep,
    required this.maxAttachmentMb,
  });

  final int maxWordsStandard;
  final int maxWordsDeep;
  final double maxAttachmentMb;

  int maxWordsFor(String tierId) =>
      tierId == 'report' ? maxWordsDeep : maxWordsStandard;

  factory AccountLimits.fromJson(Map<String, dynamic> j) => AccountLimits(
        maxWordsStandard: (j['maxWordsStandard'] as num?)?.toInt() ?? 600,
        maxWordsDeep: (j['maxWordsDeep'] as num?)?.toInt() ?? 1500,
        maxAttachmentMb: (j['maxAttachmentMb'] as num?)?.toDouble() ?? 6,
      );

  static const fallback = AccountLimits(
    maxWordsStandard: 600,
    maxWordsDeep: 1500,
    maxAttachmentMb: 6,
  );
}

/// A linked sign-in, when the user has one.
class LinkedIdentity {
  const LinkedIdentity({required this.provider, required this.email});

  final String provider;
  final String? email;

  String get label => switch (provider) {
        'google' => 'Google',
        'apple' => 'Apple',
        _ => provider,
      };

  static LinkedIdentity? fromJson(Map<String, dynamic>? j) => j == null
      ? null
      : LinkedIdentity(
          provider: (j['provider'] ?? '').toString(),
          email: j['email'] as String?,
        );
}

/// The device's account, its balance and the catalogue it was given.
class Account {
  const Account({
    required this.token,
    required this.userId,
    required this.balance,
    required this.products,
    required this.plans,
    required this.tiers,
    required this.limits,
    required this.entitlement,
    this.identity,
  });

  final String token;
  final String userId;
  final int balance;
  final List<CreditProduct> products;
  final List<SubscriptionPlan> plans;
  final List<CheckTier> tiers;
  final AccountLimits limits;
  final Entitlement entitlement;

  /// The plans worth showing on the paywall: everything the user can buy.
  List<SubscriptionPlan> get purchasablePlans =>
      plans.where((p) => !p.isFree).toList();

  /// Null while the account is anonymous, which is the state credits can be
  /// lost from if the app is reinstalled.
  final LinkedIdentity? identity;

  bool get isSignedIn => identity != null;

  Account copyWith({
    int? balance,
    String? token,
    LinkedIdentity? identity,
    Entitlement? entitlement,
  }) =>
      Account(
        token: token ?? this.token,
        userId: userId,
        balance: balance ?? this.balance,
        products: products,
        plans: plans,
        tiers: tiers,
        limits: limits,
        entitlement: entitlement ?? this.entitlement,
        identity: identity ?? this.identity,
      );

  factory Account.fromJson(Map<String, dynamic> j, {String? token}) => Account(
        token: (token ?? j['token'] ?? '').toString(),
        userId: (j['userId'] ?? '').toString(),
        balance: (j['balance'] as num?)?.toInt() ?? 0,
        products: [
          for (final p in (j['products'] as List?) ?? const [])
            CreditProduct.fromJson((p as Map).cast<String, dynamic>()),
        ],
        plans: [
          for (final p in (j['plans'] as List?) ?? const [])
            SubscriptionPlan.fromJson((p as Map).cast<String, dynamic>()),
        ],
        tiers: [
          for (final t in (j['tiers'] as List?) ?? const [])
            CheckTier.fromJson((t as Map).cast<String, dynamic>()),
        ],
        limits: AccountLimits.fromJson(
          (j['limits'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        entitlement: (j['entitlement'] as Map?) == null
            ? Entitlement.free
            : Entitlement.fromJson(
                (j['entitlement'] as Map).cast<String, dynamic>(),
              ),
        identity: LinkedIdentity.fromJson(
          (j['identity'] as Map?)?.cast<String, dynamic>(),
        ),
      );
}
