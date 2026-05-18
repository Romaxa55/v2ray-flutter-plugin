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

public class V2rayFlutterPlugin: NSObject, FlutterPlugin {
  private var coreController: Libv2rayCoreController?
  private var isInitialized = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "v2ray_flutter", binaryMessenger: registrar.messenger())
    let instance = V2rayFlutterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
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

