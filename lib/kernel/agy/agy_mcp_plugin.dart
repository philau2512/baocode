import 'dart:convert';

final class AgyMcpPluginDetails {
  const AgyMcpPluginDetails({
    this.label,
    this.target,
    this.requiresConfirmation = false,
  });

  final String? label;
  final String? target;
  final bool requiresConfirmation;
}

/// Normalizes MCP and plugin tool labels and targets without executing side effects.
final class AgyMcpPluginParser {
  static const _metaKeys = <String>{
    'server',
    'servername',
    'tool',
    'toolname',
    'connection_id',
    'session_id',
    'client_id',
    'auth',
    'token',
    'limit',
    'row_limit',
    'offset',
  };

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
        : _mcpTarget(input, tool);

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

  static String? _mcpTarget(Map<String, Object?> input, String? tool) {
    final args = extractArgs(input);

    // 1. Primary query / SQL / command / statement / code / prompt
    final commandLike = _value(args, const [
      'query',
      'sql',
      'command',
      'statement',
      'code',
      'script',
      'prompt',
      'pattern',
      'symbol',
      'symbol_name',
      'search',
      'keyword',
      'filter',
    ]);
    if (commandLike != null && commandLike.trim().isNotEmpty) {
      final scope = _value(args, const [
        'library_id',
        'library_name',
        'table_name',
        'table',
        'repo',
        'repository',
      ]);
      final cleanCmd = _cleanTarget(commandLike);
      if (scope != null && scope.trim().isNotEmpty && cleanCmd.length < 50) {
        final cleanScope = _cleanTarget(scope);
        if (!cleanCmd.contains(cleanScope)) {
          return _cleanTarget('$cleanCmd ($cleanScope)');
        }
      }
      return cleanCmd;
    }

    // 2. Resource identifiers: table, path, url, library, entity
    final resource = _value(args, const [
      'table_name',
      'table',
      'collection',
      'topic',
      'library_id',
      'library_name',
      'path',
      'file_path',
      'filepath',
      'url',
      'uri',
      'endpoint',
      'title',
      'message',
      'action',
      'name',
    ]);
    if (resource != null && resource.trim().isNotEmpty) {
      final scope = _value(args, const [
        'library_id',
        'library_name',
        'repo',
        'repository',
        'table_name',
        'table',
      ]);
      final cleanRes = _cleanTarget(resource);
      if (scope != null && scope.trim().isNotEmpty && cleanRes.length < 50) {
        final cleanScope = _cleanTarget(scope);
        if (cleanRes != cleanScope && !cleanRes.contains(cleanScope)) {
          return _cleanTarget('$cleanRes ($cleanScope)');
        }
      }
      return cleanRes;
    }

    // 3. Generic fallback for ANY arbitrary MCP tool arguments:
    final cleanEntries = args.entries.where((e) {
      final k = e.key.toLowerCase();
      if (_metaKeys.contains(k)) return false;
      final v = e.value;
      if (v == null) return false;
      if (v is String && v.trim().isEmpty) return false;
      return true;
    }).toList();

    if (cleanEntries.isEmpty) {
      return tool;
    }

    if (cleanEntries.length == 1) {
      final val = _string(cleanEntries.first.value);
      if (val != null && val.trim().isNotEmpty) {
        return _cleanTarget(val);
      }
      return _cleanTarget('${cleanEntries.first.value}');
    }

    if (cleanEntries.length <= 3) {
      final formatted = cleanEntries
          .map((e) => '${e.key}: ${_formatVal(e.value)}')
          .join(', ');
      return _cleanTarget(formatted);
    }

    final first = cleanEntries.first;
    return _cleanTarget('${first.key}: ${_formatVal(first.value)}...');
  }

  static String _formatVal(Object? value) {
    if (value is String) {
      final s = _string(value) ?? value;
      return s.length > 25 ? '${s.substring(0, 22)}...' : s;
    }
    return '$value';
  }

  static String _cleanTarget(String target) {
    final singleLine = target.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.length > 70) {
      return '${singleLine.substring(0, 67)}...';
    }
    return singleLine;
  }

  static Map<String, Object?> extractArgs(Map<String, Object?> input) {
    final raw = input['Arguments'] ??
        input['arguments'] ??
        input['args'] ??
        input['params'] ??
        input['parameters'];
    if (raw is Map) return raw.cast<String, Object?>();
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) return decoded.cast<String, Object?>();
        } catch (_) {}
      }
    }
    return input;
  }

  /// Extracts the full command/query or formatted arguments payload
  /// suitable for display when expanded.
  static String? extractCommand(Map<String, Object?> input) {
    final args = extractArgs(input);

    for (final key in const [
      'query',
      'sql',
      'command',
      'statement',
      'code',
      'script',
      'prompt',
    ]) {
      for (final entry in args.entries) {
        if (entry.key.toLowerCase() == key) {
          final s = entry.value?.toString().trim();
          if (s != null && s.isNotEmpty) return s;
        }
      }
    }

    final clean = Map<String, Object?>.from(args)
      ..removeWhere((k, _) => _metaKeys.contains(k.toLowerCase()));

    if (clean.isNotEmpty) {
      const encoder = JsonEncoder.withIndent('  ');
      try {
        return encoder.convert(clean);
      } catch (_) {
        return clean.toString();
      }
    }
    return null;
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
