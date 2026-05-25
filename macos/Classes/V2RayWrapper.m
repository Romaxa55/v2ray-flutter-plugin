//
//  V2RayWrapper.m
//  V2Ray Flutter Plugin
//

#import "V2RayWrapper.h"
#import "libv2ray.h"

// Глобальная переменная для хранения последнего индекса активного сервера
static int lastActiveServerIndex = 0;
static NSMutableString *logBuffer;
static NSPipe *stdoutPipe = nil;
static NSFileHandle *stdoutHandle = nil;
static int savedStdout = -1;

@implementation V2RayWrapper

+ (void)initialize {
    if (self == [V2RayWrapper class]) {
        logBuffer = [NSMutableString stringWithCapacity:1000];
    }
}

+ (NSString *)getCoreVersion {
    // New Xray C-API returns char* (which we must free if allocated by CString, but here it's likely static or managed by Go runtime if not explicitly freed by us?
    // Go's C.CString returns a pointer that should be freed.
    // However, our implementation in libxray_c.go uses C.CString which allocates memory.
    // We should free it if we want to be clean, but usually CString allocated by Go needs free(p).

    char *versionPtr = GetV2RayVersion(); // New API
    if (versionPtr == NULL) {
        return @"Unknown";
    }

    NSString *version = [NSString stringWithUTF8String:versionPtr];
    free(versionPtr); // Free the C string allocated by Go
    return version;
}

+ (BOOL)startV2Ray:(NSString *)configJson {
    const char *configCString = [configJson UTF8String];
    if (configCString == NULL) {
        NSLog(@"❌ [V2RAY_WRAPPER] startV2Ray: configJson is NULL");
        return NO;
    }

    // Create a mutable copy since Go expects char* not const char* (sometimes)
    char *mutableConfig = strdup(configCString);
    if (mutableConfig == NULL) {
        NSLog(@"❌ [V2RAY_WRAPPER] startV2Ray: failed to allocate memory for config");
        return NO;
    }

    // Auto-initialize Xray if not initialized
    char *statusPtr = GetV2RayStatus();
    if (statusPtr != NULL) {
        NSString *status = [NSString stringWithUTF8String:statusPtr];
        free(statusPtr);

        if ([status isEqualToString:@"NOT_INITIALIZED"]) {
            NSLog(@"🔧 [V2RAY_WRAPPER] Auto-initializing Xray before start...");
            char *initPtr = InitializeV2Ray();
            if (initPtr != NULL) {
                NSLog(@"✅ [V2RAY_WRAPPER] Auto-init result: %s", initPtr);
                free(initPtr);
            }
        }
    }

    // Перехватываем stdout для парсинга логов V2Ray
    [self startStdoutRedirect];

    NSLog(@"🚀 [V2RAY_WRAPPER] Starting Xray with config (%lu chars)", (unsigned long)strlen(mutableConfig));

    char *resultPtr = StartV2RayWithConfig(mutableConfig); // New API
    free(mutableConfig);

    if (resultPtr == NULL) {
        NSLog(@"❌ [V2RAY_WRAPPER] StartV2RayWithConfig returned NULL");
        return NO;
    }

    NSString *resultStr = [NSString stringWithUTF8String:resultPtr];
    free(resultPtr);

    if ([resultStr isEqualToString:@"SUCCESS"]) {
        NSLog(@"✅ [V2RAY_WRAPPER] Xray started successfully");
        return YES;
    } else {
        NSLog(@"❌ [V2RAY_WRAPPER] Xray failed to start: %@", resultStr);
        return NO;
    }
}

+ (BOOL)stopV2Ray {
    [self stopStdoutRedirect];
    char *resultPtr = StopV2Ray(); // New API
    NSString *resultStr = [NSString stringWithUTF8String:resultPtr];
    free(resultPtr);
    return [resultStr isEqualToString:@"SUCCESS"];
}

+ (BOOL)isRunning {
    int result = IsV2RayRunning(); // New API (returns int 0/1)
    return result == 1;
}

+ (NSString *)getLastError {
    char *statusPtr = GetV2RayStatus(); // New API (returns status string which might contain error)
    if (statusPtr == NULL) {
        return @"";
    }

    NSString *status = [NSString stringWithUTF8String:statusPtr];
    free(statusPtr);

    if ([status hasPrefix:@"ERROR:"]) {
        return [status substringFromIndex:6]; // Remove "ERROR: " prefix
    }
    return status;
}

+ (void)cleanup {
    [self stopStdoutRedirect];
    CleanupV2Ray(); // New API
    lastActiveServerIndex = 0;
    [logBuffer setString:@""];
}

+ (int)getActiveServerIndex {
    // Парсим logBuffer для поиска последнего [server-N]
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"\\[server-(\\d+)\\]"
        options:0
        error:&error];

    if (error) {
        NSLog(@"❌ [V2RAY_WRAPPER] Regex error: %@", error);
        return lastActiveServerIndex;
    }

    // Ищем все совпадения в logBuffer
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:logBuffer
        options:0
        range:NSMakeRange(0, logBuffer.length)];

    if (matches.count > 0) {
        // Берем последнее совпадение
        NSTextCheckingResult *lastMatch = matches.lastObject;
        NSRange indexRange = [lastMatch rangeAtIndex:1]; // Группа захвата (\\d+)

        if (indexRange.location != NSNotFound) {
            NSString *indexStr = [logBuffer substringWithRange:indexRange];
            int serverIndex = [indexStr intValue];

            if (serverIndex != lastActiveServerIndex) {
                NSLog(@"📊 [V2RAY_WRAPPER] Active server changed: %d -> %d",
                    lastActiveServerIndex, serverIndex);
                lastActiveServerIndex = serverIndex;
            }
        }
    }

    return lastActiveServerIndex;
}

// Метод для добавления лог-строки (будет вызываться из перехвата stdout)
+ (void)appendLogLine:(NSString *)line {
    @synchronized (logBuffer) {
        // Сохраняем только последние 50 строк для экономии памяти
        NSArray *lines = [logBuffer componentsSeparatedByString:@"\n"];
        if (lines.count > 50) {
            // Оставляем только последние 50 строк
            NSArray *recentLines = [lines subarrayWithRange:NSMakeRange(lines.count - 50, 50)];
            [logBuffer setString:[recentLines componentsJoinedByString:@"\n"]];
        }

        // Добавляем новую строку
        [logBuffer appendFormat:@"\n%@", line];
    }

    // Сразу проверяем наличие [server-N] в новой строке
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"\\[server-(\\d+)\\]"
        options:0
        error:&error];

    if (!error) {
        NSTextCheckingResult *match = [regex firstMatchInString:line
            options:0
            range:NSMakeRange(0, line.length)];

        if (match) {
            NSRange indexRange = [match rangeAtIndex:1];
            if (indexRange.location != NSNotFound) {
                NSString *indexStr = [line substringWithRange:indexRange];
                int serverIndex = [indexStr intValue];

                if (serverIndex != lastActiveServerIndex) {
                    NSLog(@"📊 [V2RAY_WRAPPER] Active server detected: %d (was: %d)",
                        serverIndex, lastActiveServerIndex);
                    lastActiveServerIndex = serverIndex;
                }
            }
        }
    }
}

// MARK: - Stdout Redirect для перехвата V2Ray логов

+ (void)startStdoutRedirect {
    if (stdoutPipe != nil) {
        return; // Уже запущен
    }

    NSLog(@"📡 [V2RAY_WRAPPER] Starting stdout redirect...");

    // Сохраняем оригинальный stdout
    savedStdout = dup(STDOUT_FILENO);

    // Создаем pipe
    stdoutPipe = [NSPipe pipe];
    stdoutHandle = [stdoutPipe fileHandleForReading];

    // Перенаправляем stdout в pipe
    dup2([[stdoutPipe fileHandleForWriting] fileDescriptor], STDOUT_FILENO);

    // Читаем данные из pipe в фоновом потоке
    [[NSNotificationCenter defaultCenter]
        addObserver:self
        selector:@selector(stdoutDataAvailable:)
        name:NSFileHandleReadCompletionNotification
        object:stdoutHandle];

    [stdoutHandle readInBackgroundAndNotify];

    NSLog(@"✅ [V2RAY_WRAPPER] Stdout redirect started");
}

+ (void)stopStdoutRedirect {
    if (stdoutPipe == nil) {
        return;
    }

    NSLog(@"📡 [V2RAY_WRAPPER] Stopping stdout redirect...");

    // Удаляем observer
    [[NSNotificationCenter defaultCenter]
        removeObserver:self
        name:NSFileHandleReadCompletionNotification
        object:stdoutHandle];

    // Восстанавливаем оригинальный stdout
    if (savedStdout != -1) {
        dup2(savedStdout, STDOUT_FILENO);
        close(savedStdout);
        savedStdout = -1;
    }

    // Закрываем pipe
    [stdoutHandle closeFile];
    stdoutHandle = nil;
    stdoutPipe = nil;

    NSLog(@"✅ [V2RAY_WRAPPER] Stdout redirect stopped");
}

// 2026-05-14: нативная конвертация share-URL → JSON xray-config.
// Заменяет ручной Dart-парсер. Go-функция в libv2ray.a:
// extern char* ConvertUrlToConfig(char* url);
+ (NSString *)convertUrlToConfig:(NSString *)url {
    const char *cUrl = [url UTF8String];
    if (cUrl == NULL) {
        return @"FAILED: url is NULL";
    }
    char *mutableUrl = strdup(cUrl);
    if (mutableUrl == NULL) {
        return @"FAILED: strdup failed";
    }
    char *resultPtr = ConvertUrlToConfig(mutableUrl);
    free(mutableUrl);
    if (resultPtr == NULL) {
        return @"FAILED: ConvertUrlToConfig returned NULL";
    }
    NSString *json = [NSString stringWithUTF8String:resultPtr];
    free(resultPtr);  // Go выделил через C.CString — обязательно free.
    return json ?: @"FAILED: utf8 decode";
}

// 2026-05-18: honest HTTP-probe через указанный outbound.
// Go-функция в libv2ray.a (libv2ray_cgo/libxray_cgo.go):
// extern char* ProbeOutbound(char* outboundTag, char* targetURL, int timeoutMs);
+ (NSString *)probeOutbound:(NSString *)outboundTag
                        url:(NSString *)targetURL
                  timeoutMs:(int)timeoutMs {
    // P2-3 (2026-05-18): strdup убраны — [NSString UTF8String] возвращает
    // указатель валидный на время autorelease pool, а ProbeOutbound() синхронный
    // и возвращает результат ДО освобождения pool. Go-side cgo не модифицирует
    // входные char*, только читает (создаёт свои GoString копии).
    // Это убирает 2 malloc/free × 20 probe × 1мин = ~57600 ненужных аллокаций
    // в день (zero-leak но GC pressure).
    //
    // signature ProbeOutbound принимает `char*` (не `const char*`) только
    // из-за того что cgo-генератор не умеет const. Cast через (char*) — OK.
    const char *cTag = [outboundTag UTF8String];
    const char *cUrl = [targetURL UTF8String];
    if (cTag == NULL || cUrl == NULL) {
        return @"FAILED: tag or url is NULL";
    }
    char *resultPtr = ProbeOutbound((char *)cTag, (char *)cUrl, timeoutMs);
    if (resultPtr == NULL) {
        return @"FAILED: ProbeOutbound returned NULL";
    }
    NSString *json = [NSString stringWithUTF8String:resultPtr];
    free(resultPtr);  // Go выделил через C.CString — обязательно free.
    return json ?: @"FAILED: utf8 decode";
}

// 2026-05-21: snapshot текущего observatory-state. Internal-only (без сети) —
// observatory сама пингует субъекты в фоне, мы только читаем уже собранную
// статистику. Дёшево (just JSON marshal внутри Go).
//
// Forward-declaration extern — после пересборки libv2ray.a (через python3
// build/main.py apple all) этот символ будет в libv2ray.h автоматически.
// Объявляем тут чтобы .m скомпилился ДО сборки libXray (CI/dev workflow).
extern char* GetObservatoryState(char* requestJSON);

// 2026-05-21: метаданные billed libv2ray. Без аргументов, простой sanity-check.
// Forward-declaration (как probeOutbound) — после первой пересборки libv2ray.a
// символ автоматически в libv2ray.h, и эта строка лишняя но не мешает.
extern char* GetBuildInfo(void);

+ (NSString *)getBuildInfo {
    char *resultPtr = GetBuildInfo();
    if (resultPtr == NULL) {
        return @"{\"error\":\"GetBuildInfo returned NULL\"}";
    }
    NSString *json = [NSString stringWithUTF8String:resultPtr];
    free(resultPtr);
    return json ?: @"{\"error\":\"utf8 decode\"}";
}

+ (NSString *)getObservatoryState:(NSString *)requestJSON {
    // Тот же контракт что ProbeOutbound: cgo читает GoString копией, не модифицирует
    // C-указатель, поэтому strdup не нужен.
    const char *cReq = requestJSON != nil ? [requestJSON UTF8String] : "";
    if (cReq == NULL) cReq = "";
    char *resultPtr = GetObservatoryState((char *)cReq);
    if (resultPtr == NULL) {
        return @"{\"nodes\":[],\"error\":\"GetObservatoryState returned NULL\"}";
    }
    NSString *json = [NSString stringWithUTF8String:resultPtr];
    free(resultPtr);  // Go выделил через C.CString — обязательно free.
    return json ?: @"{\"nodes\":[],\"error\":\"utf8 decode\"}";
}

// Проверяем нужно ли скипать строку xray-вывода. Xray валит:
//   - [Warning] common/errors: The feature WebSocket transport ... is deprecated
//     (на каждый ws-outbound, ~50 строк на 20 серверов)
//   - [Warning] common/errors: The feature gRPC transport ... is deprecated
//   - from tcp/udp 127.0.0.1:NNNN accepted ... [main-socks -> server-N]
//     (xray access-log, на каждое подключение — десятки/сек)
//   - UDP:1.1.1.1:53 got answer / cache HIT
//     (DNS-кеш xray, тоже спамит)
// Эти строки полезны ТОЛЬКО при глубокой отладке. По умолчанию глушим.
+ (BOOL)shouldSuppressXrayLine:(NSString *)line {
    // Deprecated warnings — никогда не полезны, серверы всё равно работают
    if ([line containsString:@"is deprecated, not recommended for using"]) {
        return YES;
    }
    // Access-log per-connection (sniff/route trace) — десятки в секунду
    if ([line containsString:@"accepted tcp:"] ||
        [line containsString:@"accepted udp:"]) {
        return YES;
    }
    // DNS-кеш xray — нерелевантно для пользовательской диагностики
    if ([line containsString:@"got answer:"] ||
        [line containsString:@"cache HIT:"]) {
        return YES;
    }
    return NO;
}

+ (void)stdoutDataAvailable:(NSNotification *)notification {
    NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];

    if (data && data.length > 0) {
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

        if (output) {
            // Фильтруем построчно — печатаем в NSLog только содержательные
            // строки (ошибки/предупреждения которые не от deprecated и не
            // от access-log/DNS-кеша). appendLogLine оставляем для всех,
            // потому что parser для [server-N] хочет видеть полный поток.
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            for (NSString *line in lines) {
                if (line.length == 0) continue;
                [self appendLogLine:line];
                if (![self shouldSuppressXrayLine:line]) {
                    NSLog(@"%@", line);
                }
            }
        }

        // Продолжаем читать
        [stdoutHandle readInBackgroundAndNotify];
    }
}

@end
