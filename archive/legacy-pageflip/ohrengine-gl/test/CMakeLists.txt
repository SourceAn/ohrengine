# ohrengine-gl host-side offline test executable
#
# 无 EGL/OHOS 依赖：只编译 geometry/ + animation/ 模块的纯 C++ 源码，
# 用于离线单测（Cylinder/Cone/Hybrid 曲率场参数、状态机全转移表、
# token/事务校验、Cone 逆正映射/弧长守恒）。
#
# Build:
#   cd ohrengine-gl/test
#   cmake -B build
#   cmake --build build
#   ./build/ohrengine_gl_tests
cmake_minimum_required(VERSION 3.5.0)
project(ohrengine_gl_tests CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 生产代码宿主编译的源码（与 NDK 侧共用，仅限无 GL/OHOS 依赖的模块）
set(HOST_COMPILE_SOURCES
    ../src/main/cpp/geometry/cylinder_curl_geometry.cpp
    ../src/main/cpp/geometry/cone_curl_geometry.cpp
    ../src/main/cpp/geometry/hybrid_curl_geometry.cpp
    ../src/main/cpp/animation/flip_state_machine.cpp
)

add_executable(ohrengine_gl_tests
    main.cpp
    geometry_test.cpp
    state_machine_test.cpp
    ${HOST_COMPILE_SOURCES}
)

target_include_directories(ohrengine_gl_tests PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../src/main/cpp
)
