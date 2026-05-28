import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'src/v2ray_config_helper.dart';
import 'src/v2ray_timer_utils.dart';

/// V2Ray Flutter plugin for cross-platform V2Ray integration
/// Supports both legacy native implementations and new gomobile libraries
class V2rayFlutter {
  static const MethodChannel _channel = MethodChannel('v2ray_flutter');

  /// 2026-05-22: Push-stream observatory snapshot'ов.
  ///
  /// На iOS: NE пишет в App Group + Darwin notification → ObservatoryStreamHandler
  ///   читает App Group и пушит сразу при notify, плюс fallback poll 2с.
  ///
  /// На Android: xray в том же процессе → ObservatoryStreamHandler напрямую
  ///   вызывает Libv2ray.getObservatoryState() каждые 2с. Никакого IPC.
  ///
  /// Формат каждого события: JSON-строка (как из [getObservatoryState]).
  /// Heartbeat при отсутствии данных: `{"nodes":[],"warming_up":true}`.
  ///
  /// Использование:
  /// ```dart
  /// V2rayFlutter.observatoryEvents.listen((json) {
  ///   final snapshot = ObservatorySnapshot.fromJson(json);
  ///   // обновить UI
  /// });
  /// ```
  ///
  /// Dart-сторона [ObservatoryStateNotifier] использует этот stream как
  /// primary source и падает назад на polling через [getObservatoryState]
  /// только если platform не поддерживает EventChannel.
  static Stream<String> get observatoryEvents {
    const channel = EventChannel('v2ray_flutter/observatory_events');
    return channel
        .receiveBroadcastStream()
        .map((dynamic event) => event as String);
  }

  // ========== Gomobile V2Ray Methods (New) ==========

  /// Initialize V2Ray system (Gomobile).
  /// Info-prints удалены 2026-05-12 — есть в [V2RAY_RUNNER] выше по стеку.
  static Future<String> initializeV2Ray() async {
    try {
      final String result = await _channel.invokeMethod('initializeV2Ray');
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: Error initializing V2Ray: $e');
      return 'ERROR: $e';
    }
  }

  /// Start V2Ray with JSON configuration (Gomobile).
  /// Config preview дублировал [CFG] блок — убрали.
  static Future<String> startV2RayWithConfig(
      Map<String, dynamic> config) async {
    try {
      final String configJson = json.encode(config);
      final String result = await _channel.invokeMethod('startV2Ray', {
        'config': configJson,
      });
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: Error starting V2Ray: $e');
      return 'ERROR: $e';
    }
  }

  /// Convert share URL → xray JSON config через нативный xray-парсер.
  ///
  /// 2026-05-14: заменяет ручной Dart-парсер (`V2RayUrlParser`, ~600 строк).
  /// libxray дёргает `share.ConvertShareLinksToXrayJson` — поддерживает
  /// `vless://`, `vmess://`, `trojan://`, `ss://`, `ss2022`, v2rayN-bundle.
  ///
  /// Возвращает Map с полным xray Config (`outbounds[0]` — нужный proxy
  /// outbound со всеми streamSettings, tlsSettings, realitySettings,
  /// sockopt). Если парсер не смог — возвращает `null` + debug-лог.
  ///
  /// Использование на стороне MegaV/7VPN:
  /// ```dart
  /// final cfg = await V2rayFlutter.convertUrlToConfig(decryptedUrl);
  /// final proxyOutbound = (cfg?['outbounds'] as List?)?.firstOrNull;
  /// // proxyOutbound — готовый outbound для нашего конфига.
  /// ```
  static Future<Map<String, dynamic>?> convertUrlToConfig(String url) async {
    try {
      final String raw = await _channel.invokeMethod('convertUrlToConfig', {
        'url': url,
      });
      if (raw.startsWith('FAILED:')) {
        debugPrint('[V2RAY] convertUrlToConfig failed: $raw');
        return null;
      }
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) {
        debugPrint('[V2RAY] convertUrlToConfig: unexpected type');
        return null;
      }
      return decoded;
    } catch (e) {
      debugPrint('❌ V2Ray: convertUrlToConfig error: $e');
      return null;
    }
  }

  /// Stop V2Ray service (Gomobile).
  ///
  /// Native может вернуть `bool` (новая iOS-обёртка 2026-05-12) или
  /// `String` "SUCCESS"/"FAILED" (Android legacy + старый iOS). Обе
  /// формы конвертируем в "SUCCESS"/"FAILED" для backward-compat.
  static Future<String> stopV2RayService() async {
    try {
      final dynamic raw = await _channel.invokeMethod('stopV2Ray');
      final String result =
          raw is bool ? (raw ? 'SUCCESS' : 'FAILED') : raw.toString();
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: Error stopping V2Ray: $e');
      return 'ERROR: $e';
    }
  }

  /// Check if V2Ray is running (Gomobile)
  static Future<bool> isV2RayRunning() async {
    try {
      final bool running = await _channel.invokeMethod('isV2RayRunning');
      return running;
    } catch (e) {
      debugPrint('❌ V2Ray: Error checking V2Ray status: $e');
      return false;
    }
  }

  /// Get V2Ray version (Gomobile)
  static Future<String> getV2RayVersion() async {
    debugPrint('📋 V2Ray: Getting V2Ray version...');
    try {
      final String version = await _channel.invokeMethod('getV2RayVersion');
      debugPrint('📋 V2Ray: Version: $version');
      return version;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting V2Ray version: $e');
      return 'Unknown';
    }
  }

  /// Test V2Ray connection (Gomobile)
  static Future<String> testV2RayConnection({String? url}) async {
    debugPrint('🧪 V2Ray: Testing V2Ray connection...');
    try {
      final testUrl = url ?? 'https://www.google.com/generate_204';
      debugPrint('🧪 V2Ray: Testing connection to: $testUrl');
      final String result = await _channel.invokeMethod('testV2RayConnection', {
        'url': testUrl,
      });
      debugPrint('🧪 V2Ray: Connection test result: $result');
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: Error testing V2Ray connection: $e');
      return 'ERROR: $e';
    }
  }

  /// ProbeOutbound — honest HTTP-probe через конкретный outbound в работающем
  /// xray-инстансе. Использует session.SetForcedOutboundTagToContext в нативке
  /// для принудительной маршрутизации, ИГНОРИРУЯ balancer/routing rules.
  ///
  /// Возвращает Map с полями:
  ///   - outbound_tag : str  — имя outbound который пробивался
  ///   - target_url   : str
  ///   - alive        : bool — HTTP 2xx/3xx ответ получен
  ///   - http_code    : int? — HTTP-код (если не было ошибки на dial)
  ///   - rtt_ms       : int  — общее время с момента dial до ответа
  ///   - body_excerpt : str? — первые 512 байт body (для парсинга exit_ip/asn)
  ///   - error        : str? — описание ошибки если probe не прошёл
  ///   - timestamp_ms : int  — unix-время начала probe
  ///
  /// Memory: ~1.5 MB на active probe — безопасно для iOS NE jetsam 50MB cap.
  ///
  /// Пример: проверить server-15 через ip.megav.app/whoami:
  /// ```dart
  /// final r = await V2rayFlutter.probeOutbound(
  ///   tag: 'server-15',
  ///   url: 'https://ip.megav.app/',
  ///   timeoutMs: 5000,
  /// );
  /// if (r['alive'] == true) {
  ///   debugPrint('exit through ${r['body_excerpt']}');
  /// }
  /// ```
  static Future<Map<String, dynamic>?> probeOutbound({
    required String tag,
    required String url,
    int timeoutMs = 5000,
  }) async {
    try {
      final sw = Stopwatch()..start();
      final String raw = await _channel.invokeMethod('probeOutbound', {
        'tag': tag,
        'url': url,
        'timeoutMs': timeoutMs,
      });
      sw.stop();
      // 2026-05-21: сырой ответ от нативки. Включает body_excerpt от
      // ip.megav.app — реальный exit-IP + asn_organization + город exit'а.
      // Используется чтобы доказать «трафик действительно идёт через этот
      // outbound», а не «xray dispatcher принял request». См. также
      // probe_outbound.go::ProbeOutboundResult.
      debugPrint('[NATIVE_PROBE_RAW] tag=$tag '
          'invokeMs=${sw.elapsedMilliseconds} '
          'rawLen=${raw.length} '
          'raw=$raw');
      if (raw.isEmpty) return null;
      final Map<String, dynamic> result =
          json.decode(raw) as Map<String, dynamic>;
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: probeOutbound failed for tag=$tag: $e');
      return {
        'outbound_tag': tag,
        'target_url': url,
        'alive': false,
        'error': e.toString(),
      };
    }
  }

  /// GetBuildInfo — sanity-check метаданных собранной libv2ray.
  ///
  /// Возвращает Map:
  /// ```
  /// {
  ///   "xray_version": "26.5.9",
  ///   "go_version": "go1.26.3",
  ///   "libxray_commit": "...",     // если VCS-stamping есть
  ///   "features": {
  ///     "pr5805_balancer_dialer": true,   // chain-mode (balancer-tag в sockopt.dialerProxy)
  ///     "observatory_state": true,         // наш own GetObservatoryState API
  ///     "probe_outbound": true,            // honest HTTP-probe API
  ///   }
  /// }
  /// ```
  ///
  /// **Главный feature-flag**: `pr5805_balancer_dialer`.
  /// - true → форк xray-core с PR #5805 вкомпилен → chain через
  ///   BOOTSTRAP-BAL работает (sockopt.dialerProxy резолвит balancer-tag).
  /// - false → upstream xray без форка → balancer-tag в dialerProxy
  ///   даёт `there is no outbound handler for dialerProxy` → chain
  ///   рушится. Нужно использовать simple-chain с outbound-tag.
  ///
  /// Можно вызывать в любой момент (не требует запущенного xray).
  /// Используется на старте app для логирования + sanity-check.
  static Future<Map<String, dynamic>?> getBuildInfo() async {
    try {
      final raw = await _channel.invokeMethod<String>('getBuildInfo');
      if (raw == null || raw.isEmpty) return null;
      return json.decode(raw) as Map<String, dynamic>;
    } on MissingPluginException catch (e) {
      // 2026-05-28: Android race — plugin attach происходит ПОЗЖЕ чем Activity
      // onCreate. Возвращаем error-сignal чтобы caller сделал retry.
      return {'error': 'MissingPluginException: ${e.message}'};
    } catch (e) {
      debugPrint('❌ V2Ray: getBuildInfo failed: $e');
      return {'error': e.toString()};
    }
  }

  /// 2026-05-22 (юзер): live memory stats из NE для debug-overlay.
  /// На iOS NE — отдельный процесс с jetsam 50MB cap, утечки невидимы
  /// без мониторинга. NE пишет в App Group `ne_memory_stats_json` каждые
  /// 5 сек (PacketTunnelProvider.reportMemoryUsage), Dart читает.
  ///
  /// Возвращает Map: `{"mb": 42.5, "ts": 1779465895.41, "packets_in": N,
  /// "packets_out": M}` или `{"error": "..."}` если данные недоступны.
  ///
  /// Платформы:
  ///   - iOS: реальные данные из NE через App Group bridge.
  ///   - macOS: xray в main app, можно мерить ResidentSize самого process
  ///            — NE-stats отдают error="no_data" (NE тонкий tun2socks).
  ///   - Android: не реализовано, возвращает error.
  static Future<Map<String, dynamic>?> getNeMemoryStats() async {
    try {
      final raw = await _channel.invokeMethod<String>('getNeMemoryStats');
      if (raw == null || raw.isEmpty) return null;
      return json.decode(raw) as Map<String, dynamic>;
    } catch (e) {
      // Каналу нет (Android / macOS пока) → молча
      return {'error': e.toString()};
    }
  }

  /// GetObservatoryState — snapshot текущего состояния burstObservatory:
  /// alive/dead/RTT для всех outbound'ов из subjectSelector.
  ///
  /// КРИТИЧНО: это **внутренний** вызов (без сети). Observatory сама
  /// пингует subjectSelector с интервалом VpnLimits.observatoryInterval
  /// (30с), мы только читаем уже собранную статистику. Поэтому метод
  /// можно дёргать часто (даже раз в 1-2 сек) — это **не** создаёт
  /// трафик к exit-серверам и не вызывает их подозрения.
  ///
  /// Возвращает Map:
  /// ```
  /// {
  ///   "nodes": [
  ///     {
  ///       "tag": "bs-0",                  // outbound тег из xray-config
  ///       "alive": true,                  // последняя проба прошла
  ///       "delay_ms": 818,                // average RTT в миллисекундах
  ///       "ping_all": 3,                  // сколько проб всего
  ///       "ping_fail": 0,                 // сколько неуспешных
  ///       "ping_avg": 818,                // == delay_ms
  ///       "ping_max": 883,
  ///       "ping_min": 760,
  ///       "ping_deviation": 50,           // отклонение (стабильность)
  ///       "last_error": "",               // если dead — текст ошибки
  ///       "last_seen_ms": 0,              // unix-ms последнего success
  ///       "last_try_ms": 0                // unix-ms последней пробы
  ///     },
  ///     ...
  ///   ],
  ///   "timestamp_ms": 1779326040627
  /// }
  /// ```
  ///
  /// Если ошибка — Map содержит `error` поле, `nodes` пустой.
  /// Возможные ошибки: "xray not running", "observatory not configured".
  ///
  /// Winner balancer'а Dart считает сам:
  /// ```dart
  /// final winner = nodes
  ///   .where((n) => n['alive'] == true)
  ///   .reduce((a, b) => a['delay_ms'] < b['delay_ms'] ? a : b);
  /// ```
  ///
  /// Lab-проверено на `_lab/test-09-swapped.json`:
  ///   bs-1 (freedom direct) → alive=true, delay_ms=576, **winner**
  ///   bs-0 (Egypt fake-pwd) → alive=false, ping_fail=3
  ///   server-0/server-1 (chain через мёртвый bs-0) → alive=false
  static Future<Map<String, dynamic>?> getObservatoryState({
    String requestJSON = '',
  }) async {
    try {
      final String raw = await _channel.invokeMethod('getObservatoryState', {
        'requestJSON': requestJSON,
      });
      if (raw.isEmpty) return null;
      final Map<String, dynamic> result =
          json.decode(raw) as Map<String, dynamic>;
      return result;
    } on MissingPluginException catch (_) {
      // 2026-05-28: Android race — plugin attach происходит ПОЗЖЕ чем Activity
      // onCreate, polling-loop успевает дёрнуть раньше. Молча возвращаем null,
      // не спамим лог. Следующий poll через 1с уже найдёт handler.
      return null;
    } catch (e) {
      debugPrint('❌ V2Ray: getObservatoryState failed: $e');
      return {
        'nodes': <dynamic>[],
        'error': e.toString(),
      };
    }
  }

  /// Get V2Ray status (Gomobile)
  static Future<String> getV2RayStatus() async {
    debugPrint('📊 V2Ray: Getting V2Ray status...');
    try {
      final String status = await _channel.invokeMethod('getV2RayStatus');
      debugPrint('📊 V2Ray: Status: $status');
      return status;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting V2Ray status: $e');
      return 'ERROR: $e';
    }
  }

  /// Cleanup V2Ray resources (Gomobile)
  static Future<String> cleanupV2Ray() async {
    try {
      final String result = await _channel.invokeMethod('cleanupV2Ray');
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: Error cleaning up V2Ray: $e');
      return 'ERROR: $e';
    }
  }

  // ========== Legacy Methods (Existing) ==========

  /// Get V2Ray core version (Legacy)
  static Future<String> getCoreVersion() async {
    debugPrint('📋 V2Ray: Getting core version (Legacy)...');
    try {
      final String version = await _channel.invokeMethod('getCoreVersion');
      debugPrint('📋 V2Ray: Core version (Legacy): $version');
      return version;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting core version (Legacy): $e');
      // Try gomobile version as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile version...');
      return await getV2RayVersion();
    }
  }

  /// Start V2Ray with the given configuration (Legacy)
  static Future<bool> startV2Ray(Map<String, dynamic> config) async {
    debugPrint('🚀 V2Ray: Starting V2Ray service (Legacy)...');
    try {
      String configJson = json.encode(config);
      debugPrint(
          '📋 V2Ray: Config JSON length (Legacy): ${configJson.length} chars');
      debugPrint(
          '📋 V2Ray: Config preview (Legacy): ${configJson.length > 200 ? configJson.substring(0, 200) + '...' : configJson}');

      final bool success = await _channel.invokeMethod('startV2Ray', {
        'config': configJson,
      });

      if (!success) {
        String error = await getLastError();
        debugPrint('❌ V2Ray: Failed to start V2Ray (Legacy): $error');
      } else {
        debugPrint('✅ V2Ray: Successfully started V2Ray (Legacy)');
      }

      return success;
    } catch (e) {
      debugPrint('❌ V2Ray: Error starting V2Ray (Legacy): $e');
      // Try gomobile as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile...');
      try {
        String result = await startV2RayWithConfig(config);
        if (result != 'SUCCESS') {
          debugPrint('❌ V2Ray: Fallback start failed with result: $result');
        }
        return result == 'SUCCESS';
      } catch (e2) {
        debugPrint('❌ V2Ray: Fallback to gomobile also failed: $e2');
        return false;
      }
    }
  }

  /// Stop V2Ray (Legacy).
  ///
  /// Native может вернуть `bool` (iOS после 2026-05-12) или `String`
  /// "SUCCESS"/"FAILED" (Android + legacy iOS). Обе формы → `bool`.
  static Future<bool> stopV2Ray() async {
    debugPrint('🛑 V2Ray: Stopping V2Ray (Legacy)...');
    try {
      final dynamic raw = await _channel.invokeMethod('stopV2Ray');
      final bool success = raw is bool
          ? raw
          : (raw is String ? raw == 'SUCCESS' : false);
      debugPrint('✅ V2Ray: Stop result (Legacy): $success (raw=$raw)');
      return success;
    } catch (e) {
      debugPrint('❌ V2Ray: Error stopping V2Ray (Legacy): $e');
      // Try gomobile as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile...');
      try {
        String result = await stopV2RayService();
        return result == 'SUCCESS';
      } catch (e2) {
        debugPrint('❌ V2Ray: Fallback to gomobile also failed: $e2');
        return false;
      }
    }
  }

  /// Check if V2Ray is running (Legacy)
  static Future<bool> isRunning() async {
    debugPrint('🔍 V2Ray: Checking if V2Ray is running (Legacy)...');
    try {
      final bool running = await _channel.invokeMethod('isRunning');
      debugPrint('🔍 V2Ray: Running status (Legacy): $running');
      return running;
    } catch (e) {
      debugPrint('❌ V2Ray: Error checking V2Ray status (Legacy): $e');
      // Try gomobile as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile...');
      return await isV2RayRunning();
    }
  }

  /// Get last error message (Legacy)
  static Future<String> getLastError() async {
    debugPrint('❌ V2Ray: Getting last error (Legacy)...');
    try {
      final String error = await _channel.invokeMethod('getLastError');
      debugPrint('❌ V2Ray: Last error (Legacy): $error');
      return error;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting last error (Legacy): $e');
      // Try gomobile status as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile status...');
      return await getV2RayStatus();
    }
  }

  /// Cleanup resources (Legacy)
  static Future<void> cleanup() async {
    debugPrint('🧹 V2Ray: Cleaning up resources (Legacy)...');
    try {
      await _channel.invokeMethod('cleanup');
      debugPrint('✅ V2Ray: Cleanup completed (Legacy)');
    } catch (e) {
      debugPrint('❌ V2Ray: Error during cleanup (Legacy): $e');
      // Try gomobile cleanup as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile cleanup...');
      try {
        await cleanupV2Ray();
      } catch (e2) {
        debugPrint('❌ V2Ray: Fallback cleanup also failed: $e2');
      }
    }
  }

  /// Get active server index by parsing V2Ray logs
  static Future<int> getActiveServerIndex() async {
    try {
      final int index = await _channel.invokeMethod('getActiveServerIndex');
      return index;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting active server index: $e');
      return 0;
    }
  }

  // ========== Configuration Helpers ==========

  /// Create VLESS configuration
  static Map<String, dynamic> createVlessConfig({
    required String serverAddress,
    required int serverPort,
    required String uuid,
    String? path,
    String? host,
    bool enableTLS = true,
    int localPort = 1080,
  }) {
    return V2RayConfigHelper.createVlessConfig(
      serverAddress: serverAddress,
      serverPort: serverPort,
      uuid: uuid,
      path: path,
      host: host,
      enableTLS: enableTLS,
      localPort: localPort,
    );
  }

  // ========== Connection Timer Methods ==========

  /// Get current connection duration in milliseconds
  static Future<int> getConnectionDuration() async {
    return V2RayTimerUtils.getConnectionDuration(_channel);
  }

  /// Get total connection time in milliseconds (accumulated across sessions)
  static Future<int> getTotalConnectionTime() async {
    return V2RayTimerUtils.getTotalConnectionTime(_channel);
  }

  /// Reset connection timer (clear accumulated time)
  static Future<bool> resetConnectionTimer() async {
    return V2RayTimerUtils.resetConnectionTimer(_channel);
  }

  /// Set connection limits for subscription control
  static Future<bool> setConnectionLimits({
    int? sessionLimit, // in milliseconds
    int? dailyLimit, // in milliseconds
  }) async {
    return V2RayTimerUtils.setConnectionLimits(
      _channel,
      sessionLimit: sessionLimit,
      dailyLimit: dailyLimit,
    );
  }

  /// Get connection duration in human readable format
  static String formatConnectionDuration(int milliseconds) {
    return V2RayTimerUtils.formatConnectionDuration(milliseconds);
  }

  /// Check if user has exceeded time limits
  static Future<Map<String, dynamic>> checkTimeLimits({
    int? sessionLimit,
    int? dailyLimit,
  }) async {
    return V2RayTimerUtils.checkTimeLimits(
      _channel,
      sessionLimit: sessionLimit,
      dailyLimit: dailyLimit,
    );
  }
}
