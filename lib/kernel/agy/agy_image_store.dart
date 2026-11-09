import 'dart:io';

import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';

/// Stores pasted images outside the workspace so AGY can inspect their paths.
final class AgyImageStore {
  AgyImageStore({this.baseDirectory});

  final Directory? baseDirectory;
  Directory? _directory;

  Future<List<String>> save(List<ImageAttachment> images) async {
    if (images.isEmpty) return const [];
    final directory = _directory ??= await (baseDirectory ?? Directory.systemTemp)
        .createTemp('baocode-agy-images-');
    final paths = <String>[];
    for (var index = 0; index < images.length; index++) {
      final image = images[index];
      final file = File(p.join(
        directory.path,
        'image-${DateTime.now().microsecondsSinceEpoch}-$index${_extension(image)}',
      ));
      await file.writeAsBytes(image.bytes, flush: true);
      paths.add(file.absolute.path);
    }
    return paths;
  }

  Future<void> dispose() async {
    final directory = _directory;
    _directory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  static String _extension(ImageAttachment image) => switch (image.mediaType) {
    'image/jpeg' => '.jpg',
    'image/gif' => '.gif',
    'image/webp' => '.webp',
    _ => '.png',
  };
}
