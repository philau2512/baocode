import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agy_transport.dart';

/// Native process transport for Antigravity CLI.
final class ProcessTransport implements AgyTransport {
  ProcessTransport._(this._process) {
    _live.add(this);
    _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_line, onError: _error, onDone: _stdoutDone);
    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_stderr.add, onError: _error);
    unawaited(_process.exitCode.then(_exited));
  }

  static final Set<ProcessTransport> _live = {};

  static Future<AgyTransport> start(AgyLaunch launch) async {
    if (!Directory(launch.cwd).existsSync()) {
      throw ProcessException('agy', launch.arguments, 'Folder not found', 1);
    }
    try {
      final process = await Process.start(
        'agy',
        launch.arguments,
        workingDirectory: launch.cwd,
        includeParentEnvironment: Platform.isWindows,
        runInShell: Platform.isWindows,
      );
      return ProcessTransport._(process);
    } on ProcessException {
      rethrow;
    }
  }

  static Future<void> stopAll({Duration timeout = const Duration(seconds: 3)}) async {
    await Future.wait([for (final transport in [..._live]) transport._stop(timeout)]);
  }

  final Process _process;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast(sync: true);
  final List<String> _stderr = [];
  bool _stdoutClosed = false;
  int? _exitCode;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  List<String> get stderrLines => List.unmodifiable(_stderr);

  void _error(Object error) => _stderr.add('$error');

  void _line(String line) {
    if (line.trim().isEmpty) return;
    try {
      final value = jsonDecode(line);
      if (value is Map) {
        _messages.add(value.cast<String, Object?>());
      } else {
        _stderr.add(line);
      }
    } on FormatException {
      _stderr.add(line);
    }
  }

  void _stdoutDone() {
    _stdoutClosed = true;
    _finish();
  }

  void _exited(int code) {
    _exitCode = code;
    _live.remove(this);
    _finish();
  }

  void _finish() {
    if (_exitCode == null || !_stdoutClosed || _messages.isClosed) return;
    _messages.close();
  }

  Future<void> _stop(Duration timeout) async {
    close();
    try {
      await _process.exitCode.timeout(timeout);
    } on TimeoutException {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '${_process.pid}', '/T', '/F']);
      } else {
        _process.kill(ProcessSignal.sigkill);
      }
    }
  }

  @override
  void write(Map<String, Object?> message) {
    if (_exitCode != null) return;
    try {
      _process.stdin.writeln(jsonEncode(message));
    } on StateError {
      // The process exit will close the message stream.
    }
  }

  @override
  void close() {
    if (_exitCode != null) return;
    unawaited(_process.stdin.close().catchError((_) {}));
    if (!Platform.isWindows) _process.kill();
  }

  @override
  Future<void> get exited => _process.exitCode.then((_) {});
}
