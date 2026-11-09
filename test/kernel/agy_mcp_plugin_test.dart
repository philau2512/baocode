import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agy/agy_mcp_plugin.dart';

void main() {
  group('AgyMcpPluginParser', () {
    test('normalizes MCP labels and preserves tool name when args are empty', () {
      final mcp = AgyMcpPluginParser.parse('call_mcp_tool', {
        'ServerName': '"context7"',
        'ToolName': '"resolve-library-id"',
      });
      expect(mcp.label, 'MCP · context7 · resolve-library-id');
      expect(mcp.target, 'resolve-library-id');
      expect(mcp.requiresConfirmation, isFalse);

      final noArgs = AgyMcpPluginParser.parse('call_mcp_tool', {
        'server': 'gridex',
        'tool': 'list_tables',
      });
      expect(noArgs.label, 'MCP · gridex · list_tables');
      expect(noArgs.target, 'list_tables');
    });

    test('handles plugin management tools with confirmation flag', () {
      final plugin = AgyMcpPluginParser.parse('install_plugin', {'name': 'demo'});
      expect(plugin.label, 'Plugin · demo');
      expect(plugin.target, 'demo');
      expect(plugin.requiresConfirmation, isTrue);
    });

    test('extracts SQL queries and commands for Gridex and database tools', () {
      final mcpWithSql = AgyMcpPluginParser.parse('call_mcp_tool', {
        'ServerName': 'gridex',
        'ToolName': 'query',
        'Arguments': {
          'query': 'SELECT id, raw_phone FROM crm_partner WHERE is_deleted = 0',
        },
      });
      expect(mcpWithSql.label, 'MCP · gridex · query');
      expect(
        mcpWithSql.target,
        'SELECT id, raw_phone FROM crm_partner WHERE is_deleted = 0',
      );
      expect(
        AgyMcpPluginParser.extractCommand(mcpWithSqlInput),
        'SELECT id, raw_phone FROM crm_partner WHERE is_deleted = 0',
      );

      final mcpWithTable = AgyMcpPluginParser.parse('call_mcp_tool', {
        'ServerName': 'gridex',
        'ToolName': 'describe_table',
        'Arguments': '{"table_name": "crm_partner"}',
      });
      expect(mcpWithTable.label, 'MCP · gridex · describe_table');
      expect(mcpWithTable.target, 'crm_partner');
    });

    test('extracts documentation and library queries for Context7', () {
      final resolveLib = AgyMcpPluginParser.parse('call_mcp_tool', {
        'ServerName': 'context7',
        'ToolName': 'resolve-library-id',
        'Arguments': {'library_name': 'flutter'},
      });
      expect(resolveLib.label, 'MCP · context7 · resolve-library-id');
      expect(resolveLib.target, 'flutter');

      final queryDocs = AgyMcpPluginParser.parse('call_mcp_tool', {
        'ServerName': 'context7',
        'ToolName': 'query-docs',
        'Arguments': {
          'library_id': '/flutter/flutter',
          'query': 'state management',
        },
      });
      expect(queryDocs.label, 'MCP · context7 · query-docs');
      expect(queryDocs.target, 'state management (/flutter/flutter)');
    });

    test('extracts code symbols and paths for code-intel', () {
      final outline = AgyMcpPluginParser.parse('call_mcp_tool', {
        'ServerName': 'code-intel',
        'ToolName': 'Outline',
        'Arguments': {'Path': 'lib/kernel/agy/agy_mcp_plugin.dart'},
      });
      expect(outline.label, 'MCP · code-intel · Outline');
      expect(outline.target, 'lib/kernel/agy/agy_mcp_plugin.dart');

      final symbolSearch = AgyMcpPluginParser.parse('call_mcp_tool', {
        'ServerName': 'code-intel',
        'ToolName': 'SymbolSearch',
        'Arguments': {'symbol': 'AgyMcpPluginParser'},
      });
      expect(symbolSearch.label, 'MCP · code-intel · SymbolSearch');
      expect(symbolSearch.target, 'AgyMcpPluginParser');
    });

    test('handles fast-context and web search queries', () {
      final search = AgyMcpPluginParser.parse('call_mcp_tool', {
        'ServerName': 'fast-context',
        'ToolName': 'fast_context_search',
        'Arguments': {'query': 'class AgyMcpPluginParser'},
      });
      expect(search.label, 'MCP · fast-context · fast_context_search');
      expect(search.target, 'class AgyMcpPluginParser');
    });

    test('generically formats arbitrary unknown MCP tools and parameters', () {
      final customToolSingle = AgyMcpPluginParser.parse('call_mcp_tool', {
        'ServerName': 'custom-service',
        'ToolName': 'get_metric',
        'Arguments': {'metric_key': 'cpu_utilization'},
      });
      expect(customToolSingle.label, 'MCP · custom-service · get_metric');
      expect(customToolSingle.target, 'cpu_utilization');

      final customToolMulti = AgyMcpPluginParser.parse('call_mcp_tool', {
        'ServerName': 'inventory',
        'ToolName': 'filter_items',
        'Arguments': {'category': 'books', 'min_price': 10},
      });
      expect(customToolMulti.label, 'MCP · inventory · filter_items');
      expect(customToolMulti.target, 'category: books, min_price: 10');

      final commandJson = AgyMcpPluginParser.extractCommand({
        'ServerName': 'inventory',
        'ToolName': 'filter_items',
        'Arguments': {'category': 'books', 'min_price': 10},
      });
      expect(commandJson, contains('"category": "books"'));
      expect(commandJson, contains('"min_price": 10'));
    });
  });
}

const mcpWithSqlInput = {
  'ServerName': 'gridex',
  'ToolName': 'query',
  'Arguments': {
    'query': 'SELECT id, raw_phone FROM crm_partner WHERE is_deleted = 0',
  },
};
