import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agy/agy_subagent_transcript.dart';

void main() {
  test('reconstructs prompt, child activity, and completion from AGY transcript', () async {
    final home = await Directory.systemTemp.createTemp('agy-subagent-transcript');
    addTearDown(() => home.delete(recursive: true));
    final file = File(
      '${home.path}\\.gemini\\antigravity-cli\\brain\\sub-1'
      '\\.system_generated\\logs\\transcript.jsonl',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString([
      jsonEncode({
        'type': 'SYSTEM_MESSAGE',
        'content': '<SYSTEM_MESSAGE>content=Inspect pubspec.yaml</SYSTEM_MESSAGE>',
      }),
      jsonEncode({
        'type': 'PLANNER_RESPONSE',
        'tool_calls': [
          {'name': 'read_file', 'id': 'read-1', 'args': {'Path': 'README.md'}},
        ],
      }),
      jsonEncode({
        'type': 'GENERIC',
        'content': 'Created At: now\nShowing lines 1-1 of 1\n1: hello',
      }),
      jsonEncode({
        'type': 'PLANNER_RESPONSE',
        'content': 'Finished checking the file.',
      }),
    ].join('\n'));

    final transcript = await AgySubagentTranscriptReader(home: home.path)
        .inspect(conversation: 'sub-1');

    expect(transcript.items, hasLength(2));
    expect(transcript.items.first, isA<ToolCallItem>());
    final tool = transcript.items.first as ToolCallItem;
    expect(tool.kind, ToolKind.read);
    expect(tool.output, contains('1: hello'));
    expect(
      (transcript.items.last as AssistantTextItem).text,
      'Finished checking the file.',
    );
    expect(transcript.prompt, 'Inspect pubspec.yaml');
    expect(transcript.completed, isTrue);
  });
}
