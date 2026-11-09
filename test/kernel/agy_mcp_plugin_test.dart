import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agy/agy_mcp_plugin.dart';

void main() {
  test('normalizes MCP labels and preserves the concrete tool name', () {
    final mcp = AgyMcpPluginParser.parse('call_mcp_tool', {
      'ServerName': '"context7"',
      'ToolName': '"resolve-library-id"',
    });
    expect(mcp.label, 'MCP · context7 · resolve-library-id');
    expect(mcp.target, 'resolve-library-id');
    expect(mcp.requiresConfirmation, isFalse);

    final lowerCase = AgyMcpPluginParser.parse('call_mcp_tool', {
      'server': 'docs',
      'tool': 'search',
    });
    expect(lowerCase.label, 'MCP · docs · search');
    expect(lowerCase.target, 'search');
    expect(lowerCase.requiresConfirmation, isFalse);

    final plugin = AgyMcpPluginParser.parse('install_plugin', {'name': 'demo'});
    expect(plugin.label, 'Plugin · demo');
    expect(plugin.requiresConfirmation, isTrue);
  });
}
