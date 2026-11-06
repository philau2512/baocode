import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'agy_context_inspector.dart';
import 'agy_edit_transcript.dart';
import 'agy_history.dart';
import 'agy_translator.dart';
import 'agy_transport.dart';
import 'process_transport.dart';

/// Adapts Antigravity CLI's verified stream-json print protocol to BaoCode.
final class AntigravityKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsMode,
        SelectsEffort,
        ReportsContext,
        ReportsUsage,
        ProvidesCommands,
        LoadsHistory,
        ConfirmsModelSwitch {
  AntigravityKernel(
    this.descriptor,
    this._context, {
    Future<AgyTransport> Function(AgyLaunch launch)? start,
  }) : _start = start ?? startAgy {
    _history = AgyHistory(emit: emit, nextSeq: () => nextSeq);
    _translator = AgyTranslator(
      emit: emit,
      nextSeq: () => nextSeq,
      readFile: _readFile,
      readEditSnapshot: _readEditSnapshot,
      onTurnEnded: (turnId) {
        if (_turn == turnId) {
          _turn = null;
          _refreshContextAfterTurn();
        }
      },
    );
    _model = _ModelChoice(
      models: _models,
      selectedValue: () => _selectedModel ?? _models.first.id,
      onSelected: (value) {
        _selectedModel = value;
        emitInfoChanged();
      },
    );
    _mode = _LocalChoice(
      options: _modes,
      selectedValue: () => _selectedMode,
      onSelected: (value) {
        _selectedMode = value;
        emitInfoChanged();
      },
    );
    _effort = _ModelSetting(
      options: (_) => _efforts,
      selectedValue: () => _selectedEffort,
      selectedForValue: (_) => _selectedEffort,
      onSelected: (_, value) {
        _selectedEffort = value;
        emitInfoChanged();
      },
    );
  }

  @override
  final KernelDescriptor descriptor;
  final KernelContext _context;
  final Future<AgyTransport> Function(AgyLaunch launch) _start;
  late final AgyTranslator _translator;
  late final AgyHistory _history;
  final AgyEditTranscriptReader _editTranscript = AgyEditTranscriptReader();
  late final _ModelChoice _model;
  late final _LocalChoice _mode;
  late final _ModelSetting _effort;

  static const _models = [
    KernelOption('gemini-3.8-flash-medium', 'Gemini 3.8 Flash (Medium)', Icons.auto_awesome_rounded, 'Balanced Gemini coding model'),
    KernelOption('gemini-3.8-flash-high', 'Gemini 3.8 Flash (High)', Icons.auto_awesome_rounded, 'Higher reasoning effort'),
    KernelOption('gemini-3.8-flash-low', 'Gemini 3.8 Flash (Low)', Icons.auto_awesome_rounded, 'Fast Gemini coding model'),
    KernelOption('claude-sonnet-4-6', 'Claude Sonnet 4.6', Icons.auto_awesome_rounded, 'Claude through Antigravity'),
    KernelOption('claude-opus-4-6-thinking', 'Claude Opus 4.6 Thinking', Icons.auto_awesome_rounded, 'High capability Claude model'),
  ];

  static const _modes = [
    KernelOption('auto', 'Auto', Icons.all_inclusive_rounded, 'Antigravity chooses the execution policy'),
    KernelOption('accept-edits', 'Accept edits', Icons.edit_rounded, 'Allow workspace edits'),
    KernelOption('plan', 'Plan', Icons.assignment_outlined, 'Plan before editing'),
  ];

  static const _efforts = [
    KernelOption('low', 'Low', Icons.speed_rounded, 'Fastest reasoning'),
    KernelOption('medium', 'Medium', Icons.speed_rounded, 'Balanced reasoning'),
    KernelOption('high', 'High', Icons.bolt_rounded, 'Deeper reasoning'),
    KernelOption('xhigh', 'Extra high', Icons.bolt_rounded, 'Maximum supported reasoning'),
    KernelOption('max', 'Max', Icons.bolt_rounded, 'Maximum reasoning'),
  ];

  static const _commands = [
    KernelCommand('context', 'Show context usage and loaded files', Icons.data_usage_rounded),
    KernelCommand('refresh-context', 'Refresh context usage from Antigravity', Icons.refresh_rounded),
    KernelCommand('model', 'Switch Antigravity model', Icons.auto_awesome_rounded, argumentHint: '<model>'),
    KernelCommand('mode', 'Switch Antigravity execution mode', Icons.tune_rounded, argumentHint: '<auto|accept-edits|plan>'),
    KernelCommand('effort', 'Set reasoning effort', Icons.bolt_rounded, argumentHint: '<low|medium|high|xhigh|max>'),
    KernelCommand('clear', 'Start a new Antigravity conversation', Icons.refresh_rounded),
    KernelCommand('compact', 'Compact the Antigravity conversation', Icons.compress_rounded),
    KernelCommand('help', 'Show Antigravity slash commands', Icons.help_outline_rounded),
  ];

  @override
  List<KernelCommand> get commands => _commands;

  String? _selectedModel = _models.first.id;
  String _selectedMode = 'auto';
  String? _selectedEffort = 'medium';
  AgyTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void>? _starting;
  Future<void> _stopped = Future.value();
  KernelHealth _health = KernelHealth.idle;
  String? _sessionId;
  String? _turn;
  bool _disposed = false;
  bool _loadingHistory = false;
  bool _historyLoaded = false;

  @override
  KernelHealth get health => _health;

  @override
  String? get sessionId => _sessionId;

  @override
  Future<void> get stopped => _stopped;

  @override
  KernelChoiceSource get model => _model;

  @override
  KernelChoiceSource get mode => _mode;

  @override
  ModelSetting get effort => _effort;

  @override
  bool get loadingHistory => _loadingHistory;

  @override
  bool get hasEarlierHistory => false;

  @override
  bool get loadingEarlier => false;

  @override
  Future<void> loadEarlier() => Future.value();

  @override
  int get contextWindow => 1_000_000;

  @override
  List<RateLimitWindow> get accountLimits => const [];

  @override
  Future<void> refreshUsage() async {
    final report = await inspectAgyContext(
      cwd: _cwd,
      conversation: _sessionId ?? _context.resume?.id,
    );
    if (report == null) return;
    emit(
      UsageReported(
        nextSeq,
        ContextUsage(
          window: report.window,
          used: report.used,
          segments: [
            for (final segment in report.segments)
              ContextSegment(
                segment.label,
                segment.tokens,
                kind: segment.free ? ContextKind.free : ContextKind.used,
              ),
          ],
          detail: report.files.isEmpty
              ? null
              : ContextDetail(
                  memoryFiles: [
                    for (final file in report.files) ContextItem(file, 0),
                  ],
                ),
        ),
      ),
    );
  }

  void _refreshContextAfterTurn() {
    unawaited(refreshUsage());
  }

  @override
  bool switchRestarts(String model) => model != _selectedModel;

  String get _cwd => _context.cwd ?? _context.resume?.cwd ?? '.';

  Future<String?> _readFile(String path) async {
    try {
      final file = File(p.isAbsolute(path) ? path : p.join(_cwd, path));
      return await file.readAsString();
    } on Object {
      return null;
    }
  }

  Future<({String before, String after})?> _readEditSnapshot(String path) async {
    final conversation = _sessionId;
    if (conversation == null) return null;
    for (var attempt = 0; attempt < 10; attempt++) {
      final snapshot = await _editTranscript.read(
        conversation: conversation,
        path: path,
      );
      if (snapshot != null) {
        return (before: snapshot.before, after: snapshot.after);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  void _setHealth(KernelHealth value) {
    _health = value;
    emitInfoChanged();
  }

  Future<void> _ensureStarted() {
    if (_disposed) return Future.error(StateError('Antigravity kernel is disposed'));
    if (_transport != null && _health.status == KernelHealthStatus.ready) return Future.value();
    return _starting ??= _launch().whenComplete(() => _starting = null);
  }

  Future<void> _launch() async {
    await _stopped;
    final session = _context.resume;
    if (!_historyLoaded && session != null) {
      _historyLoaded = true;
      _loadingHistory = true;
      emitInfoChanged();
      await _history.replay(session);
      _loadingHistory = false;
      emitInfoChanged();
    }
    _setHealth(const KernelHealth(KernelHealthStatus.starting));
    try {
      final launch = AgyLaunch(
        cwd: _cwd,
        conversation: _context.resume?.id ?? _sessionId,
        model: _selectedModel,
        mode: _selectedMode,
        effort: _selectedEffort,
        dangerouslySkipPermissions: true,
      );
      final transport = await _start(launch);
      _transport = transport;
      _stopped = transport.exited.whenComplete(() {
        if (identical(_transport, transport)) {
          _transport = null;
          _subscription = null;
          if (!_disposed && _health.status != KernelHealthStatus.idle) {
            _setHealth(const KernelHealth(KernelHealthStatus.failed, message: 'Antigravity stopped'));
          }
        }
      });
      _subscription = transport.messages.listen(_receive, onError: _failed, onDone: _done);
      _setHealth(KernelHealth.ready);
    } on Object catch (error) {
      _setHealth(KernelHealth(KernelHealthStatus.failed, message: 'Antigravity could not start', detail: '$error'));
      rethrow;
    }
  }

  void _receive(Map<String, Object?> message) {
    final event = message['event'];
    if (event == 'init') {
      _sessionId = message['conversation_id'] as String?;
      _setHealth(KernelHealth.ready);
    }
    _translator.accept(message);
  }

  void _failed(Object error) {
    _setHealth(KernelHealth(KernelHealthStatus.failed, message: 'Antigravity stream failed', detail: '$error'));
  }

  void _done() {
    if (_turn case final turn?) {
      emit(TurnEnded(nextSeq, turn, interrupted: true));
      _turn = null;
    }
  }

  @override
  void send(KernelTurn turn) {
    if (_disposed || _turn != null) return;
    if (turn.text.trim() == '/context' || turn.text.trim() == '/refresh-context') {
      unawaited(refreshUsage());
      return;
    }
    _turn = turn.id;
    _translator.beginTurn(turn.id);
    emit(TurnStarted(nextSeq, turn.id));
    emit(ItemUpserted(nextSeq, '${turn.id}:user', UserMessageItem(text: turn.text)));
    unawaited(_send(turn));
  }

  Future<void> _send(KernelTurn turn) async {
    try {
      await _ensureStarted();
      if (_turn != turn.id) return;
      final transport = _transport;
      if (transport == null) throw StateError('Antigravity transport is unavailable');
      transport.write(AgyLaunch(cwd: _cwd).userMessage(turn.text));
    } on Object catch (error) {
      _setHealth(KernelHealth(KernelHealthStatus.failed, message: 'Antigravity turn failed', detail: '$error'));
      if (_turn == turn.id) {
        emit(TurnEnded(nextSeq, turn.id, interrupted: true));
        _turn = null;
      }
    }
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {}

  @override
  void cancel() {
    final turn = _turn;
    _turn = null;
    _transport?.close();
    if (turn != null) emit(TurnEnded(nextSeq, turn, interrupted: true));
  }

  @override
  void restart() {
    _transport?.close();
    _transport = null;
    _setHealth(KernelHealth.idle);
  }

  @override
  void prepare() {
    unawaited(_ensureStarted());
  }

  @override
  void release() {
    if (_turn == null) _transport?.close();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _turn = null;
    unawaited(_subscription?.cancel() ?? Future.value());
    _transport?.close();
    closeEvents();
  }
}

final class _LocalChoice implements KernelChoiceSource {
  _LocalChoice({required this.options, required this.selectedValue, required this.onSelected});
  @override
  List<KernelOption> options;
  final String Function() selectedValue;
  final void Function(String value) onSelected;
  @override
  String get selected => selectedValue();
  @override
  void select(String id) => onSelected(id);
}

final class _ModelChoice extends _LocalChoice implements SelectsModel {
  _ModelChoice({required List<KernelOption> models, required super.selectedValue, required super.onSelected}) : super(options: models);
  @override
  KernelChoiceSource get model => this;
}

final class _ModelSetting implements ModelSetting {
  _ModelSetting({required this.options, required this.selectedValue, required this.selectedForValue, required this.onSelected});
  final List<KernelOption> Function(String model) options;
  final String? Function() selectedValue;
  final String? Function(String model) selectedForValue;
  final void Function(String model, String value) onSelected;
  @override
  bool get toggle => false;
  @override
  List<KernelOption> optionsFor(String model) => options(model);
  @override
  String? get selected => selectedValue();
  @override
  String? selectedFor(String model) => selectedForValue(model);
  @override
  void select(String model, String id) => onSelected(model, id);
}
