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

@end

NS_ASSUME_NONNULL_END