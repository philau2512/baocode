import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class AgyEditSnapshot {
  const AgyEditSnapshot({
    required this.before,
    required this.after,
  });

  final String before;
  final String after;
}

/// Shares one transcript read among all edits waiting for a conversation.
final class AgyEditTranscriptReader {
  AgyEditTranscriptReader({this.home});

  final String? home;
  final Map<String, Future<Map<String, AgyEditSnapshot>>> _reads = {};

  Future<AgyEditSnapshot?> read({
    required String conversation,
    required String path,
  }) async {
    if (conversation.isEmpty) return null;
    final future = _reads[conversation] ??= _read(conversation);
    try {
      final snapshots = await future;
      return snapshots[_pathKey(path)];
    } finally {
      // Share only an in-flight scan. A later edit must rescan, otherwise it
      // could receive an older snapshot for the same file.
      if (identical(_reads[conversation], future)) {
        _reads.remove(conversation);
      }
    }
  }

  Future<Map<String, AgyEditSnapshot>> _read(String conversation) async {
    final base = home ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'];
    if (base == null) return const {};
    final transcript = File(p.join(
      base,
      '.gemini',
      'antigravity-cli',
      'brain',
      conversation,
      '.system_generated',
      'logs',
      'transcript_full.jsonl',
    ));
    if (!await transcript.exists()) return const {};
    final snapshots = <String, AgyEditSnapshot>{};
    try {
      await for (final line in transcript
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final record = jsonDecode(line);
        if (record is! Map || record['tool_calls'] is! List) continue;
        for (final call in record['tool_calls'] as List) {
          if (call is! Map || call['name'] != 'edit_file') continue;
          final args = call['args'];
          if (args is! Map) continue;
          final path = args['Path'] ?? args['path'];
          final before = args['Target'] ?? args['target'];
          final after = args['Replacement'] ?? args['replacement'];
          if (path is String && before is String && after is String) {
            snapshots[_pathKey(path)] = AgyEditSnapshot(
              before: before,
              after: after,
            );
          }
        }
      }
    } on FormatException {
      // The CLI may be writing the final line while it is being read.
    }
    return snapshots;
  }
}

Future<AgyEditSnapshot?> readAgyEditSnapshot({
  required String conversation,
  required String path,
  String? home,
}) => AgyEditTranscriptReader(home: home).read(
  conversation: conversation,
  path: path,
);

String _pathKey(String path) => path.replaceAll('\\', '/').toLowerCase();
