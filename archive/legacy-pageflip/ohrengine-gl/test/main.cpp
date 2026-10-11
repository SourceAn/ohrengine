/*
 * main.cpp — host 端离线单测入口（无 EGL/真机依赖）
 *
 * 编译方式（两种任选其一）：
 *   1. CMake:  cd ohrengine-gl/test && cmake -B build && cmake --build build && ./build/ohrengine_gl_tests
 *   2. 脚本:   ./run_tests.sh
 *
 * 覆盖（Test Requirements 1/3/4）：
 *   - geometry：Cylinder 曲率场参数输出（radius bounds / axis / band width /
 *     boundary conditions / blendFactor=0 cylinder equivalence）
 *   - state machine：0.10 完整状态转移表
 *   - token/pageGeneration/纹理事务双向校验
 */
#include "test_framework.h"

#include <cstdio>

// 测试用例注册表由 test 宏自动填充（见 test_framework.h 的 TEST_CASE）。
// geometry_test.cpp / state_machine_test.cpp 中的 TEST_CASE 通过静态注册器
// 在 main 前完成注册，无需显式调用。


int main() {
  std::printf("=== ohrengine-gl host offline tests ===\n");
  auto& registry = flipgl_test::Registry();
  int totalFailed = 0;
  int totalCases = 0;
  int totalAsserts = 0;
  for (auto& tc : registry) {
    flipgl_test::FailCount() = 0;
    flipgl_test::AssertCount() = 0;
    flipgl_test::CurrentTest() = tc.name.c_str();
    std::printf("[RUN] %s\n", tc.name.c_str());
    tc.fn();
    totalCases++;
    totalAsserts += flipgl_test::AssertCount();
    if (flipgl_test::FailCount() > 0) {
      std::printf("[FAIL] %s (%d failures / %d asserts)\n",
                  tc.name.c_str(), flipgl_test::FailCount(),
                  flipgl_test::AssertCount());
      totalFailed++;
    } else {
      std::printf("[ OK ] %s (%d asserts)\n", tc.name.c_str(),
                  flipgl_test::AssertCount());
    }
  }
  std::printf("=== summary: %d cases, %d asserts, %d failed ===\n",
              totalCases, totalAsserts, totalFailed);
  return totalFailed == 0 ? 0 : 1;
}
