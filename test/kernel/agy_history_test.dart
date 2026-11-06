import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agy/agy_history.dart';
import 'package:baocode/kernel/kernel_event.dart';

void main() {
  test('normalizes AGY envelopes and restores persisted tool calls', () async {
    final dir = await Directory.systemTemp.createTemp('agy-history-test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}\\transcript.jsonl');
    await file.writeAsString('''
{"step_index":0,"type":"USER_INPUT","content":"<USER_REQUEST>\\nInspect test_edit.md\\n</USER_REQUEST>\\n<ADDITIONAL_METADATA>hidden</ADDITIONAL_METADATA>"}
{"step_index":1,"type":"PLANNER_RESPONSE","content":"Checking the file.","tool_calls":[{"id":"command-1","name":"run_command","args":{"CommandLine":"dir","toolSummary":"List files"}},{"id":"mcp-1","name":"call_mcp_tool","args":{"ServerName":"\\\"context7\\\"","ToolName":"\\\"resolve-library-id\\\""}}]}
{"step_index":2,"type":"GENERIC","content":"Created At: now\\nCompleted At: now\\nCommand output:\\nfile.txt"}
{"step_index":3,"type":"GENERIC","content":"[\\n  {\\n    \\"name\\": \\"React\\"\\n  }\\n]"}
''');

    final events = <KernelEvent>[];
    await AgyHistory(emit: events.add, nextSeq: () => events.length).replay(
      SessionRecord(
        id: 'history-1',
        title: 'history',
        updatedAt: DateTime.now(),
        cwd: dir.path,
        path: file.path,
      ),
    );

    final itemsById = <String, ChatItem>{
      for (final event in events.whereType<ItemUpserted>()) event.id: event.item,
    };
    final items = itemsById.values.toList();
    expect(items.whereType<UserMessageItem>().single.text, 'Inspect test_edit.md');
    expect(items.whereType<AssistantTextItem>().single.text, 'Checking the file.');
    final command = itemsById['command-1'] as TerminalItem;
    expect(command.command, 'dir');
    expect(command.output, 'file.txt');
    final tool = itemsById['mcp-1'] as ToolCallItem;
    expect(tool.label, 'MCP · context7 · resolve-library-id');
    expect(tool.target, 'resolve-library-id');
    expect(tool.output, contains('"React"'));
  });

  test('does not expose AGY system notices during history replay', () async {
    final dir = await Directory.systemTemp.createTemp('agy-history-system');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}\\transcript.jsonl');
    await file.writeAsString([
      jsonEncode({
        'step_index': 0,
        'type': 'USER_INPUT',
        'content': '<USER_REQUEST>\nFirst turn\n</USER_REQUEST>',
      }),
      jsonEncode({
        'step_index': 1,
        'type': 'PLANNER_RESPONSE',
        'content': 'First response.',
      }),
      jsonEncode({
        'step_index': 2,
        'type': 'SYSTEM_MESSAGE',
        'content': 'The following is a <SYSTEM_MESSAGE> not actually sent by the user.\n<SYSTEM_MESSAGE>server restart notice</SYSTEM_MESSAGE>',
      }),
      jsonEncode({
        'step_index': 3,
        'type': 'USER_INPUT',
        'content': '<USER_REQUEST>\nSecond turn\n</USER_REQUEST>',
      }),
    ].join('\n'));

    final events = <KernelEvent>[];
    await AgyHistory(emit: events.add, nextSeq: () => events.length).replay(
      SessionRecord(
        id: 'history-system',
        title: 'history',
        updatedAt: DateTime.now(),
        cwd: dir.path,
        path: file.path,
      ),
    );

    final texts = events
        .whereType<ItemUpserted>()
        .map((event) => event.item)
        .whereType<AssistantTextItem>()
        .map((item) => item.text);
    expect(texts, ['First response.']);
  });
}
