import Flutter
import UIKit
import Libv2ray

// Используем CoreController класс из Libv2ray
@objc protocol Libv2rayCoreCallbackHandler {
  func onEmitStatus(_ p0: Int, p1: String?) -> Int
  func shutdown() -> Int
  func startup() -> Int
}

class Libv2rayCoreController: NSObject {
  var callbackHandler: Libv2rayCoreCallbackHandler?
  var isRunning: Bool = false

  init(_ handler: Libv2rayCoreCallbackHandler?) {
    self.callbackHandler = handler
    super.init()
  }

  func startLoop(_ configContent: String?) throws -> Bool {
    return false
  }

  func stopLoop() throws -> Bool {
    return false
  }

  func measureDelay(_ url: String?) throws -> Int64 {
    return 0
  }
}

/// Pull→Push адаптер для observatory snapshot'ов на iOS.
///
/// Архитектура iOS: xray работает внутри Network Extension (отдельный процесс).
/// Из main app напрямую вызвать Libv2ray нельзя. Вместо этого:
///   1. NE пишет `observatory_state_json` + `observatory_state_ts` в App Group
///      (UserDefaults suite = "group.com.megav.vpn") каждые 2с.
///   2. NE постит Darwin notification "com.megav.vpn.observatory.updated".
///   3. ObservatoryStreamHandler подписывается на Darwin notification →
///      при каждом notify читает App Group → пушит на Dart через EventSink.
///   4. Если NE молчит (cold start / warming) — fallback polling каждые 2с
///      пушит heartbeat {"nodes":[],"warming_up":true}.
///
/// Dart-сторона: `EventChannel('v2ray_flutter/observatory_events').receiveBroadcastStream()`
/// Существующий MethodChannel `getObservatoryState` остаётся как fallback poll.
class ObservatoryStreamHandler: NSObject, FlutterStreamHandler {
  // FlutterEventSink доступен только с main thread — всегда диспатчим туда.
  private var eventSink: FlutterEventSink?
  // Типизированный pointer: CFNotificationCenter API ожидает UnsafeRawPointer.
  private var darwinObserver: UnsafeRawPointer?
  private var fallbackTimer: Timer?

  private let appGroupID = "group.com.megav.vpn"
  private let stateKey = "observatory_state_json"
  private let tsKey = "observatory_state_ts"
  private let darwinNotification = "com.megav.vpn.observatory.updated"
  // Stale threshold: если NE не писал 10с — считаем stale и пушим warming_up.
  private let staleThresholdSec: TimeInterval = 10.0
  // Fallback poll interval: когда нет Darwin уведомлений (NE ещё не поднялся).
  private let fallbackIntervalSec: TimeInterval = 2.0

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events

    // Очищаем предыдущую подписку, если onListen вызван повторно без onCancel
    // (e.g. re-subscribe). Без этого старый passRetained pointer утечёт.
    removeExistingObserver()

    // Подписываемся на Darwin notification от NE (мгновенный push).
    // passRetained увеличивает RC на 1 — балансируется в removeExistingObserver().
    let selfPtr = Unmanaged.passRetained(self).toOpaque()
    // CFNotificationCenterAddObserver принимает `CFString?` для параметра name
    // (несмотря на формальный CFNotificationName в bridging-header — в Swift
    // он раскрывается как CFString). Прямое создание через `as CFString`.
    let notifName = darwinNotification as CFString
    let center = CFNotificationCenterGetDarwinNotifyCenter()

    // CFNotificationCallback: (CFNotificationCenter?, UnsafeMutableRawPointer?,
    //   CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void
    // Второй параметр — observer context, это наш selfPtr.
    CFNotificationCenterAddObserver(
      center,
      selfPtr,
      { _, observer, _, _, _ in
        // Darwin callback может прийти на произвольный thread.
        // Диспатчим на main thread для thread-safe доступа к eventSink.
        guard let observer = observer else { return }
        let handler = Unmanaged<ObservatoryStreamHandler>
          .fromOpaque(UnsafeRawPointer(observer))
          .takeUnretainedValue()
        DispatchQueue.main.async {
          handler.pushFromAppGroup()
        }
      },
      notifName,
      nil,
      .deliverImmediately
    )
    darwinObserver = UnsafeRawPointer(selfPtr)

    // Fallback: если NE ещё не постил уведомление (cold start) — poll каждые 2с.
    startFallbackTimer()

    // Первый push сразу при subscribe.
    pushFromAppGroup()

    NSLog("[OBS_STREAM] iOS ObservatoryStreamHandler: onListen started")
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    removeExistingObserver()

    fallbackTimer?.invalidate()
    fallbackTimer = nil

    NSLog("[OBS_STREAM] iOS ObservatoryStreamHandler: onCancel")
    return nil
  }

  /// Отписывается от Darwin notification и балансирует passRetained.
  /// Выделено в отдельный метод чтобы вызывать как из onCancel, так и
  /// при повторном onListen (защита от утечки retain).
  private func removeExistingObserver() {
    guard let ptr = darwinObserver else { return }
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    // nil в name — снимаем все Darwin notifications для этого observer.
    CFNotificationCenterRemoveObserver(center, ptr, nil, nil)
    // Балансируем passRetained: одно passRetained → одно release().
    Unmanaged<ObservatoryStreamHandler>.fromOpaque(ptr).release()
    darwinObserver = nil
  }

  /// Читает App Group и пушит snapshot на Dart.
  /// ВСЕГДА вызывается с main thread (из timer или через DispatchQueue.main.async).
  func pushFromAppGroup() {
    // eventSink не thread-safe — вызов обязан быть на main thread.
    assert(Thread.isMainThread, "pushFromAppGroup must be called on main thread")
    guard let sink = eventSink else { return }
    guard let defaults = UserDefaults(suiteName: appGroupID) else {
      sink("{\"nodes\":[],\"error\":\"app_group_unavailable\"}")
      return
    }

    let ts = defaults.double(forKey: tsKey)
    let age = Date().timeIntervalSince1970 - ts

    if ts <= 0 || age > staleThresholdSec {
      // NE не писал — warming up или отключён.
      sink("{\"nodes\":[],\"warming_up\":true}")
      return
    }

    let json = defaults.string(forKey: stateKey) ?? ""
    if json.isEmpty {
      sink("{\"nodes\":[],\"warming_up\":true}")
    } else {
      sink(json)
    }
  }

  private func startFallbackTimer() {
    fallbackTimer?.invalidate()
    // Создаём Timer без немедленного добавления на RunLoop (не используем
    // scheduledTimer, чтобы избежать двойного добавления на main RunLoop).
    // Добавляем явно в .common mode — работает и при scroll/interaction.
    let timer = Timer(
      timeInterval: fallbackIntervalSec,
      repeats: true
    ) { [weak self] _ in
      self?.pushFromAppGroup()
    }
    RunLoop.main.add(timer, forMode: .common)
    fallbackTimer = timer
  }
}

public class V2rayFlutterPlugin: NSObject, FlutterPlugin {
  private var coreController: Libv2rayCoreController?
  private var isInitialized = false

  // Darwin notification + EventChannel управляется ObservatoryStreamHandler.
  // Статические поля здесь не нужны — вся логика внутри ObservatoryStreamHandler.

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "v2ray_flutter", binaryMessenger: registrar.messenger())
    let instance = V2rayFlutterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    // EventChannel для observatory push.
    let obsChannel = FlutterEventChannel(
      name: "v2ray_flutter/observatory_events",
      binaryMessenger: registrar.messenger()
    )
    obsChannel.setStreamHandler(ObservatoryStreamHandler())
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initializeV2Ray":
      if !isInitialized {
        coreController = Libv2rayCoreController(nil)
        isInitialized = true
      }
      result("SUCCESS")

    case "startV2Ray":
      guard let args = call.arguments as? [String: Any],
            let config = args["config"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing config", details: nil))
        return
      }

      // On iOS, V2Ray runs inside the Network Extension (PacketTunnelProvider),
      // not in the main app process. Save config to App Group so the NE can read it.
      // The NE calls Libv2rayStartV2RayWithConfig() directly.
      if let sharedDefaults = UserDefaults(suiteName: "group.com.megav.vpn") {
        sharedDefaults.set(config, forKey: "v2ray_config")
        sharedDefaults.synchronize()
        NSLog("✅ [V2Ray Plugin] Config saved to App Group (\(config.count) chars)")
        result("SUCCESS")
      } else {
        NSLog("❌ [V2Ray Plugin] Failed to access App Group")
        result("FAILED: App Group not accessible")
      }

    case "stopV2Ray":
      // Возвращаем Bool (как Android), а не String — Dart-сторона
      // (Future<bool> stopV2Ray) кастит результат и ловит TypeError
      // на String. 2026-05-12: было `result("SUCCESS"/"FAILED")` →
      // `type 'String' is not a subtype of type 'bool'`.
      do {
        let stopped = try coreController?.stopLoop() ?? false
        result(stopped)
      } catch {
        // На ошибке возвращаем false — Dart воспримет как «stop не сработал»
        // (например, V2Ray уже остановлен). Полный текст пишем в лог.
        NSLog("[V2rayFlutter] stopV2Ray error: \(error.localizedDescription)")
        result(false)
      }

    case "isV2RayRunning":
      let running = coreController?.isRunning ?? false
      result(running)

    case "getV2RayVersion":
      // Используем CheckVersionX
      result("V2Ray Core (gomobile)")

    case "getV2RayStatus":
      let running = coreController?.isRunning ?? false
      result(running ? "RUNNING" : "STOPPED")

    case "testV2RayConnection":
      guard let args = call.arguments as? [String: Any],
            let url = args["url"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing url", details: nil))
        return
      }

      do {
        let delay = try coreController?.measureDelay(url) ?? 0
        result(delay > 0 ? "SUCCESS" : "FAILED")
      } catch {
        result("FAILED: \(error.localizedDescription)")
      }

    case "probeOutbound":
      // Honest HTTP-probe через конкретный outbound в работающем xray-инстансе.
      // Использует session.SetForcedOutboundTagToContext внутри Libv2ray для
      // принудительной маршрутизации, ИГНОРИРУЯ balancer/routing rules.
      //
      // Args: tag(String), url(String), timeoutMs(Int)
      // Returns: JSON-string из xray.ProbeOutboundResult (см. libXray/xray/probe_outbound.go)
      //
      // Memory: ~1.5 MB на active probe — безопасно для NE jetsam 50MB cap.
      //
      // P1-async (2026-05-18): вызов вынесен в DispatchQueue.global() —
      // Libv2rayProbeOutbound СИНХРОННЫЙ (блокирует до получения HTTP-ответа,
      // до timeout). При Dart-side Future.wait([20 probes × 5s]) на main
      // platform thread это **замораживает UI Flutter на 5+ секунд worst case**.
      // Background-очередь снимает блокировку, result(...) обратно
      // диспатчится на main thread (FlutterMethodCallHandler требует).
      guard let args = call.arguments as? [String: Any],
            let tag = args["tag"] as? String,
            let url = args["url"] as? String else {
        result(FlutterError(code: "INVALID_ARGS",
                            message: "Missing tag/url for probeOutbound",
                            details: nil))
        return
      }
      let timeoutMs = (args["timeoutMs"] as? Int) ?? 5000

      DispatchQueue.global(qos: .userInitiated).async {
        // Libv2rayProbeOutbound — gomobile-binding из libv2ray/libv2ray.go
        // Сигнатура: func Libv2rayProbeOutbound(outboundTag, targetURL string, timeoutMs int) string
        let json = Libv2rayProbeOutbound(tag, url, timeoutMs)
        DispatchQueue.main.async {
          result(json)
        }
      }

    case "getBuildInfo":
      // 2026-05-21: метаданные libv2ray. На iOS NE — gomobile-binding, метод
      // доступен напрямую через Libv2rayGetBuildInfo (без proxy через App Group).
      let json = Libv2rayGetBuildInfo()
      result(json)

    case "getObservatoryState":
      // 2026-05-22: App Group bridge. Xray работает в Network Extension
      // (отдельный процесс), к Libv2ray из main app напрямую не достучаться.
      // Реализовано через shared UserDefaults:
      //   1. NE (PacketTunnelProvider.startObservatoryPolling) каждые 2с
      //      вызывает Libv2rayGetObservatoryState, пишет JSON + ts.
      //   2. Здесь читаем JSON, проверяем что ts свежий (<=10с),
      //      отдаём Dart'у.
      //   3. Stale / отсутствует → возвращаем явный error чтоб Dart-сторона
      //      нарисовала пустой snapshot без NoSuchMethodError.
      let appGroupID = "group.com.megav.vpn"
      let stateKey = "observatory_state_json"
      let tsKey = "observatory_state_ts"
      let staleThresholdSec: TimeInterval = 10.0

      guard let defaults = UserDefaults(suiteName: appGroupID) else {
        result("{\"nodes\":[],\"error\":\"app_group_unavailable\"}")
        break
      }
      let ts = defaults.double(forKey: tsKey)
      let nowTs = Date().timeIntervalSince1970
      if ts <= 0 {
        // NE ещё не начала poll'ить (только что connect, observatory cold)
        // или VPN не активен.
        result("{\"nodes\":[],\"error\":\"no_observatory_data\"}")
        break
      }
      let age = nowTs - ts
      if age > staleThresholdSec {
        // NE упал / disconnect только что — данные устарели.
        result("{\"nodes\":[],\"error\":\"stale\",\"age_sec\":\(age)}")
        break
      }
      let json = defaults.string(forKey: stateKey) ?? ""
      if json.isEmpty {
        result("{\"nodes\":[],\"error\":\"empty_state\"}")
        break
      }
      result(json)

    case "cleanupV2Ray":
      coreController = nil
      isInitialized = false
      result("SUCCESS")

    case "getConnectionDuration":
      // Return 0 - actual duration is tracked in Flutter/VPNManager
      result(0)

    case "getStats":
      // Return empty stats - not implemented in iOS stub
      result([:] as [String: Any])

    case "convertUrlToConfig":
      // 2026-05-14: нативная конвертация vless://, vmess://, trojan://, ss://
      // URL → JSON xray-config через xray-парсер. Заменяет ручной Dart-парсер
      // (V2RayUrlParser ~600 строк) — теперь все streamSettings, tlsSettings,
      // realitySettings и т.д. строит сам xray, без багов в Dart.
      //
      // Возвращает либо JSON string с outbounds[0] (готовый proxy outbound),
      // либо строку начинающуюся с "FAILED: " при ошибке парсинга.
      // Сам конвертер запускается в main app process (не в NE), т.к. это
      // чисто Go-функция парсинга, не запускающая xray-core.
      guard let args = call.arguments as? [String: Any],
            let url = args["url"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing url", details: nil))
        return
      }
      let json = Libv2rayConvertUrlToConfig(url) ?? "FAILED: nil result"
      result(json)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

// Примечание: ObservatoryStreamHandler определён выше (до V2rayFlutterPlugin).
// Раньше здесь был дубль-класс (упрощённая версия, пушила только "updated"
// сигнал). Он удалён 2026-05-22 — основной класс на line ~48 умеет читать
// App Group и пушить полный JSON snapshot, что нужно Dart-стороне.
