final class AgyTaskToolInfo {
  const AgyTaskToolInfo({
    required this.label,
    required this.target,
    this.detail,
  });

  final String label;
  final String target;
  final String? detail;
}

/// Normalizes AGY schedule, manage_task, and manage_subagents tool calls into
/// readable presentation titles and details.
final class AgyTaskPresentation {
  static AgyTaskToolInfo? parse(
    String name,
    Map<String, Object?> input, {
    String? output,
    bool running = false,
  }) {
    final lower = name.toLowerCase();
    if (lower == 'schedule') {
      return _parseSchedule(input, running: running);
    }
    if (lower == 'manage_task') {
      return _parseManageTask(input, output: output, running: running);
    }
    if (lower == 'manage_subagents') {
      return _parseManageSubagents(input, running: running);
    }
    return null;
  }

  static AgyTaskToolInfo _parseSchedule(
    Map<String, Object?> input, {
    required bool running,
  }) {
    final prompt = _clean(input['Prompt'] ?? input['prompt']);
    final duration = _clean(input['DurationSeconds'] ?? input['duration_seconds']);
    final cron = _clean(input['CronExpression'] ?? input['cron_expression']);

    final String label;
    if (cron != null) {
      label = running ? 'Scheduling cron' : 'Scheduled cron';
    } else {
      label = running ? 'Scheduling timer' : 'Scheduled timer';
    }

    final target = prompt ?? (duration != null ? '${duration}s timer' : cron ?? 'timer');
    final String? detail = duration != null ? '${duration}s' : cron;

    return AgyTaskToolInfo(
      label: label,
      target: target,
      detail: detail,
    );
  }

  static AgyTaskToolInfo _parseManageTask(
    Map<String, Object?> input, {
    String? output,
    required bool running,
  }) {
    final action =
        _clean(input['Action'] ?? input['action'])?.toLowerCase() ?? 'manage';
    final taskIdRaw = _clean(input['TaskId'] ?? input['task_id']);
    final shortTaskId = taskIdRaw != null ? _shortTaskId(taskIdRaw) : null;
    final taskInput = _clean(input['Input'] ?? input['input']);

    final String label = switch (action) {
      'status' => running ? 'Checking task' : 'Checked task',
      'kill' => running ? 'Stopping task' : 'Stopped task',
      'list' => running ? 'Listing tasks' : 'Listed tasks',
      'send_input' => running ? 'Sending input' : 'Sent input',
      _ => 'Task',
    };

    final target = shortTaskId ?? (action == 'list' ? 'background tasks' : 'task');
    String? detail;
    if (output != null && output.isNotEmpty) {
      detail = _statusFromOutput(output);
    }
    if (detail == null && taskInput != null && action == 'send_input') {
      detail = taskInput;
    }

    return AgyTaskToolInfo(
      label: label,
      target: target,
      detail: detail,
    );
  }

  static AgyTaskToolInfo _parseManageSubagents(
    Map<String, Object?> input, {
    required bool running,
  }) {
    final action =
        _clean(input['Action'] ?? input['action'])?.toLowerCase() ?? 'manage';
    final label = switch (action) {
      'kill' => running ? 'Stopping subagent' : 'Stopped subagent',
      'kill_all' => running ? 'Stopping subagents' : 'Stopped subagents',
      'list' => running ? 'Listing subagents' : 'Listed subagents',
      _ => 'Subagents',
    };
    return AgyTaskToolInfo(
      label: label,
      target: action == 'kill_all' ? 'all subagents' : 'subagents',
    );
  }

  static String _shortTaskId(String id) {
    final slash = id.lastIndexOf('/');
    return slash >= 0 && slash < id.length - 1 ? id.substring(slash + 1) : id;
  }

  static String? _statusFromOutput(String output) {
    final statusMatch =
        RegExp(r'Status:\s*(\w+)', caseSensitive: false).firstMatch(output);
    if (statusMatch != null) {
      return statusMatch.group(1)!.toLowerCase();
    }
    if (output.contains('cannot kill task') ||
        output.contains('Encountered error')) {
      if (output.contains('not running')) return 'not running';
      return 'failed';
    }
    return null;
  }

  static String? _clean(Object? value) {
    if (value == null) return null;
    var str = value.toString().trim();
    if (str.isEmpty) return null;
    if (str.length >= 2 && str.startsWith('"') && str.endsWith('"')) {
      str = str.substring(1, str.length - 1).trim();
    }
    return str.isEmpty ? null : str;
  }
}
