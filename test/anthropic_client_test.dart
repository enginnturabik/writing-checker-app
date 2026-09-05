import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_checker/models/check_request.dart';
import 'package:writing_checker/services/anthropic_client.dart';
import 'package:writing_checker/services/document_loader.dart';

CheckRequest _request({
  String text = 'Je suis alle au marche.',
  String modelId = 'claude-opus-5',
  String learningLanguage = 'fr',
  String nativeLanguage = 'tr',
  Attachment? attachment,
}) =>
    CheckRequest(
      text: text,
      learningLanguage: learningLanguage,
      nativeLanguage: nativeLanguage,
      modelId: modelId,
      effort: 'medium',
      attachment: attachment,
    );

void main() {
  final client = AnthropicClient();

  group('buildPayload', () {
    test('asks for a schema-constrained streaming response', () {
      final p = client.buildPayload(_request());

      expect(p['model'], 'claude-opus-5');
      expect(p['stream'], isTrue);
      expect(p['output_config']['format']['type'], 'json_schema');
      expect(
        p['output_config']['format']['schema']['additionalProperties'],
        isFalse,
      );
    });

    test('caches the system prompt so repeat checks stay cheap', () {
      final p = client.buildPayload(_request());
      final system = (p['system'] as List).single as Map;

      expect(system['cache_control'], {'type': 'ephemeral'});
    });

    test('sends effort only to models that accept it', () {
      final opus = client.buildPayload(_request());
      final haiku = client.buildPayload(_request(modelId: 'claude-haiku-4-5'));

      expect(opus['output_config'].containsKey('effort'), isTrue);
      // Haiku 4.5 rejects output_config.effort with a 400.
      expect(haiku['output_config'].containsKey('effort'), isFalse);
    });

    test('puts an image attachment before the instructions', () {
      final p = client.buildPayload(_request(
        text: '',
        attachment: Attachment(
          kind: AttachmentKind.image,
          fileName: 'homework.jpg',
          bytes: Uint8List.fromList([1, 2, 3]),
          mediaType: 'image/jpeg',
        ),
      ));

      final content = (p['messages'] as List).single['content'] as List;
      expect(content.first['type'], 'image');
      expect(content.first['source']['media_type'], 'image/jpeg');
      expect(content.last['type'], 'text');
    });

    test('sends a PDF as a document block', () {
      final p = client.buildPayload(_request(
        text: '',
        attachment: Attachment(
          kind: AttachmentKind.pdf,
          fileName: 'essay.pdf',
          bytes: Uint8List.fromList([37, 80, 68, 70]),
          mediaType: 'application/pdf',
        ),
      ));

      final content = (p['messages'] as List).single['content'] as List;
      expect(content.first['type'], 'document');
      expect(content.first['source']['media_type'], 'application/pdf');
    });

    test('carries the submission and the brief into the user turn', () {
      final p = client.buildPayload(_request());
      final content = (p['messages'] as List).single['content'] as List;
      final text = content.last['text'] as String;

      expect(text, contains('Je suis alle au marche.'));
      expect(text, contains('French'));
    });
  });

  group('learner profile in the brief', () {
    String briefFor(CheckRequest request) {
      final content =
          (client.buildPayload(request)['messages'] as List).single['content']
              as List;
      return content.last['text'] as String;
    }

    test('names both languages', () {
      final text = briefFor(_request());

      expect(text, contains('native speaker of Turkish'));
      expect(text, contains('learning French'));
    });

    test('asks for feedback in the native language by default', () {
      final text = briefFor(_request());

      expect(text, contains('next step in Turkish'));
      // The distinctive value of knowing the mother tongue.
      expect(text, contains('Turkish speakers typically make'));
    });

    test('does not ask the learner for a level or a text type', () {
      final text = briefFor(_request());

      expect(text, contains('Level: unknown'));
      expect(text, isNot(contains('Text type')));
      expect(text, isNot(contains('Strict marking')));
    });

    test('still names the native language when the target is auto-detected',
        () {
      final text = briefFor(_request(learningLanguage: 'auto'));

      expect(text, contains('native speaker of Turkish'));
      expect(text, contains('detect from the text'));
    });

    test('is valid JSON end to end', () {
      expect(
        () => jsonEncode(client.buildPayload(_request())),
        returnsNormally,
      );
    });
  });

  group('estimate', () {
    test('grows with the length of the text', () {
      final short = AnthropicClient.estimate(
        text: 'Bonjour.',
        modelId: 'claude-opus-5',
      );
      final long = AnthropicClient.estimate(
        text: 'Bonjour. ' * 400,
        modelId: 'claude-opus-5',
      );

      expect(long.cost, greaterThan(short.cost));
    });

    test('ranks the cheap model below the expensive one', () {
      const text = 'Une petite dissertation sur les vacances.';
      final opus =
          AnthropicClient.estimate(text: text, modelId: 'claude-opus-5');
      final haiku =
          AnthropicClient.estimate(text: text, modelId: 'claude-haiku-4-5');

      expect(haiku.cost, lessThan(opus.cost));
    });
  });

  group('docx extraction', () {
    test('keeps paragraphs and drops markup', () {
      // Minimal WordprocessingML body, the shape the real file uses.
      const xml = '<w:document><w:body>'
          '<w:p><w:r><w:t>Premiere ligne</w:t></w:r></w:p>'
          '<w:p><w:r><w:t>Deuxieme &amp; derniere</w:t></w:r></w:p>'
          '</w:body></w:document>';

      final text = _extractFromFakeDocx(xml);

      expect(text, 'Premiere ligne\nDeuxieme & derniere');
    });
  });
}

/// Builds a one-entry zip containing `word/document.xml` and runs the
/// extractor over it, which is exactly what a picked .docx goes through.
String _extractFromFakeDocx(String documentXml) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        'word/document.xml',
        Uint8List.fromList(utf8.encode(documentXml)),
      ),
    );
  final zipped = ZipEncoder().encode(archive);
  return DocumentLoader.extractDocx(Uint8List.fromList(zipped));
}
