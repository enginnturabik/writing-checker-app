import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../models/check_request.dart';
import '../models/check_result.dart';
import 'prompt_builder.dart';

/// A failure worth showing the user, with a message written for them rather
/// than for a log file.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.type});

  final String message;
  final int? statusCode;
  final String? type;

  bool get isAuthError => statusCode == 401 || statusCode == 403;
  bool get isRateLimited => statusCode == 429;
  bool get isCredits => type == 'invalid_request_error' &&
      message.toLowerCase().contains('credit');

  @override
  String toString() => message;
}

/// Progress ticks emitted while a check is running, so the UI can show
/// something honest instead of a spinner that never moves.
class CheckProgress {
  const CheckProgress({required this.charsReceived, required this.stage});

  final int charsReceived;
  final String stage;
}

/// Talks to the Messages API over raw HTTP.
///
/// Dart has no official Anthropic SDK, so this speaks the REST API directly:
/// `POST /v1/messages` with `stream: true`, reading Server-Sent Events. The
/// answer is constrained by a JSON schema through `output_config.format`, so
/// the accumulated text is guaranteed to parse.
class AnthropicClient {
  AnthropicClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  static const _endpoint = 'https://api.anthropic.com/v1/messages';
  static const _apiVersion = '2023-06-01';

  /// Streaming keeps long reports away from request timeouts, so the ceiling
  /// only needs to be under the smallest model's output cap. Haiku 4.5 tops out
  /// at 64K; Opus and Sonnet allow 128K but a marking report never approaches
  /// either. This is a ceiling, not a spend - unused headroom costs nothing.
  static const _maxTokens = 64000;

  final http.Client _http;
  bool _cancelled = false;

  void cancel() => _cancelled = true;
  void dispose() => _http.close();

  Map<String, String> _headers(String apiKey) => {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': _apiVersion,
        // Required for the Flutter web build; ignored on mobile and desktop.
        'anthropic-dangerous-direct-browser-access': 'true',
      };

  Map<String, dynamic> buildPayload(CheckRequest req) {
    final content = <Map<String, dynamic>>[];

    // Attachments go first: the API reads a document or image better when it
    // precedes the instructions that refer to it.
    final att = req.attachment;
    if (att != null) {
      switch (att.kind) {
        case AttachmentKind.image:
          content.add({
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': att.mediaType,
              'data': att.base64Data,
            },
          });
        case AttachmentKind.pdf:
          content.add({
            'type': 'document',
            'source': {
              'type': 'base64',
              'media_type': 'application/pdf',
              'data': att.base64Data,
            },
          });
        case AttachmentKind.text:
          break;
      }
    }

    content.add({
      'type': 'text',
      'text': PromptBuilder.buildUserInstructions(req),
    });

    final payload = <String, dynamic>{
      'model': req.modelId,
      'max_tokens': _maxTokens,
      'stream': true,
      // The system prompt never varies, so caching it keeps repeat checks
      // cheaper. Everything per-submission lives in the user message.
      'system': [
        {
          'type': 'text',
          'text': PromptBuilder.systemPrompt,
          'cache_control': {'type': 'ephemeral'},
        }
      ],
      'messages': [
        {'role': 'user', 'content': content}
      ],
    };

    final outputConfig = <String, dynamic>{
      'format': {
        'type': 'json_schema',
        'schema': PromptBuilder.responseSchema(),
      },
    };
    // Effort is rejected by the older Haiku tier, so only send it where the
    // model actually supports it.
    if (modelById(req.modelId).supportsEffort) {
      outputConfig['effort'] = req.effort;
    }
    payload['output_config'] = outputConfig;

    return payload;
  }

  /// Runs one check. Emits progress through [onProgress] while streaming.
  Future<CheckResult> check(
    CheckRequest req, {
    required String apiKey,
    void Function(CheckProgress)? onProgress,
  }) async {
    _cancelled = false;

    if (apiKey.trim().isEmpty) {
      throw ApiException(
        'No API key set. Add your Anthropic key in Settings to start checking.',
      );
    }

    final request = http.Request('POST', Uri.parse(_endpoint))
      ..headers.addAll(_headers(apiKey.trim()))
      ..body = jsonEncode(buildPayload(req));
    request.encoding = utf8;

    http.StreamedResponse response;
    try {
      response = await _http.send(request).timeout(const Duration(minutes: 5));
    } on TimeoutException {
      throw ApiException(
          'The check took too long and was stopped. Try a shorter text.');
    } catch (e) {
      throw ApiException(
        'Could not reach the Anthropic API. Check your internet connection.',
      );
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw _errorFor(response.statusCode, body);
    }

    onProgress?.call(
        const CheckProgress(charsReceived: 0, stage: 'Reading your writing'));

    final buffer = StringBuffer();
    var inputTokens = 0;
    var outputTokens = 0;
    var cacheRead = 0;
    String? stopReason;
    String? streamError;

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (_cancelled) break;
      if (!line.startsWith('data:')) continue;

      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;

      Map<String, dynamic> event;
      try {
        event = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      switch (event['type']) {
        case 'message_start':
          final usage = (event['message'] as Map?)?['usage'] as Map?;
          inputTokens = (usage?['input_tokens'] as num?)?.toInt() ?? 0;
          cacheRead = (usage?['cache_read_input_tokens'] as num?)?.toInt() ?? 0;
          onProgress?.call(const CheckProgress(
              charsReceived: 0, stage: 'Marking your text'));
        case 'content_block_delta':
          final delta = event['delta'] as Map?;
          if (delta?['type'] == 'text_delta') {
            buffer.write(delta!['text']);
            onProgress?.call(CheckProgress(
              charsReceived: buffer.length,
              stage: 'Writing feedback',
            ));
          }
        case 'message_delta':
          final usage = event['usage'] as Map?;
          outputTokens = (usage?['output_tokens'] as num?)?.toInt() ?? 0;
          stopReason =
              ((event['delta'] as Map?)?['stop_reason'] as String?) ?? stopReason;
        case 'error':
          final err = event['error'] as Map?;
          streamError = (err?['message'] ?? 'The API reported an error.').toString();
      }
    }

    if (_cancelled) {
      throw ApiException('Check cancelled.');
    }
    if (streamError != null) {
      throw ApiException(streamError);
    }
    if (stopReason == 'refusal') {
      throw ApiException(
        'The model declined to mark this submission. Try rephrasing or '
        'removing sensitive content.',
      );
    }
    if (stopReason == 'max_tokens') {
      throw ApiException(
        'The text is too long to mark in one pass. Split it into shorter '
        'sections and check them separately.',
      );
    }

    final raw = buffer.toString().trim();
    if (raw.isEmpty) {
      throw ApiException('The API returned an empty response. Please retry.');
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      // The schema makes this near-impossible, but a truncated stream would
      // land here, and a crash is a worse outcome than a clear message.
      throw ApiException(
          'The feedback came back malformed. Please run the check again.');
    }

    final result = CheckResult.fromJson(
      json,
      usage: TokenUsage(
        // Cached prefix tokens are billed at a discount but still count as
        // input; keeping them in the total keeps the cost meter conservative.
        inputTokens: inputTokens + cacheRead,
        outputTokens: outputTokens,
      ),
      modelId: req.modelId,
    );

    // Highlights are resolved against whatever text we actually have. For a
    // photo or PDF the model transcribed it, so there is nothing to anchor to
    // locally and the report falls back to the list view.
    if (req.text.trim().isNotEmpty) {
      result.locateSpans(req.text);
    }
    return result;
  }

  ApiException _errorFor(int status, String body) {
    String? type;
    String message;
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      final err = (j['error'] as Map?)?.cast<String, dynamic>();
      type = err?['type'] as String?;
      message = (err?['message'] ?? body).toString();
    } catch (_) {
      message = body.isEmpty ? 'HTTP $status' : body;
    }

    final friendly = switch (status) {
      401 || 403 =>
        'Your API key was rejected. Check it in Settings, or create a new one '
            'at console.anthropic.com.',
      400 when message.toLowerCase().contains('credit') =>
        'Your Anthropic account is out of credit. Top it up at '
            'console.anthropic.com/settings/billing.',
      400 => 'The request was rejected: $message',
      404 => 'That model is not available on your account. Pick another one '
          'in Settings.',
      413 => 'The attachment is too large. Try a smaller file or fewer pages.',
      429 => 'Rate limit reached. Wait a few seconds and try again.',
      529 => 'The API is overloaded right now. Try again shortly.',
      _ when status >= 500 =>
        'The API had a server error ($status). Try again in a moment.',
      _ => message,
    };

    return ApiException(friendly, statusCode: status, type: type);
  }

  /// Rough pre-flight estimate so the user sees a price before spending.
  /// Around four characters per token holds well enough across languages for
  /// an estimate; the real figure comes back with the response.
  static ({int input, int output, double cost}) estimate({
    required String text,
    required String modelId,
    bool hasAttachment = false,
  }) {
    final systemTokens = PromptBuilder.systemPrompt.length ~/ 4;
    final textTokens = text.length ~/ 4;
    final attachmentTokens = hasAttachment ? 1600 : 0;
    final input = systemTokens + textTokens + attachmentTokens + 400;

    // The report echoes the corrected text and adds explanations, so output
    // scales with the submission rather than being flat.
    final output = 700 + (textTokens * 2.2).round();

    return (
      input: input,
      output: output,
      cost: modelById(modelId)
          .costFor(inputTokens: input, outputTokens: output),
    );
  }
}
