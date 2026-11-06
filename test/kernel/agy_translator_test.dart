import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agy/agy_translator.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';

void main() {
  test('updates one AGY tool item from active to completed', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'tool-1',
        'tool_name': 'read_file',
        'state': 'ACTIVE',
        'tool_info': {
          'parameters': {'Path': 'README.md'},
        },
      },
    });
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'tool-1',
        'tool_name': 'read_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {'Path': 'README.md'},
          'output': 'done',
        },
      },
    });

    final items = events.whereType<ItemUpserted>().toList();
    expect(items, hasLength(2));
    expect(items[0].id, items[1].id);
    expect((items[0].item as ToolCallItem).status, ToolStatus.running);
    expect((items[1].item as ToolCallItem).status, ToolStatus.succeeded);
    expect((items[1].item as ToolCallItem).output, 'done');
  });

  test('classifies AGY read_file as a file read', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'read-1',
        'tool_name': 'read_file',
        'state': 'COMPLETED',
        'tool_info': {'parameters': {'Path': r'C:\\PROJECTS\\baocode\\README.md'}},
      },
    });

    final item = events.whereType<ItemUpserted>().single.item as ToolCallItem;
    expect(item.kind, ToolKind.read);
    expect(item.path, r'C:\\PROJECTS\\baocode\\README.md');
  });

  test('parses context report text from AGY result response', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'result',
      'result': {
        'status': 'SUCCESS',
        'response': '''Context window 39.0k / 1.0M tokens - 4%
User messages 38.4k tokens (98%)
Agent responses 636 tokens (2%)
Tool calls 0 tokens (0%)
System prompt 8.3k tokens (0%)
Free space 1.0M tokens (97%)''',
      },
    });

    final usage = events.whereType<UsageReported>().single.usage;
    expect(usage.segments.map((segment) => segment.label), containsAll([
      'User messages',
      'Agent responses',
      'Tool calls',
      'System prompt',
      'Free space',
    ]));
    expect(usage.segments.firstWhere((segment) => segment.label == 'Tool calls').tokens, 0);
  });

  test('reports AGY context categories and loaded files when provided', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'agent_response',
        'text_delta': 'ok',
        'usage': {
          'total_tokens': 39000,
          'context_window': 1000000,
          'categories': [
            {'name': 'System prompt', 'tokens': 8300},
            {'name': 'System tools', 'tokens': 5100},
            {'name': 'User messages', 'tokens': 38400},
            {'name': 'Agent responses', 'tokens': 636},
            {'name': 'Free space', 'tokens': 961000, 'kind': 'free'},
          ],
          'files': [
            {'path': 'README.md', 'tokens': 120},
          ],
        },
      },
    });

    final usage = events.whereType<UsageReported>().single.usage;
    expect(usage.used, 39000);
    expect(usage.window, 1000000);
    expect(usage.segments, hasLength(5));
    expect(usage.segments.last.kind, ContextKind.free);
    expect(usage.detail?.memoryFiles.single.name, 'README.md');
  });

  test('uses AGY original and new content for file review', () async {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {'Path': 'README.md'},
          'originalContent': 'before\n',
          'newContent': 'after\n',
        },
      },
    });
    await Future<void>.delayed(Duration.zero);

    final edit = events.whereType<FileEdited>().single;
    expect(edit.original, isA<OriginalByPatch>());
    expect((edit.original as OriginalByPatch).diff, contains('-before'));
    expect((edit.original as OriginalByPatch).diff, contains('+after'));
  });

  test('keeps AGY edit payload while the turn ends', () async {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'Path': 'README.md',
            'Target': 'before\n',
            'Replacement': 'after\n',
          },
        },
      },
    });
    translator.accept({
      'event': 'result',
      'result': {'status': 'SUCCESS'},
    });
    await Future<void>.delayed(Duration.zero);

    final edit = events.whereType<FileEdited>().single;
    expect(edit.original, isA<OriginalByPatch>());
  });

  test('uses persisted AGY edit snapshot for file review', () async {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readEditSnapshot: (_) async => (before: 'before\n', after: 'after\n'),
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {'parameters': {'Path': 'README.md'}},
      },
    });
    await Future<void>.delayed(Duration.zero);

    final edit = events.whereType<FileEdited>().single;
    expect(edit.original, isA<OriginalByPatch>());
  });

  test('uses AGY edit target and replacement for file review', () async {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'Path': 'README.md',
            'Target': 'before\n',
            'Replacement': 'after\n',
          },
        },
      },
    });
    await Future<void>.delayed(Duration.zero);

    final edit = events.whereType<FileEdited>().single;
    expect(edit.original, isA<OriginalByPatch>());
    expect((edit.original as OriginalByPatch).diff, contains('-before'));
    expect((edit.original as OriginalByPatch).diff, contains('+after'));
  });

  test('normalizes relative and absolute path keys for file snapshots', () async {
    final events = <KernelEvent>[];
    var reads = 0;
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readFile: (_) async {
        reads++;
        return reads == 1 ? 'before\n' : 'after\n';
      },
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'ACTIVE',
        'tool_info': {'parameters': {'Path': 'README.md'}},
      },
    });
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {'parameters': {'Path': 'README.md'}},
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(events.whereType<FileEdited>(), hasLength(1));
    expect(events.whereType<FileEdited>().single.original, isA<OriginalByPatch>());
  });

  test('captures the original before AGY can finish a fast edit', () async {
    final events = <KernelEvent>[];
    final original = Completer<String?>();
    var captured = false;
    var reads = 0;
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readFile: (_) {
        captured = true;
        return ++reads == 1 ? original.future : Future.value('after\n');
      },
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'ACTIVE',
        'tool_info': {'parameters': {'Path': 'README.md'}},
      },
    });
    expect(captured, isTrue);
    original.complete('before\n');
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {'parameters': {'Path': 'README.md'}},
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(events.whereType<FileEdited>().single.original, isA<OriginalByPatch>());
  });

  test('emits a patch that ChangeReview can undo', () async {
    final events = <KernelEvent>[];
    var reads = 0;
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readFile: (path) async {
        reads++;
        return reads == 1 ? 'before\n' : 'after\n';
      },
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {'Path': 'README.md'},
        },
      },
    });
    await Future<void>.delayed(Duration.zero);

    final edit = events.whereType<FileEdited>().single;
    expect(edit.original, isA<OriginalByPatch>());
    expect(edit.original, isNotNull);
  });
}
