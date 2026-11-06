import 'dart:async';

/// Antigravity's `--input-format stream-json` transport over one JSON object
/// per line on stdin/stdout.
abstract interface class AgyTransport {
  Stream<Map<String, Object?>> get messages;
  void write(Map<String, Object?> message);
  void close();
  Future<void> get exited;
}

/// Launch settings for one Antigravity process.
class AgyLaunch {
  const AgyLaunch({
    required this.cwd,
    this.conversation,
    this.model,
    this.mode = 'auto',
    this.effort,
    this.sandbox = false,
    this.addDirectories = const [],
    this.dangerouslySkipPermissions = true,
  });

  final String cwd;
  final String? conversation;
  final String? model;
  final String mode;
  final String? effort;
  final bool sandbox;
  final List<String> addDirectories;
  final bool dangerouslySkipPermissions;

  List<String> get arguments => [
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    if (conversation case final id? when id.isNotEmpty) ...['--conversation', id],
    if (model case final value? when value.isNotEmpty) ...['--model', value],
    if (mode.isNotEmpty) ...['--mode', mode],
    if (effort case final value? when value.isNotEmpty) ...['--effort', value],
    if (sandbox) '--sandbox',
    for (final directory in addDirectories) ...['--add-dir', directory],
    if (dangerouslySkipPermissions) '--dangerously-skip-permissions',
  ];

  Map<String, Object?> userMessage(String text) => {
    'event': 'user',
    'message': {'role': 'user', 'content': text},
  };
}
