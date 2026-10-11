/*
 * test_framework.h — 轻量 assert 测试框架（无第三方依赖，host 可编译）
 *
 * 用法：
 *   TEST_CASE(GroupName) {
 *     CHECK(expr);
 *     CHECK_EQ(a, b);
 *   }
 * 每个测试用例注册到全局注册表，由 main.cpp 统一执行。
 */
#pragma once

#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace flipgl_test {

struct TestCase {
  std::string name;
  std::function<void()> fn;
};

inline std::vector<TestCase>& Registry() {
  static std::vector<TestCase> registry;
  return registry;
}

struct TestRegistrar {
  TestRegistrar(const std::string& name, std::function<void()> fn) {
    Registry().push_back({name, fn});
  }
};

// 全局失败计数（当前用例内）
inline int& FailCount() {
  static int count = 0;
  return count;
}
inline int& AssertCount() {
  static int count = 0;
  return count;
}
inline const char*& CurrentTest() {
  static const char* name = "";
  return name;
}

inline void ReportFailure(const char* file, int line, const std::string& msg) {
  FailCount()++;
  std::printf("    FAIL %s:%d: %s\n", file, line, msg.c_str());
}

}  // namespace flipgl_test

#define TEST_CASE(Name)                                                     \
  static void TestFn_##Name();                                              \
  static ::flipgl_test::TestRegistrar reg_##Name(#Name, TestFn_##Name);     \
  static void TestFn_##Name()

#define CHECK(expr)                                                         \
  do {                                                                      \
    ::flipgl_test::AssertCount()++;                                         \
    if (!(expr)) {                                                          \
      ::flipgl_test::ReportFailure(__FILE__, __LINE__, "CHECK failed: " #expr); \
    }                                                                       \
  } while (0)

#define CHECK_EQ(a, b)                                                      \
  do {                                                                      \
    ::flipgl_test::AssertCount()++;                                         \
    auto va = (a);                                                          \
    auto vb = (b);                                                          \
    if (!(va == vb)) {                                                      \
      ::flipgl_test::ReportFailure(__FILE__, __LINE__,                      \
        std::string("CHECK_EQ failed: ") + #a + " == " + #b);               \
    }                                                                       \
  } while (0)

#define CHECK_NEAR(a, b, eps)                                               \
  do {                                                                      \
    ::flipgl_test::AssertCount()++;                                         \
    double va = static_cast<double>(a);                                     \
    double vb = static_cast<double>(b);                                     \
    if ((va < vb - (eps)) || (va > vb + (eps))) {                           \
      ::flipgl_test::ReportFailure(__FILE__, __LINE__,                      \
        std::string("CHECK_NEAR failed: ") + #a + " ~= " + #b +             \
        " (got " + std::to_string(va) + " vs " + std::to_string(vb) + ")"); \
    }                                                                       \
  } while (0)

#define CHECK_TRUE(expr) CHECK(expr)
#define CHECK_FALSE(expr) CHECK(!(expr))
