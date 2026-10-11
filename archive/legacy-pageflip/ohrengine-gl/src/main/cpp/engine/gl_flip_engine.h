/*
 * gl_flip_engine.h — 瘦身编排层（T024，0.1/0.2）
 *
 * 职责：surface 生命周期回调转发、soloist 帧回调、跨线程状态快照、
 * render_backend/geometry/animation（FlipStateMachine）模块串联。
 *
 * 本文件**不含任何曲率数学**（公式只在 geometry/ 与 shader/），
 * **不含内嵌性能统计**（T031 迁出到独立采集模块）。
 */
#pragma once

#include <cstdint>
#include <functional>
#include <mutex>

#include "animation/flip_state_machine.h"
#include "core/gles_render_backend.h"
#include "core/perf_collector.h"
#include "core/render_backend.h"
#include "geometry/cylinder_curl_geometry.h"
#include "geometry/cone_curl_geometry.h"
#include "geometry/hybrid_curl_geometry.h"
#include "geometry/curl_geometry.h"

struct OH_DisplaySoloist;  // native_display_soloist（cpp 中完整类型）

namespace flipgl {

/**
 * GlFlipEngine — 编排层（保持单例，仅负责串联各模块）。
 * 生命周期与 XComponent surface 绑定。
 */
class GlFlipEngine {
public:
  static GlFlipEngine* GetInstance();

  // ── XComponent surface 生命周期回调（由 napi 注册） ─────────────────
  void OnSurfaceCreated(void* window, int surfaceW, int surfaceH);
  void OnSurfaceChanged(void* window, int surfaceW, int surfaceH);
  void OnSurfaceDestroyed();

  // ── N-API 入口（意图级 API，0.6/0.13，坐标=Surface px） ────────────
  void SetDisplayRefreshRate(int refreshRate);
  void SetTsfnAvailable(bool available);
  void SetCompletionCallback(
      std::function<void(int32_t token, FlipResult result)> completionCb);
  TextureHandle UploadTexture(const uint8_t* rgba, int w, int h);
  void ReleaseTexture(TextureHandle tex);

  BeginGestureResult BeginGesture(int32_t direction, SpineSide spine,
                                  float downX, float downY, CurlModel model,
                                  bool synthetic, int32_t pageGenerationSnapshot,
                                  TextureHandle frontTex, TextureHandle backTex,
                                  int32_t frontW, int32_t frontH,
                                  int32_t backW, int32_t backH);
  void UpdateGesture(int32_t token, float x, float y, int64_t timestampMs);
  bool EndGesture(int32_t token, float x, float y);
  bool CancelGesture(int32_t token);
  BeginGestureResult BeginReboundRecovery(int32_t prevToken, int32_t direction);
  bool ReleaseTextureTransaction(int32_t token);

  // soloist 驱动（由 napi 层回调）
  void OnSoloistFrame(int64_t timestampNs);

  bool IsReady() const { return ready_; }
  void Destroy();

private:
  GlFlipEngine();
  ~GlFlipEngine() = default;

  void RenderFrame(int64_t timestampNs);

  // 状态
  bool ready_ = false;
  int surfaceW_ = 0;
  int surfaceH_ = 0;
  int displayRefreshRate_ = 60;

  // 当前手势上下文纹理（beginGesture 登记 → 渲染使用）
  TextureHandle ctxFrontTex_ = 0;
  TextureHandle ctxBackTex_ = 0;

  // 完成回调（napi 层注册，经常驻 TSFN 转发 ArkTS）
  std::function<void(int32_t token, FlipResult result)> completionCb_;

  // soloist 帧驱动（OnSurfaceCreated 建立 / OnSurfaceDestroyed 释放；驱动
  // stateMachine_.OnFrame → 渲染 + 收尾插值 + 900ms 超时判定）
  OH_DisplaySoloist* soloist_ = nullptr;

  // 模块
  GlesRenderBackend backend_;
  CylinderCurlGeometry cylinderGeometry_;
  ConeCurlGeometry coneGeometry_;
  HybridCurlGeometry hybridGeometry_;
  FlipStateMachine stateMachine_;

#ifdef FLIPGL_ENABLE_PERF
  // 性能采集（T031，编译宏开关；release 构建零成本剔除）
  PerfCollector perf_;
  int64_t beginRequestNs_ = 0;
#endif
};

}  // namespace flipgl
