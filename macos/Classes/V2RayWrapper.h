//
//  V2RayWrapper.h
//  V2Ray Flutter Plugin
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface V2RayWrapper : NSObject

+ (NSString *)getCoreVersion;
+ (BOOL)startV2Ray:(NSString *)configJson;
+ (BOOL)stopV2Ray;
+ (BOOL)isRunning;
+ (NSString *)getLastError;
+ (void)cleanup;
+ (int)getActiveServerIndex;

// 2026-05-14: нативная конвертация share-URL → JSON xray-config.
// Возвращает либо JSON string, либо строку начинающуюся с "FAILED: "
// при ошибке парсинга. Реализация в Go (libv2ray.a, c-archive),
// смотри libXray/libv2ray_cgo/libxray_cgo.go.
+ (NSString *)convertUrlToConfig:(NSString *)url;

// 2026-05-18: honest HTTP-probe через конкретный outbound в работающем
// xray-инстансе. Использует session.SetForcedOutboundTagToContext внутри
// libv2ray.a для принудительной маршрутизации (игнорируя balancer/routing).
//
// Returns JSON-string с полями:
//   outbound_tag, target_url, alive, http_code, rtt_ms, body_excerpt, error, timestamp_ms
// (см. libXray/xray/probe_outbound.go::ProbeOutboundResult)
//
// При любой ошибке возвращает строку начинающуюся с "FAILED: ".
+ (NSString *)probeOutbound:(NSString *)outboundTag
                        url:(NSString *)targetURL
                  timeoutMs:(int)timeoutMs;

// 2026-05-21: snapshot текущего observatory-state в работающем xray-инстансе.
// Внутренний вызов (без сети) — observatory сама пингует subjectSelector
// в фоне с интервалом 30с, мы только читаем cached статистику.
//
// Returns JSON-string с полями (см. libXray/xray/observatory_state.go):
//   nodes[]:{tag,alive,delay_ms,ping_all,ping_fail,ping_avg,ping_max,
//            ping_min,ping_deviation,last_error,last_seen_ms,last_try_ms}
//   timestamp_ms
//   error (если что-то пошло не так)
//
// Winner balancer'а Dart считает сам: min(delay_ms) среди alive=true
// (та же логика что использует xray leastPing strategy внутри).
//
// requestJSON — зарезервирован под будущие расширения (фильтрация по
// тегам). Сейчас можно передавать nil или "" — игнорируется.
+ (NSString *)getObservatoryState:(NSString *)requestJSON;

// 2026-05-21: метаданные собранной libv2ray (xray-version, features).
// Главный feature-flag: `pr5805_balancer_dialer` (true если форк xray-core
// с PR #5805 вкомпилен, false если upstream без chain-mode балансера).
//
// Returns JSON (см. libXray/xray/build_info.go):
//   {"xray_version": "26.5.9", "go_version": "go1.26.3",
//    "features": {"pr5805_balancer_dialer": true, "observatory_state": true, ...}}
+ (NSString *)getBuildInfo;

@end

NS_ASSUME_NONNULL_END