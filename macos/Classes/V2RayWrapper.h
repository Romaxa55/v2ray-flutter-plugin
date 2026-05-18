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

@end

NS_ASSUME_NONNULL_END