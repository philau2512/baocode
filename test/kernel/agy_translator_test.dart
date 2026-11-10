import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_test/flutter_test.dart';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store_io.dart';
import 'package:baocode/kernel/agy/agy_translator.dart';
import 'package:baocode/kernel/agy/agy_subagent_transcript.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/transcript.dart';

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
        'tool_info': {
          'parameters': {
            'Path': r'C:\\PROJECTS\\baocode\\README.md',
            'StartLine': 10,
            'EndLine': '15',
          },
        },
      },
    });

    final item = events.whereType<ItemUpserted>().single.item as ToolCallItem;
    expect(item.kind, ToolKind.read);
    expect(item.target, 'README.md');
    expect(item.path, r'C:\\PROJECTS\\baocode\\README.md');
    expect(item.detail, 'L10-15');
  });

  test('uses subagent prompt and role from tool info when parameters are normalized there', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'invoke-1',
        'tool_name': 'invoke_subagent',
        'state': 'DONE',
        'tool_info': {
          'parameters': {'conversation_id': 'subagent-1'},
          'subagent_info': {
            'conversation_id': 'subagent-1',
            'Role': 'File Inspector',
            'TypeName': 'research',
            'Prompt': 'Inspect test_edit.md',
          },
        },
      },
    });

    final agent = events
        .whereType<ItemUpserted>()
        .map((event) => event.item)
        .whereType<AgentItem>()
        .single;
    expect(agent.description, 'File Inspector');
    expect(agent.prompt, 'Inspect test_edit.md');
    expect(agent.agentType, 'research');
  });

  test('maps invoke_subagent to an AgentItem', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'invoke-1',
        'tool_name': 'invoke_subagent',
        'state': 'DONE',
        'tool_info': {
          'parameters': {
            'Role': 'File Inspector',
            'TypeName': 'research',
            'Prompt': 'Inspect test_edit.md',
          },
          'subagent_info': {'conversation_id': 'subagent-1'},
          'output': '12 lines',
        },
      },
    });

    final agent = events
        .whereType<ItemUpserted>()
        .map((event) => event.item)
        .whereType<AgentItem>()
        .single;
    expect(agent.id, 'subagent-1');
    expect(agent.description, 'File Inspector');
    expect(agent.agentType, 'research');
    expect(agent.prompt, 'Inspect test_edit.md');
    expect(agent.status, CommandStatus.succeeded);
    expect(agent.result, '12 lines');
  });

  test('uses completed child transcript to update a subagent view', () async {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readSubagentTranscript: (_) async => const AgySubagentTranscript(
        prompt: 'Inspect pubspec.yaml',
        completed: true,
        items: [AssistantTextItem('Package: baocode')],
      ),
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'invoke-1',
        'tool_name': 'invoke_subagent',
        'state': 'ACTIVE',
        'tool_info': {
          'parameters': {'conversation_id': 'subagent-1'},
          'subagent_info': {'conversation_id': 'subagent-1'},
        },
      },
    });
    await Future<void>.delayed(Duration.zero);

    final agent = events
        .whereType<ItemUpserted>()
        .map((event) => event.item)
        .whereType<AgentItem>()
        .last;
    expect(agent.prompt, 'Inspect pubspec.yaml');
    expect(agent.children, [isA<AssistantTextItem>()]);
    expect(agent.status, CommandStatus.succeeded);
  });

  test('shows the concrete MCP tool name from AGY arguments', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'mcp-1',
        'tool_name': 'call_mcp_tool',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'ServerName': '"context7"',
            'ToolName': '"resolve-library-id"',
            'Arguments': '{}',
          },
        },
      },
    });

    final item = events.whereType<ItemUpserted>().single.item as ToolCallItem;
    expect(item.kind, ToolKind.mcp);
    expect(item.label, 'MCP · context7 · resolve-library-id');
    expect(item.target, 'resolve-library-id');
  });

  test('emits clickable search results and images from AGY output', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'search-1',
        'tool_name': 'grep_search',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {'pattern': 'AGY'},
          'output': 'lib/main.dart:42: AGY\ndata:image/png;base64,AA==',
        },
      },
    });

    final item = events.whereType<ItemUpserted>().single.item as ToolCallItem;
    expect(item.kind, ToolKind.grep);
    expect(item.results, ['lib/main.dart:42: AGY']);
    expect(item.images, hasLength(1));
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
    expect(
      usage.segments.map((segment) => segment.label),
      containsAll([
        'User messages',
        'Agent responses',
        'Tool calls',
        'System prompt',
        'Free space',
      ]),
    );
    expect(
      usage.segments
          .firstWhere((segment) => segment.label == 'Tool calls')
          .tokens,
      0,
    );
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

  test('does not overwrite a context report with turn-only token usage', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'agent_response',
        'usage': {
          'total_tokens': 167500,
          'context_window': 1000000,
          'categories': [
            {'name': 'Tool calls', 'tokens': 107700},
            {'name': 'Free space', 'tokens': 832500, 'kind': 'free'},
          ],
        },
      },
    });
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'agent_response',
        'usage': {'input_tokens': 3200, 'output_tokens': 400},
      },
    });

    final usage = events.whereType<UsageReported>().toList();
    expect(usage, hasLength(1));
    expect(usage.single.usage.used, 167500);
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
    await Future<void>.delayed(const Duration(milliseconds: 10));

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
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final edit = events.whereType<FileEdited>().single;
    expect(edit.original, isA<OriginalByPatch>());
  });

  test('uses persisted AGY edit snapshot for file review', () async {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readEditSnapshot: (_, {target}) async =>
          (before: 'before\n', after: 'after\n'),
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
    await Future<void>.delayed(const Duration(milliseconds: 10));

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
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final edit = events.whereType<FileEdited>().single;
    expect(edit.original, isA<OriginalByPatch>());
    expect((edit.original as OriginalByPatch).diff, contains('-before'));
    expect((edit.original as OriginalByPatch).diff, contains('+after'));
  });

  test(
    'normalizes relative and absolute path keys for file snapshots',
    () async {
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
          'tool_info': {
            'parameters': {'Path': 'README.md'},
          },
        },
      });
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

      expect(events.whereType<FileEdited>(), hasLength(1));
      expect(
        events.whereType<FileEdited>().single.original,
        isA<OriginalByPatch>(),
      );
    },
  );

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
        'tool_info': {
          'parameters': {'Path': 'README.md'},
        },
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
        'tool_info': {
          'parameters': {'Path': 'README.md'},
        },
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      events.whereType<FileEdited>().single.original,
      isA<OriginalByPatch>(),
    );
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
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final edit = events.whereType<FileEdited>().single;
    expect(edit.original, isA<OriginalByPatch>());
    expect(edit.original, isNotNull);
  });

  test('ChangeReview preserves initial base across multiple edits to same file', () async {
    final tempDir = Directory.systemTemp.createTempSync('agy_multi_edit_test');
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final file = File('${tempDir.path}\\config.ts');
    file.writeAsStringSync('const a = 1;\nconst b = 2;\n');

    final review = ChangeReview(
      BlobReviewStore.open('${tempDir.path}\\store'),
      root: tempDir.path,
    );

    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readFile: (path) async => file.readAsString(),
    )..beginTurn('turn-1');

    // First edit: change 'a = 1' to 'a = 10'
    file.writeAsStringSync('const a = 10;\nconst b = 2;\n');
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'Path': file.path,
            'Target': 'const a = 1;',
            'Replacement': 'const a = 10;',
          },
        },
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final edit1 = events.whereType<FileEdited>().last;
    review.report(edit1.change, original: edit1.original);
    await review.look();

    final baseAfterFirst = review.baseOf(file.path);
    expect(baseAfterFirst, isNotNull);

    // Second edit: change 'b = 2' to 'b = 20'
    file.writeAsStringSync('const a = 10;\nconst b = 20;\n');
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-2',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'Path': file.path,
            'Target': 'const b = 2;',
            'Replacement': 'const b = 20;',
          },
        },
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final edit2 = events.whereType<FileEdited>().last;
    review.report(edit2.change, original: edit2.original);
    await review.look();

    // Base must remain the original file before the first edit, not rebased
    expect(review.baseOf(file.path), baseAfterFirst);
    expect(await review.original(file.path)!(), 'const a = 1;\nconst b = 2;\n');

    // Undoing all restores the very original content
    await review.undoAll();
    expect(file.readAsStringSync(), 'const a = 1;\nconst b = 2;\n');
  });

  test('ChangeReview tracks and undoes AGY CRLF file edits', () async {
    final tempDir = Directory.systemTemp.createTempSync('agy_review_test');
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final file = File('${tempDir.path}\\popup.js');
    file.writeAsStringSync('line1\r\nold code\r\nline3\r\n');

    final review = ChangeReview(
      BlobReviewStore.open('${tempDir.path}\\store'),
      root: tempDir.path,
    );

    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readFile: (path) async => file.readAsString(),
    )..beginTurn('turn-1');

    // Simulate AGY edit changing 'old code' to 'new code'
    file.writeAsStringSync('line1\r\nnew code\r\nline3\r\n');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'Path': file.path,
            'Target': 'old code',
            'Replacement': 'new code',
          },
        },
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final edit = events.whereType<FileEdited>().single;
    review.report(edit.change, original: edit.original);
    await review.look();

    expect(review.changes, hasLength(1));
    expect(review.changes.single.tracked, isTrue);
    expect(review.baseOf(file.path), isNotNull);

    await review.undoAll();
    expect(file.readAsStringSync(), 'line1\r\nold code\r\nline3\r\n');
  });

  test('CodeDiffItem preserves actual file line numbers for middle file edits', () async {
    final tempDir = Directory.systemTemp.createTempSync('agy-diff-lines-test');
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final file = File(p.join(tempDir.path, 'source.dart'));

    // File with 109 lines before the target
    final prefix = List.generate(109, (i) => 'line ${i + 1}').join('\n');
    final before = '$prefix\nold code\nline 111\n';
    file.writeAsStringSync(before);

    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readFile: (path) async => file.readAsString(),
    )..beginTurn('turn-1');

    // Simulate AGY tool ACTIVE capturing original
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'ACTIVE',
        'tool_info': {
          'parameters': {'Path': file.path},
        },
      },
    });

    // File modified on disk
    file.writeAsStringSync('$prefix\nnew code 1\nnew code 2\nline 111\n');

    // Tool COMPLETED with Target and Replacement
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'Path': file.path,
            'Target': 'old code',
            'Replacement': 'new code 1\nnew code 2',
          },
        },
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final item = events
        .whereType<ItemUpserted>()
        .map((e) => e.item)
        .whereType<CodeDiffItem>()
        .single;
    expect(item.firstChangedLine, 110);
    final removed = item.lines.firstWhere((l) => l.type == DiffLineType.removed);
    expect(removed.lineNumber, 110);
    expect(removed.text, 'old code');

    final added = item.lines.where((l) => l.type == DiffLineType.added).toList();
    expect(added, hasLength(2));
    expect(added[0].lineNumber, 110);
    expect(added[0].text, 'new code 1');
    expect(added[1].lineNumber, 111);
    expect(added[1].text, 'new code 2');
  });

  test('matches context lines before insertion point at line 110', () async {
    final tempDir = Directory.systemTemp.createTempSync('agy-diff-context-test');
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final file = File(p.join(tempDir.path, 'source.dart'));

    // 98 lines before target starts at line 99
    final prefix = List.generate(98, (i) => 'prefix line ${i + 1}').join('\n');
    final target = [
      'class IdeFileListing {', // line 99
      '  final bool truncated;', // line 100
      '}', // line 101
    ].join('\n');
    file.writeAsStringSync('$prefix\n$target\n');

    final replacement = [
      'class IdeFileListing {', // line 99
      '  final bool truncated;', // line 100
      '}', // line 101
      '', // line 102
      'class IdeFileNameKey {', // line 103
      '}', // line 104
    ].join('\n');

    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readFile: (path) async => file.readAsString(),
    )..beginTurn('turn-1');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'ACTIVE',
        'tool_info': {
          'parameters': {'Path': file.path},
        },
      },
    });

    file.writeAsStringSync('$prefix\n$replacement\n');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'edit-1',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'Path': file.path,
            'Target': target,
            'Replacement': replacement,
          },
        },
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final item = events
        .whereType<ItemUpserted>()
        .map((e) => e.item)
        .whereType<CodeDiffItem>()
        .single;

    // Context lines should have lineNumber 99, 100, 101
    final contextLines = item.lines.where((l) => l.type == DiffLineType.context).toList();
    expect(contextLines.map((l) => l.lineNumber).toList(), [99, 100, 101]);

    // Added lines should start from line 102
    final addedLines = item.lines.where((l) => l.type == DiffLineType.added).toList();
    expect(addedLines.map((l) => l.lineNumber).toList(), [102, 103, 104]);
    expect(item.firstChangedLine, 102);
  });

  test('handles multiple sequential edits on the same file without overwriting', () async {
    final events = <KernelEvent>[];
    final dir = Directory.systemTemp.createTempSync('agy-multi-edit-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/test_file.dart')
      ..writeAsStringSync('line 1\nline 2\nline 3\n');

    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readFile: (path) async => File(path).readAsString(),
    )..beginTurn('turn-1');

    // First edit: change line 1
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_name': 'edit_file',
        'state': 'ACTIVE',
        'tool_info': {
          'parameters': {
            'Path': file.path,
            'Target': 'line 1\n',
            'Replacement': 'line 1 edited\n',
          },
        },
      },
    });
    file.writeAsStringSync('line 1 edited\nline 2\nline 3\n');
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {'Path': file.path},
        },
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Second edit on the same file: change line 3
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_name': 'edit_file',
        'state': 'ACTIVE',
        'tool_info': {
          'parameters': {
            'Path': file.path,
            'Target': 'line 3\n',
            'Replacement': 'line 3 edited\n',
          },
        },
      },
    });
    file.writeAsStringSync('line 1 edited\nline 2\nline 3 edited\n');
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_name': 'edit_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {'Path': file.path},
        },
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Must emit two distinct CodeDiffItem entries with distinct item IDs
    final diffItems = events
        .whereType<ItemUpserted>()
        .where((e) => e.item is CodeDiffItem)
        .toList();
    expect(diffItems.length, 2);
    expect(diffItems[0].id, isNot(equals(diffItems[1].id)));

    // Must emit two FileEdited events
    final fileEdits = events.whereType<FileEdited>().toList();
    expect(fileEdits.length, 2);

    final item1 = diffItems[0].item as CodeDiffItem;
    final item2 = diffItems[1].item as CodeDiffItem;
    expect(item1.added, 1);
    expect(item1.removed, 1);
    expect(item2.added, 1);
    expect(item2.removed, 1);
  });

  test('preserves strict temporal order between assistant texts and tool calls', () {
    final events = <KernelEvent>[];
    final transcript = Transcript();
    void emit(KernelEvent event) {
      events.add(event);
      transcript.apply(event);
    }

    final translator = AgyTranslator(
      emit: emit,
      nextSeq: () => events.length + 1,
    )..beginTurn('turn-1');

    // 1. Initial assistant text before tool
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'agent_response',
        'text_delta': 'Starting work...',
      },
    });

    // 2. Tool call in the middle
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'tool-1',
        'tool_name': 'read_file',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {'Path': 'pubspec.yaml'},
        },
      },
    });

    // 3. Final assistant text after tool
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'agent_response',
        'text_delta': 'Completed all tasks!',
      },
    });

    // Verify Transcript order
    expect(transcript.length, 3);
    final item0 = transcript.itemAt(0);
    final item1 = transcript.itemAt(1);
    final item2 = transcript.itemAt(2);

    expect(item0, isA<AssistantTextItem>());
    expect((item0 as AssistantTextItem).text, 'Starting work...');

    expect(item1, isA<ToolCallItem>());
    expect((item1 as ToolCallItem).tool, 'read_file');

    expect(item2, isA<AssistantTextItem>());
    expect((item2 as AssistantTextItem).text, 'Completed all tasks!');
  });

  test('run_command preserves toolSummary as TerminalItem.description', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-terminal');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'cmd-1',
        'tool_name': 'run_command',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'CommandLine': 'git status',
            'toolSummary': 'Git status check',
          },
          'output': 'On branch main',
        },
      },
    });

    final upserted = events.whereType<ItemUpserted>().last;
    expect(upserted.item, isA<TerminalItem>());
    final term = upserted.item as TerminalItem;
    expect(term.command, 'git status');
    expect(term.description, 'Git status check');
    expect(term.status, CommandStatus.succeeded);
  });

  test('ask_question emits QuestionRequest interaction', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-question');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'q-1',
        'tool_name': 'ask_question',
        'state': 'ACTIVE',
        'tool_info': {
          'parameters': {
            'questions': [
              {
                'question': 'Choose deployment target',
                'options': ['(Recommended) Staging', 'Production'],
                'is_multi_select': false,
              }
            ],
          },
        },
      },
    });

    final interaction = events.whereType<InteractionRequested>().single;
    expect(interaction.request, isA<QuestionRequest>());
    final req = interaction.request as QuestionRequest;
    expect(req.id, 'q-1');
    expect(req.questions, hasLength(1));
    expect(req.questions.first.prompt, 'Choose deployment target');
    expect(req.questions.first.options, hasLength(2));
    expect(req.questions.first.options.first.label, '(Recommended) Staging');
  });

  test('define_subagent formats label and target properly', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-define');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'sub-def-1',
        'tool_name': 'define_subagent',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'Name': 'Database Debugger',
            'Description': 'Inspects PostgreSQL schemas and locks',
            'SystemPrompt': 'You are a database expert.',
          },
        },
      },
    });

    final upserted = events.whereType<ItemUpserted>().last;
    expect(upserted.item, isA<ToolCallItem>());
    final tool = upserted.item as ToolCallItem;
    expect(tool.label, 'Define Agent');
    expect(tool.target, 'Database Debugger');
    expect(tool.detail, 'Inspects PostgreSQL schemas and locks');
  });

  test('manage_task with action list does not report a background task', () {
    final tasks = <KernelTask>[];
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      onTasksChanged: (t) => tasks.addAll(t),
    )..beginTurn('turn-task');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'task-list-1',
        'tool_name': 'manage_task',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'Action': 'list',
          },
          'output': 'Active tasks: none',
        },
      },
    });

    expect(tasks, isEmpty);
  });

  test('eager MCP tools starting with mcp_ are classified as ToolKind.mcp with clean label', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-mcp');

    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'mcp-1',
        'tool_name': 'mcp_fast-context_fast_context_search',
        'state': 'COMPLETED',
        'tool_info': {
          'parameters': {
            'query': 'AgyTranslator',
          },
          'output': 'Found 5 symbols',
        },
      },
    });

    final upserted = events.whereType<ItemUpserted>().last;
    expect(upserted.item, isA<ToolCallItem>());
    final tool = upserted.item as ToolCallItem;
    expect(tool.kind, ToolKind.mcp);
    expect(tool.label, 'MCP · fast-context · fast_context_search');
    expect(tool.target, 'AgyTranslator');
  });

  test('streams thinking_delta and completes ThinkingItem when assistant text starts', () {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
    )..beginTurn('turn-thinking');

    // 1. Thinking delta chunk 1
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'agent_response',
        'thinking_delta': 'Thinking about mathematics...',
      },
    });

    final thinkUpsert1 = events.whereType<ItemUpserted>().first;
    expect(thinkUpsert1.item, isA<ThinkingItem>());
    expect((thinkUpsert1.item as ThinkingItem).streaming, isTrue);

    final delta1 = events.whereType<TextDelta>().first;
    expect(delta1.text, 'Thinking about mathematics...');

    // 2. Thinking delta chunk 2
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'agent_response',
        'thinking_delta': ' 9.9 is greater than 9.11.',
      },
    });

    final delta2 = events.whereType<TextDelta>().last;
    expect(delta2.text, ' 9.9 is greater than 9.11.');

    // 3. Assistant text starts
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'agent_response',
        'text_delta': 'The larger number is 9.9.',
      },
    });

    // Thinking item should be completed with non-streaming ThinkingItem
    final completedItems = events.whereType<ItemUpserted>().where((e) => e.item is ThinkingItem).toList();
    expect(completedItems, hasLength(2));
    final completedThinking = completedItems.last.item as ThinkingItem;
    expect(completedThinking.streaming, isFalse);
    expect(completedThinking.text, 'Thinking about mathematics... 9.9 is greater than 9.11.');
    expect(completedThinking.seconds, greaterThanOrEqualTo(1));

    expect(events.whereType<ItemCompleted>().any((e) => e.id.contains('thinking')), isTrue);

    // Assistant text should now be streaming
    final assistantUpsert = events.whereType<ItemUpserted>().last;
    expect(assistantUpsert.item, isA<AssistantTextItem>());
  });

  test('creates ThinkingItem from agent_response and loads thinking text asynchronously', () async {
    final events = <KernelEvent>[];
    final completer = Completer<void>();
    final translator = AgyTranslator(
      emit: (e) {
        events.add(e);
        if (e is ItemUpserted &&
            e.item is ThinkingItem &&
            (e.item as ThinkingItem).text.contains('Detailed reasoning from transcript')) {
          if (!completer.isCompleted) completer.complete();
        }
      },
      nextSeq: () => events.length,
      readStepThinking: (conversation, stepIndex) async {
        if (conversation == 'conv-think-1' && '$stepIndex' == '1') {
          return 'Detailed reasoning from transcript about prime numbers';
        }
        return null;
      },
    );

    translator.accept({
      'event': 'init',
      'conversation_id': 'conv-think-1',
    });
    translator.beginTurn('turn-think-async');

    // AGY CLI emits agent_response DONE with duration (no text_delta)
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_index': 1,
        'step_type': 'agent_response',
        'state': 'DONE',
        'duration_seconds': 5.2,
      },
    });

    // Wait for async disk transcript load
    await completer.future.timeout(const Duration(seconds: 2));

    // ThinkingItem should have the loaded text and tokens
    final thinkingUpsert = events.whereType<ItemUpserted>().firstWhere(
      (e) => e.item is ThinkingItem,
    );
    final thinking = thinkingUpsert.item as ThinkingItem;
    expect(thinking.tokens, greaterThan(0));
    expect(thinking.seconds, 5);
    expect(thinking.text, contains('Detailed reasoning from transcript'));
  });

  test('does not create empty ThinkingItem when transcript has no thinking for that step', () async {
    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readStepThinking: (conversation, stepIndex) async => null,
    );

    translator.accept({
      'event': 'init',
      'conversation_id': 'conv-think-2',
    });
    translator.beginTurn('turn-no-think');

    // Step with no thinking in transcript (e.g. step 3)
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_index': 3,
        'step_type': 'agent_response',
        'state': 'DONE',
        'duration_seconds': 8.0,
      },
    });

    // Tool step
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_index': 4,
        'step_type': 'tool',
        'tool_name': 'run_command',
        'parameters': {
          'CommandLine': 'rg -n receivables',
        },
      },
    });

    await Future.delayed(const Duration(milliseconds: 150));

    // No ThinkingItem should be emitted because step 3 had no thinking text
    expect(events.whereType<ItemUpserted>().any((e) => e.item is ThinkingItem), isFalse);
    expect(events.whereType<ItemUpserted>().any((e) => e.item is TerminalItem), isTrue);
  });

  test('write_file tool emits CodeDiffItem with diff lines', () async {
    final tempDir = Directory.systemTemp.createTempSync('agy-write-test');
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final file = File(p.join(tempDir.path, 'created.txt'));

    final events = <KernelEvent>[];
    final translator = AgyTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      readFile: (path) async {
        if (File(path).existsSync()) return File(path).readAsString();
        return null;
      },
    )..beginTurn('turn-write');

    // Simulate AGY CLI tool call with 'args' (as emitted from AGY jsonl)
    translator.accept({
      'event': 'step_update',
      'step_update': {
        'step_type': 'tool',
        'tool_id': 'write-1',
        'tool_name': 'write_file',
        'state': 'COMPLETED',
        'tool_info': {
          'args': {
            'Path': file.path,
            'Content': 'line 1\nline 2\n',
          },
          'output': 'Created file',
        },
      },
    });

    // Write to disk as AGY CLI does
    file.writeAsStringSync('line 1\nline 2\n');

    await Future<void>.delayed(const Duration(milliseconds: 50));

    final diffItems = events
        .whereType<ItemUpserted>()
        .map((e) => e.item)
        .whereType<CodeDiffItem>()
        .toList();

    expect(diffItems, hasLength(1));
    expect(diffItems.single.fileName, 'created.txt');
    expect(diffItems.single.added, 2);
    expect(diffItems.single.removed, 0);
  });
}
