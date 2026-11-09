import 'agy_context_inspector_stub.dart'
    if (dart.library.io) 'agy_context_inspector_io.dart';

export 'agy_context_inspector_stub.dart'
    if (dart.library.io) 'agy_context_inspector_io.dart';

Future<ContextReport?> inspectAgyContext({
  required String cwd,
  required String? conversation,
}) => inspectAgyContextPlatform(
      cwd: cwd,
      conversation: conversation,
    );

class ContextReport {
  const ContextReport({
    required this.window,
    required this.used,
    required this.segments,
    this.files = const [],
  });

  final int window;
  final int used;
  final List<ContextReportSegment> segments;
  final List<String> files;
}

class ContextReportSegment {
  const ContextReportSegment(this.label, this.tokens, {this.free = false});

  final String label;
  final int tokens;
  final bool free;
}
