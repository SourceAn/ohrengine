/*
 * perf_collector.h — 独立性能采集模块（T031，FR-019）
 *
 * 与渲染热路径完全解耦：
 *  - 帧耗时统计、first-frame 指标等全部移入本模块；
 *  - 由编译宏 FLIPGL_ENABLE_PERF 控制，release 构建零成本剔除（不编译任何
 *    统计代码路径，无运行时分支）。
 *
 * 6 类指标口径（plan.md §9）：
 *  1. Input-to-first-frame（beginGesture 请求 → 首次含卷曲画面的 eglSwapBuffers）
 *  2. CPU frame preparation（Geometry + uniform 注入耗时）
 *  3. GPU 渲染耗时（EXT_disjoint_timer_query 或替代代理；不支持时记录）
 *  4. Soloist 回调间隔（仅代表调度节奏，不作 GPU 耗时证据）
 *  5. 纹理上传耗时（CPU 回读 / GPU 上传分段）
 *  6. Commit Barrier（B1→B3，新增埋点，Phase B 完整落地）
 *
 * 本模块仅提供埋点 API 与统计容器；实际日志输出由调用方（engine）决定。
 */
#pragma once

#include <cstdint>

#ifdef FLIPGL_ENABLE_PERF

namespace flipgl {

/** 简单滚动窗口统计（P50/P95 计算用样本） */
struct FrameStatBuffer {
  static constexpr int kSamples = 256;
  float samples[kSamples] = {0.0f};
  int count = 0;

  void Add(float us) {
    if (count < kSamples) {
      samples[count++] = us;
    }
  }
  void Reset() { count = 0; }
};

/** 性能采集容器（编译宏启用，release 零成本） */
struct PerfCollector {
  /** 输入到首帧（第 1 类）：beginGesture 请求 → 首次 swap，us */
  int64_t inputToFirstFrameUs = 0;
  /** 首帧是否已记录 */
  bool firstFrameLogged = false;
  /** CPU 帧准备耗时累计（第 2 类），us */
  int64_t cpuFramePrepUs = 0;
  /** Soloist 回调间隔窗口（第 4 类，仅调度节奏） */
  FrameStatBuffer soloistInterval;
  int64_t lastSoloistNs = 0;

  void Reset() {
    inputToFirstFrameUs = 0;
    firstFrameLogged = false;
    cpuFramePrepUs = 0;
    soloistInterval.Reset();
    lastSoloistNs = 0;
  }
};

}  // namespace flipgl

#endif  // FLIPGL_ENABLE_PERF
