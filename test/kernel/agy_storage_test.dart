import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agy/agy_storage_io.dart';

void main() {
  test('finds AGY brain transcript by conversation id', () async {
    final temp = await Directory.systemTemp.createTemp('agy-storage-test');
    addTearDown(() => temp.delete(recursive: true));
    final root = Directory('${temp.path}\\.gemini\\antigravity-cli');
    final brain = Directory('${root.path}\\brain\\conversation-1\\.system_generated\\logs');
    await brain.create(recursive: true);
    File('${root.path}\\cache\\conversation_metadata.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'conversations': {
        'conversation-1': {'summary': {
          'Preview': '@test_edit.md edit',
          'UpdatedAt': '2026-11-06T08:10:00Z',
          'WorkspaceURIs': ['file:///C:/PROJECTS/baocode'],
        }},
      }}));
    await File('${brain.path}\\transcript_full.jsonl').writeAsString(
      '{"step_index":0,"type":"USER_INPUT","content":"edit"}\n',
    );

    final projects = await AgyStorage(home: temp.path).projects();
    expect(projects.single.path, r'C:\PROJECTS\baocode');
    final session = projects.single.sessions.single;
    expect(session.id, 'conversation-1');
    expect(session.path, endsWith('transcript_full.jsonl'));
  });

  test('keeps a short first-line title when preview has more text', () async {
    final temp = await Directory.systemTemp.createTemp('agy-storage-title-test');
    addTearDown(() => temp.delete(recursive: true));
    final root = Directory('${temp.path}\\.gemini\\antigravity-cli');
    final brain = Directory('${root.path}\\brain\\conversation-2\\.system_generated\\logs');
    await brain.create(recursive: true);
    File('${root.path}\\cache\\conversation_metadata.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'conversations': {
        'conversation-2': {'summary': {
          'Preview': 'short title\n${'x' * 100}',
          'WorkspaceURIs': ['file:///C:/PROJECTS/baocode'],
        }},
      }}));
    await File('${brain.path}\\transcript_full.jsonl').writeAsString('');

    final projects = await AgyStorage(home: temp.path).projects();
    expect(projects.single.sessions.single.title, 'short title');
  });

  test('deletes new and legacy records by conversation id', () async {
    final temp = await Directory.systemTemp.createTemp('agy-storage-delete-test');
    addTearDown(() => temp.delete(recursive: true));
    final root = Directory('${temp.path}\\.gemini\\antigravity-cli');
    final brain = Directory('${root.path}\\brain\\conversation-1\\.system_generated\\logs');
    await brain.create(recursive: true);
    File('${root.path}\\cache\\conversation_metadata.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'conversations': {
        'conversation-1': {'summary': {
          'Preview': 'title',
          'WorkspaceURIs': ['file:///C:/PROJECTS/baocode'],
        }},
      }}));
    await File('${brain.path}\\transcript_full.jsonl').writeAsString('');
    final oldProject = Directory('${temp.path}\\.gemini\\tmp\\hash');
    await oldProject.create(recursive: true);
    final oldFile = File('${oldProject.path}\\session-old.json');
    await oldFile.writeAsString(jsonEncode({
      'sessionId': 'conversation-1',
      'projectHash': 'hash',
      'cwd': r'C:\\PROJECTS\\baocode',
      'messages': [{'type': 'user', 'content': 'old title'}],
    }));

    await AgyStorage(home: temp.path).delete('conversation-1');

    expect(await brain.exists(), isFalse);
    expect(await oldFile.exists(), isFalse);
  });

  test('deduplicates old and new records by conversation id', () async {
    final temp = await Directory.systemTemp.createTemp('agy-storage-dedupe-test');
    addTearDown(() => temp.delete(recursive: true));
    final root = Directory('${temp.path}\\.gemini\\antigravity-cli');
    final brain = Directory('${root.path}\\brain\\conversation-1\\.system_generated\\logs');
    await brain.create(recursive: true);
    File('${root.path}\\cache\\conversation_metadata.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'conversations': {
        'conversation-1': {'summary': {
          'Preview': 'new title',
          'WorkspaceURIs': ['file:///C:/PROJECTS/baocode'],
        }},
      }}));
    await File('${brain.path}\\transcript_full.jsonl').writeAsString('');

    final oldProject = Directory('${temp.path}\\.gemini\\tmp\\hash');
    await oldProject.create(recursive: true);
    await File('${oldProject.path}\\session-old.json').writeAsString(jsonEncode({
      'sessionId': 'conversation-1',
      'projectHash': 'hash',
      'cwd': r'C:\\PROJECTS\\baocode',
      'messages': [{'type': 'user', 'content': 'old title'}],
    }));

    final projects = await AgyStorage(home: temp.path).projects();
    expect(projects.single.sessions, hasLength(1));
    expect(projects.single.sessions.single.title, 'new title');
  });
}

// Keep this fixture test independent from the host filesystem.