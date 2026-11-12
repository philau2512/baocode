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

  String? parse(
    Map<String, Object?> step,
    Map<String, Object?> info, {
    String? name,
    Map<String, Object?>? parameters,
    String? toolCallId,
    bool done = false,
  }) {
    final raw = step['interaction'] ?? info['interaction'] ??
        step['request'] ?? info['request'];
    if (raw is Map) {
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

    final lower = name?.toLowerCase();
    if ((lower == 'ask_question' || lower == 'ask_user_question') &&
        !done &&
        parameters != null) {
      final id = _string(step['tool_id']) ??
          _string(info['tool_id']) ??
          _string(step['id']) ??
          _string(info['id']) ??
          toolCallId;
      if (id == null) return null;

      final questionsRaw = parameters['questions'];
      final list = <Question>[];
      if (questionsRaw is List) {
        for (final item in questionsRaw) {
          if (item is Map) {
            final prompt = _string(item['question']) ??
                _string(item['prompt']) ??
                'Antigravity Question';
            final opts = [
              for (final opt in (item['options'] is List
                  ? item['options'] as List
                  : const []))
                if (opt is String && opt.trim().isNotEmpty)
                  QuestionOption(opt.trim()),
            ];
            final multi = item['is_multi_select'] == true;
            list.add(Question(
              prompt: prompt,
              options: opts,
              allowMultiple: multi,
            ));
          }
        }
      } else if (parameters['question'] != null) {
        final prompt = _string(parameters['question']) ?? 'Question';
        final opts = [
          for (final opt in (parameters['options'] is List
              ? parameters['options'] as List
              : const []))
            if (opt is String && opt.trim().isNotEmpty)
              QuestionOption(opt.trim()),
        ];
        final multi = parameters['is_multi_select'] == true;
        list.add(Question(
          prompt: prompt,
          options: opts,
          allowMultiple: multi,
        ));
      }

      if (list.isNotEmpty) {
        emit(InteractionRequested(
          nextSeq(),
          QuestionRequest(
            id: id,
            title: 'Antigravity Question',
            questions: list,
          ),
        ));
        return id;
      }
    }
    return null;
  }

  static String? _string(Object? value) => value is String && value.isNotEmpty
      ? value
      : null;
}
