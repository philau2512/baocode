import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agy/agy_task_presentation.dart';

void main() {
  group('AgyTaskPresentation', () {
    test('parses schedule tool calls with duration and prompt', () {
      final info = AgyTaskPresentation.parse(
        'schedule',
        {
          'DurationSeconds': '8',
          'Prompt': '"Check if gradle test finished"',
        },
      );
      expect(info, isNotNull);
      expect(info!.label, 'Scheduled timer');
      expect(info.target, 'Check if gradle test finished');
      expect(info.detail, '8s');
    });

    test('parses schedule tool calls while running', () {
      final info = AgyTaskPresentation.parse(
        'schedule',
        {
          'DurationSeconds': 15,
          'Prompt': 'Wait for task',
        },
        running: true,
      );
      expect(info, isNotNull);
      expect(info!.label, 'Scheduling timer');
      expect(info.target, 'Wait for task');
      expect(info.detail, '15s');
    });

    test('parses schedule tool calls with cron expression', () {
      final info = AgyTaskPresentation.parse(
        'schedule',
        {
          'CronExpression': '*/5 * * * *',
          'Prompt': 'Periodic health check',
        },
      );
      expect(info, isNotNull);
      expect(info!.label, 'Scheduled cron');
      expect(info.target, 'Periodic health check');
      expect(info.detail, '*/5 * * * *');
    });

    test('parses manage_task status and shortens TaskId', () {
      final info = AgyTaskPresentation.parse(
        'manage_task',
        {
          'Action': '"status"',
          'TaskId': '"79377b35-b41c-4ba4-a64b-7a3c6e60f70b/task-154"',
        },
        output: 'Task: 79377b35/task-154\nStatus: RUNNING',
      );
      expect(info, isNotNull);
      expect(info!.label, 'Checked task');
      expect(info.target, 'task-154');
      expect(info.detail, 'running');
    });

    test('parses manage_task kill and handles error output', () {
      final info = AgyTaskPresentation.parse(
        'manage_task',
        {
          'Action': 'kill',
          'TaskId': '79377b35-b41c-4ba4-a64b-7a3c6e60f70b/task-168',
        },
        output: 'Encountered error in step execution: cannot kill task: not running',
      );
      expect(info, isNotNull);
      expect(info!.label, 'Stopped task');
      expect(info.target, 'task-168');
      expect(info.detail, 'not running');
    });

    test('parses manage_task list', () {
      final info = AgyTaskPresentation.parse(
        'manage_task',
        {'Action': 'list'},
      );
      expect(info, isNotNull);
      expect(info!.label, 'Listed tasks');
      expect(info.target, 'background tasks');
    });

    test('parses manage_subagents', () {
      final info = AgyTaskPresentation.parse(
        'manage_subagents',
        {'Action': 'kill_all'},
      );
      expect(info, isNotNull);
      expect(info!.label, 'Stopped subagents');
      expect(info.target, 'all subagents');
    });
  });
}
