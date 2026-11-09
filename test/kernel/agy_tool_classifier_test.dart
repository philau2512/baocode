import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agy/agy_tool_classifier.dart';

void main() {
  test('classifies AGY file, search, terminal, browser and MCP tools', () {
    expect(AgyToolClassifier.classify('read_file', {}).kind, ToolKind.read);
    expect(
      AgyToolClassifier.classify('multi_replace_file_content', {}).kind,
      ToolKind.edit,
    );
    expect(AgyToolClassifier.classify('grep_search', {}).kind, ToolKind.grep);
    expect(
      AgyToolClassifier.classify('find_by_name', {}).kind,
      ToolKind.search,
    );
    expect(AgyToolClassifier.classify('search_web', {}).kind, ToolKind.web);
    expect(
      AgyToolClassifier.classify('run_command', {}).kind,
      ToolKind.command,
    );
    expect(
      AgyToolClassifier.classify('browser_get_dom', {}).kind,
      ToolKind.browser,
    );
    expect(AgyToolClassifier.classify('call_mcp_tool', {}).kind, ToolKind.mcp);
    expect(
      AgyToolClassifier.classify('capture_browser_screenshot', {}).kind,
      ToolKind.image,
    );
  });
}
