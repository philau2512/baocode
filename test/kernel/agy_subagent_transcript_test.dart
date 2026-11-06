import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agy/agy_subagent_transcript.dart';

void main() {
  test('reconstructs child tool activity from AGY transcript', () async {
    final home = await Directory.systemTemp.createTemp('agy-subagent-transcript');
    addTearDown(() => home.delete(recursive: true));
    final file = File('${home.path}\\.gemini\\antigravity-cli\\brain\\sub-1\\.system_generated\\logs\\transcript.jsonl');
    await file.parent.create(recursive: true);
    await file.writeAsString('${jsonEncode({
      'tool_calls': [
        {'name': 'read_file', 'id': 'read-1', 'args': {'Path': 'README.md'}, 'output': '11 lines, 784 bytes'},
      ],
    })}\n');

    final items = await AgySubagentTranscriptReader(home: home.path)
        .read(conversation: 'sub-1');

    expect(items, hasLength(1));
    expect(items.single, isA<ToolCallItem>());
    expect((items.single as ToolCallItem).kind, ToolKind.read);
  });
}
