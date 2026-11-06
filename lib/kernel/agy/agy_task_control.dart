import 'dart:convert';

import 'agy_transport.dart';

// Kept separate so task actions never share the main turn cancellation path.

/// Best-effort task control using AGY's public tool protocol. The adapter does
/// not close the coding session when a single task is controlled.
final class AgyTaskControl {
  const AgyTaskControl(this.transport, {this.cwd = '.'});

  final AgyTransport? transport;
  final String cwd;

  void cancel(String taskId) => _send('cancel', taskId);

  void background(String taskId) => _send('background', taskId);

  void _send(String action, String taskId) {
    final target = transport;
    if (target == null || taskId.isEmpty) return;
    target.write(AgyLaunch(cwd: cwd).userMessage(
      'Use manage_task with ${jsonEncode({'Action': action, 'TaskId': taskId})}',
    ));
  }
}
