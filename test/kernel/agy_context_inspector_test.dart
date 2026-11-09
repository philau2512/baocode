import 'package:flutter_test/flutter_test.dart';

import 'package:baocode/kernel/agy/agy_context_inspector_io.dart';

void main() {
  test('does not treat prompt text inside output as ready input', () {
    expect(parseAgyContextForTest('> /context'), isNull);
  });
  test('parses AGY context categories and files', () {
    final report = parseAgyContextForTest('''
Context Usage 21.4k/1.0M tokens (2.0%)
Token usage by category
User messages: 160 tokens (0.0%)
Agent responses: 383 tokens (0.0%)
Tool calls: 296 tokens (0.0%)
System prompt: 7.1k tokens (0.7%)
System tools: 5.1k tokens (0.5%)
Skills: 7.6k tokens (0.7%)
Subagents: 689 tokens (0.1%)
Free space: 1.0M tokens (98.0%)
System files · auto-loaded
└ ~/.gemini/GEMINI.md
└ ~/.gemini/skills/
''');

    expect(report, isNotNull);
    expect(report!.segments, hasLength(8));
    expect(report.segments.last.free, isTrue);
    expect(report.files, contains('~/.gemini/GEMINI.md'));
    expect(report.window, 1000000);
  });

  test('normalizes terminal decorations from category labels', () {
    final report = parseAgyContextForTest('''
Context Usage 21.4k/1.0M tokens (2.0%)
Token usage by category
└ ◉ User messages: 160 tokens (0.0%)
└ ◉ System prompt: 7.1k tokens (0.7%)
└ ○ Free space: 1.0M tokens (98.0%)
''');

    expect(report, isNotNull);
    expect(
      report!.segments.map((segment) => segment.label),
      containsAll(['User messages', 'System prompt', 'Free space']),
    );
  });

  test('does not count repeated PTY redraws twice', () {
    const snapshot = '''
Context Usage 21.4k/1.0M tokens (2.0%)
Token usage by category
User messages: 160 tokens (0.0%)
Agent responses: 383 tokens (0.0%)
Tool calls: 296 tokens (0.0%)
System prompt: 7.1k tokens (0.7%)
System tools: 5.1k tokens (0.5%)
Skills: 7.6k tokens (0.7%)
Subagents: 689 tokens (0.1%)
Free space: 1.0M tokens (98.0%)
System files · auto-loaded
└ ~/.gemini/GEMINI.md
''';
    final report = parseAgyContextForTest(snapshot + snapshot);

    expect(report, isNotNull);
    expect(report!.used, 21_328);
    expect(report.segments, hasLength(8));
  });
}
