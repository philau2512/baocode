import 'dart:async';
import 'dart:convert';

import '../../chat/chat_models.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';

/// Translates verified Antigravity stream-json events into BaoCode events.
final class AgyTranslator {
  AgyTranslator({
    required this.emit,
    required this.nextSeq,
    this.onTurnEnded,
    this.readFile,
    this.readEditSnapshot,
  });

  final void Function(KernelEvent event) emit;
  final int Function() nextSeq;
  final void Function(String turnId)? onTurnEnded;
  final Future<String?> Function(String path)? readFile;
  final Future<({String before, String after})?> Function(String path)?
      readEditSnapshot;
  final Map<String, Future<String?>> _beforeFiles = {};
  final Map<String, String> _reportedOriginals = {};

  String? conversationId;
  String? turnId;
  String? textId;
  int textLength = 0;
  DateTime? startedAt;
  /// Maps AGY's tool identity to the stable BaoCode item id. AGY emits
  /// multiple `step_update` events for one tool, so the id must not be based
  /// on the number of updates received.
  final Map<String, String> _toolIds = {};
  final Map<String, DateTime> _tools = {};

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
    _tools.clear();
    _toolIds.clear();
    _reportedOriginals.clear();
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
      emit(ItemUpserted(nextSeq(), id, const AssistantTextItem(''), streaming: true));
    }
    emit(TextDelta(nextSeq(), id, textLength, delta));
    textLength += delta.length;
  }

  void _tool(Map<String, Object?> step) {
    _begin();
    final name = _string(step['tool_name']) ?? _string(step['name']) ?? 'tool';
    final info = _map(step['tool_info']);
    final parameters = _map(info['parameters']).isNotEmpty
        ? _map(info['parameters'])
        : _map(step['parameters']).isNotEmpty
        ? _map(step['parameters'])
        : _decodeParameters(step['arguments']) ??
            _decodeParameters(info['arguments']) ??
            const <String, Object?>{};
    final toolKey = _string(step['tool_id']) ??
        _string(step['id']) ??
        _string(info['tool_id']) ??
        _string(info['id']) ??
        '$name:${parameters.toString()}';
    final id = _toolIds.putIfAbsent(
      toolKey,
      () => '$turnId:tool:${_toolIds.length}',
    );
    final state = (_string(step['state']) ??
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
    final failed = const {
      'ERROR',
      'FAILED',
      'CANCELLED',
      'CANCELED',
    }.contains(state);
    final output = _string(info['output']) ??
        _string(info['result']) ??
        _string(info['error']) ??
        _string(step['output']) ??
        _string(step['error']);
    final original = _string(info['originalContent']) ??
        _string(info['original_content']) ??
        _string(step['originalContent']) ??
        _string(step['original_content']) ??
        _string(parameters['Target']) ??
        _string(parameters['target']);
    final newContent = _string(info['newContent']) ??
        _string(info['new_content']) ??
        _string(step['newContent']) ??
        _string(step['new_content']) ??
        _string(parameters['Replacement']) ??
        _string(parameters['replacement']);
    final command = _string(parameters['CommandLine']) ?? _string(parameters['command']);
    final path = _string(parameters['Path']) ?? _string(parameters['path']);
    final fileKey = path == null ? null : _pathKey(path);
    if (path != null && original != null) {
      _reportedOriginals[fileKey!] = original;
    }
    if (path != null && newContent != null) {
      _reportedOriginals['$fileKey:after'] = newContent;
    }
    if (fileKey != null && !_beforeFiles.containsKey(fileKey)) {
      _beforeFiles[fileKey] = _captureBefore(path!);
    }
    final kind = switch (name.toLowerCase()) {
      'read_file' || 'readfile' => ToolKind.read,
      _ when path != null => ToolKind.edit,
      _ => ToolKind.other,
    };
    final item = command != null
        ? TerminalItem(
            command: command,
            output: output ?? '',
            status: failed ? CommandStatus.failed : done
                ? CommandStatus.succeeded
                : CommandStatus.running,
            startedAt: _tools[id],
          )
        : ToolCallItem(
            kind: kind,
            target: path ?? name,
            path: path,
            label: name,
            input: parameters,
            output: output,
            status: failed ? ToolStatus.failed : done
                ? ToolStatus.succeeded
                : ToolStatus.running,
          );
    _tools.putIfAbsent(id, DateTime.now);
    emit(ItemUpserted(nextSeq(), id, item));
    if (done) _tools.remove(id);
    if (path != null && done && kind == ToolKind.edit) {
      unawaited(_reportFile(
        path,
        turnId: turnId,
        itemId: id,
        before: original,
        after: newContent,
      ));
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


  static String _pathKey(String path) => path.replaceAll('\\', '/').toLowerCase();

  Future<void> _reportFile(
    String path, {
    String? turnId,
    required String itemId,
    String? before,
    String? after,
  }) async {
    final key = _pathKey(path);
    if (before == null || after == null) {
      final snapshot = await readEditSnapshot?.call(path);
      before ??= snapshot?.before;
      after ??= snapshot?.after;
    }
    before ??= _reportedOriginals[key] ??
        await _beforeFiles[key]?.catchError((_) => null);
    after ??= _reportedOriginals['$key:after'] ?? await readFile?.call(path);
    if (after == null && before == null) return;
    if (after == before) return;
    final diff = _unifiedDiff(before, after);
    final oldLines = (before ?? '').split('\n');
    final newLines = (after ?? '').split('\n');
    final diffLines = <DiffLine>[];
    final common = oldLines.length < newLines.length ? oldLines.length : newLines.length;
    var added = 0;
    var removed = 0;
    for (var i = 0; i < common; i++) {
      if (oldLines[i] == newLines[i]) {
        diffLines.add(DiffLine(DiffLineType.context, i + 1, oldLines[i]));
      } else {
        diffLines.add(DiffLine(DiffLineType.removed, i + 1, oldLines[i]));
        diffLines.add(DiffLine(DiffLineType.added, i + 1, newLines[i]));
        removed++;
        added++;
      }
    }
    for (var i = common; i < oldLines.length; i++) {
      diffLines.add(DiffLine(DiffLineType.removed, i + 1, oldLines[i]));
      removed++;
    }
    for (var i = common; i < newLines.length; i++) {
      diffLines.add(DiffLine(DiffLineType.added, i + 1, newLines[i]));
      added++;
    }
    emit(ItemUpserted(
      nextSeq(),
      itemId,
      CodeDiffItem(
        fileName: path.split(RegExp(r'[/\\]')).last,
        directory: path.contains(RegExp(r'[/\\]'))
            ? path.substring(0, path.lastIndexOf(RegExp(r'[/\\]')))
            : '',
        lines: diffLines,
        added: added,
        removed: removed,
      ),
    ));
    emit(
      FileEdited(

        nextSeq(),
        FileChange(path: path, added: added, removed: removed),
        turnId: turnId,
        original: before == null ? const OriginalText(null) : OriginalByPatch(diff),
      ),
    );
    _beforeFiles.remove(key);
  }

  static String _unifiedDiff(String? before, String? after) {
    final oldLines = (before ?? '').split('\n');
    final newLines = (after ?? '').split('\n');
    final lines = <String>[
      '--- a/file',
      '+++ b/file',
      '@@ -1,${oldLines.length} +1,${newLines.length} @@',
    ];
    final common = oldLines.length < newLines.length ? oldLines.length : newLines.length;
    for (var i = 0; i < common; i++) {
      if (oldLines[i] == newLines[i]) {
        lines.add(' ${oldLines[i]}');
      } else {
        lines.add('-${oldLines[i]}');
        lines.add('+${newLines[i]}');
      }
    }
    for (var i = common; i < oldLines.length; i++) {
      lines.add('-${oldLines[i]}');
    }
    for (var i = common; i < newLines.length; i++) {
      lines.add('+${newLines[i]}');
    }
    return lines.join('\n');
  }

  void _result(Map<String, Object?> result) {
    final current = turnId;
    if (current == null) return;
    final id = textId;
    if (id != null) emit(ItemCompleted(nextSeq(), id));
    final rawUsage = _map(result['usage']);
    final usage = _turnUsage(rawUsage);
    if (rawUsage.isNotEmpty) _reportUsage(rawUsage);
    final response = _string(result['response']);
    if (response != null && _looksLikeContextReport(response)) {
      _reportUsage(_parseContextReport(response));
    }
    final duration = _number(result['duration_seconds']);
    final status = _string(result['status']);
    emit(
      TurnEnded(
        nextSeq(),
        current,
        interrupted: status != null && status != 'SUCCESS',
        worked: duration == null
            ? startedAt == null
                ? null
                : DateTime.now().difference(startedAt!)
            : Duration(milliseconds: (duration * 1000).round()),
        usage: usage,
      ),
    );
    onTurnEnded?.call(current);
    resetTurn();
  }

  TurnUsage? _turnUsage(Map<String, Object?> usage) {
    if (usage.isEmpty) return null;
    final input = _int(usage['input_tokens']);
    final output = _int(usage['output_tokens']);
    if (input == null && output == null) return null;
    return TurnUsage(inputTokens: input, outputTokens: output);
  }

  void _reportUsage(Map<String, Object?> usage) {
    emit(UsageReported(nextSeq(), _contextUsage(usage)));
  }

  ContextUsage _contextUsage(Map<String, Object?> usage) {
    final total = _int(usage['total_tokens']) ??
        ((_int(usage['input_tokens']) ?? 0) + (_int(usage['output_tokens']) ?? 0));
    final window = _int(usage['context_window']) ??
        _int(usage['max_tokens']) ??
        1_000_000;
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
    final total = categories.fold<int>(0, (sum, item) => sum + (item['tokens'] as int));
    final windowMatch = RegExp(r'Context window.*?([\d.]+)([kKmM])?').firstMatch(text);
    final window = windowMatch == null
        ? 1000000
        : tokens(windowMatch.group(1)!, windowMatch.group(2) ?? '');
    return {'total_tokens': total, 'context_window': window, 'categories': categories};
  }

  List<ContextSegment> _categories(Map<String, Object?> usage) {
    final raw = usage['categories'] ??
        usage['breakdown'] ??
        usage['token_breakdown'] ??
        usage['context_breakdown'];
    if (raw is! List) return const [];
    return [
      for (final value in raw)
        if (value is Map)
          if (_string(value['name'] ?? value['label']) case final label?)
            if (_int(value['tokens'] ?? value['token_count']) case final tokens?)
              ContextSegment(
                label,
                tokens,
                kind: _contextKind(value['kind'] ?? value['type']),
              ),
    ];
  }

  ContextDetail? _detail(Map<String, Object?> usage) {
    final files = usage['files'] ?? usage['loaded_files'] ?? usage['context_files'];
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

  static ContextKind _contextKind(Object? value) => switch ('$value'.toLowerCase()) {
    'free' => ContextKind.free,
    'buffer' || 'reserved' => ContextKind.buffer,
    'deferred' => ContextKind.deferred,
    _ => ContextKind.used,
  };

  static Map<String, Object?> _map(Object? value) => value is Map ? value.cast<String, Object?>() : const {};
  static String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;
  static int? _int(Object? value) => value is int ? value : int.tryParse('$value');
  static double? _number(Object? value) => value is num ? value.toDouble() : double.tryParse('$value');
}
