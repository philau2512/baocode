import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';
import '../kernel_types.dart';

/// Reads AGY's persisted task metadata when the CLI has produced it.
final class AgySubagentTaskReader {
  AgySubagentTaskReader({this.home});

  final String? home;

  Future<List<KernelTask>> read({required String conversation}) async {
    final base = home ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'];
    if (base == null || conversation.isEmpty) return const [];
    final root = Directory(p.join(
      base,
      '.gemini',
      'antigravity-cli',
      'brain',
      conversation,
    ));
    if (!await root.exists()) return const [];
    final tasks = <String, KernelTask>{};
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
      try {
        await for (final line in entity
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          final value = jsonDecode(line);
          if (value is! Map) continue;
          _read(value, tasks);
        }
      } on Object {
        // Ignore unrelated or partially written AGY records.
      }
    }
    return tasks.values.toList(growable: false);
  }

  void _read(Map<Object?, Object?> value, Map<String, KernelTask> tasks) {
    final task = value['task'] is Map ? value['task'] as Map : value;
    final id = _string(task['task_id']) ??
        _string(task['conversation_id']) ??
        _string(task['subagent_id']);
    if (id == null) return;
    final description = _string(task['description']) ??
        _string(task['role']) ??
        'AGY subagent';
    final status = _status(task['status'] ?? task['state']);
    tasks[id] = KernelTask(
      id: id,
      description: description,
      kind: KernelTaskKind.agent,
      status: status,
      startedAt: DateTime.tryParse(_string(task['created_at']) ?? '') ??
          DateTime.now(),
      toolUseId: _string(task['tool_use_id']) ?? id,
      background: task['is_backgrounded'] != false,
      summary: _string(task['summary']) ?? _string(task['result']),
    );
  }

  static CommandStatus _status(Object? value) => switch ('$value'.toUpperCase()) {
    'DONE' || 'COMPLETED' || 'SUCCESS' || 'SUCCEEDED' =>
      CommandStatus.succeeded,
    'ERROR' || 'FAILED' || 'CANCELLED' || 'CANCELED' || 'STOPPED' =>
      CommandStatus.failed,
    _ => CommandStatus.running,
  };

  static String? _string(Object? value) => value is String && value.isNotEmpty
      ? value
      : null;
}
