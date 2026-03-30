#ifndef V2RAY_WRAPPER_H
#define V2RAY_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

// V2Ray core functions
int v2ray_start(const char* config_json);
int v2ray_stop(void);
int v2ray_is_running(void);
const char* v2ray_get_version(void);

// Error handling
const char* v2ray_get_last_error(void);

// Memory management
void v2ray_free_string(const char* str);
void v2ray_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif // V2RAY_WRAPPER_H