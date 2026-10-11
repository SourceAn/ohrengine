#!/usr/bin/env bash
# run_tests.sh — g++ 直编宿主测试（无 CMake/无 EGL 依赖的轻量方式）
# 用法: ./run_tests.sh
set -euo pipefail
cd "$(dirname "$0")"

SRC=../src/main/cpp
g++ -std=c++17 -Wall -Wextra -I. -I"$SRC" \
  main.cpp \
  geometry_test.cpp \
  state_machine_test.cpp \
  "$SRC/geometry/cylinder_curl_geometry.cpp" \
  "$SRC/geometry/cone_curl_geometry.cpp" \
  "$SRC/geometry/hybrid_curl_geometry.cpp" \
  "$SRC/animation/flip_state_machine.cpp" \
  -o /tmp/ohrengine_gl_tests

/tmp/ohrengine_gl_tests
