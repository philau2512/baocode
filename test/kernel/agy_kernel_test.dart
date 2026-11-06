import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/agy/agy_kernel.dart';
import 'package:baocode/kernel/agy/agy_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';

void main() {
  test('does not send interactive /context through stream-json', () async {
    final transport = _FakeAgyTransport();
    final descriptor = KernelDescriptor(
      id: 'antigravity-test',
      label: 'Antigravity',
      icon: Icons.auto_awesome,
      description: 'test',
      create: (_) => throw UnimplementedError(),
    );
    final kernel = AntigravityKernel(
      descriptor,
      const KernelContext(cwd: '.'),
      start: (_) async => transport,
    );
    await kernel.refreshUsage();
    expect(transport.writes, isEmpty);
    kernel.dispose();
  });

  test('translates AGY text and result events into kernel events', () async {
    final transport = _FakeAgyTransport();
    final descriptor = KernelDescriptor(
      id: 'antigravity-test',
      label: 'Antigravity',
      icon: Icons.auto_awesome,
      description: 'test',
      create: (_) => throw UnimplementedError(),
    );
    final kernel = AntigravityKernel(
      descriptor,
      const KernelContext(cwd: '.'),
      start: (_) async => transport,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);

    kernel.send(const KernelTurn(id: 'turn-1', text: 'hello'));
    await Future<void>.delayed(Duration.zero);
    transport.emit({
      'event': 'init',
      'conversation_id': 'conversation-1',
    });
    transport.emit({
      'event': 'step_update',
      'step_update': {
        'step_type': 'agent_response',
        'text_delta': 'hello back',
      },
    });
    transport.emit({
      'event': 'step_update',
      'step_update': {
        'step_type': 'agent_response',
        'text_delta': '',
        'usage': {
          'input_tokens': 3,
          'output_tokens': 2,
          'total_tokens': 5,
        },
      },
    });
    transport.emit({
      'event': 'result',
      'result': {
        'status': 'SUCCESS',
        'duration_seconds': 1.0,
        'usage': {'input_tokens': 3, 'output_tokens': 2},
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(kernel.sessionId, 'conversation-1');
    expect(events.whereType<TurnStarted>(), isNotEmpty);
    expect(events.whereType<TextDelta>().single.text, 'hello back');
    expect(events.whereType<TurnEnded>().single.interrupted, isFalse);
    expect(events.whereType<TurnEnded>().single.usage?.totalTokens, 5);

    await subscription.cancel();
    kernel.dispose();
  });
}

final class _FakeAgyTransport implements AgyTransport {
  final StreamController<Map<String, Object?>> _controller =
      StreamController.broadcast(sync: true);
  final Completer<void> _exit = Completer<void>();
  final List<Map<String, Object?>> writes = [];

  @override
  Stream<Map<String, Object?>> get messages => _controller.stream;

  @override
  Future<void> get exited => _exit.future;

  @override
  void write(Map<String, Object?> message) => writes.add(message);

  void emit(Map<String, Object?> message) => _controller.add(message);

  @override
  void close() {
    if (!_exit.isCompleted) _exit.complete();
    _controller.close();
  }
}
