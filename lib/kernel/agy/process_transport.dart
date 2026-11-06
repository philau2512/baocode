import 'agy_transport.dart';
import 'process_transport_agy_stub.dart'
    if (dart.library.io) 'process_transport_agy_io.dart' as platform;

Future<AgyTransport> startAgy(AgyLaunch launch) => platform.ProcessTransport.start(launch);
Future<void> stopAgyProcesses() => platform.ProcessTransport.stopAll();
