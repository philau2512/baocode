final class AgyMcpPluginDetails {
  const AgyMcpPluginDetails({this.label, this.target, this.requiresConfirmation = false});

  final String? label;
  final String? target;
  final bool requiresConfirmation;
}

/// Normalizes MCP and plugin tool labels without executing side effects.
final class AgyMcpPluginParser {
  static AgyMcpPluginDetails parse(
    String name,
    Map<String, Object?> input,
  ) {
    final lower = name.toLowerCase();
    final plugin = lower.contains('plugin') || lower.contains('marketplace');
    final server = _value(input, const ['server', 'servername']);
    final tool = _value(input, const ['tool', 'toolname']);
    final label = plugin
        ? 'Plugin · ${_value(input, const ['name', 'plugin']) ?? name}'
        : 'MCP · ${server ?? name}${tool == null ? '' : ' · $tool'}';
    final target = plugin
        ? _value(input, const ['url', 'query', 'name', 'plugin'])
        : tool;
    return AgyMcpPluginDetails(
      label: label,
      target: target,
      requiresConfirmation: plugin && const {
        'install_plugin',
        'uninstall_plugin',
        'enable_plugin',
        'disable_plugin',
      }.contains(lower),
    );
  }

  static String? _value(Map<String, Object?> input, List<String> names) {
    for (final name in names) {
      for (final entry in input.entries) {
        if (entry.key.toLowerCase() == name) {
          final value = _string(entry.value);
          if (value != null) return value;
        }
      }
    }
    return null;
  }

  static String? _string(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final trimmed = value.trim();
    if (trimmed.length >= 2 &&
        ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
            (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
      return trimmed.substring(1, trimmed.length - 1);
    }
    return trimmed;
  }
}
