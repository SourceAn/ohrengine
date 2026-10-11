# Copyright (c) 2025 OhEngine Authors.
# Licensed under the Apache License, Version 2.0.
#
# Liquid Glass 原生库（EGL + OpenGL ES 3.0）
#
# 只构建 arm64-v8a：由 ohrengine-reader/build-profile.json5 的
#   buildOption.externalNativeOptions.abiFilters = ["arm64-v8a"]
# 强制约束，CMake 侧不再重复过滤。

cmake_minimum_required(VERSION 3.5.0)
project(liquidglass)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# 使 #include "glass/xxx.h" 这类相对工程的写法生效
include_directories(${NATIVERENDER_ROOT_PATH})

# 目标名即产物名：libliquidglass.so
# 必须与 ArkTS 侧 XComponent 的 libraryname('liquidglass')
# 以及 napi_module.nm_modname("liquidglass") 三者完全一致。
add_library(liquidglass SHARED
    lg/lg_renderer.cpp
    lg/lg_napi.cpp
)

target_compile_options(liquidglass PRIVATE -Wall -Wextra -Wno-unused-parameter)

target_link_libraries(liquidglass PUBLIC
    libace_napi.z.so        # N-API
    libace_ndk.z.so         # OH_NativeXComponent / OH_LOG
    libhilog_ndk.z.so       # hilog
    libnative_window.so     # XComponent 提供的 NativeWindow
    libEGL.so               # EGL
    libGLESv3.so            # OpenGL ES 3.0
)
