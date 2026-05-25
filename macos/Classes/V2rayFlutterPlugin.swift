import Cocoa
import FlutterMacOS

// MARK: - Observatory EventChannel stream handler (2026-05-22)
//
// Dart-сторона подписывается через EventChannel "v2ray_flutter/observatory_events".
// При получении Darwin notification "com.megav.vpn.observatory.updated" (которую
// постит либо NE PacketTunnelProvider, либо сам plugin после записи snapshot)
// pusher шлёт событие "updated" в EventSink. Dart вызывает poll() немедленно.
//
// Архитектура macOS: xray работает в MAIN APP (V2RayWrapper.m), не в NE.
// Поэтому после каждого getObservatoryState call plugin сам обновляет
// App Group (observatory_state_json / observatory_state_ts) и постит Darwin.

private class ObservatoryStreamHandler: NSObject, FlutterStreamHandler {
  private static let appGroupID = "group.com.megav.vpn"
  private static let observatoryDarwinNotification = "com.megav.vpn.observatory.updated"
  private static let observatoryStateKey = "observatory_state_json"
  private static let observatoryTimestampKey = "observatory_state_ts"
  private static let staleThresholdSec: TimeInterval = 10.0

  // Хранится как static чтобы Darwin C-callback мог достучаться.
  static var eventSink: FlutterEventSink?
  static var observerRegistered = false

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    ObservatoryStreamHandler.eventSink = events

    if !ObservatoryStreamHandler.observerRegistered {
      let cfName = CFNotificationName(ObservatoryStreamHandler.observatoryDarwinNotification as CFString)
      CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        nil,
        { _, _, _, _, _ in
          // Darwin → читаем App Group и пушим JSON в Dart EventChannel
          // (симметрично iOS). Dart получает сразу snapshot, без extra
          // round-trip через MethodChannel poll.
          DispatchQueue.main.async {
            ObservatoryStreamHandler.pushFromAppGroup()
          }
        },
        cfName.rawValue,
        nil,
        .deliverImmediately
      )
      ObservatoryStreamHandler.observerRegistered = true
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    ObservatoryStreamHandler.eventSink = nil
    return nil
  }

  /// Читает App Group и пушит JSON snapshot на Dart EventSink.
  /// Симметрично iOS ObservatoryStreamHandler.pushFromAppGroup.
  ///
  /// Должно вызываться с main thread (eventSink не thread-safe).
  static func pushFromAppGroup() {
    assert(Thread.isMainThread)
    guard let sink = eventSink else { return }
    guard let defaults = UserDefaults(suiteName: appGroupID) else {
      sink("{\"nodes\":[],\"error\":\"app_group_unavailable\"}")
      return
    }
    let ts = defaults.double(forKey: observatoryTimestampKey)
    let age = Date().timeIntervalSince1970 - ts
    if ts <= 0 || age > staleThresholdSec {
      // App Group stale / ещё не писали — warming up.
      sink("{\"nodes\":[],\"warming_up\":true}")
      return
    }
    let json = defaults.string(forKey: observatoryStateKey) ?? ""
    if json.isEmpty {
      sink("{\"nodes\":[],\"warming_up\":true}")
    } else {
      sink(json)
    }
  }

  /// Хелпер: записать observatory snapshot в App Group + postить Darwin notification.
  /// Вызывается из getObservatoryState handler'а plugin'а (macOS-специфика:
  /// xray в main app, NE не видит getObservatoryState напрямую).
  static func writeToAppGroupAndNotify(json: String) {
    guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
    let snapshotJson = json.isEmpty ? "{\"nodes\":[],\"warming_up\":true}" : json
    defaults.set(snapshotJson, forKey: observatoryStateKey)
    defaults.set(Date().timeIntervalSince1970, forKey: observatoryTimestampKey)
    // Darwin push → NE + main app listeners (включая наш собственный
    // observer выше — он прочитает свежий snapshot и пушнёт в EventSink).
    let cfName = CFNotificationName(observatoryDarwinNotification as CFString)
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), cfName, nil, nil, true
    )
  }
}

public class V2rayFlutterPlugin: NSObject, FlutterPlugin {

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "v2ray_flutter", binaryMessenger: registrar.messenger)
    let instance = V2rayFlutterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    // 2026-05-22: EventChannel для мгновенного observatory push.
    // Dart-сторона (ObservatoryStateNotifier) подписывается на поток —
    // при Darwin notification приходит событие "updated" и poll стартует сразу.
    let obsChannel = FlutterEventChannel(
      name: "v2ray_flutter/observatory_events",
      binaryMessenger: registrar.messenger
    )
    obsChannel.setStreamHandler(ObservatoryStreamHandler())

    print("✅ V2Ray Flutter Plugin registered for macOS")
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {

    // ========== Gomobile V2Ray Methods (New) ==========

    case "initializeV2Ray":
      // Инициализация V2Ray - просто возвращаем SUCCESS, библиотека инициализируется при первом вызове
      result("SUCCESS")

    case "startV2Ray":
      guard let args = call.arguments as? [String: Any],
            let configJson = args["config"] as? String else {
        result("FAILED: Invalid arguments")
        return
      }

      let success = V2RayWrapper.startV2Ray(configJson)
      if success {
        result("SUCCESS")
      } else {
        let error = V2RayWrapper.getLastError() ?? "Unknown error"
        result("FAILED: " + error)
      }

    case "stopV2Ray":
      let success = V2RayWrapper.stopV2Ray()
      result(success ? "SUCCESS" : "FAILED")

    case "isV2RayRunning":
      let running = V2RayWrapper.isRunning()
      result(running)

    case "getV2RayVersion", "getVersion":
      let version = V2RayWrapper.getCoreVersion()
      result(version)

    case "getV2RayStatus":
      let running = V2RayWrapper.isRunning()
      result(running ? "RUNNING" : "STOPPED")

    case "testV2RayConnection":
      // Simple connectivity test - if V2Ray is running, assume connection is OK
      let running = V2RayWrapper.isRunning()
      result(running ? "SUCCESS" : "FAILED: V2Ray not running")

    case "probeOutbound":
      // 2026-05-18: honest HTTP-probe через конкретный outbound в работающем
      // xray-инстансе через libv2ray.a (c-archive). Использует
      // session.SetForcedOutboundTagToContext для принудительной маршрутизации.
      //
      // Args: tag(String), url(String), timeoutMs(Int)
      // Returns: JSON-string (см. libXray/xray/probe_outbound.go::ProbeOutboundResult)
      //
      // P1-async (2026-05-18): вызов синхронный (блокирует до HTTP-ответа
      // или timeout). На macOS FlutterMethodCallHandler по умолчанию
      // на main thread, при Future.wait([20 probes]) — UI freeze.
      // Background-очередь + main-dispatch для result.
      //
      // P2: sanity-clamp timeoutMs в [100, 60000]ms — без этого передача
      // отрицательного или большого Int в Int32 может вызвать Swift trap.
      guard let args = call.arguments as? [String: Any],
            let tag = args["tag"] as? String,
            let url = args["url"] as? String else {
        result(FlutterError(code: "INVALID_ARGS",
                            message: "Missing tag/url for probeOutbound",
                            details: nil))
        return
      }
      let raw = (args["timeoutMs"] as? Int) ?? 5000
      let timeoutMs = Int32(clamping: max(100, min(raw, 60_000)))

      DispatchQueue.global(qos: .userInitiated).async {
        let json = V2RayWrapper.probeOutbound(tag, url: url, timeoutMs: timeoutMs)
        DispatchQueue.main.async {
          result(json)
        }
      }

    case "cleanupV2Ray":
      V2RayWrapper.cleanup()
      result("SUCCESS")

    // ========== Legacy Methods ==========

    case "getCoreVersion":
      let version = V2RayWrapper.getCoreVersion()
      result(version)

    case "isRunning":
      let running = V2RayWrapper.isRunning()
      result(running)

    case "getLastError":
      let error = V2RayWrapper.getLastError()
      result(error)

    case "cleanup":
      V2RayWrapper.cleanup()
      result(true)

    case "getActiveServerIndex":
      let index = V2RayWrapper.getActiveServerIndex()
      result(index)

    case "getBuildInfo":
      // 2026-05-21: метаданные libv2ray (sanity-check feature-flags PR #5805 etc.)
      result(V2RayWrapper.getBuildInfo())

    case "getObservatoryState":
      // 2026-05-21: snapshot текущего burstObservatory из работающего
      // xray-инстансе. Internal-only (без сети) — дёшево.
      //
      // Args: requestJSON(String?) — reserved, можно nil.
      // Returns: JSON-string (см. libXray/xray/observatory_state.go).
      //
      // 2026-05-22 (Bug B fix, macOS): после получения JSON записываем в
      // App Group UserDefaults (observatory_state_json + observatory_state_ts)
      // и постим Darwin notification через ObservatoryStreamHandler.
      // Причина: macOS xray в main app, NE не вызывает Libv2ray напрямую —
      // NE polling (PacketTunnelProvider.pollObservatoryOnce) только читает
      // уже записанный snapshot. Без этой записи NE писал бы heartbeat
      // {"nodes":[],"warming_up":true} поверх реального alive-данных.
      let requestJSON = (call.arguments as? [String: Any])?["requestJSON"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async {
        let json = V2RayWrapper.getObservatoryState(requestJSON)
        // Записываем в App Group + Darwin push (NE прочитает на следующем tick,
        // Dart EventChannel subscriber получит "updated" мгновенно).
        ObservatoryStreamHandler.writeToAppGroupAndNotify(json: json ?? "")
        DispatchQueue.main.async {
          result(json)
        }
      }

    case "convertUrlToConfig":
      // 2026-05-14: see iOS V2rayFlutterPlugin.swift comment.
      // Swift import ObjC: 'convertUrlToConfig:' → convertUrl(toConfig:)
      // (это стандартная Apple's "first selector word ends with preposition"
      // renaming — обычный метод обозвался криво, поэтому либо переименовать
      // в Objc на 'convertShareLinkToXrayConfig:', либо использовать имя
      // которое Swift импортирует).
      guard let args = call.arguments as? [String: Any],
            let url = args["url"] as? String else {
        result("FAILED: missing url argument")
        return
      }
      let json = V2RayWrapper.convertUrl(toConfig: url)
      result(json)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}