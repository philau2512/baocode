import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agy/agy_interactions.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';

void main() {
  test('maps AGY approval interaction to BaoCode request', () {
    final events = <KernelEvent>[];
    final parser = AgyInteractionParser(events.add, () => events.length);
    final id = parser.parse({
      'interaction': {
        'id': 'approval-1',
        'type': 'permission',
        'title': 'Allow command',
        'tool_name': 'run_command',
      },
    }, {});
    expect(id, 'approval-1');
    expect(events.single, isA<InteractionRequested>());
    expect((events.single as InteractionRequested).request, isA<ApprovalRequest>());
  });
}
