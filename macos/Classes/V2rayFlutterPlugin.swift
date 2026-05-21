import Cocoa
import FlutterMacOS

public class V2rayFlutterPlugin: NSObject, FlutterPlugin {

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "v2ray_flutter", binaryMessenger: registrar.messenger)
    let instance = V2rayFlutterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

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

    case "getObservatoryState":
      // 2026-05-21: snapshot текущего burstObservatory из работающего
      // xray-инстансе. Internal-only (без сети) — дёшево.
      //
      // Args: requestJSON(String?) — reserved, можно nil.
      // Returns: JSON-string (см. libXray/xray/observatory_state.go).
      //
      // Sync-call (быстро, ~1мс): просто читает кеш observatory. На main
      // thread безопасно — но для симметрии с probeOutbound используем
      // background queue, всё равно invokeMethod async на Dart-стороне.
      let requestJSON = (call.arguments as? [String: Any])?["requestJSON"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async {
        let json = V2RayWrapper.getObservatoryState(requestJSON)
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