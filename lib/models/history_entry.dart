import 'check_result.dart';

/// One saved check: what was submitted, and what came back.
class HistoryEntry {
  HistoryEntry({
    required this.id,
    required this.createdAt,
    required this.title,
    required this.sourceText,
    required this.result,
    required this.targetLanguage,
  });

  final String id;
  final DateTime createdAt;
  final String title;
  final String sourceText;
  final CheckResult result;
  final String targetLanguage;

  /// First line of the submission, trimmed to fit a list tile.
  static String titleFrom(String text, String fallback) {
    final firstLine = text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) return fallback;
    return firstLine.length <= 60 ? firstLine : '${firstLine.substring(0, 57)}...';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'created_at': createdAt.toIso8601String(),
        'title': title,
        'source_text': sourceText,
        'target_language': targetLanguage,
        'result': result.toJson(),
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) {
    final resultJson = (j['result'] as Map).cast<String, dynamic>();
    final result = CheckResult.fromJson(
      resultJson,
      usage: TokenUsage.fromJson(
          (resultJson['usage'] as Map?)?.cast<String, dynamic>() ?? const {}),
      modelId: (resultJson['model_id'] ?? '').toString(),
    );
    final source = (j['source_text'] ?? '').toString();
    result.locateSpans(source);
    return HistoryEntry(
      id: (j['id'] ?? '').toString(),
      createdAt:
          DateTime.tryParse((j['created_at'] ?? '').toString()) ?? DateTime.now(),
      title: (j['title'] ?? 'Untitled').toString(),
      sourceText: source,
      result: result,
      targetLanguage: (j['target_language'] ?? 'auto').toString(),
    );
  }
}
