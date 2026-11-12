import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/widgets/command_step.dart';

void main() {
  group('CommandStep.title', () {
    test('uses description when present', () {
      expect(
        CommandStep.title('python -c "print(1)"', 'Run python test'),
        'Run python test',
      );
    });

    test('collapses multi-line commands to a single readable line', () {
      const multiline = '''python -c "
FROM finance_transaction_detail d
JOIN finance_transaction t ON t.id = d.transaction_id
"''';
      expect(
        CommandStep.title(multiline, null),
        'python -c " FROM finance_transaction_detail d JOIN finance_transaction t ON t.id = d.transaction_id "',
      );
    });

    test('trims single line command', () {
      expect(
        CommandStep.title('  git status --short  ', null),
        'git status --short',
      );
    });
  });

  testWidgets('renders command and output with divider when expanded', (
    tester,
  ) async {
    const cmd = 'python -c "SELECT 1"';
    const out = 'Command exited with code 0.\nCommand output:\n1';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CommandStep(
            command: cmd,
            output: out,
            expanded: true,
          ),
        ),
      ),
    );

    expect(find.byType(CommandStep), findsOneWidget);
    expect(find.textContaining('python -c "SELECT 1"'), findsWidgets);
    expect(find.text(out), findsOneWidget);
  });
}
