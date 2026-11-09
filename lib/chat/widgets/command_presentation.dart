import 'package:flutter/material.dart';

import '../../theme/codicons.dart';
import '../../theme/app_theme.dart';

/// The compact visual identity of a shell command in the chat timeline.
class CommandPresentation {
  const CommandPresentation(this.icon, this.color);

  final IconData icon;
  final Color color;
}

/// Classifies the command the user sees, without attempting to parse a shell.
/// A leading `cd … &&` is common in agent output, so it is skipped once.
CommandPresentation commandPresentation(String command) {
  final executable = _executable(command);
  return switch (executable) {
    'git' => const CommandPresentation(Codicons.gitBranch, Color(0xfff1502f)),
    'flutter' => const CommandPresentation(
      Icons.flutter_dash_rounded,
      Color(0xff54c5f8),
    ),
    'dart' => const CommandPresentation(Icons.code_rounded, Color(0xff0175c2)),
    'npm' || 'pnpm' || 'yarn' || 'bun' => const CommandPresentation(
      Icons.inventory_2_outlined,
      Color(0xffcb3837),
    ),
    'docker' => const CommandPresentation(
      Icons.inventory_2_rounded,
      Color(0xff2496ed),
    ),
    'rg' ||
    'grep' ||
    'find' => CommandPresentation(Codicons.search, AppColors.textMuted),
    _ => CommandPresentation(Codicons.terminal, AppColors.textMuted),
  };
}

String _executable(String command) {
  var source = command.trimLeft();
  final chained = RegExp(r'^cd\s+.+?\s+&&\s+').firstMatch(source);
  if (chained != null) source = source.substring(chained.end);
  final match = RegExp(r'^([^\s;&|]+)').firstMatch(source);
  return match?.group(1)?.toLowerCase() ?? '';
}
