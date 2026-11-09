import 'agy_transport.dart';

final class ProcessTransport implements AgyTransport {
  ProcessTransport._();

  static Future<AgyTransport> start(AgyLaunch launch) async =>
      throw UnsupportedError('Antigravity CLI requires a native platform');

  static Future<void> stopAll() async {}

  @override
  Stream<Map<String, Object?>> get messages => const Stream.empty();

  @override
  void write(Map<String, Object?> message) {}

  @override
  void close() {}

  @override
  Future<void> get exited => Future.value();
}
