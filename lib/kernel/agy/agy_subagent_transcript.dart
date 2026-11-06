import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';

/// Reconstructs the visible child activity of an AGY subagent from its
/// persisted transcript. Unknown records are ignored so this remains forward
/// compatible with newer AGY transcript fields.
final class AgySubagentTranscriptReader {
  AgySubagentTranscriptReader({this.home});

  final String? home;

  Future<List<ChatItem>> read({required String conversation}) async {
    final base = home ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'];
    if (base == null || conversation.isEmpty) return const [];
    final file = File(p.join(
      base,
      '.gemini',
      'antigravity-cli',
      'brain',
      conversation,
      '.system_generated',
      'logs',
      'transcript.jsonl',
    ));
    if (!await file.exists()) return const [];

    final items = <String, ChatItem>{};
    try {
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final record = jsonDecode(line);
        if (record is! Map) continue;
        _readRecord(record, items);
      }
    } on FormatException {
      // AGY may be appending the final JSONL record while it is read.
    } on IOException {
      return items.values.toList(growable: false);
    }
    return items.values.toList(growable: false);
  }

  void _readRecord(Map<Object?, Object?> record, Map<String, ChatItem> items) {
    final type = record['type'];
    if (type == 'MODEL' || type == 'ASSISTANT') {
      final text = record['content'];
      if (text is String && text.trim().isNotEmpty) {
        items['assistant:${items.length}'] = AssistantTextItem(text.trim());
      }
    }
    final calls = record['tool_calls'];
    if (calls is! List) return;
    for (final raw in calls) {
      if (raw is! Map) continue;
      final name = _string(raw['name']) ?? _string(raw['tool_name']);
      if (name == null) continue;
      final args = raw['args'] is Map
          ? (raw['args'] as Map).cast<String, Object?>()
          : const <String, Object?>{};
      final output = _string(raw['output']) ?? _string(raw['result']);
      final path = _string(args['Path']) ?? _string(args['path']);
      final id = _string(raw['id']) ?? '$name:${items.length}';
      final kind = switch (name.toLowerCase()) {
        'read_file' || 'readfile' => ToolKind.read,
        'invoke_subagent' || 'browser_subagent' => ToolKind.agent,
        _ when path != null => ToolKind.edit,
        _ => ToolKind.other,
      };
      items[id] = ToolCallItem(
        kind: kind,
        target: path ?? name,
        path: path,
        label: name,
        input: args,
        output: output,
        status: ToolStatus.succeeded,
      );
    }
  }

  static String? _string(Object? value) => value is String && value.isNotEmpty
      ? value
      : null;
}
