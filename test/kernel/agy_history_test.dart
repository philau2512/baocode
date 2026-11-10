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
{"step_index":1,"type":"PLANNER_RESPONSE","content":"Checking the file.","tool_calls":[{"id":"command-1","name":"run_command","args":{"CommandLine":"dir","toolSummary":"List files"}},{"id":"mcp-1","name":"call_mcp_tool","args":{"ServerName":"\\"context7\\"","ToolName":"\\"resolve-library-id\\""}}]}
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
      for (final event in events.whereType<ItemUpserted>())
        event.id: event.item,
    };
    final items = itemsById.values.toList();
    expect(
      items.whereType<UserMessageItem>().single.text,
      'Inspect test_edit.md',
    );
    expect(
      items.whereType<AssistantTextItem>().single.text,
      'Checking the file.',
    );
    final command = itemsById['command-1'] as TerminalItem;
    expect(command.command, 'dir');
    expect(command.output, 'file.txt');
    final tool = itemsById['mcp-1'] as ToolCallItem;
    expect(tool.label, 'MCP · context7 · resolve-library-id');
    expect(tool.target, 'resolve-library-id');
    expect(tool.output, contains('"React"'));
  });

  test('keeps persisted edit results with their tool rows', () async {
    final dir = await Directory.systemTemp.createTemp('agy-history-edit');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}\\transcript.jsonl');
    await file.writeAsString(
      [
        jsonEncode({
          'step_index': 0,
          'type': 'PLANNER_RESPONSE',
          'tool_calls': [
            {
              'id': 'edit-1',
              'name': 'edit_file',
              'args': {'Path': 'lib/main.dart'},
            },
          ],
        }),
        jsonEncode({
          'step_index': 1,
          'type': 'GENERIC',
          'content':
              'Made 1 replacement in C:\\PROJECTS\\baocode\\lib\\main.dart.',
        }),
        jsonEncode({
          'step_index': 2,
          'type': 'PLANNER_RESPONSE',
          'content': 'Finished the edit.',
        }),
      ].join('\n'),
    );

    final events = <KernelEvent>[];
    await AgyHistory(emit: events.add, nextSeq: () => events.length).replay(
      SessionRecord(
        id: 'history-edit',
        title: 'history',
        updatedAt: DateTime.now(),
        cwd: dir.path,
        path: file.path,
      ),
    );

    final itemsById = <String, ChatItem>{
      for (final event in events.whereType<ItemUpserted>())
        event.id: event.item,
    };
    expect(
      itemsById.values.whereType<AssistantTextItem>().single.text,
      'Finished the edit.',
    );
    expect(
      (itemsById['edit-1'] as ToolCallItem).output,
      contains('Made 1 replacement'),
    );
  });

  test('restores AGY read ranges from persisted tool arguments', () async {
    final dir = await Directory.systemTemp.createTemp('agy-history-range');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}\\transcript.jsonl');
    await file.writeAsString(
      jsonEncode({
        'step_index': 0,
        'type': 'PLANNER_RESPONSE',
        'tool_calls': [
          {
            'id': 'read-1',
            'name': 'read_file',
            'args': {'Path': 'lib/main.dart', 'StartLine': 10, 'EndLine': '15'},
          },
        ],
      }),
    );

    final events = <KernelEvent>[];
    await AgyHistory(emit: events.add, nextSeq: () => events.length).replay(
      SessionRecord(
        id: 'history-range',
        title: 'history',
        updatedAt: DateTime.now(),
        cwd: dir.path,
        path: file.path,
      ),
    );

    final read = events.whereType<ItemUpserted>().single.item as ToolCallItem;
    expect(read.detail, 'L10-15');
  });

  test('does not expose AGY system notices during history replay', () async {
    final dir = await Directory.systemTemp.createTemp('agy-history-system');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}\\transcript.jsonl');
    await file.writeAsString(
      [
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
      ].join('\n'),
    );

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

  test('restores AGY schedule and manage_task tool calls from transcript', () async {
    final dir = await Directory.systemTemp.createTemp('agy-history-task-tools');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}\\transcript.jsonl');
    await file.writeAsString([
      jsonEncode({
        'step_index': 0,
        'type': 'PLANNER_RESPONSE',
        'tool_calls': [
          {
            'id': 'schedule-1',
            'name': 'schedule',
            'args': {
              'DurationSeconds': '8',
              'Prompt': '"Check if gradle test finished"',
            },
          },
        ],
      }),
      jsonEncode({
        'step_index': 1,
        'type': 'GENERIC',
        'content':
            'Created At: now\nTool is running as a background task with task id: 79377b35/task-160',
      }),
      jsonEncode({
        'step_index': 2,
        'type': 'PLANNER_RESPONSE',
        'tool_calls': [
          {
            'id': 'manage-1',
            'name': 'manage_task',
            'args': {
              'Action': '"status"',
              'TaskId': '"79377b35-b41c-4ba4-a64b-7a3c6e60f70b/task-154"',
            },
          },
        ],
      }),
      jsonEncode({
        'step_index': 3,
        'type': 'GENERIC',
        'content':
            'Created At: now\nTask: 79377b35/task-154\nStatus: RUNNING\nLog: file:///task.log',
      }),
    ].join('\n'));

    final events = <KernelEvent>[];
    await AgyHistory(emit: events.add, nextSeq: () => events.length).replay(
      SessionRecord(
        id: 'history-task-tools',
        title: 'history',
        updatedAt: DateTime.now(),
        cwd: dir.path,
        path: file.path,
      ),
    );

    final itemsById = <String, ChatItem>{
      for (final event in events.whereType<ItemUpserted>())
        event.id: event.item,
    };
    final schedule = itemsById['schedule-1'] as ToolCallItem;
    expect(schedule.label, 'Scheduled timer');
    expect(schedule.target, 'Check if gradle test finished');
    expect(schedule.detail, '8s');

    final manage = itemsById['manage-1'] as ToolCallItem;
    expect(manage.label, 'Checked task');
    expect(manage.target, 'task-154');
    expect(manage.detail, 'running');
  });

  test('resolves contextual task names for background commands and cancelled timers', () async {
    final dir = await Directory.systemTemp.createTemp('agy-history-task-resolved');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}\\transcript.jsonl');
    await file.writeAsString([
      jsonEncode({
        'step_index': 0,
        'type': 'PLANNER_RESPONSE',
        'tool_calls': [
          {
            'id': 'cmd-1',
            'name': 'run_command',
            'args': {
              'CommandLine': 'cd sea-turtle && .\\gradlew.bat testClasses',
              'toolSummary': 'Run gradle testClasses to verify',
            },
          },
        ],
      }),
      jsonEncode({
        'step_index': 1,
        'type': 'GENERIC',
        'content':
            'Created At: now\nTool is running as a background task with task id: conv-1/task-150\nTask Description: cd sea-turtle && .\\gradlew.bat testClasses',
      }),
      jsonEncode({
        'step_index': 2,
        'type': 'PLANNER_RESPONSE',
        'tool_calls': [
          {
            'id': 'check-status-1',
            'name': 'manage_task',
            'args': {
              'Action': 'status',
              'TaskId': 'conv-1/task-150',
            },
          },
        ],
      }),
      jsonEncode({
        'step_index': 3,
        'type': 'GENERIC',
        'content': 'Task: conv-1/task-150\nStatus: RUNNING\nLog: file:///task.log',
      }),
      jsonEncode({
        'step_index': 4,
        'type': 'PLANNER_RESPONSE',
        'tool_calls': [
          {
            'id': 'timer-1',
            'name': 'schedule',
            'args': {
              'DurationSeconds': '5',
              'Prompt': 'Check task-150 status',
            },
          },
        ],
      }),
      jsonEncode({
        'step_index': 5,
        'type': 'GENERIC',
        'content':
            'Tool is running as a background task with task id: conv-1/task-154\nTask Description: Timer: 5s, Prompt: Check task-150 status',
      }),
      jsonEncode({
        'step_index': 6,
        'type': 'PLANNER_RESPONSE',
        'tool_calls': [
          {
            'id': 'kill-timer-1',
            'name': 'manage_task',
            'args': {
              'Action': 'kill',
              'TaskId': 'conv-1/task-154',
            },
          },
        ],
      }),
      jsonEncode({
        'step_index': 7,
        'type': 'GENERIC',
        'content': 'Task "conv-1/task-154" cancelled.',
      }),
    ].join('\n'));

    final events = <KernelEvent>[];
    await AgyHistory(emit: events.add, nextSeq: () => events.length).replay(
      SessionRecord(
        id: 'history-task-resolved',
        title: 'history',
        updatedAt: DateTime.now(),
        cwd: dir.path,
        path: file.path,
      ),
    );

    final itemsById = <String, ChatItem>{
      for (final event in events.whereType<ItemUpserted>())
        event.id: event.item,
    };

    final statusItem = itemsById['check-status-1'] as ToolCallItem;
    expect(statusItem.label, 'Checked task');
    expect(statusItem.target, 'Run gradle testClasses to verify (task-150)');
    expect(statusItem.detail, 'running');

    final killTimerItem = itemsById['kill-timer-1'] as ToolCallItem;
    expect(killTimerItem.label, 'Cancelled timer');
    expect(killTimerItem.target, 'Check task-150 status (5s)');
  });

  test('restores thinking as ThinkingItem from PLANNER_RESPONSE steps', () async {
    final dir = await Directory.systemTemp.createTemp('agy-history-thinking');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}\\transcript.jsonl');
    await file.writeAsString([
      jsonEncode({
        'step_index': 0,
        'type': 'USER_INPUT',
        'content': '<USER_REQUEST>\nSolve math puzzle\n</USER_REQUEST>',
      }),
      jsonEncode({
        'step_index': 1,
        'type': 'PLANNER_RESPONSE',
        'thinking': 'First, compare the integer parts. Both are 9. Next, compare the tenths...',
        'content': '9.9 is larger than 9.11.',
      }),
    ].join('\n'));

    final events = <KernelEvent>[];
    await AgyHistory(emit: events.add, nextSeq: () => events.length).replay(
      SessionRecord(
        id: 'history-thinking',
        title: 'history',
        updatedAt: DateTime.now(),
        cwd: dir.path,
        path: file.path,
      ),
    );

    final itemsById = <String, ChatItem>{
      for (final event in events.whereType<ItemUpserted>())
        event.id: event.item,
    };

    final thinkingItem = itemsById['agy-history-1:thinking'] as ThinkingItem;
    expect(thinkingItem.text, contains('First, compare the integer parts'));
    expect(thinkingItem.streaming, isFalse);
    expect(thinkingItem.tokens, greaterThan(0));
    expect(thinkingItem.seconds, greaterThanOrEqualTo(1));

    final assistantItem = itemsById['1:history'] as AssistantTextItem;
    expect(assistantItem.text, '9.9 is larger than 9.11.');
  });
}
