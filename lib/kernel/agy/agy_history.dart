import 'dart:convert';
import 'dart:io';

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';

export '../agent_kernel.dart' show SessionRecord;

/// Replays an Antigravity local chat file into BaoCode transcript events.
final class AgyHistory {
  const AgyHistory({required this.emit, required this.nextSeq});

  final void Function(KernelEvent event) emit;
  final int Function() nextSeq;

  Future<void> replay(SessionRecord session) async {
    final path = session.path;
    if (path == null) return;
    try {
      final file = File(path);
      if (path.endsWith('.jsonl')) {
        await _replayJsonl(file);
        return;
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      final messages = raw['messages'];
      if (messages is! List) return;
      for (final value in messages) {
        if (value is! Map) continue;
        _emitMessage(value.cast<String, Object?>());
      }
    } on Object catch (error) {
      emit(
        ItemUpserted(
          nextSeq(),
          'agy-history-error',
          NoticeItem(NoticeKind.error, 'Could not read Antigravity history: $error'),
        ),
      );
    }
  }

  Future<void> _replayJsonl(File file) async {
    await for (final line in file.openRead().transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final raw = jsonDecode(line);
      if (raw is Map) _emitStep(raw.cast<String, Object?>());
    }
  }

  void _emitStep(Map<String, Object?> step) {
    final type = step['type'];
    final content = step['content'];
    if (type == 'USER_INPUT' && content is String) {
      _emitItem('user', content);
    } else if (type == 'PLANNER_RESPONSE' && content is String) {
      _emitItem('assistant', content);
    } else if (type == 'GENERIC' && content is String && content.trim().isNotEmpty) {
      _emitItem('assistant', content);
    }
  }

  void _emitMessage(Map<String, Object?> message) {
    final type = message['type'];
    final content = message['content'];
    if (type == 'user' && content is String && content.trim().isNotEmpty) {
      _emitItem('user', content, id: message['id']);
    } else if (type == 'assistant' && content is String && content.trim().isNotEmpty) {
      _emitItem('assistant', content, id: message['id']);
    }
  }

  void _emitItem(String type, String content, {Object? id}) {
    if (type == 'user') {
      emit(ItemUpserted(nextSeq(), '${id ?? 'user'}:history', UserMessageItem(text: content)));
    } else {
      emit(ItemUpserted(nextSeq(), '${id ?? 'assistant'}:history', AssistantTextItem(content)));
    }
  }
}
