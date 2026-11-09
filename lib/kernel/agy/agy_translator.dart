import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../../chat/chat_models.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'agy_interactions.dart';
import 'agy_mcp_plugin.dart';
import 'agy_output_parser.dart';
import 'agy_subagent_transcript.dart';
import 'agy_task_presentation.dart';
import 'agy_tool_classifier.dart';

// MCP/plugin metadata is presentation-only; mutating plugin actions still
// require the normal AGY permission flow.

/// Translates verified Antigravity stream-json events into BaoCode events.
final class AgyTranslator {
  AgyTranslator({
    required this.emit,
    required this.nextSeq,
    this.onTurnEnded,
    this.beforeEdit,
    this.afterEdit,
    this.readFile,
    this.readEditSnapshot,
    this.readSubagentTranscript,
    this.onTasksChanged,
    this.sendInteractionAnswer,
  });

  final void Function(String requestId, InteractionAnswer answer)?
  sendInteractionAnswer;

  final void Function(KernelEvent event) emit;
  final int Function() nextSeq;
  final void Function(String turnId)? onTurnEnded;
  final Future<void>? Function(String path)? beforeEdit;
  final Future<void>? Function(String path)? afterEdit;
  final Future<String?> Function(String path)? readFile;
  final Future<({String before, String after})?> Function(
    String path, {
    String? target,
  })?
  readEditSnapshot;
  final Future<AgySubagentTranscript> Function(String conversation)?
  readSubagentTranscript;
  final void Function(List<KernelTask> tasks)? onTasksChanged;
  late final AgyInteractionParser _interactions = AgyInteractionParser(
    emit,
    nextSeq,
  );
  final Map<String, Future<String?>> _beforeFiles = {};
  final Map<String, ({String? before, String? after})> _reportedEditPayloads =
      {};
  final Map<String, AgentItem> _agents = {};
  final Map<String, String> _agentIdsByTool = {};
  final Map<String, List<ChatItem>> _agentChildren = {};
  final Map<String, String> _agentParents = {};
  final Map<String, KernelTask> _tasks = {};
  final Map<String, AgyTaskInfo> _taskInfos = {};
  final Map<String, String> _interactionTools = {};

  String? conversationId;
  String? turnId;
  String? textId;
  int textLength = 0;
  DateTime? startedAt;

  /// Maps AGY's tool identity to the stable BaoCode item id. AGY emits
  /// multiple `step_update` events for one tool, so the id must not be based
  /// on the number of updates received.
  final Map<String, String> _toolIds = {};
  final Map<String, String> _activeToolIds = {};
  int _toolCount = 0;
  final Map<String, DateTime> _tools = {};

  void answer(String requestId, InteractionAnswer answer) {
    sendInteractionAnswer?.call(requestId, answer);
    emit(InteractionResolved(nextSeq(), requestId));
  }

  void beginTurn(String id) {
    if (turnId != null) return;
    turnId = id;
    startedAt = DateTime.now();
  }

  void resetTurn() {
    turnId = null;
    textId = null;
    textLength = 0;
    startedAt = null;
    _toolCount = 0;
    _tools.clear();
    _toolIds.clear();
    _activeToolIds.clear();
    _reportedEditPayloads.clear();
    _beforeFiles.clear();
  }

  void accept(Map<String, Object?> message) {
    switch (message['event']) {
      case 'init':
        conversationId = _string(message['conversation_id']);
        emit(KernelInfoChanged(nextSeq()));
      case 'step_update':
        _step(_map(message['step_update']));
      case 'result':
        _result(_map(message['result']));
    }
  }

  void _step(Map<String, Object?> step) {
    final kind = _string(step['step_type']) ?? _string(step['type']);
    if (kind == 'agent_response') {
      _text(step);
    } else if (kind == 'tool') {
      _tool(step);
    }
    final usage = _map(step['usage']);
    if (usage.isNotEmpty) _reportUsage(usage);
  }

  void _begin() {
    if (turnId != null) return;
    beginTurn('agy-turn-${DateTime.now().microsecondsSinceEpoch}');
  }

  void _text(Map<String, Object?> step) {
    final delta = _string(step['text_delta']) ?? '';
    if (delta.isEmpty) return;
    _begin();
    final id = textId ??= '$turnId:assistant';
    if (textLength == 0) {
      emit(
        ItemUpserted(
          nextSeq(),
          id,
          const AssistantTextItem(''),
          streaming: true,
        ),
      );
    }
    emit(TextDelta(nextSeq(), id, textLength, delta));
    textLength += delta.length;
  }

  void _tool(Map<String, Object?> step) {
    _begin();
    final name = _string(step['tool_name']) ?? _string(step['name']) ?? 'tool';
    final info = _map(step['tool_info']);
    final subagentInfo = _map(step['subagent_info']).isNotEmpty
        ? _map(step['subagent_info'])
        : _map(info['subagent_info']);
    final parameters = _map(info['parameters']).isNotEmpty
        ? _map(info['parameters'])
        : _map(step['parameters']).isNotEmpty
        ? _map(step['parameters'])
        : _decodeParameters(step['arguments']) ??
              _decodeParameters(info['arguments']) ??
              const <String, Object?>{};
    final explicitId =
        _string(step['tool_id']) ??
        _string(step['id']) ??
        _string(info['tool_id']) ??
        _string(info['id']);
    final stepIndex = _string(step['step_index']);
    final command =
        _string(parameters['CommandLine']) ?? _string(parameters['command']);
    final path = _string(parameters['Path']) ?? _string(parameters['path']);
    final fileKey = path == null ? null : _pathKey(path);
    final scopeKey = '$name:${fileKey ?? command ?? ''}';

    final String id;
    if (explicitId != null) {
      id = _toolIds.putIfAbsent(
        explicitId,
        () => '$turnId:tool:${_toolCount++}',
      );
    } else if (stepIndex != null) {
      id = _toolIds.putIfAbsent(
        '$name:step:$stepIndex',
        () => '$turnId:tool:${_toolCount++}',
      );
    } else if (_activeToolIds.containsKey(scopeKey)) {
      id = _activeToolIds[scopeKey]!;
    } else {
      id = '$turnId:tool:${_toolCount++}';
    }
    final interactionId = _interactions.parse(step, info);
    if (interactionId != null) _interactionTools[interactionId] = name;
    final state =
        (_string(step['state']) ??
                _string(step['status']) ??
                _string(step['tool_status']) ??
                _string(info['state']) ??
                _string(info['status']) ??
                _string(info['tool_status']) ??
                'ACTIVE')
            .toUpperCase();
    final done = const {
      'DONE',
      'COMPLETED',
      'SUCCESS',
      'SUCCEEDED',
      'ERROR',
      'FAILED',
      'CANCELLED',
      'CANCELED',
    }.contains(state);
    if (!done && scopeKey.isNotEmpty) {
      _activeToolIds[scopeKey] = id;
    } else if (done) {
      _activeToolIds.remove(scopeKey);
    }
    final failed = const {
      'ERROR',
      'FAILED',
      'CANCELLED',
      'CANCELED',
    }.contains(state);
    final output =
        _string(info['output']) ??
        _string(info['result']) ??
        _string(info['error']) ??
        _string(step['output']) ??
        _string(step['error']);
    final progress =
        _string(info['description']) ??
        _string(info['summary']) ??
        _string(step['description']) ??
        _string(step['summary']);
    final readRange = _readRange(parameters);
    final original =
        _string(info['originalContent']) ??
        _string(info['original_content']) ??
        _string(step['originalContent']) ??
        _string(step['original_content']) ??
        _string(parameters['Target']) ??
        _string(parameters['target']);
    final newContent =
        _string(info['newContent']) ??
        _string(info['new_content']) ??
        _string(step['newContent']) ??
        _string(step['new_content']) ??
        _string(parameters['Replacement']) ??
        _string(parameters['replacement']) ??
        _string(parameters['Content']) ??
        _string(parameters['content']);
    final isAgent = _isAgentTool(name);
    _tools.putIfAbsent(id, DateTime.now);
    final agentId =
        _agentId(
          step,
          subagentInfo.isEmpty ? info : subagentInfo,
          parameters,
        ) ??
        id;
    final parentAgent = _parentAgentId(step, info, parameters);
    if (parentAgent case final parent?) {
      _agentParents[agentId] = parent;
    }
    if (original != null || newContent != null) {
      final existing = _reportedEditPayloads[id];
      _reportedEditPayloads[id] = (
        before: original ?? existing?.before,
        after: newContent ?? existing?.after,
      );
    }
    if (fileKey != null && !_beforeFiles.containsKey(fileKey)) {
      _beforeFiles[fileKey] = _captureBefore(path!);
    }
    final kind = AgyToolClassifier.classify(name, parameters).kind;
    if (path != null && kind == ToolKind.edit && !done) {
      unawaited(beforeEdit?.call(path));
    }
    final isTaskTool = _isTaskTool(name);
    final taskId = _taskId(parameters, output) ?? id;
    if (isTaskTool) {
      _reportTask(taskId, name: name, state: state, output: output);
    }
    if (isAgent) {
      _agentIdsByTool[id] = agentId;
      _reportAgent(
        agentId,
        name: name,
        parameters: parameters,
        info: subagentInfo.isEmpty ? info : subagentInfo,
        output: output,
        state: state,
        startedAt: _tools[id],
        parentId: parentAgent,
      );
      return;
    }
    final taskMatch = RegExp(
      r'with task id:\s*([^\s\n]+)',
      caseSensitive: false,
    ).firstMatch(output ?? '');
    if (taskMatch != null) {
      final fullId = taskMatch.group(1)!.trim();
      final shortId = _shortTaskId(fullId);
      final descMatch = RegExp(
        r'Task Description:\s*([^\n]+)',
        caseSensitive: false,
      ).firstMatch(output ?? '');
      final desc = descMatch?.group(1)?.trim();
      final isSchedule = name.toLowerCase() == 'schedule';
      final summary = _string(parameters['toolSummary']) ??
          (isSchedule ? _string(parameters['Prompt']) : null) ??
          desc;
      final cmd = _string(parameters['CommandLine']) ??
          _string(parameters['command']) ??
          (!isSchedule ? desc : null);
      final prompt = _string(parameters['Prompt']) ??
          _string(parameters['prompt']);
      final duration = _string(parameters['DurationSeconds']) ??
          _string(parameters['duration_seconds']);
      final info = AgyTaskInfo(
        id: fullId,
        summary: summary,
        command: cmd,
        prompt: prompt,
        duration: duration != null ? '${duration}s' : null,
        kind: isSchedule ? 'timer' : 'command',
      );
      _taskInfos[fullId] = info;
      _taskInfos[shortId] = info;
    }
    final parsedOutput = AgyOutputParser.parse(output);
    final mcp = kind == ToolKind.mcp || _isPluginTool(name)
        ? AgyMcpPluginParser.parse(name, parameters)
        : null;
    final taskPresentation = AgyTaskPresentation.parse(
      name,
      parameters,
      output: output,
      running: !done && !failed,
      taskLookup: (tid) => _taskInfos[tid],
    );
    final isFilePath = path != null &&
        (kind == ToolKind.read ||
            kind == ToolKind.edit ||
            kind == ToolKind.listDir);
    final target = taskPresentation?.target ??
        (kind == ToolKind.web
            ? _string(parameters['query']) ?? name
            : (mcp != null
                ? (mcp.target ?? '')
                : (isFilePath ? _baseName(path) : path) ?? name));
    final item = command != null
        ? TerminalItem(
            command: command,
            output: output ?? '',
            status: failed
                ? CommandStatus.failed
                : done
                ? CommandStatus.succeeded
                : CommandStatus.running,
            background: false,
            startedAt: _tools[id],
          )
        : ToolCallItem(
            kind: kind,
            target: target,
            path: path,
            results: parsedOutput.results,
            detail: taskPresentation?.detail ??
                (kind == ToolKind.read ? readRange ?? progress : progress),
            label: taskPresentation?.label ?? mcp?.label ?? name,
            tool: name,
            input: parameters,
            output: output,
            images: parsedOutput.images,
            status: failed
                ? ToolStatus.failed
                : done
                ? ToolStatus.succeeded
                : ToolStatus.running,
          );
    _tools.putIfAbsent(id, DateTime.now);
    emit(ItemUpserted(nextSeq(), id, item));
    if (done) _tools.remove(id);
    if (_agentIdsByTool[id] case final finishedAgent?) {
      _updateParent(finishedAgent);
    }
    if (path != null && done && kind == ToolKind.edit) {
      final payload = _reportedEditPayloads[id];
      final editBefore = original ?? payload?.before;
      final editAfter = newContent ?? payload?.after;
      unawaited(afterEdit?.call(path));
      unawaited(
        _reportFile(
          path,
          turnId: turnId,
          itemId: id,
          before: editBefore,
          after: editAfter,
        ),
      );
    }
  }

  /// Start the disk read synchronously while AGY's edit tool is ACTIVE.
  /// Declaring this `async` defers invoking [readFile] to a microtask, which
  /// lets a fast AGY edit overwrite the file before its original is captured.
  Future<String?> _captureBefore(String path) =>
      readFile?.call(path) ?? Future<String?>.value();

  static Map<String, Object?>? _decodeParameters(Object? value) {
    if (value is Map) return value.cast<String, Object?>();
    if (value is! String || value.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

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

  static String _pathKey(String path) =>
      path.replaceAll('\\', '/').toLowerCase();

  static bool _isAgentTool(String name) => const {
    'invoke_subagent',
    'browser_subagent',
  }.contains(name.toLowerCase());

  static bool _isPluginTool(String name) => const {
    'search_marketplace',
    'list_plugin_accounts',
    'install_plugin',
    'uninstall_plugin',
    'enable_plugin',
    'disable_plugin',
    'list_plugins',
  }.contains(name.toLowerCase());

  static bool _isTaskTool(String name) => const {
    'manage_task',
    'manage_subagents',
    'schedule',
  }.contains(name.toLowerCase());

  static String? _taskId(Map<String, Object?> input, String? output) =>
      _string(input['TaskId']) ??
      _string(input['task_id']) ??
      _string(input['conversation_id']) ??
      RegExp(
        r'(?:with task id|task id|Task ID|Task):\s*([^\s]+)',
        caseSensitive: false,
      ).firstMatch(output ?? '')?.group(1);

  static String _shortTaskId(String id) {
    final slash = id.lastIndexOf('/');
    return slash >= 0 && slash < id.length - 1 ? id.substring(slash + 1) : id;
  }

  static KernelTask _task(
    String id,
    String description,
    CommandStatus status,
    DateTime startedAt, {
    bool background = true,
    String? summary,
  }) => KernelTask(
    id: id,
    description: description,
    kind: KernelTaskKind.agent,
    status: status,
    startedAt: startedAt,
    toolUseId: id,
    background: background,
    summary: summary,
  );

  void _reportTask(
    String id, {
    required String name,
    required String state,
    required String? output,
  }) {
    final status = _agentStatus(state);
    final background = _isBackgroundState(state);
    final terminal = _isTerminalState(state);
    _tasks[id] = _task(
      id,
      name,
      status,
      _tools[id] ?? DateTime.now(),
      background: background || !terminal,
      summary: output,
    );
    onTasksChanged?.call([..._tasks.values]);
  }

  static bool _isBackgroundState(String state) =>
      state == 'BACKGROUND' || state == 'SCHEDULED' || state == 'RUNNING';

  static bool _isTerminalState(String state) => const {
    'DONE',
    'COMPLETED',
    'SUCCESS',
    'SUCCEEDED',
    'ERROR',
    'FAILED',
    'CANCELLED',
    'CANCELED',
    'STOPPED',
  }.contains(state);

  static String? _agentId(
    Map<String, Object?> step,
    Map<String, Object?> info,
    Map<String, Object?> parameters,
  ) =>
      _string(step['subagent_id']) ??
      _string(step['conversation_id']) ??
      _string(info['subagent_id']) ??
      _string(info['conversation_id']) ??
      _string(parameters['conversationId']) ??
      _string(parameters['conversation_id']) ??
      _string(parameters['ConversationId']);

  static String? _parentAgentId(
    Map<String, Object?> step,
    Map<String, Object?> info,
    Map<String, Object?> parameters,
  ) =>
      _string(step['parent_subagent_id']) ??
      _string(info['parent_subagent_id']) ??
      _string(parameters['parent_subagent_id']);

  void _reportAgent(
    String agentId, {
    required String name,
    required Map<String, Object?> parameters,
    required Map<String, Object?> info,
    required String? output,
    required String state,
    required DateTime? startedAt,
    required String? parentId,
  }) {
    final existing = _agents[agentId];
    final prompt =
        _string(
          parameters['Prompt'] ??
              parameters['prompt'] ??
              parameters['initial_prompt'],
        ) ??
        _string(info['Prompt'] ?? info['prompt'] ?? info['initial_prompt']);
    final resolvedDescription =
        _string(parameters['Role'] ?? parameters['role']) ??
        _string(info['Role'] ?? info['role']) ??
        _string(parameters['description']) ??
        _string(info['description']) ??
        name;
    final description = resolvedDescription;
    final item =
        existing ??
        AgentItem(
          description: description,
          id: agentId,
          agentType:
              _string(parameters['TypeName'] ?? parameters['type_name']) ??
              _string(info['TypeName'] ?? info['type_name']) ??
              _string(info['type']),
          prompt: prompt,
          status: CommandStatus.running,
          startedAt: startedAt,
        );
    final children = _agentChildren[agentId] ?? const <ChatItem>[];
    _agents[agentId] = item.copyWith(
      description: description,
      prompt: prompt,
      status: _agentStatus(state),
      result: output,
      children: children,
    );
    if (parentId case final parent? when parent != agentId) {
      _agentParents[agentId] = parent;
      final parentItem = _agents[parent];
      if (parentItem != null) {
        _reportAgentChild(parent, agentId, _agents[agentId]!);
        return;
      }
    }
    emit(ItemUpserted(nextSeq(), agentId, _agents[agentId]!));
    _tasks[agentId] = KernelTask(
      id: agentId,
      description: description,
      kind: KernelTaskKind.agent,
      status: _agentStatus(state),
      startedAt: startedAt ?? DateTime.now(),
      toolUseId: agentId,
      background: false,
      summary: output,
    );
    onTasksChanged?.call([..._tasks.values]);
    // AGY creates the child transcript after the initial invocation event.
    // Reload on later status updates too, otherwise a first empty read leaves
    // Subagent View permanently blank for the rest of the parent turn.
    if (readSubagentTranscript != null) {
      unawaited(_loadAgentTranscript(agentId));
    }
  }

  Future<void> _loadAgentTranscript(String agentId) async {
    final transcript = await readSubagentTranscript?.call(agentId);
    if (transcript == null) return;
    final agent = _agents[agentId];
    if (agent == null) return;
    if (transcript.items.isNotEmpty) {
      _agentChildren[agentId] = transcript.items;
    }
    _agents[agentId] = agent.copyWith(
      prompt: transcript.prompt,
      children: _agentChildren[agentId] ?? const <ChatItem>[],
      status: transcript.completed ? CommandStatus.succeeded : null,
    );
    emit(ItemUpserted(nextSeq(), agentId, _agents[agentId]!));
  }

  void _reportAgentChild(String agentId, String childId, ChatItem child) {
    final children = [...?_agentChildren[agentId]];
    final index = children.indexWhere(
      (item) => item is AgentItem && item.id == childId,
    );
    if (index >= 0) {
      children[index] = child;
    } else {
      children.add(child);
    }
    _agentChildren[agentId] = children;
    final agent = _agents[agentId];
    if (agent == null) return;
    _agents[agentId] = agent.copyWith(children: children);
    emit(ItemUpserted(nextSeq(), agentId, _agents[agentId]!));
  }

  void _updateParent(String agentId) {
    final parent = _agentParents[agentId];
    if (parent == null) return;
    final child = _agents[agentId];
    if (child != null) _reportAgentChild(parent, agentId, child);
  }

  static CommandStatus _agentStatus(String state) => switch (state) {
    'DONE' ||
    'COMPLETED' ||
    'SUCCESS' ||
    'SUCCEEDED' => CommandStatus.succeeded,
    'ERROR' || 'FAILED' || 'CANCELLED' || 'CANCELED' => CommandStatus.failed,
    _ => CommandStatus.running,
  };

  Future<void> _reportFile(
    String path, {
    String? turnId,
    required String itemId,
    String? before,
    String? after,
  }) async {
    final key = _pathKey(path);
    final fullBefore = await _beforeFiles[key]?.catchError((_) => null);
    final fullAfter = await readFile?.call(path);

    if (before == null || after == null) {
      final snapshot = await readEditSnapshot?.call(path, target: before);
      before ??= snapshot?.before;
      after ??= snapshot?.after;
    }
    final payload = _reportedEditPayloads[itemId];
    before ??= payload?.before ?? fullBefore;
    after ??= payload?.after ?? fullAfter;
    final cleanBefore = before?.replaceAll('\r\n', '\n');
    final cleanAfter = after?.replaceAll('\r\n', '\n');
    if (cleanAfter == null && cleanBefore == null) return;
    if (cleanAfter == cleanBefore) return;

    var startLine = 1;
    if (cleanBefore != null && fullBefore != null) {
      final normFile = fullBefore.replaceAll('\r\n', '\n');
      final index = normFile.indexOf(cleanBefore);
      if (index >= 0) {
        startLine = '\n'.allMatches(normFile.substring(0, index)).length + 1;
      }
    }
    if (startLine == 1 && cleanAfter != null && fullAfter != null) {
      final normFile = fullAfter.replaceAll('\r\n', '\n');
      final index = normFile.indexOf(cleanAfter);
      if (index >= 0) {
        startLine = '\n'.allMatches(normFile.substring(0, index)).length + 1;
      }
    }

    final diffResult = _computeDiff(
      cleanBefore ?? '',
      cleanAfter ?? '',
      startLine: startLine,
    );
    emit(
      ItemUpserted(
        nextSeq(),
        itemId,
        CodeDiffItem(
          fileName: path.split(RegExp(r'[/\\]')).last,
          directory: path.contains(RegExp(r'[/\\]'))
              ? path.substring(0, path.lastIndexOf(RegExp(r'[/\\]')))
              : '',
          lines: diffResult.lines,
          added: diffResult.added,
          removed: diffResult.removed,
        ),
      ),
    );
    emit(
      FileEdited(
        nextSeq(),
        FileChange(
          path: path,
          added: diffResult.added,
          removed: diffResult.removed,
        ),
        turnId: turnId,
        original: before == null
            ? const OriginalText(null)
            : OriginalByPatch(diffResult.diff),
      ),
    );
    if (fullAfter != null) {
      _beforeFiles[key] = Future.value(fullAfter);
    } else {
      _beforeFiles.remove(key);
    }
  }

  static ({List<DiffLine> lines, int added, int removed, String diff}) _computeDiff(
    String before,
    String after, {
    int startLine = 1,
  }) {
    List<String> split(String text) {
      if (text.isEmpty) return const [];
      final lines = text.split('\n');
      if (lines.length > 1 && lines.last.isEmpty) {
        lines.removeLast();
      }
      return lines;
    }

    final a = split(before);
    final b = split(after);
    final common = a.length * b.length <= 250000
        ? List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0))
        : null;
    if (common != null) {
      for (var i = a.length - 1; i >= 0; i--) {
        for (var j = b.length - 1; j >= 0; j--) {
          common[i][j] = a[i] == b[j]
              ? common[i + 1][j + 1] + 1
              : math.max(common[i + 1][j], common[i][j + 1]);
        }
      }
    }
    final diffLines = <DiffLine>[];
    final unified = <String>[
      '--- a/file',
      '+++ b/file',
      '@@ -$startLine,${a.length} +$startLine,${b.length} @@',
    ];
    var added = 0;
    var removed = 0;
    var i = 0;
    var j = 0;
    while (i < a.length || j < b.length) {
      if (common != null && i < a.length && j < b.length && a[i] == b[j]) {
        diffLines.add(DiffLine(DiffLineType.context, startLine + j, b[j]));
        unified.add(' ${b[j]}');
        i++;
        j++;
      } else if (i < a.length &&
          (j == b.length ||
              common == null ||
              common[i + 1][j] >= common[i][j + 1])) {
        diffLines.add(DiffLine(DiffLineType.removed, startLine + i, a[i]));
        unified.add('-${a[i]}');
        removed++;
        i++;
      } else {
        diffLines.add(DiffLine(DiffLineType.added, startLine + j, b[j]));
        unified.add('+${b[j]}');
        added++;
        j++;
      }
    }
    return (
      lines: diffLines,
      added: added,
      removed: removed,
      diff: unified.join('\n'),
    );
  }

  void _result(Map<String, Object?> result) {
    final current = turnId;
    if (current == null) return;
    final id = textId;
    if (id != null) emit(ItemCompleted(nextSeq(), id));
    final rawUsage = _map(result['usage']);
    if (rawUsage.isNotEmpty) _reportUsage(rawUsage);
    final response = _string(result['response']);
    if (response != null && _looksLikeContextReport(response)) {
      _reportUsage(_parseContextReport(response));
    }
    final status = _string(result['status']);
    emit(
      TurnEnded(
        nextSeq(),
        current,
        interrupted: status != null && status != 'SUCCESS',
        worked: startedAt == null
            ? null
            : DateTime.now().difference(startedAt!),
      ),
    );
    onTurnEnded?.call(current);
    resetTurn();
  }

  void _reportUsage(Map<String, Object?> usage) {
    final reported = _contextUsage(usage);
    // AGY stream events expose only this request's token counts. They are not
    // the conversation-wide `/context` reading, so never replace one here.
    if (_isTurnOnlyUsage(usage, reported)) return;
    emit(UsageReported(nextSeq(), reported));
  }

  bool _isTurnOnlyUsage(Map<String, Object?> usage, ContextUsage reported) {
    if (_categories(usage).isNotEmpty || _detail(usage) != null) return false;
    final input = _int(usage['input_tokens']);
    final output = _int(usage['output_tokens']);
    final total = _int(usage['total_tokens']);
    return input != null ||
        output != null ||
        total != null && reported.used < 10_000;
  }

  ContextUsage _contextUsage(Map<String, Object?> usage) {
    final total =
        _int(usage['total_tokens']) ??
        ((_int(usage['input_tokens']) ?? 0) +
            (_int(usage['output_tokens']) ?? 0));
    final window =
        _int(usage['context_window']) ?? _int(usage['max_tokens']) ?? 1_000_000;
    final categories = _categories(usage);
    final input = _int(usage['input_tokens']);
    final output = _int(usage['output_tokens']);
    return ContextUsage(
      window: window,
      used: total,
      segments: [
        ...categories,
        if (categories.isEmpty && input != null && input > 0)
          ContextSegment('User messages', input),
        if (categories.isEmpty && output != null && output > 0)
          ContextSegment('Agent responses', output),
      ],
      detail: _detail(usage),
    );
  }

  bool _looksLikeContextReport(String text) =>
      text.contains('Context window') ||
      text.contains('Context Usage') ||
      text.contains('Token usage by category');

  Map<String, Object?> _parseContextReport(String text) {
    final categories = <Map<String, Object?>>[];
    final linePattern = RegExp(
      r'^\s*(?:[◉○●◌◍▪▫□■]\s*)?(.+?)(?::|\s+)\s*([\d.]+)([kKmM]?)\s*(?:tokens?)?\s*\((\d+)%\)',
      multiLine: true,
    );
    int tokens(String raw, String suffix) {
      final value = double.parse(raw);
      final multiplier = suffix.toLowerCase() == 'm'
          ? 1000000
          : suffix.toLowerCase() == 'k'
          ? 1000
          : 1;
      return (value * multiplier).round();
    }

    for (final match in linePattern.allMatches(text)) {
      final label = match.group(1)!.trim();
      final value = tokens(match.group(2)!, match.group(3)!);
      final percent = int.parse(match.group(4)!);
      categories.add({
        'name': label,
        'tokens': value,
        'kind': label.toLowerCase().contains('free') ? 'free' : 'used',
      });
      if (percent == 0 && value == 0) {
        categories.last['tokens'] = 0;
      }
    }
    final total = categories.fold<int>(
      0,
      (sum, item) => sum + (item['tokens'] as int),
    );
    final windowMatch = RegExp(r'Context window.*?([\d.]+)([kKmM])?')
        .firstMatch(text);
    final window = windowMatch == null
        ? 1000000
        : tokens(windowMatch.group(1)!, windowMatch.group(2) ?? '');
    return {
      'total_tokens': total,
      'context_window': window,
      'categories': categories,
    };
  }

  List<ContextSegment> _categories(Map<String, Object?> usage) {
    final raw =
        usage['categories'] ??
        usage['breakdown'] ??
        usage['token_breakdown'] ??
        usage['context_breakdown'];
    if (raw is! List) return const [];
    return [
      for (final value in raw)
        if (value is Map)
          if (_string(value['name'] ?? value['label']) case final label?)
            if (_int(value['tokens'] ?? value['token_count'])
                case final tokens?)
              ContextSegment(
                label,
                tokens,
                kind: _contextKind(value['kind'] ?? value['type']),
              ),
    ];
  }

  ContextDetail? _detail(Map<String, Object?> usage) {
    final files =
        usage['files'] ?? usage['loaded_files'] ?? usage['context_files'];
    if (files is! List || files.isEmpty) return null;
    final items = <ContextItem>[];
    for (final value in files) {
      if (value is Map) {
        final name = _string(value['name'] ?? value['path']);
        if (name != null) {
          items.add(
            ContextItem(
              name,
              _int(value['tokens'] ?? value['token_count']) ?? 0,
              source: 'Antigravity',
            ),
          );
        }
      } else {
        final name = _string(value);
        if (name != null) items.add(ContextItem(name, 0));
      }
    }
    return items.isEmpty ? null : ContextDetail(memoryFiles: items);
  }

  static ContextKind _contextKind(Object? value) =>
      switch ('$value'.toLowerCase()) {
        'free' => ContextKind.free,
        'buffer' || 'reserved' => ContextKind.buffer,
        'deferred' => ContextKind.deferred,
        _ => ContextKind.used,
      };

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};
  static String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
  static int? _int(Object? value) =>
      value is int ? value : int.tryParse('$value');
}
