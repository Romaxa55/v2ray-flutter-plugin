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

@end

NS_ASSUME_NONNULL_END