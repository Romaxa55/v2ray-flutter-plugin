package com.example.v2ray_flutter

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import libv2ray.Libv2ray
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Pull→Push адаптер для observatory snapshot'ов на Android.
 *
 * Архитектура Android: xray (Libv2ray) работает В ТОМ ЖЕ процессе что и main app
 * (VpnTunnelService не имеет android:process в манифесте). Поэтому IPC не нужен —
 * Libv2ray.getObservatoryState() вызывается напрямую из plugin'а.
 *
 * Стратегия Pull→Push:
 *   1. При onListen — стартуем ScheduledExecutorService с интервалом [pollIntervalMs].
 *   2. Каждый тик: вызываем Libv2ray.getObservatoryState(""), парсим результат.
 *   3. Если json пустой / null — пушим heartbeat {"nodes":[],"warming_up":true}.
 *   4. Результат пушим через EventSink на Dart (на main thread).
 *   5. При onCancel — останавливаем executor.
 *
 * Dart-сторона: EventChannel('v2ray_flutter/observatory_events').receiveBroadcastStream()
 * Существующий MethodChannel `getObservatoryState` остаётся как fallback poll.
 */
private class ObservatoryStreamHandler(
  private val plugin: V2rayFlutterPlugin,
  private val appContext: android.content.Context,
) : EventChannel.StreamHandler {
  private val TAG = "ObsStreamHandler"
  private val OBSERVATORY_CHANNEL = "v2ray_flutter/observatory_events"
  // Интервал опроса: 2с. Service пишет snapshot в MMKV каждые 3с,
  // мы читаем чаще чтобы не пропустить обновление.
  // 2026-05-28 (Phase 1.5 #20): читаем из MMKV вместо прямого
  // Libv2ray-вызова — xray в :vpntunnel процессе после изоляции.
  private val pollIntervalMs = 2000L

  private val mainHandler = Handler(Looper.getMainLooper())
  private val sinkRef = AtomicReference<EventChannel.EventSink?>(null)
  private val executor = Executors.newSingleThreadScheduledExecutor { r ->
    Thread(r, "obs-poll-thread").also { it.isDaemon = true }
  }
  private var scheduledFuture: ScheduledFuture<*>? = null

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    Log.d(TAG, "[OBS_STREAM] Android ObservatoryStreamHandler: onListen")
    sinkRef.set(events)
    scheduledFuture?.cancel(false)
    // Первый push немедленно, затем каждые pollIntervalMs.
    scheduledFuture = executor.scheduleWithFixedDelay(
      ::pollAndPush,
      0L,
      pollIntervalMs,
      TimeUnit.MILLISECONDS
    )
  }

  override fun onCancel(arguments: Any?) {
    Log.d(TAG, "[OBS_STREAM] Android ObservatoryStreamHandler: onCancel")
    scheduledFuture?.cancel(false)
    scheduledFuture = null
    sinkRef.set(null)
  }

  private fun pollAndPush() {
    val sink = sinkRef.get() ?: return
    val json: String = try {
      // 2026-05-28 (Phase 1.5 #20): читаем из MMKV (Service пишет).
      // Fallback на прямой Libv2ray для legacy single-process mode.
      val fromMmkv = plugin.readObservatorySnapshotFromMmkv()
      if (!fromMmkv.isNullOrEmpty()) {
        fromMmkv
      } else {
        val raw = Libv2ray.getObservatoryState("")
        if (raw.isNullOrEmpty()) {
          """{"nodes":[],"warming_up":true}"""
        } else {
          raw
        }
      }
    } catch (e: Exception) {
      Log.w(TAG, "[OBS_STREAM] getObservatoryState exception: ${e.message}")
      """{"nodes":[],"warming_up":true}"""
    }
    // EventSink.success() должен вызываться на main thread.
    mainHandler.post {
      try {
        sinkRef.get()?.success(json)
      } catch (e: Exception) {
        Log.w(TAG, "[OBS_STREAM] sink.success failed: ${e.message}")
      }
    }
  }
}

/** V2rayFlutterPlugin with Gomobile V2Ray Integration */
class V2rayFlutterPlugin: FlutterPlugin, MethodCallHandler {
  private val TAG = "V2rayFlutterPlugin"

  // Connection timer variables
  private var connectionStartTime: Long = 0
  private var isConnected: Boolean = false
  private var timerExecutor: ScheduledExecutorService? = null
  private val totalConnectionTime = AtomicLong(0)

  /// The MethodChannel that will handle communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel

  // 2026-05-28 (#20 iOS-parity Observatory bridge): MMKV instance для
  // чтения snapshot'ов которые пишет VpnTunnelService (:vpntunnel process).
  // mmkvID должен совпадать с AppGroupStore.MMKV_ID в app модуле.
  private var appGroupMmkv: com.tencent.mmkv.MMKV? = null

  private fun ensureMmkv(context: android.content.Context): com.tencent.mmkv.MMKV? {
    val existing = appGroupMmkv
    if (existing != null) return existing
    return try {
      // MMKV.initialize идемпотентно — безопасно звать дважды (UI process
      // уже инициализировал через MegaVApplication.onCreate, но Plugin
      // может attached до этого).
      com.tencent.mmkv.MMKV.initialize(context.applicationContext)
      val kv = com.tencent.mmkv.MMKV.mmkvWithID(
        "megav_app_group",
        com.tencent.mmkv.MMKV.MULTI_PROCESS_MODE
      )
      appGroupMmkv = kv
      kv
    } catch (e: Exception) {
      Log.w(TAG, "[OBS_BRIDGE] MMKV init failed: ${e.message}")
      null
    }
  }

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    Log.d(TAG, "🔧 V2Ray Flutter plugin attached to engine")
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "v2ray_flutter")
    channel.setMethodCallHandler(this)

    // 2026-05-22: EventChannel observatory push.
    // 2026-05-28 (Phase 1.5 follow-up): после изоляции xray в :vpntunnel
    // прямой Libv2ray.getObservatoryState() в UI-процессе вернёт пустоту.
    // ObservatoryStreamHandler теперь читает snapshot из MMKV (его пишет
    // VpnTunnelService.startObservatorySnapshotWriter каждые 3 сек).
    EventChannel(flutterPluginBinding.binaryMessenger, "v2ray_flutter/observatory_events")
      .setStreamHandler(ObservatoryStreamHandler(this, flutterPluginBinding.applicationContext))

    // Pre-init MMKV в onAttachedToEngine — UI-процесс уже должен был
    // инициализировать через MegaVApplication, но safety-net.
    ensureMmkv(flutterPluginBinding.applicationContext)

    Log.d(TAG, "✅ V2Ray Flutter plugin initialized (MethodChannel + EventChannel)")

    // Initialize connection timer
    initializeConnectionTimer()
  }

  /// Internal helper для ObservatoryStreamHandler — читает snapshot из MMKV.
  internal fun readObservatorySnapshotFromMmkv(): String? {
    val kv = appGroupMmkv ?: return null
    return try {
      kv.decodeString("observatory_snapshot_json", null)
    } catch (e: Exception) {
      null
    }
  }

  /// Internal helper — читает buildInfo из MMKV.
  internal fun readBuildInfoFromMmkv(): String? {
    val kv = appGroupMmkv ?: return null
    return try {
      kv.decodeString("xray_build_info_json", null)
    } catch (e: Exception) {
      null
    }
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    Log.d(TAG, "📞 V2Ray method call: ${call.method}")

    when (call.method) {
      "getPlatformVersion" -> {
        Log.d(TAG, "📱 Platform version request")
        result.success("Android ${android.os.Build.VERSION.RELEASE}")
      }

      // V2Ray Gomobile Functions
      "initializeV2Ray" -> {
        Log.d(TAG, "🚀 Initializing V2Ray...")
        try {
          val response = Libv2ray.initializeV2Ray()
          Log.d(TAG, "✅ V2Ray initialization result: $response")
          result.success(response)
        } catch (e: Exception) {
          Log.e(TAG, "❌ V2Ray initialization failed: ${e.message}")
          result.error("INIT_ERROR", "Failed to initialize V2Ray: ${e.message}", null)
        }
      }

      "startV2Ray" -> {
        Log.d(TAG, "🚀 Starting V2Ray...")
        try {
          val config = call.argument<String>("config")
          if (config != null) {
            Log.d(TAG, "📋 V2Ray config received (${config.length} chars)")
            Log.d(TAG, "📋 V2Ray config preview: ${config.take(200)}...")
            val response = Libv2ray.startV2RayWithConfig(config)
            Log.d(TAG, "✅ V2Ray start result: $response")

            // Start connection timer if V2Ray started successfully
            if (response == "SUCCESS") {
              startConnectionTimer()
              result.success("SUCCESS")
            } else {
              result.success("FAILED: $response")
            }

          } else {
            Log.e(TAG, "❌ V2Ray config is null")
            result.error("CONFIG_ERROR", "Config parameter is null", null)
          }
        } catch (e: Exception) {
          Log.e(TAG, "❌ V2Ray start failed: ${e.message}")
          result.error("START_ERROR", "Failed to start V2Ray: ${e.message}", null)
        }
      }

      "stopV2Ray" -> {
        Log.d(TAG, "🛑 Stopping V2Ray...")
        try {
          val response = Libv2ray.stopV2Ray()
          Log.d(TAG, "✅ V2Ray stop result: $response")

          // Stop connection timer if V2Ray stopped successfully
          if (response == "SUCCESS") {
            stopConnectionTimer()
          }

          result.success(response)
        } catch (e: Exception) {
          Log.e(TAG, "❌ V2Ray stop failed: ${e.message}")
          result.error("STOP_ERROR", "Failed to stop V2Ray: ${e.message}", null)
        }
      }

      "isV2RayRunning" -> {
        Log.d(TAG, "🔍 Checking V2Ray running status...")
        try {
          val running = Libv2ray.isV2RayRunning()
          Log.d(TAG, "🔍 V2Ray running status: $running")
          result.success(running)
        } catch (e: Exception) {
          Log.e(TAG, "❌ Failed to get V2Ray status: ${e.message}")
          result.error("STATUS_ERROR", "Failed to get V2Ray status: ${e.message}", null)
        }
      }

      "getV2RayVersion" -> {
        Log.d(TAG, "📋 Getting V2Ray version...")
        try {
          val version = Libv2ray.getV2RayVersion()
          Log.d(TAG, "📋 V2Ray version: $version")
          result.success(version)
        } catch (e: Exception) {
          Log.e(TAG, "❌ Failed to get V2Ray version: ${e.message}")
          result.error("VERSION_ERROR", "Failed to get V2Ray version: ${e.message}", null)
        }
      }

      "testV2RayConnection" -> {
        Log.d(TAG, "🧪 Testing V2Ray connection...")
        try {
          val url = call.argument<String>("url") ?: "https://www.google.com/generate_204"
          Log.d(TAG, "🧪 Testing connection to: $url")
          val response = Libv2ray.testV2RayConnection(url)
          Log.d(TAG, "🧪 V2Ray connection test result: $response")
          result.success(response)
        } catch (e: Exception) {
          Log.e(TAG, "❌ V2Ray connection test failed: ${e.message}")
          result.error("TEST_ERROR", "Failed to test connection: ${e.message}", null)
        }
      }

      "getV2RayStatus" -> {
        Log.d(TAG, "📊 Getting V2Ray status...")
        try {
          val status = Libv2ray.getV2RayStatus()
          Log.d(TAG, "📊 V2Ray status: $status")
          result.success(status)
        } catch (e: Exception) {
          Log.e(TAG, "❌ Failed to get V2Ray status: ${e.message}")
          result.error("STATUS_ERROR", "Failed to get status: ${e.message}", null)
        }
      }

      "probeOutbound" -> {
        // 2026-05-18: honest HTTP-probe через конкретный outbound в работающем
        // xray-инстансе. Использует session.SetForcedOutboundTagToContext для
        // принудительной маршрутизации, ИГНОРИРУЯ balancer/routing rules.
        //
        // Реализация: libXray/libv2ray/libv2ray.go::ProbeOutbound — тонкая
        // обёртка над root libxray.ProbeOutbound (xray/probe_outbound.go).
        // Compat-shim экспортирует её под тем же пакетом libv2ray, поэтому
        // на Android используем единый AAR (compat-shim, gomobile-bind с
        // подпакета ./libv2ray) — root libXray.aar отдельно не подключаем,
        // иначе ловим duplicate go.Seq / разные libgojni.so в одном APK.
        //
        // Sanity-clamp timeoutMs:
        //   - MethodChannel может передать Int или Long в зависимости от Dart-side
        //   - clamping в [100ms, 60000ms] предохраняет от user-передачи мусора
        //
        // Args: tag(String), url(String), timeoutMs(Int|Long в [100, 60000])
        // Returns: JSON string (см. libXray/xray/probe_outbound.go::ProbeOutboundResult)
        try {
          val tag = call.argument<String>("tag")
          val url = call.argument<String>("url")
          val rawTimeout = when (val v = call.argument<Any>("timeoutMs")) {
            is Int -> v.toLong()
            is Long -> v
            else -> 5000L
          }
          if (tag.isNullOrEmpty() || url.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "Missing tag/url for probeOutbound", null)
            return@onMethodCall
          }
          // clamp [100, 60_000]ms; gomobile биндит Go int → Java long на 64-bit.
          val timeoutMs = rawTimeout.coerceIn(100L, 60_000L)

          val json = Libv2ray.probeOutbound(tag, url, timeoutMs)
          if (json.isNullOrEmpty()) {
            result.success(
              """{"outbound_tag":"$tag","target_url":"$url","alive":false,"error":"empty response"}"""
            )
          } else {
            result.success(json)
          }
        } catch (e: Exception) {
          Log.e(TAG, "❌ probeOutbound failed: ${e.message}")
          result.error("PROBE_ERROR", "probeOutbound failed: ${e.message}", null)
        }
      }

      "getBuildInfo" -> {
        // 2026-05-21: метаданные собранной libv2ray (xray version + feature flags).
        // 2026-05-28 (Phase 1.5 #20): xray-core в :vpntunnel, не в UI.
        // Читаем snapshot из MMKV который пишет VpnTunnelService на старте.
        // Fallback на прямой Libv2ray (legacy / pre-Phase-1.5 builds).
        try {
          val fromMmkv = readBuildInfoFromMmkv()
          if (!fromMmkv.isNullOrEmpty()) {
            result.success(fromMmkv)
            return@onMethodCall
          }
          // Fallback: прямой вызов (legacy single-process mode).
          val json = Libv2ray.getBuildInfo()
          result.success(json ?: """{"error":"empty"}""")
        } catch (e: Exception) {
          Log.e(TAG, "❌ getBuildInfo failed: ${e.message}")
          result.error("BUILD_INFO_ERROR", "getBuildInfo failed: ${e.message}", null)
        }
      }

      "getObservatoryState" -> {
        // 2026-05-21: snapshot текущего burstObservatory из работающего
        // xray-инстансе. Internal-only (без сети) — observatory сама пингует
        // в фоне с интервалом 30с, мы только читаем cached статистику.
        //
        // 2026-05-28 (Phase 1.5 #20 iOS-parity): xray-core в :vpntunnel,
        // не в UI. Читаем snapshot из MMKV который пишет VpnTunnelService
        // .startObservatorySnapshotWriter каждые 3 сек.
        // Fallback на прямой Libv2ray для legacy single-process mode.
        //
        // Args: requestJSON(String?) — зарезервирован, можно null/empty.
        // Returns: JSON (см. libXray/xray/observatory_state.go).
        //   {"nodes":[{"tag":"bs-0","alive":true,"delay_ms":818,...}], "timestamp_ms":...}
        try {
          val fromMmkv = readObservatorySnapshotFromMmkv()
          if (!fromMmkv.isNullOrEmpty()) {
            result.success(fromMmkv)
            return@onMethodCall
          }
          // Fallback: прямой вызов (legacy single-process mode / cold start
          // когда Service ещё не записал snapshot).
          val requestJSON = call.argument<String>("requestJSON") ?: ""
          val json = Libv2ray.getObservatoryState(requestJSON)
          if (json.isNullOrEmpty()) {
            result.success("""{"nodes":[],"error":"empty response"}""")
          } else {
            result.success(json)
          }
        } catch (e: Exception) {
          Log.e(TAG, "❌ getObservatoryState failed: ${e.message}")
          result.error("OBS_STATE_ERROR", "getObservatoryState failed: ${e.message}", null)
        }
      }

      "cleanupV2Ray" -> {
        Log.d(TAG, "🧹 Cleaning up V2Ray...")
        try {
          val response = Libv2ray.cleanupV2Ray()
          Log.d(TAG, "🧹 V2Ray cleanup result: $response")
          result.success(response)
        } catch (e: Exception) {
          Log.e(TAG, "❌ V2Ray cleanup failed: ${e.message}")
          result.error("CLEANUP_ERROR", "Failed to cleanup: ${e.message}", null)
        }
      }

      // Legacy method support
      "start_v2ray" -> {
        Log.d(TAG, "🚀 Legacy start_v2ray called...")
        try {
          val config = call.argument<String>("remark") ?: call.argument<String>("config")
          if (config != null) {
            Log.d(TAG, "📋 Legacy V2Ray config received (${config.length} chars)")
            val response = Libv2ray.startV2RayWithConfig(config)
            val resultCode = if (response == "SUCCESS") 0 else -1
            Log.d(TAG, "✅ Legacy V2Ray start result: $response (code: $resultCode)")

            // Start connection timer if V2Ray started successfully
            if (response == "SUCCESS") {
              startConnectionTimer()
            }

            result.success(resultCode)
          } else {
            Log.e(TAG, "❌ Legacy V2Ray config is null")
            result.success(-1)
          }
        } catch (e: Exception) {
          Log.e(TAG, "❌ Legacy V2Ray start failed: ${e.message}")
          result.success(-1)
        }
      }

      "stop_v2ray" -> {
        Log.d(TAG, "🛑 Legacy stop_v2ray called...")
        try {
          val response = Libv2ray.stopV2Ray()
          val resultCode = if (response == "SUCCESS") 0 else -1
          Log.d(TAG, "✅ Legacy V2Ray stop result: $response (code: $resultCode)")

          // Stop connection timer if V2Ray stopped successfully
          if (response == "SUCCESS") {
            stopConnectionTimer()
          }

          result.success(resultCode)
        } catch (e: Exception) {
          Log.e(TAG, "❌ Legacy V2Ray stop failed: ${e.message}")
          result.success(-1)
        }
      }

      "get_v2ray_version" -> {
        Log.d(TAG, "📋 Legacy get_v2ray_version called...")
        try {
          val version = Libv2ray.getV2RayVersion()
          Log.d(TAG, "📋 Legacy V2Ray version: $version")
          result.success(version)
        } catch (e: Exception) {
          Log.e(TAG, "❌ Legacy V2Ray version failed: ${e.message}")
          result.success("Unknown")
        }
      }

      // Connection timer methods
      "getConnectionDuration" -> {
        Log.d(TAG, "⏰ Getting connection duration...")
        try {
          val duration = getCurrentConnectionDuration()
          Log.d(TAG, "⏰ Current connection duration: ${duration}ms")
          result.success(duration)
        } catch (e: Exception) {
          Log.e(TAG, "❌ Error getting connection duration: ${e.message}")
          result.error("DURATION_ERROR", "Failed to get connection duration: ${e.message}", null)
        }
      }

      "getTotalConnectionTime" -> {
        Log.d(TAG, "⏰ Getting total connection time...")
        try {
          val totalTime = getTotalConnectionTime()
          Log.d(TAG, "⏰ Total connection time: ${totalTime}ms")
          result.success(totalTime)
        } catch (e: Exception) {
          Log.e(TAG, "❌ Error getting total connection time: ${e.message}")
          result.error("TOTAL_TIME_ERROR", "Failed to get total connection time: ${e.message}", null)
        }
      }

      "resetConnectionTimer" -> {
        Log.d(TAG, "⏰ Resetting connection timer...")
        try {
          totalConnectionTime.set(0)
          Log.d(TAG, "✅ Connection timer reset")
          result.success(true)
        } catch (e: Exception) {
          Log.e(TAG, "❌ Error resetting connection timer: ${e.message}")
          result.error("RESET_ERROR", "Failed to reset connection timer: ${e.message}", null)
        }
      }

      "setConnectionLimits" -> {
        Log.d(TAG, "⏰ Setting connection limits...")
        try {
          val sessionLimit = call.argument<Long>("sessionLimit") ?: 3600000 // 1 hour default
          val dailyLimit = call.argument<Long>("dailyLimit") ?: 28800000 // 8 hours default

          Log.d(TAG, "⏰ Session limit: ${sessionLimit}ms, Daily limit: ${dailyLimit}ms")

          // Here you can store these limits for use in checkSubscriptionLimits
          // For now, just log them
          result.success(true)
        } catch (e: Exception) {
          Log.e(TAG, "❌ Error setting connection limits: ${e.message}")
          result.error("LIMITS_ERROR", "Failed to set connection limits: ${e.message}", null)
        }
      }

      "getActiveServerIndex" -> {
        Log.d(TAG, "📡 Getting active server index...")
        try {
          // На Android V2Ray не возвращает индекс активного сервера из нативной библиотеки
          // Возвращаем 0 как дефолтное значение (первый сервер)
          // Это совместимо с поведением на macOS
          val index = 0
          Log.d(TAG, "📡 Active server index: $index (default)")
          result.success(index)
        } catch (e: Exception) {
          Log.e(TAG, "❌ Error getting active server index: ${e.message}")
          result.error("INDEX_ERROR", "Failed to get active server index: ${e.message}", null)
        }
      }

      // 2026-05-15: нативная конвертация share-URL (vless://, vmess://,
      // trojan://, ss://) → JSON xray-config через xray-core парсер.
      // Заменяет хрупкий Dart-парсер V2RayUrlParser. Симметрично iOS
      // (Libv2rayConvertUrlToConfig) и macOS (V2RayWrapper.convertUrlToConfig).
      //
      // Возвращает JSON-строку с outbounds или строку начинающуюся с
      // "FAILED: " при ошибке парсинга. Dart-сторона
      // (V2rayFlutter.convertUrlToConfig) ловит prefix FAILED и
      // возвращает null.
      "convertUrlToConfig" -> {
        try {
          val url = call.argument<String>("url")
          if (url == null) {
            result.success("FAILED: missing url argument")
            return
          }
          val json = Libv2ray.convertUrlToConfig(url)
          result.success(json ?: "FAILED: convertUrlToConfig returned null")
        } catch (e: Exception) {
          Log.e(TAG, "❌ convertUrlToConfig failed: ${e.message}")
          result.success("FAILED: ${e.message}")
        }
      }

      else -> {
        Log.w(TAG, "⚠️ Unknown V2Ray method called: ${call.method}")
        result.notImplemented()
      }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    Log.d(TAG, "🔧 V2Ray Flutter plugin detached from engine")
    channel.setMethodCallHandler(null)

    // Cleanup connection timer
    cleanupConnectionTimer()
  }

  // ========== Connection Timer Methods ==========

  /**
   * Initialize connection timer
   */
  private fun initializeConnectionTimer() {
    Log.d(TAG, "⏰ Initializing connection timer...")
    timerExecutor = Executors.newSingleThreadScheduledExecutor()
    Log.d(TAG, "✅ Connection timer initialized")
  }

  /**
   * Start connection timer
   */
  private fun startConnectionTimer() {
    if (isConnected) {
      Log.w(TAG, "⚠️ Connection timer already running")
      return
    }

    connectionStartTime = System.currentTimeMillis()
    isConnected = true

    Log.d(TAG, "⏰ Starting connection timer at: ${java.util.Date(connectionStartTime)}")

    // Schedule timer to update every second
    timerExecutor?.scheduleAtFixedRate({
      try {
        val currentTime = System.currentTimeMillis()
        val elapsedTime = currentTime - connectionStartTime
        totalConnectionTime.addAndGet(1000) // Add 1 second

        Log.d(TAG, "⏰ Connection timer update - Elapsed: ${elapsedTime}ms, Total: ${totalConnectionTime.get()}ms")

        // Check if connection is still active
        if (!isConnected) {
          Log.d(TAG, "⏰ Connection stopped, stopping timer")
          return@scheduleAtFixedRate
        }

        // Here you can add logic for subscription checks
        // For example, check if user has exceeded their time limit
        checkSubscriptionLimits(elapsedTime)

      } catch (e: Exception) {
        Log.e(TAG, "❌ Error in connection timer: ${e.message}")
      }
    }, 0, 1, TimeUnit.SECONDS)

    Log.d(TAG, "✅ Connection timer started")
  }

  /**
   * Stop connection timer
   */
  private fun stopConnectionTimer() {
    if (!isConnected) {
      Log.w(TAG, "⚠️ Connection timer not running")
      return
    }

    val endTime = System.currentTimeMillis()
    val sessionDuration = endTime - connectionStartTime

    Log.d(TAG, "⏰ Stopping connection timer - Session duration: ${sessionDuration}ms")

    isConnected = false
    timerExecutor?.shutdown()

    Log.d(TAG, "✅ Connection timer stopped - Total session time: ${sessionDuration}ms")
  }

  /**
   * Get current connection duration
   */
  private fun getCurrentConnectionDuration(): Long {
    return if (isConnected) {
      System.currentTimeMillis() - connectionStartTime
    } else {
      0
    }
  }

  /**
   * Get total connection time (accumulated across sessions)
   */
  private fun getTotalConnectionTime(): Long {
    return totalConnectionTime.get()
  }

  /**
   * Check subscription limits and handle time restrictions
   */
  private fun checkSubscriptionLimits(elapsedTime: Long) {
    // Convert to minutes for easier handling
    val elapsedMinutes = elapsedTime / (1000 * 60)

    // Example: Check if user has exceeded 60 minutes (1 hour)
    if (elapsedMinutes >= 60) {
      Log.w(TAG, "⚠️ User exceeded time limit (60 minutes) - Current: ${elapsedMinutes} minutes")

      // Here you can implement logic to:
      // 1. Stop the connection
      // 2. Show a notification to the user
      // 3. Redirect to payment screen
      // 4. Save usage statistics

      // For now, just log the event
      Log.d(TAG, "💰 Time limit exceeded - User needs to upgrade subscription")
    }

    // Example: Check if user has exceeded daily limit (8 hours)
    val totalMinutes = totalConnectionTime.get() / (1000 * 60)
    if (totalMinutes >= 480) { // 8 hours
      Log.w(TAG, "⚠️ User exceeded daily limit (8 hours) - Current: ${totalMinutes} minutes")
      Log.d(TAG, "💰 Daily limit exceeded - User needs to upgrade subscription")
    }
  }

  /**
   * Cleanup connection timer resources
   */
  private fun cleanupConnectionTimer() {
    Log.d(TAG, "🧹 Cleaning up connection timer...")

    if (isConnected) {
      stopConnectionTimer()
    }

    timerExecutor?.shutdown()
    timerExecutor = null

    Log.d(TAG, "✅ Connection timer cleaned up")
  }
}