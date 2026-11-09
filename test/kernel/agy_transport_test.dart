import 'package:flutter_test/flutter_test.dart';

import 'package:baocode/kernel/agy/agy_transport.dart';

void main() {
  test('builds stream-json launch arguments with AGY defaults', () {
    const launch = AgyLaunch(
      cwd: r'C:\PROJECTS\baocode',
      model: 'gemini-3.8-flash-medium',
      mode: 'accept-edits',
      effort: 'high',
      sandbox: true,
      addDirectories: [r'C:\PROJECTS\shared'],
    );

    expect(launch.arguments, [
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--model', 'gemini-3.8-flash-medium',
      '--mode', 'accept-edits',
      '--effort', 'high',
      '--sandbox',
      '--add-dir', r'C:\PROJECTS\shared',
      '--dangerously-skip-permissions',
    ]);
  });

  test('encodes a user stream event', () {
    const launch = AgyLaunch(cwd: '.');
    expect(launch.userMessage('hello'), {
      'event': 'user',
      'message': {'role': 'user', 'content': 'hello'},
    });
  });

  test('can build a conversation resume launch', () {
    const launch = AgyLaunch(cwd: '.', conversation: 'conversation-1');
    expect(launch.arguments, containsAllInOrder(['--conversation', 'conversation-1']));
  });
}
