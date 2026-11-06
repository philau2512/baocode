import '../agent_kernel.dart';

class AgyStorage implements SessionCatalog {
  const AgyStorage();

  @override
  Future<List<ProjectRecord>> projects() async => const [];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];

  @override
  Future<void> delete(String id) async {}
}
