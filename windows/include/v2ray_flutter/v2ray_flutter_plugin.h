#ifndef FLUTTER_PLUGIN_V2RAY_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_V2RAY_FLUTTER_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

// Публичная C-точка входа — её зовёт generated_plugin_registrant.cc.
// Flutter 3.41 на Windows для pluginClass=V2rayFlutterPlugin генерит:
//   #include <v2ray_flutter/v2ray_flutter_plugin.h>
//   V2rayFlutterPluginRegisterWithRegistrar(...);
#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void V2rayFlutterPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#ifdef __cplusplus

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/plugin_registrar_windows.h>

#include <windows.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace v2ray_flutter {

// libv2ray.dll flat C-API (libXray/libv2ray_cgo/libxray_cgo.go //export).
// Имена БЕЗ CGo-префикса — это НЕ libXray.dll (там CGo*-API), а libv2ray.dll,
// тот же что грузит vpn_native_client/windows/runner/vpn_manager.cpp.
using FnVoidStr = char* (*)();
using FnStrStr = char* (*)(char*);
using FnVoidInt = int (*)();
using FnProbe = char* (*)(char*, char*, int);
using FnFree = void (*)(char*);

class V2rayFlutterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  V2rayFlutterPlugin();
  ~V2rayFlutterPlugin() override;

  V2rayFlutterPlugin(const V2rayFlutterPlugin&) = delete;
  V2rayFlutterPlugin& operator=(const V2rayFlutterPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StartObservatoryThread();
  void StopObservatoryThread();

  // EventSink + mutex доступны RegisterWithRegistrar-лямбдам.
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> obs_sink_;
  std::mutex obs_mutex_;

 private:
  bool EnsureLoaded();
  std::string CallStr(FnVoidStr fn);
  std::string CallStr1(FnStrStr fn, const std::string& arg);
  int ActiveServerIndexFromObservatory();

  HMODULE h_ = nullptr;
  bool loaded_ = false;

  FnVoidStr fn_init_ = nullptr;
  FnStrStr fn_start_ = nullptr;
  FnVoidStr fn_stop_ = nullptr;
  FnVoidInt fn_isrunning_ = nullptr;
  FnVoidStr fn_ver_ = nullptr;
  FnStrStr fn_test_ = nullptr;
  FnVoidStr fn_status_ = nullptr;
  FnVoidStr fn_cleanup_ = nullptr;
  FnStrStr fn_convert_ = nullptr;
  FnProbe fn_probe_ = nullptr;
  FnStrStr fn_obs_ = nullptr;
  FnVoidStr fn_buildinfo_ = nullptr;
  FnFree fn_free_ = nullptr;

  std::string last_error_;

  std::thread obs_thread_;
  std::atomic<bool> obs_run_{false};

  std::atomic<long long> connect_start_ms_{0};
  std::atomic<long long> total_ms_{0};
};

}  // namespace v2ray_flutter

#endif  // __cplusplus

#endif  // FLUTTER_PLUGIN_V2RAY_FLUTTER_PLUGIN_H_
