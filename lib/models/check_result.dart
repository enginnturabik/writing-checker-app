import 'dart:convert';

/// One flagged span of writing plus the fix and the explanation behind it.
class Correction {
  Correction({
    required this.id,
    required this.original,
    required this.correction,
    required this.category,
    required this.severity,
    required this.explanation,
    required this.rule,
    required this.contextBefore,
    this.start,
    this.end,
    this.applied = false,
    this.dismissed = false,
  });

  final String id;
  final String original;
  final String correction;
  final String category;
  final String severity;
  final String explanation;
  final String rule;
  final String contextBefore;

  /// Character offsets into the original text, resolved locally by
  /// [CheckResult.locateSpans]. Null when the snippet could not be found.
  int? start;
  int? end;

  /// User state, persisted so a reopened report remembers what was handled.
  bool applied;
  bool dismissed;

  bool get isLocated => start != null && end != null;
  bool get isDeletion => correction.trim().isEmpty;

  factory Correction.fromJson(Map<String, dynamic> j, int index) => Correction(
        id: (j['id'] as String?)?.isNotEmpty == true ? j['id'] as String : 'c$index',
        original: (j['original'] ?? '').toString(),
        correction: (j['correction'] ?? '').toString(),
        category: normalizeCategory(j['category']?.toString()),
        severity: normalizeSeverity(j['severity']?.toString()),
        explanation: (j['explanation'] ?? '').toString(),
        rule: (j['rule'] ?? '').toString(),
        contextBefore: (j['context_before'] ?? '').toString(),
        applied: j['applied'] == true,
        dismissed: j['dismissed'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'original': original,
        'correction': correction,
        'category': category,
        'severity': severity,
        'explanation': explanation,
        'rule': rule,
        'context_before': contextBefore,
        'applied': applied,
        'dismissed': dismissed,
      };
}

String normalizeCategory(String? raw) {
  const allowed = {
    'grammar',
    'spelling',
    'punctuation',
    'vocabulary',
    'style',
    'register',
    'coherence',
    'other',
  };
  final v = (raw ?? '').toLowerCase().trim();
  return allowed.contains(v) ? v : 'other';
}

String normalizeSeverity(String? raw) {
  const allowed = {'minor', 'moderate', 'critical'};
  final v = (raw ?? '').toLowerCase().trim();
  return allowed.contains(v) ? v : 'minor';
}

/// A "you could say this instead" upgrade rather than an outright error.
class VocabSuggestion {
  VocabSuggestion({
    required this.original,
    required this.suggestion,
    required this.note,
  });

  final String original;
  final String suggestion;
  final String note;

  factory VocabSuggestion.fromJson(Map<String, dynamic> j) => VocabSuggestion(
        original: (j['original'] ?? '').toString(),
        suggestion: (j['suggestion'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'original': original,
        'suggestion': suggestion,
        'note': note,
      };
}

class Scores {
  Scores({
    required this.grammar,
    required this.vocabulary,
    required this.spelling,
    required this.coherence,
    required this.style,
    required this.overall,
  });

  final int grammar;
  final int vocabulary;
  final int spelling;
  final int coherence;
  final int style;
  final int overall;

  static int _clamp(dynamic v) {
    final n = v is num ? v.round() : int.tryParse('${v ?? ''}') ?? 0;
    return n.clamp(0, 100);
  }

  factory Scores.fromJson(Map<String, dynamic> j) => Scores(
        grammar: _clamp(j['grammar']),
        vocabulary: _clamp(j['vocabulary']),
        spelling: _clamp(j['spelling']),
        coherence: _clamp(j['coherence']),
        style: _clamp(j['style']),
        overall: _clamp(j['overall']),
      );

  Map<String, dynamic> toJson() => {
        'grammar': grammar,
        'vocabulary': vocabulary,
        'spelling': spelling,
        'coherence': coherence,
        'style': style,
        'overall': overall,
      };

  Map<String, int> get asMap => {
        'Grammar': grammar,
        'Vocabulary': vocabulary,
        'Spelling': spelling,
        'Coherence': coherence,
        'Style': style,
      };
}

/// Token spend for one check, feeding the running cost meter.
class TokenUsage {
  const TokenUsage({this.inputTokens = 0, this.outputTokens = 0});

  final int inputTokens;
  final int outputTokens;

  factory TokenUsage.fromJson(Map<String, dynamic> j) => TokenUsage(
        inputTokens: (j['input_tokens'] as num?)?.toInt() ?? 0,
        outputTokens: (j['output_tokens'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
      };

  TokenUsage merge(TokenUsage other) => TokenUsage(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
      );
}

/// The full report for one submission.
class CheckResult {
  CheckResult({
    required this.detectedLanguage,
    required this.languageCode,
    required this.cefrEstimate,
    required this.scores,
    required this.correctedText,
    required this.summary,
    required this.strengths,
    required this.priorities,
    required this.corrections,
    required this.vocabulary,
    required this.nextSteps,
    required this.wordCount,
    this.usage = const TokenUsage(),
    this.modelId = '',
  });

  final String detectedLanguage;
  final String languageCode;
  final String cefrEstimate;
  final Scores scores;
  final String correctedText;
  final String summary;
  final List<String> strengths;
  final List<String> priorities;
  final List<Correction> corrections;
  final List<VocabSuggestion> vocabulary;
  final List<String> nextSteps;
  final int wordCount;
  final TokenUsage usage;
  final String modelId;

  List<Correction> get active =>
      corrections.where((c) => !c.dismissed).toList(growable: false);

  Map<String, int> get countsByCategory {
    final out = <String, int>{};
    for (final c in active) {
      out[c.category] = (out[c.category] ?? 0) + 1;
    }
    return out;
  }

  static List<String> _stringList(dynamic v) => v is List
      ? v.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList()
      : const <String>[];

  factory CheckResult.fromJson(
    Map<String, dynamic> j, {
    TokenUsage usage = const TokenUsage(),
    String modelId = '',
  }) {
    final rawCorrections = (j['corrections'] as List?) ?? const [];
    return CheckResult(
      detectedLanguage: (j['detected_language'] ?? 'Unknown').toString(),
      languageCode: (j['language_code'] ?? '').toString(),
      cefrEstimate: (j['cefr_estimate'] ?? '-').toString(),
      scores: Scores.fromJson(
          (j['scores'] as Map?)?.cast<String, dynamic>() ?? const {}),
      correctedText: (j['corrected_text'] ?? '').toString(),
      summary: (j['summary'] ?? '').toString(),
      strengths: _stringList(j['strengths']),
      priorities: _stringList(j['priorities']),
      corrections: [
        for (var i = 0; i < rawCorrections.length; i++)
          Correction.fromJson(
              (rawCorrections[i] as Map).cast<String, dynamic>(), i),
      ],
      vocabulary: [
        for (final v in (j['vocabulary_upgrades'] as List?) ?? const [])
          VocabSuggestion.fromJson((v as Map).cast<String, dynamic>()),
      ],
      nextSteps: _stringList(j['next_steps']),
      wordCount: (j['word_count'] as num?)?.toInt() ?? 0,
      usage: usage,
      modelId: modelId,
    );
  }

  Map<String, dynamic> toJson() => {
        'detected_language': detectedLanguage,
        'language_code': languageCode,
        'cefr_estimate': cefrEstimate,
        'scores': scores.toJson(),
        'corrected_text': correctedText,
        'summary': summary,
        'strengths': strengths,
        'priorities': priorities,
        'corrections': corrections.map((c) => c.toJson()).toList(),
        'vocabulary_upgrades': vocabulary.map((v) => v.toJson()).toList(),
        'next_steps': nextSteps,
        'word_count': wordCount,
        'usage': usage.toJson(),
        'model_id': modelId,
      };

  static CheckResult decode(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return CheckResult.fromJson(
      j,
      usage: TokenUsage.fromJson(
          (j['usage'] as Map?)?.cast<String, dynamic>() ?? const {}),
      modelId: (j['model_id'] ?? '').toString(),
    );
  }

  /// Resolves each correction snippet to character offsets in [source].
  ///
  /// The model returns snippets rather than indices, because LLM-reported
  /// character offsets are unreliable. `context_before` disambiguates repeated
  /// snippets, and every match consumes its range so two corrections can never
  /// claim the same characters.
  void locateSpans(String source) {
    final taken = <_Range>[];

    bool free(int s, int e) => !taken.any((r) => s < r.end && e > r.start);

    for (final c in corrections) {
      final needle = c.original;
      if (needle.isEmpty) continue;

      // Preferred anchor: the snippet sitting right after its stated context.
      var resolved = -1;
      if (c.contextBefore.isNotEmpty) {
        final anchor = source.indexOf(c.contextBefore + needle);
        if (anchor >= 0) {
          final s = anchor + c.contextBefore.length;
          if (free(s, s + needle.length)) resolved = s;
        }
      }

      // Otherwise the first occurrence nobody has claimed yet.
      if (resolved < 0) {
        var from = 0;
        while (true) {
          final idx = source.indexOf(needle, from);
          if (idx < 0) break;
          if (free(idx, idx + needle.length)) {
            resolved = idx;
            break;
          }
          from = idx + 1;
        }
      }

      if (resolved >= 0) {
        c.start = resolved;
        c.end = resolved + needle.length;
        taken.add(_Range(c.start!, c.end!));
      } else {
        c.start = null;
        c.end = null;
      }
    }
  }

  /// Rebuilds [source] with every accepted correction substituted in.
  String applyAccepted(String source) {
    final accepted = corrections
        .where((c) => c.applied && !c.dismissed && c.isLocated)
        .toList()
      ..sort((a, b) => a.start!.compareTo(b.start!));
    if (accepted.isEmpty) return source;

    final buf = StringBuffer();
    var cursor = 0;
    for (final c in accepted) {
      if (c.start! < cursor) continue;
      buf.write(source.substring(cursor, c.start!));
      buf.write(c.correction);
      cursor = c.end!;
    }
    buf.write(source.substring(cursor));
    return buf.toString();
  }
}

class _Range {
  const _Range(this.start, this.end);
  final int start;
  final int end;
}
