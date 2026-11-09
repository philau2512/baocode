export 'agy_storage_stub.dart'
    if (dart.library.io) 'agy_storage_io.dart';

import '../agent_kernel.dart';
import 'agy_storage_stub.dart'
    if (dart.library.io) 'agy_storage_io.dart' show AgyStorage;

SessionCatalog get agySessionCatalog => const AgyStorage();
