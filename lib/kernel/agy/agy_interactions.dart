import '../kernel_event.dart';
import '../kernel_types.dart';
import 'agy_transport.dart';

/// Converts AGY interaction payloads to BaoCode's common approval/question
/// requests. Unknown interaction shapes are intentionally ignored.
final class AgyInteractionParser {
  AgyInteractionParser(this.emit, this.nextSeq);

  final void Function(KernelEvent event) emit;
  final int Function() nextSeq;
  AgyTransport? transport;

  void answer(String requestId, InteractionAnswer answer) {
    final target = transport;
    if (target == null) return;
    target.write(AgyLaunch(cwd: '.').userMessage(
      'Answer interaction $requestId: ${_answer(answer)}',
    ));
  }

  static String _answer(InteractionAnswer answer) => switch (answer) {
    QuestionAnswer(:final summary) => summary,
    ApprovalAnswer(decision: final decision, :final message) =>
      '${decision.name}${message == null ? '' : ': $message'}',
  };

  String? parse(Map<String, Object?> step, Map<String, Object?> info) {
    final raw = step['interaction'] ?? info['interaction'] ??
        step['request'] ?? info['request'];
    if (raw is! Map) return null;
    final request = raw.cast<String, Object?>();
    final id = _string(request['id']) ?? _string(request['request_id']);
    if (id == null) return null;
    final title = _string(request['title']) ?? 'Antigravity needs your input';
    final kind = '${request['kind'] ?? request['type']}'.toLowerCase();
    if (kind.contains('permission') || kind.contains('approval')) {
      emit(InteractionRequested(nextSeq(), ApprovalRequest(
        id: id,
        title: title,
        toolName: _string(request['tool_name']) ?? _string(request['tool']) ?? 'AGY tool',
        reason: _string(request['reason']),
      )));
    } else {
      emit(InteractionRequested(nextSeq(), QuestionRequest(
        id: id,
        title: title,
        questions: [Question(
          prompt: _string(request['prompt']) ?? title,
          options: [
            for (final option in request['options'] is List
                ? request['options'] as List
                : const [])
              if (option is String) QuestionOption(option),
          ],
        )],
      )));
    }
    return id;
  }

  static String? _string(Object? value) => value is String && value.isNotEmpty
      ? value
      : null;
}
