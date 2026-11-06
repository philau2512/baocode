import 'dart:convert';

import '../../chat/chat_models.dart';

final class AgyParsedOutput {
  const AgyParsedOutput({this.results = const [], this.images = const []});

  final List<String> results;
  final List<ImageAttachment> images;
}

/// Extracts clickable matches and inline images from AGY tool payloads.
final class AgyOutputParser {
  static AgyParsedOutput parse(String? text) {
    if (text == null || text.isEmpty) return const AgyParsedOutput();
    final results = <String>[];
    for (final line in text.split(RegExp(r'\r?\n'))) {
      if (RegExp(r'^[^\s].*[:(]\d+(?:[-:]\d+)?').hasMatch(line.trim())) {
        results.add(line.trim());
      }
    }
    final images = <ImageAttachment>[];
    final pattern = RegExp(
      r'data:(image/[^;]+);base64,([A-Za-z0-9+/=\r\n]+)',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(text)) {
      try {
        images.add(ImageAttachment(
          bytes: base64Decode(match.group(2)!.replaceAll(RegExp(r'\s+'), '')),
          mediaType: match.group(1)!,
        ));
      } on FormatException {
        // Ignore malformed image payloads.
      }
    }
    return AgyParsedOutput(results: results, images: images);
  }

  static ImageAttachment? image(Object? value) {
    if (value is! Map || value['type'] != 'base64') return null;
    try {
      final data = value['data'];
      if (data is! String) return null;
      return ImageAttachment(
        bytes: base64Decode(data),
        mediaType: value['media_type'] as String? ?? 'image/png',
      );
    } on FormatException {
      return null;
    }
  }
}
