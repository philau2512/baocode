import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import 'agy_mcp_plugin.dart';
import 'agy_output_parser.dart';
import 'agy_subagent_transcript.dart';
import 'agy_task_presentation.dart';
import 'agy_tool_classifier.dart';

/// Replays AGY's persisted records without exposing its internal envelope.
/// The JSONL transcript stores user wrappers and tool calls separately from
/// visible prose, so history needs to normalize both before emitting items.

export '../agent_kernel.dart' show SessionRecord;

/// Replays an Antigravity local chat file into BaoCode transcript events.
final class AgyHistory {
  AgyHistory({required this.emit, required this.nextSeq});

  final void Function(KernelEvent event) emit;
  final int Function() nextSeq;
  final List<String> _pendingToolIds = [];
  final Map<String, _HistoryTool> _historyTools = {};
  final List<_HistorySubagent> _pendingSubagents = [];
  final Map<String, AgyTaskInfo> _tasks = {};
  final AgySubagentTranscriptReader _subagentTranscript =
      AgySubagentTranscriptReader();

  Future<void> replay(SessionRecord session) async {
    final path = session.path;
    if (path == null) return;
    try {
      final file = File(path);
      if (path.endsWith('.jsonl')) {
        await _replayJsonl(file);
        return;
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      final messages = raw['messages'];
      if (messages is! List) return;
      for (final value in messages) {
        if (value is! Map) continue;
        _emitMessage(value.cast<String, Object?>());
      }
    } on Object catch (error) {
      emit(
        ItemUpserted(
          nextSeq(),
          'agy-history-error',
          NoticeItem(
            NoticeKind.error,
            'Could not read Antigravity history: $error',
          ),
        ),
      );
    }
  }

  Future<void> _replayJsonl(File file) async {
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final raw = jsonDecode(line);
      if (raw is Map) await _emitStep(raw.cast<String, Object?>());
    }
  }

  Future<void> _emitStep(Map<String, Object?> step) async {
    final type = '${step['type'] ?? ''}'.toUpperCase();
    final content = _string(step['content']);
    if (content != null) {
      _extractTaskNotice(content);
    }
    if (type == 'USER_INPUT') {
      final visible = _cleanUserContent(content);
      if (visible != null) _emitItem('user', visible, id: step['step_index']);
      return;
    }
    if (type == 'PLANNER_RESPONSE' || type == 'GENERIC') {
      if (type == 'PLANNER_RESPONSE') {
        _emitToolCalls(step['tool_calls'], step: step);
      }
      if (content != null && !_isInternalEnvelope(content)) {
        if (type == 'GENERIC' &&
            (_applySubagentCreated(content) || _applyToolResult(content))) {
          return;
        }
        if (type == 'PLANNER_RESPONSE' && await _applySubagentResult(content)) {
          return;
        }
        _emitItem('assistant', content, id: step['step_index']);
      }
    } else if (type == 'SYSTEM_MESSAGE') {
      // AGY system messages are runtime envelopes (subagent delivery, server
      // notices, and metadata), never user-visible assistant conversation.
      if (content != null) {
        if (await _applySubagentResult(content)) return;
        _applyToolResult(content);
      }
    }
  }

  void _emitMessage(Map<String, Object?> message) {
    final type = '${message['type'] ?? ''}'.toLowerCase();
    final content = _string(message['content']);
    if (content == null) return;
    if (type == 'user') {
      final visible = _cleanUserContent(content);
      if (visible != null) _emitItem('user', visible, id: message['id']);
    } else if (type == 'assistant' && !_isInternalEnvelope(content)) {
      _emitItem('assistant', content, id: message['id']);
    }
  }

  void _emitToolCalls(Object? raw, {required Map<String, Object?> step}) {
    if (raw is! List) return;
    for (final value in raw) {
      if (value is! Map) continue;
      final call = value.cast<String, Object?>();
      final name = _string(call['name']) ?? _string(call['tool_name']);
      if (name == null) continue;
      final input = _map(call['args'] ?? call['arguments']);
      final output = _string(call['output']) ?? _string(call['result']);
      final id = _string(call['id']) ?? 'history-tool-${nextSeq()}';
      if (name.toLowerCase() == 'invoke_subagent') {
        _emitSubagent(id, input, step, output);
        continue;
      }
      final descriptor = AgyToolClassifier.classify(name, input);
      final mcp = descriptor.kind == ToolKind.mcp
          ? AgyMcpPluginParser.parse(name, input)
          : null;
      _pendingToolIds.add(id);
      final historyTool = _HistoryTool(
        name,
        input,
        descriptor.kind,
        mcp,
        terminal: descriptor.terminal,
      );
      final item = _historyItem(historyTool, output);
      _historyTools[id] = historyTool;
      emit(ItemUpserted(nextSeq(), id, item));
    }
  }

  void _emitSubagent(
    String fallbackId,
    Map<String, Object?> input,
    Map<String, Object?> step,
    String? output,
  ) {
    final prompt = _string(input['Prompt']) ?? _string(input['prompt']);
    final role = _string(input['Role']) ?? _string(input['role']) ?? 'Subagent';
    final conversation = _conversationId(output) ?? fallbackId;
    _pendingSubagents.add(
      _HistorySubagent(
        conversation,
        prompt,
        role,
        _string(input['TypeName']) ?? _string(input['type_name']),
      ),
    );
    // The following GENERIC record gives this invocation its conversation id;
    // the child report then arrives as a SYSTEM_MESSAGE. Hydrate there so one
    // final AgentItem contains both its transcript and result.
  }

  static String? _conversationId(String? output) =>
      RegExp(r'"conversationId"\s*:\s*"([^"]+)"')
          .firstMatch(output ?? '')
          ?.group(1);

  bool _applySubagentCreated(String content) {
    if (!_looksLikeSubagentCreation(content) || _pendingSubagents.isEmpty) {
      return false;
    }
    final conversation = _conversationId(content);
    if (conversation == null) return false;
    final pending = _pendingSubagents.removeLast();
    final updated = _HistorySubagent(
      conversation,
      pending.prompt,
      pending.role,
      pending.type,
    );
    _pendingSubagents.add(updated);
    return true;
  }

  static bool _looksLikeSubagentCreation(String content) =>
      content.contains('Created the following subagent:');

  Future<void> _emitCompletedSubagent(
    _HistorySubagent subagent,
    String result,
  ) async {
    final transcript = await _subagentTranscript.inspect(
      conversation: subagent.id,
    );
    emit(
      ItemUpserted(
        nextSeq(),
        subagent.id,
        AgentItem(
          id: subagent.id,
          description: subagent.role,
          agentType: subagent.type,
          prompt: transcript.prompt ?? subagent.prompt,
          status: CommandStatus.succeeded,
          children: transcript.items,
          result: result,
        ),
      ),
    );
  }

  Future<bool> _applySubagentResult(String content) async {
    final match = RegExp(
      r'sender=([^\s]+).*?\bcontent=(.*?)(?:\n</SYSTEM_MESSAGE>|$)',
      dotAll: true,
    ).firstMatch(content);
    if (match == null) return false;
    final id = match.group(1)!;
    final pending = _pendingSubagents
        .where((agent) => agent.id == id)
        .firstOrNull;
    if (pending == null) return false;
    await _emitCompletedSubagent(pending, match.group(2)!.trim());
    return true;
  }

  ChatItem _historyItem(_HistoryTool tool, String? output) {
    if (tool.terminal) {
      return TerminalItem(
        command:
            _string(tool.input['CommandLine']) ??
            _string(tool.input['command']) ??
            tool.name,
        description: _string(tool.input['toolSummary']),
        output: output ?? '',
      );
    }
    final parsed = AgyOutputParser.parse(output);
    final task = AgyTaskPresentation.parse(
      tool.name,
      tool.input,
      output: output,
      taskLookup: (id) => _tasks[id],
    );
    final path = _string(tool.input['Path']) ?? _string(tool.input['path']);
    final isFilePath = path != null &&
        (tool.kind == ToolKind.read ||
            tool.kind == ToolKind.edit ||
            tool.kind == ToolKind.listDir);
    return ToolCallItem(
      kind: tool.kind,
      target: task?.target ??
          (tool.mcp != null
              ? (tool.mcp!.target ?? '')
              : (isFilePath ? _baseName(path) : path) ?? tool.name),
      path: path,
      detail: task?.detail ??
          (tool.kind == ToolKind.read ? _readRange(tool.input) : null),
      label: task?.label ?? tool.mcp?.label ?? tool.name,
      tool: tool.name,
      input: tool.input,
      output: output,
      results: parsed.results,
      images: parsed.images,
      status: ToolStatus.succeeded,
    );
  }

  bool _applyToolResult(String content) {
    if (_pendingToolIds.isEmpty || !_looksLikeToolResult(content)) return false;
    final id = _pendingToolIds.removeAt(0);
    final previous = _historyTools[id];
    if (previous == null) return false;
    _recordCreatedTask(previous, content);
    final output = _toolOutput(content);
    final item = _historyItem(previous, output);
    emit(ItemUpserted(nextSeq(), id, item));
    return true;
  }

  void _recordCreatedTask(_HistoryTool tool, String content) {
    final taskMatch = RegExp(
      r'with task id:\s*([^\s\n]+)',
      caseSensitive: false,
    ).firstMatch(content);
    if (taskMatch == null) return;
    final fullId = taskMatch.group(1)!.trim();
    final shortId = _shortTaskId(fullId);
    final descMatch = RegExp(
      r'Task Description:\s*([^\n]+)',
      caseSensitive: false,
    ).firstMatch(content);
    final desc = descMatch?.group(1)?.trim();

    final isSchedule = tool.name.toLowerCase() == 'schedule';
    final summary = _string(tool.input['toolSummary']) ??
        (isSchedule ? _string(tool.input['Prompt']) : null) ??
        desc;
    final command = _string(tool.input['CommandLine']) ??
        _string(tool.input['command']) ??
        (!isSchedule ? desc : null);
    final prompt = _string(tool.input['Prompt']) ??
        _string(tool.input['prompt']);
    final duration = _string(tool.input['DurationSeconds']) ??
        _string(tool.input['duration_seconds']);

    final info = AgyTaskInfo(
      id: fullId,
      summary: summary,
      command: command,
      prompt: prompt,
      duration: duration != null ? '${duration}s' : null,
      kind: isSchedule ? 'timer' : 'command',
    );
    _tasks[fullId] = info;
    _tasks[shortId] = info;
  }

  void _extractTaskNotice(String content) {
    final taskMatch = RegExp(
      r'with task id:\s*([^\s\n]+)',
      caseSensitive: false,
    ).firstMatch(content);
    if (taskMatch == null) return;
    final fullId = taskMatch.group(1)!.trim();
    final shortId = _shortTaskId(fullId);
    if (_tasks.containsKey(fullId)) return;
    final descMatch = RegExp(
      r'Task Description:\s*([^\n]+)',
      caseSensitive: false,
    ).firstMatch(content);
    final desc = descMatch?.group(1)?.trim();
    final isTimer = desc != null && desc.startsWith('Timer:');
    String? prompt;
    String? duration;
    if (isTimer) {
      final promptMatch = RegExp(r'Prompt:\s*(.*)$').firstMatch(desc);
      prompt = promptMatch?.group(1)?.trim();
      final durMatch = RegExp(r'Timer:\s*([^\s,]+)').firstMatch(desc);
      duration = durMatch?.group(1)?.trim();
    }
    final info = AgyTaskInfo(
      id: fullId,
      summary: prompt ?? desc,
      command: !isTimer ? desc : null,
      prompt: prompt,
      duration: duration,
      kind: isTimer ? 'timer' : 'command',
    );
    _tasks[fullId] = info;
    _tasks[shortId] = info;
  }

  static String _shortTaskId(String id) {
    final slash = id.lastIndexOf('/');
    return slash >= 0 && slash < id.length - 1 ? id.substring(slash + 1) : id;
  }

  static bool _looksLikeToolResult(String content) =>
      content.startsWith('Created At:') ||
      content.startsWith('Showing lines ') ||
      content.startsWith('Task:') ||
      content.startsWith('Tool is running as a background task') ||
      RegExp(
        r'^Made \d+ replacement',
        caseSensitive: false,
      ).hasMatch(content) ||
      content.startsWith('Wrote ') ||
      content.startsWith('Deleted ') ||
      content.startsWith('Encountered error in step execution:') ||
      content.startsWith('[') ||
      content.startsWith('{');

  static String _toolOutput(String content) {
    const commandOutput = 'Command output:';
    final index = content.indexOf(commandOutput);
    if (index >= 0) {
      return content.substring(index + commandOutput.length).trim();
    }
    return content;
  }

  static String? _cleanUserContent(String? content) {
    if (content == null || content.trim().isEmpty) return null;
    final trimmed = content.trim();
    final match = RegExp(
      r'<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>',
      dotAll: true,
    ).firstMatch(trimmed);
    if (match != null) return match.group(1)!.trim();
    return trimmed;
  }

  static bool _isInternalEnvelope(String content) =>
      content.trimLeft().startsWith('<USER_REQUEST>') ||
      content.contains('<ADDITIONAL_METADATA>') ||
      content.contains('<USER_SETTINGS_CHANGE>');

  static String? _readRange(Map<String, Object?> parameters) {
    int? line(Object? value) => switch (value) {
      int value when value > 0 => value,
      String value => switch (int.tryParse(value)) {
        final parsed? when parsed > 0 => parsed,
        _ => null,
      },
      _ => null,
    };
    final start = line(parameters['StartLine'] ?? parameters['start_line']);
    if (start == null) return null;
    final end = line(parameters['EndLine'] ?? parameters['end_line']);
    return end == null || end <= start ? 'L$start' : 'L$start-$end';
  }

  static String _baseName(String path) {
    if (path.isEmpty) return path;
    final clean = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final slash = clean.lastIndexOf('/');
    return slash >= 0 ? clean.substring(slash + 1) : clean;
  }

  static String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};

  void _emitItem(String type, String content, {Object? id}) {
    if (type == 'user') {
      emit(
        ItemUpserted(
          nextSeq(),
          '${id ?? 'user'}:history',
          UserMessageItem(text: content),
        ),
      );
    } else {
      emit(
        ItemUpserted(
          nextSeq(),
          '${id ?? 'assistant'}:history',
          AssistantTextItem(content),
        ),
      );
    }
  }
}

final class _HistorySubagent {
  const _HistorySubagent(this.id, this.prompt, this.role, this.type);

  final String id;
  final String? prompt;
  final String role;
  final String? type;
}

final class _HistoryTool {
  const _HistoryTool(
    this.name,
    this.input,
    this.kind,
    this.mcp, {
    required this.terminal,
  });

  final String name;
  final Map<String, Object?> input;
  final ToolKind kind;
  final AgyMcpPluginDetails? mcp;
  final bool terminal;
}
