import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../models/check_request.dart';

/// What came back from a picker: either text we extracted on-device, or a file
/// to hand to the API as an image or PDF block.
class LoadedDocument {
  const LoadedDocument({this.text, this.attachment});

  final String? text;
  final Attachment? attachment;

  bool get isEmpty => (text == null || text!.trim().isEmpty) && attachment == null;
}

class DocumentLoadException implements Exception {
  DocumentLoadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns files and photos into something checkable.
///
/// Text formats are extracted locally so nothing unnecessary is uploaded.
/// PDFs and images go to the API untouched, because the model reads both
/// natively and does a far better job of a photographed page than any
/// on-device OCR would.
class DocumentLoader {
  static const _maxBytes = 12 * 1024 * 1024;

  static const textExtensions = {'txt', 'md', 'text', 'rtf', 'csv'};
  static const imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif'};

  final ImagePicker _imagePicker = ImagePicker();

  /// Opens the system file browser for any supported document type.
  Future<LoadedDocument?> pickFile() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: [
        ...textExtensions,
        ...imageExtensions,
        'pdf',
        'docx',
      ],
    );
    if (picked == null) return null;

    final Uint8List bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (_) {
      throw DocumentLoadException('That file could not be read.');
    }
    return fromBytes(bytes, picked.name);
  }

  /// Camera or gallery capture of handwritten or printed work.
  Future<LoadedDocument?> pickImage({required bool fromCamera}) async {
    final file = await _imagePicker.pickImage(
      source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      // Enough resolution for the model to read handwriting, small enough to
      // keep the upload and the input-token bill sane.
      maxWidth: 2000,
      imageQuality: 85,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return fromBytes(bytes, file.name);
  }

  /// Shared path for both pickers, and the seam unit tests hook into.
  Future<LoadedDocument> fromBytes(Uint8List bytes, String fileName) async {
    if (bytes.length > _maxBytes) {
      throw DocumentLoadException(
        'That file is larger than 12 MB. Try a smaller file or fewer pages.',
      );
    }

    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';

    if (ext == 'pdf') {
      return LoadedDocument(
        attachment: Attachment(
          kind: AttachmentKind.pdf,
          fileName: fileName,
          bytes: bytes,
          mediaType: 'application/pdf',
        ),
      );
    }

    if (imageExtensions.contains(ext)) {
      return LoadedDocument(
        attachment: Attachment(
          kind: AttachmentKind.image,
          fileName: fileName,
          bytes: bytes,
          mediaType: _imageMediaType(ext),
        ),
      );
    }

    if (ext == 'docx') {
      final text = extractDocx(bytes);
      if (text.trim().isEmpty) {
        throw DocumentLoadException(
          'No text was found in that document. If it is a scan, import it as '
          'a photo or PDF instead.',
        );
      }
      return LoadedDocument(text: text);
    }

    if (ext == 'doc') {
      throw DocumentLoadException(
        'Old .doc files are not supported. Save it as .docx or .pdf first.',
      );
    }

    // Anything else is treated as plain text.
    try {
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.trim().isEmpty) {
        throw DocumentLoadException('That file appears to be empty.');
      }
      return LoadedDocument(text: text);
    } catch (_) {
      throw DocumentLoadException(
        'That file type is not supported. Use .txt, .docx, .pdf or a photo.',
      );
    }
  }

  static String _imageMediaType(String ext) => switch (ext) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        _ => 'image/jpeg',
      };

  /// Pulls the visible text out of a .docx.
  ///
  /// A .docx is a zip whose `word/document.xml` holds the body. Rather than
  /// pull in a full Office parser, we unzip, keep paragraph and break markers
  /// as newlines, then drop the remaining tags.
  @visibleForTesting
  static String extractDocx(Uint8List bytes) {
    late final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw DocumentLoadException('That .docx file could not be opened.');
    }

    final entry = archive.files.where((f) => f.name == 'word/document.xml');
    if (entry.isEmpty) {
      throw DocumentLoadException('That .docx file is missing its content.');
    }

    final xml = utf8.decode(
      entry.first.content as List<int>,
      allowMalformed: true,
    );

    final withBreaks = xml
        .replaceAll(RegExp(r'<w:p\b[^>]*/>'), '\n')
        .replaceAll('</w:p>', '\n')
        .replaceAll(RegExp(r'<w:br\b[^>]*/>'), '\n')
        .replaceAll(RegExp(r'<w:tab\b[^>]*/>'), '\t');

    final stripped = withBreaks.replaceAll(RegExp(r'<[^>]+>'), '');

    final unescaped = stripped
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");

    // Collapse the runs of blank lines that empty paragraphs leave behind.
    return unescaped
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}
