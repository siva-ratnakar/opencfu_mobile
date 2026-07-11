export 'opencfu_engine_stub.dart'
    if (dart.library.ffi) 'opencfu_engine_native.dart'
    if (dart.library.js_interop) 'opencfu_engine_web.dart';
