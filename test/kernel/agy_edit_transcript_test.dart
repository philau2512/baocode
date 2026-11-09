import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agy/agy_edit_transcript.dart';

void main() {
  test('reads the latest matching persisted edit arguments', () async {
    final home = await Directory.systemTemp.createTemp('agy-edit-transcript');
    addTearDown(() => home.delete(recursive: true));
    final file = File('${home.path}\\.gemini\\antigravity-cli\\brain\\conversation-1\\.system_generated\\logs\\transcript_full.jsonl');
    await file.parent.create(recursive: true);
    await file.writeAsString('${jsonEncode({
      'tool_calls': [
        {'name': 'edit_file', 'args': {
          'Path': r'C:\PROJECTS\baocode\README.md',
          'Target': 'old',
          'Replacement': 'new',
        }},
      ],
    })}\n');

    final snapshot = await readAgyEditSnapshot(
      home: home.path,
      conversation: 'conversation-1',
      path: 'C:/PROJECTS/baocode/README.md',
    );

    expect(snapshot?.before, 'old');
    expect(snapshot?.after, 'new');
  });
}
