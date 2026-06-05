# Flutter Windows plugin: v2ray_flutter
# Собирает STATIC-lib v2ray_flutter_plugin, который
# vpn_native_client/windows/flutter/generated_plugins.cmake линкует в exe.
# libv2ray.dll НЕ бандлим — его кладёт runner (resources/libs/x64 → next to exe),
# плагин грузит его в рантайме через LoadLibraryA (search path = exe dir).
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "v2ray_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "v2ray_flutter_plugin")

add_library(${PLUGIN_NAME} STATIC
  "v2ray_flutter_plugin.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Список DLL-ов плагина для бандла приложением — пусто (libv2ray.dll кладёт runner).
set(v2ray_flutter_bundled_libraries
  ""
  PARENT_SCOPE
)
