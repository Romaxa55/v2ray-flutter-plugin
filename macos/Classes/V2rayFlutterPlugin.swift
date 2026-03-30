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

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}