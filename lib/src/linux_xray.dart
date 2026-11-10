import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef _ConvertNative = Pointer<Utf8> Function(Pointer<Utf8>);

/// MegaV#344: on Linux the core runs in the root daemon, not in the app, and there is no platform
/// plugin. Share links are converted by libXray.so from the same core release as the daemon's xray
/// (fetch-core.sh linux-amd64-lib, bundle lib/): CGoConvertShareLinksToXrayJson is the function the
/// Windows libv2ray ConvertUrlToConfig wraps (Romaxa55/libXray libv2ray_cgo/libxray_cgo.go), so the
/// outbound is the same as on every other platform.
class LinuxXray {
  static _ConvertNative? _convert;
  static bool _loadFailed = false;

  static bool _load() {
    if (_convert != null) return true;
    if (_loadFailed) return false;
    final bundled =
        '${File(Platform.resolvedExecutable).parent.path}/lib/libXray.so';
    try {
      final lib = DynamicLibrary.open(bundled);
      _convert = lib.lookupFunction<_ConvertNative, _ConvertNative>(
          'CGoConvertShareLinksToXrayJson');
      return true;
    } catch (e) {
      _loadFailed = true;
      debugPrint('[V2RAY] libXray.so not loaded from $bundled: $e');
      return false;
    }
  }

  /// The same answer as the platform channel's convertUrlToConfig: the xray JSON for one share link,
  /// or null when the link does not convert.
  static Map<String, dynamic>? convertUrlToConfig(String url) {
    if (!_load()) return null;
    final arg = base64.encode(utf8.encode(url)).toNativeUtf8();
    Pointer<Utf8> res = nullptr;
    try {
      res = _convert!(arg);
      if (res == nullptr) return null;
      final resp = json.decode(utf8.decode(base64.decode(res.toDartString())));
      if (resp is! Map || resp['success'] != true) {
        debugPrint('[V2RAY] convertUrlToConfig failed: '
            '${resp is Map ? resp['error'] ?? resp['err'] : resp}');
        return null;
      }
      final data = resp['data'];
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (e) {
      debugPrint('[V2RAY] convertUrlToConfig error: $e');
      return null;
    } finally {
      malloc.free(arg);
      // C.CString of the Go side is malloc'ed; package:ffi's malloc.free is libc free.
      if (res != nullptr) malloc.free(res);
    }
  }
}
