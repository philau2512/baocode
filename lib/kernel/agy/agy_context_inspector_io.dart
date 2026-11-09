import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_conpty/bao_conpty.dart';

import 'agy_context_inspector.dart';

Future<ContextReport?> inspectAgyContextPlatform({
  required String cwd,
  required String? conversation,
}) async {
  if (!WindowsPty.supported) return null;
  final pty = await WindowsPty.start(
    PtyLaunch(
      executable: 'agy',
      workingDirectory: cwd,
      arguments: [
        if (conversation case final id? when id.isNotEmpty)
          ...['--conversation', id],
        '--prompt-interactive=',
        '--dangerously-skip-permissions',
      ],
      columns: 140,
      rows: 60,
    ),
    Platform.environment,
  );
  final output = StringBuffer();
  // Decode the complete byte stream incrementally. Decoding each PTY chunk
  // separately can split a UTF-8 character and turn AGY labels into squares.
  final subscription = utf8.decoder
      .bind(pty.output.cast<List<int>>())
      .listen(output.write);
  try {
    if (!await _waitForPrompt(output)) return null;
    pty.writeText('/context\r\n');
    if (!await _waitForContext(output)) return null;
    return _parseContext(output.toString());
  } finally {
    await subscription.cancel();
    pty.kill(PtySignal.terminate);
    await pty.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () => -1,
    );
  }
}

Future<bool> _waitForPrompt(StringBuffer output) async {
  for (var i = 0; i < 100; i++) {
    final text = output.toString();
    if (_hasInputPrompt(text)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}

Future<bool> _waitForContext(StringBuffer output) async {
  for (var i = 0; i < 150; i++) {
    final text = output.toString();
    if (text.contains('Token usage by category') &&
        text.contains('Free space')) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}

bool _hasInputPrompt(String text) {
  final lines = text.replaceAll(_ansi, '').split('\n');
  return lines.any((line) {
    final trimmed = line.trimRight();
    return trimmed == '>' || trimmed.endsWith('> ');
  });
}

ContextReport? parseAgyContextForTest(String raw) => _parseContext(raw);

ContextReport? _parseContext(String raw) {
  final text = raw.replaceAll(_ansi, '');
  final contextStart = text.lastIndexOf('Context Usage');
  if (contextStart < 0) return null;
  final windowMatch = RegExp(
    r'Context Usage.*?([\d.]+)([kKmM])?/([\d.]+)([kKmM])?\s*tokens',
    dotAll: true,
  ).firstMatch(text.substring(contextStart));
  final categoryStart = text.indexOf('Token usage by category', contextStart);
  if (categoryStart < 0) return null;
  final body = text.substring(categoryStart);
  final pattern = RegExp(
    r'^\s*(?:[◉○●◌◍▪▫□■]\s*)?(.+?)(?::|\s+)\s*([\d.]+)([kKmM]?)\s*tokens\s*\(([\d.]+)%\)',
    multiLine: true,
  );
  final segments = <ContextReportSegment>[];
  for (final match in pattern.allMatches(body)) {
    final label = _categoryLabel(match.group(1)!);
    final tokens = _tokens(match.group(2)!, match.group(3)!);
    segments.add(
      ContextReportSegment(
        label,
        tokens,
        free: label.toLowerCase().contains('free'),
      ),
    );
  }
  if (segments.isEmpty) return null;
  final files = [
    for (final line in text.split('\n'))
      if (line.trimLeft().startsWith('└'))
        line.replaceFirst(RegExp(r'^\s*└\s*'), '').trim(),
  ];
  final window = windowMatch == null
      ? 1000000
      : _tokens(windowMatch.group(3)!, windowMatch.group(4) ?? '');
  final used = segments
      .where((segment) => !segment.free)
      .fold(0, (sum, segment) => sum + segment.tokens);
  return ContextReport(
    window: window,
    used: used,
    segments: segments,
    files: files,
  );
}

String _categoryLabel(String raw) {
  final label = raw
      .replaceAll(_ansi, '')
      .replaceAll(RegExp(r'^[\s◉○●◌◍▪▫□■┌└├│─]+'), '')
      .trim();
  const labels = {
    'user messages': 'User messages',
    'agent responses': 'Agent responses',
    'tool calls': 'Tool calls',
    'system prompt': 'System prompt',
    'system tools': 'System tools',
    'skills': 'Skills',
    'subagents': 'Subagents',
    'free space': 'Free space',
  };
  return labels[label.toLowerCase()] ?? label;
}

int _tokens(String value, String suffix) {
  final multiplier = switch (suffix.toLowerCase()) {
    'm' => 1000000,
    'k' => 1000,
    _ => 1,
  };
  return (double.parse(value) * multiplier).round();
}

final _ansi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
