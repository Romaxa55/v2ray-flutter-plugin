#include "include/v2ray_flutter/v2ray_flutter_plugin.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <vector>

namespace v2ray_flutter {

namespace {
long long NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
}  // namespace

void V2rayFlutterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto method_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "v2ray_flutter",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<V2rayFlutterPlugin>();
  auto* plugin_ptr = plugin.get();

  method_channel->SetMethodCallHandler(
      [plugin_ptr](const auto& call, auto result) {
        plugin_ptr->HandleMethodCall(call, std::move(result));
      });

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "v2ray_flutter/observatory_events",
          &flutter::StandardMethodCodec::GetInstance());

  event_channel->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [plugin_ptr](const flutter::EncodableValue*,
                       std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& sink)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            {
              std::lock_guard<std::mutex> lock(plugin_ptr->obs_mutex_);
              plugin_ptr->obs_sink_ = std::move(sink);
            }
            plugin_ptr->StartObservatoryThread();
            return nullptr;
          },
          [plugin_ptr](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            plugin_ptr->StopObservatoryThread();
            {
              std::lock_guard<std::mutex> lock(plugin_ptr->obs_mutex_);
              plugin_ptr->obs_sink_ = nullptr;
            }
            return nullptr;
          }));

  registrar->AddPlugin(std::move(plugin));
}

V2rayFlutterPlugin::V2rayFlutterPlugin() {}

V2rayFlutterPlugin::~V2rayFlutterPlugin() {
  StopObservatoryThread();
  if (h_) {
    FreeLibrary(h_);
    h_ = nullptr;
  }
}

bool V2rayFlutterPlugin::EnsureLoaded() {
  if (loaded_) return h_ != nullptr;
  loaded_ = true;
  // libv2ray.dll лежит рядом с megav_vpn.exe (его кладёт runner/CMake из
  // resources/libs/x64). LoadLibraryA ищет в каталоге exe. Тот же DLL уже
  // загружен vpn_manager.cpp — LoadLibraryA вернёт тот же модуль (общий
  // xray-instance в процессе).
  h_ = LoadLibraryA("libv2ray.dll");
  if (!h_) {
    last_error_ = "libv2ray.dll not found";
    return false;
  }
  fn_init_ = reinterpret_cast<FnVoidStr>(GetProcAddress(h_, "InitializeV2Ray"));
  fn_start_ = reinterpret_cast<FnStrStr>(GetProcAddress(h_, "StartV2RayWithConfig"));
  fn_stop_ = reinterpret_cast<FnVoidStr>(GetProcAddress(h_, "StopV2Ray"));
  fn_isrunning_ = reinterpret_cast<FnVoidInt>(GetProcAddress(h_, "IsV2RayRunning"));
  fn_ver_ = reinterpret_cast<FnVoidStr>(GetProcAddress(h_, "GetV2RayVersion"));
  fn_test_ = reinterpret_cast<FnStrStr>(GetProcAddress(h_, "TestV2RayConnection"));
  fn_status_ = reinterpret_cast<FnVoidStr>(GetProcAddress(h_, "GetV2RayStatus"));
  fn_cleanup_ = reinterpret_cast<FnVoidStr>(GetProcAddress(h_, "CleanupV2Ray"));
  fn_convert_ = reinterpret_cast<FnStrStr>(GetProcAddress(h_, "ConvertUrlToConfig"));
  fn_probe_ = reinterpret_cast<FnProbe>(GetProcAddress(h_, "ProbeOutbound"));
  fn_obs_ = reinterpret_cast<FnStrStr>(GetProcAddress(h_, "GetObservatoryState"));
  fn_buildinfo_ = reinterpret_cast<FnVoidStr>(GetProcAddress(h_, "GetBuildInfo"));
  fn_free_ = reinterpret_cast<FnFree>(GetProcAddress(h_, "Free"));
  return true;
}

std::string V2rayFlutterPlugin::CallStr(FnVoidStr fn) {
  if (!fn) return "";
  char* r = fn();
  std::string s = r ? r : "";
  if (fn_free_ && r) fn_free_(r);
  return s;
}

std::string V2rayFlutterPlugin::CallStr1(FnStrStr fn, const std::string& arg) {
  if (!fn) return "";
  std::vector<char> buf(arg.begin(), arg.end());
  buf.push_back('\0');
  char* r = fn(buf.data());
  std::string s = r ? r : "";
  if (fn_free_ && r) fn_free_(r);
  return s;
}

// Активный exit-индекс. Контракт getActiveServerIndex туманен (на iOS вообще
// не реализован, Dart дефолтит в 0). Возвращаем 0 — observatory-карта и winner
// строятся на Dart-стороне из getObservatoryState/observatory_events (role).
int V2rayFlutterPlugin::ActiveServerIndexFromObservatory() {
  return 0;
}

void V2rayFlutterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& m = call.method_name();
  EnsureLoaded();

  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  auto getS = [&](const char* k) -> std::string {
    if (!args) return "";
    auto it = args->find(flutter::EncodableValue(k));
    if (it == args->end()) return "";
    if (const auto* p = std::get_if<std::string>(&it->second)) return *p;
    return "";
  };
  auto getI = [&](const char* k, int d) -> int {
    if (!args) return d;
    auto it = args->find(flutter::EncodableValue(k));
    if (it == args->end()) return d;
    if (const auto* p = std::get_if<int>(&it->second)) return *p;
    if (const auto* p = std::get_if<int64_t>(&it->second)) return static_cast<int>(*p);
    return d;
  };

  if (m == "initializeV2Ray") {
    result->Success(flutter::EncodableValue(CallStr(fn_init_)));
  } else if (m == "startV2Ray") {
    auto r = CallStr1(fn_start_, getS("config"));
    if (r.rfind("FAILED", 0) == 0) last_error_ = r;
    if (r == "SUCCESS") connect_start_ms_ = NowMs();
    result->Success(flutter::EncodableValue(r));
  } else if (m == "stopV2Ray") {
    auto r = CallStr(fn_stop_);
    long long s = connect_start_ms_.exchange(0);
    if (s) total_ms_ += (NowMs() - s);
    result->Success(flutter::EncodableValue(r == "SUCCESS"));
  } else if (m == "isV2RayRunning" || m == "isRunning") {
    result->Success(
        flutter::EncodableValue(fn_isrunning_ ? fn_isrunning_() != 0 : false));
  } else if (m == "getV2RayVersion" || m == "getCoreVersion") {
    auto v = CallStr(fn_ver_);
    result->Success(flutter::EncodableValue(v.empty() ? std::string("unknown") : v));
  } else if (m == "testV2RayConnection") {
    result->Success(flutter::EncodableValue(CallStr1(fn_test_, getS("url"))));
  } else if (m == "getV2RayStatus") {
    result->Success(flutter::EncodableValue(CallStr(fn_status_)));
  } else if (m == "getLastError") {
    result->Success(flutter::EncodableValue(last_error_));
  } else if (m == "cleanupV2Ray" || m == "cleanup") {
    result->Success(flutter::EncodableValue(CallStr(fn_cleanup_)));
  } else if (m == "convertUrlToConfig") {
    result->Success(flutter::EncodableValue(CallStr1(fn_convert_, getS("url"))));
  } else if (m == "getObservatoryState") {
    result->Success(flutter::EncodableValue(CallStr1(fn_obs_, getS("requestJSON"))));
  } else if (m == "getBuildInfo") {
    result->Success(flutter::EncodableValue(CallStr(fn_buildinfo_)));
  } else if (m == "getActiveServerIndex") {
    result->Success(flutter::EncodableValue(ActiveServerIndexFromObservatory()));
  } else if (m == "probeOutbound") {
    int t = getI("timeoutMs", 5000);
    if (t < 100) t = 100;
    if (t > 60000) t = 60000;
    if (!fn_probe_) {
      result->Success(flutter::EncodableValue(
          std::string("{\"alive\":false,\"error\":\"probe unavailable\"}")));
      return;
    }
    std::vector<char> tag(getS("tag").begin(), getS("tag").end());
    tag.push_back('\0');
    std::vector<char> url(getS("url").begin(), getS("url").end());
    url.push_back('\0');
    char* r = fn_probe_(tag.data(), url.data(), t);
    std::string s = r ? r : "";
    if (fn_free_ && r) fn_free_(r);
    result->Success(flutter::EncodableValue(s));
  } else if (m == "getConnectionDuration") {
    long long s = connect_start_ms_.load();
    result->Success(
        flutter::EncodableValue(static_cast<int>(s ? NowMs() - s : 0)));
  } else if (m == "getTotalConnectionTime") {
    result->Success(
        flutter::EncodableValue(static_cast<int>(total_ms_.load())));
  } else if (m == "resetConnectionTimer") {
    total_ms_ = 0;
    result->Success(flutter::EncodableValue(true));
  } else if (m == "setConnectionLimits") {
    // Windows: free-timer = Dart-side (desktop app не suspend'ится).
    // Нативный лимитер не нужен — placeholder, как Android.
    result->Success(flutter::EncodableValue(true));
  } else {
    result->NotImplemented();
  }
}

// Поллер observatory: каждые 2с дёргает GetObservatoryState и пушит в sink.
// Mirror radio_plugin.cpp — Success зовётся из worker-потока напрямую (в этом
// кодовом базе паттерн рабочий). Если данных нет — heartbeat warming_up.
void V2rayFlutterPlugin::StartObservatoryThread() {
  EnsureLoaded();  // platform-thread (из onListen) — гонки с HandleMethodCall нет
  if (obs_run_.exchange(true)) return;
  obs_thread_ = std::thread([this] {
    while (obs_run_.load()) {
      std::string j = fn_obs_ ? CallStr1(fn_obs_, "") : "";
      if (j.empty()) j = "{\"nodes\":[],\"warming_up\":true}";
      {
        std::lock_guard<std::mutex> lock(obs_mutex_);
        if (obs_sink_) obs_sink_->Success(flutter::EncodableValue(j));
      }
      for (int i = 0; i < 20 && obs_run_.load(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
      }
    }
  });
}

void V2rayFlutterPlugin::StopObservatoryThread() {
  obs_run_ = false;
  if (obs_thread_.joinable()) obs_thread_.join();
}

}  // namespace v2ray_flutter

void V2rayFlutterPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  v2ray_flutter::V2rayFlutterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
