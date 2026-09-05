/// Static configuration: models, pricing, supported languages, error taxonomy.
library;

class ClaudeModel {
  const ClaudeModel({
    required this.id,
    required this.label,
    required this.blurb,
    required this.inputPerMTok,
    required this.outputPerMTok,
    this.supportsEffort = true,
  });

  final String id;
  final String label;
  final String blurb;
  final double inputPerMTok;
  final double outputPerMTok;

  /// `output_config.effort` is rejected by older tiers such as Haiku 4.5.
  final bool supportsEffort;

  /// Cost in USD for a single request with the given token counts.
  double costFor({required int inputTokens, required int outputTokens}) =>
      (inputTokens / 1000000) * inputPerMTok +
      (outputTokens / 1000000) * outputPerMTok;
}

/// Ordered cheapest-last so the picker reads top-down as "best -> cheapest".
const kModels = <ClaudeModel>[
  ClaudeModel(
    id: 'claude-opus-5',
    label: 'Claude Opus 5',
    blurb: 'Best feedback quality. Catches nuance, register and idiom errors.',
    inputPerMTok: 5.00,
    outputPerMTok: 25.00,
  ),
  ClaudeModel(
    id: 'claude-sonnet-5',
    label: 'Claude Sonnet 5',
    blurb: 'Strong all-rounder at under half the cost of Opus.',
    inputPerMTok: 2.00,
    outputPerMTok: 10.00,
  ),
  ClaudeModel(
    id: 'claude-haiku-4-5',
    label: 'Claude Haiku 4.5',
    blurb: 'Cheapest and fastest. Good for spelling and basic grammar.',
    inputPerMTok: 1.00,
    outputPerMTok: 5.00,
    supportsEffort: false,
  ),
];

ClaudeModel modelById(String id) =>
    kModels.firstWhere((m) => m.id == id, orElse: () => kModels.first);

const kDefaultModelId = 'claude-opus-5';

/// Effort controls how deeply the model reasons. Lower = cheaper and faster.
const kEffortLevels = <String, String>{
  'low': 'Quick pass — spelling and obvious grammar. Cheapest.',
  'medium': 'Balanced. Recommended for everyday practice.',
  'high': 'Thorough. Best for exam prep and long essays.',
  'xhigh': 'Deeper still. Worth it on long or difficult pieces.',
  'max': 'No ceiling on reasoning. Slowest and most expensive.',
};

const kDefaultEffort = 'medium';

class LanguageOption {
  const LanguageOption(this.code, this.name, this.flag);
  final String code;
  final String name;
  final String flag;
}

/// Every language the app knows by name. `auto` is only ever offered as a
/// learning language, never as a native one: the whole point of knowing the
/// learner's first language is that we can name it.
const kLanguages = <LanguageOption>[
  LanguageOption('auto', 'Detect automatically', '🌐'),
  LanguageOption('en', 'English', '🇬🇧'),
  LanguageOption('fr', 'French', '🇫🇷'),
  LanguageOption('de', 'German', '🇩🇪'),
  LanguageOption('es', 'Spanish', '🇪🇸'),
  LanguageOption('it', 'Italian', '🇮🇹'),
  LanguageOption('pt', 'Portuguese', '🇵🇹'),
  LanguageOption('nl', 'Dutch', '🇳🇱'),
  LanguageOption('tr', 'Turkish', '🇹🇷'),
  LanguageOption('ru', 'Russian', '🇷🇺'),
  LanguageOption('pl', 'Polish', '🇵🇱'),
  LanguageOption('sv', 'Swedish', '🇸🇪'),
  LanguageOption('ar', 'Arabic', '🇸🇦'),
  LanguageOption('zh', 'Chinese', '🇨🇳'),
  LanguageOption('ja', 'Japanese', '🇯🇵'),
  LanguageOption('ko', 'Korean', '🇰🇷'),
  LanguageOption('hi', 'Hindi', '🇮🇳'),
  LanguageOption('id', 'Indonesian', '🇮🇩'),
  LanguageOption('uk', 'Ukrainian', '🇺🇦'),
  LanguageOption('el', 'Greek', '🇬🇷'),
];

/// Languages offered as a mother tongue. Same list, without `auto`.
final kNativeLanguages = List<LanguageOption>.unmodifiable(
  kLanguages.where((l) => l.code != 'auto'),
);

/// Languages offered as the one being learned.
const kLearningLanguages = kLanguages;

LanguageOption languageOption(String code) => kLanguages.firstWhere(
      (l) => l.code == code,
      orElse: () => const LanguageOption('auto', 'Detect automatically', '🌐'),
    );

String languageName(String code) => kLanguages
    .firstWhere((l) => l.code == code, orElse: () => const LanguageOption('auto', 'Unknown', '🌐'))
    .name;

/// Error taxonomy. Keys must match the JSON schema enum exactly.
const kCategories = <String, String>{
  'grammar': 'Grammar',
  'spelling': 'Spelling',
  'punctuation': 'Punctuation',
  'vocabulary': 'Word choice',
  'style': 'Style',
  'register': 'Register',
  'coherence': 'Coherence',
  'other': 'Other',
};

const kSeverities = <String>['minor', 'moderate', 'critical'];
