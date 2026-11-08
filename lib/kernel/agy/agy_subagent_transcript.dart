import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';
import 'agy_mcp_plugin.dart';
import 'agy_output_parser.dart';
import 'agy_task_presentation.dart';
import 'agy_tool_classifier.dart';

/// Reconstructs the visible child activity of an AGY subagent from its
/// persisted transcript. Unknown records are ignored so this remains forward
/// compatible with newer AGY transcript fields.
final class AgySubagentTranscript {
  const AgySubagentTranscript({
    required this.items,
    this.prompt,
    required this.completed,
  });

  final List<ChatItem> items;
  final String? prompt;
  final bool completed;
}

final class AgySubagentTranscriptReader {
  AgySubagentTranscriptReader({this.home});

  final String? home;

  Future<List<ChatItem>> read({required String conversation}) async =>
      (await inspect(conversation: conversation)).items;

  Future<AgySubagentTranscript> inspect({required String conversation}) async {
    final base = home ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'];
    if (base == null || conversation.isEmpty) {
      return const AgySubagentTranscript(items: [], completed: false);
    }
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
    if (!await file.exists()) {
      return const AgySubagentTranscript(items: [], completed: false);
    }

    final items = <String, ChatItem>{};
    final pendingToolIds = <String>[];
    String? prompt;
    var completed = false;
    try {
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final record = jsonDecode(line);
        if (record is! Map) continue;
        prompt ??= _prompt(record['content']);
        final type = '${record['type'] ?? ''}'.toUpperCase();
        if (type == 'PLANNER_RESPONSE' && _string(record['content']) != null) {
          completed = true;
        }
        _readRecord(record, items, pendingToolIds);
      }
    } on FormatException {
      // AGY may be appending the final JSONL record while it is read.
    } on IOException {
      // Return the complete portion already read.
    }
    return AgySubagentTranscript(
      items: items.values.toList(growable: false),
      prompt: prompt,
      completed: completed,
    );
  }

  void _readRecord(
    Map<Object?, Object?> record,
    Map<String, ChatItem> items,
    List<String> pendingToolIds,
  ) {
    final type = '${record['type'] ?? ''}'.toUpperCase();
    final content = _string(record['content']);
    if (type == 'PLANNER_RESPONSE') {
      _readCalls(record['tool_calls'], items, pendingToolIds);
    }
    if (type == 'GENERIC' && content != null && _isToolResult(content)) {
      _applyToolResult(content, items, pendingToolIds);
      return;
    }
    if ((type == 'PLANNER_RESPONSE' || type == 'GENERIC') &&
        content != null &&
        !_isToolResult(content)) {
      items['assistant:${items.length}'] = AssistantTextItem(content);
    }
  }

  void _readCalls(
    Object? raw,
    Map<String, ChatItem> items,
    List<String> pendingToolIds,
  ) {
    if (raw is! List) return;
    for (final value in raw) {
      if (value is! Map) continue;
      final call = value.cast<String, Object?>();
      final name = _string(call['name']) ?? _string(call['tool_name']);
      if (name == null) continue;
      final args = _map(call['args'] ?? call['arguments']);
      final output = _string(call['output']) ?? _string(call['result']);
      final descriptor = AgyToolClassifier.classify(name, args);
      final mcp = descriptor.kind == ToolKind.mcp
          ? AgyMcpPluginParser.parse(name, args)
          : null;
      final id = _string(call['id']) ?? '$name:${items.length}';
      pendingToolIds.add(id);
      if (descriptor.terminal) {
        items[id] = TerminalItem(
          command: _string(args['CommandLine']) ?? name,
          description: _string(args['toolSummary']),
          output: output ?? '',
        );
        continue;
      }
      final parsed = AgyOutputParser.parse(output);
      final path = _string(args['Path']) ?? _string(args['path']);
      final isMessage = descriptor.kind == ToolKind.message;
      final task = AgyTaskPresentation.parse(name, args, output: output);
      items[id] = ToolCallItem(
        kind: descriptor.kind,
        target: isMessage
            ? 'parent agent'
            : task?.target ?? mcp?.target ?? path ?? name,
        path: path,
        detail: task?.detail,
        label: isMessage ? 'Sent message' : task?.label ?? mcp?.label,
        tool: name,
        input: args,
        output: output,
        results: parsed.results,
        images: parsed.images,
        status: ToolStatus.succeeded,
      );
    }
  }

  void _applyToolResult(
    String content,
    Map<String, ChatItem> items,
    List<String> pendingToolIds,
  ) {
    if (pendingToolIds.isEmpty) return;
    final id = pendingToolIds.removeAt(0);
    final previous = items[id];
    if (previous is TerminalItem) {
      items[id] = TerminalItem(
        command: previous.command,
        description: previous.description,
        output: _toolOutput(content),
      );
    } else if (previous is ToolCallItem) {
      final output = _toolOutput(content);
      final parsed = AgyOutputParser.parse(output);
      items[id] = ToolCallItem(
        kind: previous.kind,
        target: previous.target,
        path: previous.path,
        label: previous.label,
        tool: previous.tool,
        input: previous.input,
        output: output,
        results: parsed.results,
        images: parsed.images,
        status: ToolStatus.succeeded,
      );
    }
  }

  static String _toolOutput(String content) {
    const marker = 'Command output:';
    final at = content.indexOf(marker);
    return at < 0 ? content : content.substring(at + marker.length).trim();
  }

  static String? _prompt(Object? content) {
    final text = _string(content);
    if (text == null) return null;
    final match = RegExp(
      r'<SYSTEM_MESSAGE>.*?\bcontent=(.*?)\s*</SYSTEM_MESSAGE>',
      dotAll: true,
    ).firstMatch(text);
    return match?.group(1)?.trim();
  }

  static bool _isToolResult(String content) =>
      content.startsWith('Created At:') ||
      content.startsWith('Showing lines ') ||
      content.startsWith('Encountered error in step execution:');

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};

  static String? _string(Object? value) => value is String && value.isNotEmpty
      ? value
      : null;
}
