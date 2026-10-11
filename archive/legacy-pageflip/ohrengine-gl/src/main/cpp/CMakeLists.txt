cmake_minimum_required(VERSION 3.5.0)
project(ohrengine_gl)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})

# 性能采集开关（T031 解耦）：诊断期启用（FLIPGL_ENABLE_PERF），release 默认关闭零成本。
# 调试：add_definitions(-DFLIPGL_ENABLE_PERF)
add_definitions(-DFLIPGL_ENABLE_PERF)

add_library(ohrengine_gl SHARED
    napi/napi_init.cpp
    engine/gl_flip_engine.cpp
    core/gles_render_backend.cpp
    geometry/cylinder_curl_geometry.cpp
    geometry/cone_curl_geometry.cpp
    geometry/hybrid_curl_geometry.cpp
    animation/flip_state_machine.cpp
)

target_link_libraries(ohrengine_gl PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    libhilog_ndk.z.so
    libnative_window.so
    libnative_display_soloist.so
    libEGL.so
    libGLESv3.so
)
