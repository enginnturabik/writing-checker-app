import 'dart:convert';
import 'dart:typed_data';

/// How the submitted material reaches the API.
enum AttachmentKind {
  /// Plain text extracted on-device (typed, .txt, .md, .docx).
  text,

  /// Sent as a base64 `image` block so the model reads handwriting or photos.
  image,

  /// Sent as a base64 `document` block; the API parses the PDF natively.
  pdf,
}

/// A file the learner attached, already loaded into memory.
class Attachment {
  const Attachment({
    required this.kind,
    required this.fileName,
    required this.bytes,
    required this.mediaType,
  });

  final AttachmentKind kind;
  final String fileName;
  final Uint8List bytes;
  final String mediaType;

  String get base64Data => base64Encode(bytes);

  /// Rough size label for the attachment chip.
  String get sizeLabel {
    final kb = bytes.length / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}

/// Everything the user chose before pressing Check.
class CheckRequest {
  const CheckRequest({
    required this.text,
    required this.learningLanguage,
    required this.nativeLanguage,
    required this.modelId,
    required this.effort,
    this.attachment,
  });

  /// The typed or extracted text. Empty when the content is only an
  /// attachment (a photo of handwriting, or a PDF).
  final String text;

  /// The language being learned, which the submission should be written in.
  /// `auto` leaves it to be detected.
  final String learningLanguage;

  /// The learner's mother tongue. Feedback is written in this language, and it
  /// lets the marking name mistakes that come from their first language.
  final String nativeLanguage;

  final String modelId;
  final String effort;

  final Attachment? attachment;

  bool get hasAttachment => attachment != null;

  int get wordCount =>
      text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;
}
