import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/widgets/tool_call_row.dart';

void main() {
  testWidgets('renders complete MCP output despite path-like lines', (
    tester,
  ) async {
    const output = '''Outline for lib/main.dart
main() [L1-L4]
lib/main.dart:42: path-like detail
BaoCodeApp [L10-L20]''';
    await tester.pumpWidget(
      const MaterialApp(
        home: ToolCallRow(
          kind: ToolKind.mcp,
          target: 'Outline',
          output: output,
          results: ['lib/main.dart:42: path-like detail'],
          expanded: true,
        ),
      ),
    );

    expect(find.text(output), findsOneWidget);
  });

  testWidgets('does not expand a file read summary', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ToolCallRow(
          kind: ToolKind.read,
          target: 'lib/main.dart',
          output: '713 lines, 20629 bytes',
          onToggle: () => toggles++,
        ),
      ),
    );

    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    expect(toggles, 0);
    expect(find.text('713 lines, 20629 bytes'), findsNothing);
  });

  testWidgets('renders expandable search results', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ToolCallRow(
          kind: ToolKind.grep,
          target: 'AGY',
          results: const ['lib/main.dart:42: AGY'],
          expanded: false,
          onToggle: () => toggles++,
        ),
      ),
    );

    expect(find.byType(ToolCallRow), findsOneWidget);
    expect(toggles, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: ToolCallRow(
          kind: ToolKind.grep,
          target: 'AGY',
          results: const ['lib/main.dart:42: AGY'],
          expanded: true,
        ),
      ),
    );
    expect(find.text('lib/main.dart:42: AGY'), findsOneWidget);
  });
}
