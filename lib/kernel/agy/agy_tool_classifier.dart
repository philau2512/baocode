import '../../chat/chat_models.dart';

final class AgyToolDescriptor {
  const AgyToolDescriptor({required this.kind, this.terminal = false});

  final ToolKind kind;
  final bool terminal;
}

/// Maps AGY's tool names to BaoCode's existing presentation contracts.
final class AgyToolClassifier {
  static AgyToolDescriptor classify(String name, Map<String, Object?> input) {
    final lower = name.toLowerCase();
    if (_any(lower, const {
      'read_file',
      'readfile',
      'view_file',
      'open_file',
    })) {
      return const AgyToolDescriptor(kind: ToolKind.read);
    }
    if (_any(lower, const {
      'edit_file',
      'write_file',
      'replace_file_content',
      'multi_replace_file_content',
      'delete_file',
      'notebook_edit',
    })) {
      return const AgyToolDescriptor(kind: ToolKind.edit);
    }
    if (_any(lower, const {'grep_search', 'grep', 'rg', 'search_files'})) {
      return const AgyToolDescriptor(kind: ToolKind.grep);
    }
    if (_any(lower, const {'find_by_name', 'glob', 'search', 'search_files'})) {
      return const AgyToolDescriptor(kind: ToolKind.search);
    }
    if (_any(lower, const {'list_dir', 'ls', 'list_directory'})) {
      return const AgyToolDescriptor(kind: ToolKind.listDir);
    }
    if (_any(lower, const {
      'run_command',
      'execute_command',
      'send_command_input',
      'command_status',
      'notebook_execution',
    })) {
      return const AgyToolDescriptor(kind: ToolKind.command, terminal: true);
    }
    if (_any(lower, const {'search_web', 'read_url_content', 'read_url'})) {
      return const AgyToolDescriptor(kind: ToolKind.web);
    }
    if (_any(lower, const {'generate_image', 'capture_browser_screenshot'})) {
      return const AgyToolDescriptor(kind: ToolKind.image);
    }
    if (lower.startsWith('browser_') ||
        lower.startsWith('capture_browser_') ||
        lower.startsWith('click_browser_') ||
        lower == 'execute_browser_javascript') {
      return const AgyToolDescriptor(kind: ToolKind.browser);
    }
    if (_any(lower, const {
          'call_mcp_tool',
          'mcp_tool',
          'list_resources',
          'read_resource',
        }) ||
        lower.startsWith('mcp_')) {
      return const AgyToolDescriptor(kind: ToolKind.mcp);
    }
    if (_any(lower, const {
      'search_marketplace',
      'list_plugin_accounts',
      'install_plugin',
      'uninstall_plugin',
      'enable_plugin',
      'disable_plugin',
      'list_plugins',
    })) {
      return const AgyToolDescriptor(kind: ToolKind.other);
    }
    if (_any(lower, const {'ask_question', 'ask_user_question'})) {
      return const AgyToolDescriptor(kind: ToolKind.question);
    }
    if (_any(lower, const {'send_message'})) {
      return const AgyToolDescriptor(kind: ToolKind.message);
    }
    if (_any(lower, const {'manage_task', 'manage_subagents', 'schedule'})) {
      return const AgyToolDescriptor(kind: ToolKind.other);
    }
    if (_any(lower, const {'generate_image', 'capture_browser_screenshot'})) {
      return const AgyToolDescriptor(kind: ToolKind.image);
    }
    if (_any(lower, const {
      'invoke_subagent',
      'browser_subagent',
      'define_subagent',
    })) {
      return const AgyToolDescriptor(kind: ToolKind.agent);
    }
    return AgyToolDescriptor(
      kind: input.containsKey('path') || input.containsKey('Path')
          ? ToolKind.edit
          : ToolKind.other,
    );
  }

  static bool _any(String name, Set<String> names) => names.contains(name);
}
