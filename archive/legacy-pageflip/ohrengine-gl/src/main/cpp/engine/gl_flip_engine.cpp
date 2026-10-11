/*
 * gl_flip_engine.cpp — 瘦身编排层实现（T024）
 *
 * 职责：surface 生命周期转发、soloist 帧回调、跨线程状态快照、
 * render_backend/geometry/animation 模块串联。**不含曲率数学**（0.1），
 * **不含内嵌性能统计**（T031 已迁出）。
 */
#include "gl_flip_engine.h"

#include <hilog/log.h>
#include <native_display_soloist/native_display_soloist.h>

#include <ctime>
#include <cmath>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "OhEngineGL"
#define LOG_DOMAIN 0x3900
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace flipgl {

namespace {
// 帧率档位：1=交互（设备上限），2=长动画（≤90Hz），3=短动画（≤60Hz）
void SetSoloistFrameRate(OH_DisplaySoloist* soloist, int mode, int displayRate) {
  if (soloist == nullptr) {
    return;
  }
  const int maxRate = std::max(30, std::min(displayRate, 120));
  int expected = maxRate;
  if (mode == 2) {
    expected = std::min(maxRate, 90);
  } else if (mode == 3) {
    expected = std::min(maxRate, 60);
  }
  const int minRate = mode == 1
      ? std::max(30, maxRate / 2)
      : (mode == 2 ? std::max(30, expected - 30) : 30);
  DisplaySoloist_ExpectedRateRange range{minRate, maxRate, expected};
  OH_DisplaySoloist_SetExpectedFrameRateRange(soloist, &range);
}

void OnSoloistFrameCb(long long timestamp, long long /*targetTimestamp*/, void* data) {
  auto* engine = static_cast<GlFlipEngine*>(data);
  if (engine != nullptr) {
    engine->OnSoloistFrame(static_cast<int64_t>(timestamp));
  }
}

int64_t NowMs() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}
}  // namespace

GlFlipEngine* GlFlipEngine::GetInstance() {
  static GlFlipEngine instance;
  return &instance;
}

GlFlipEngine::GlFlipEngine() = default;

// ── Surface 生命周期 ──────────────────────────────────────────────────

void GlFlipEngine::OnSurfaceCreated(void* window, int surfaceW, int surfaceH) {
  if (backend_.Init(window, surfaceW, surfaceH)) {
    surfaceW_ = backend_.SurfaceWidth();
    surfaceH_ = backend_.SurfaceHeight();
    ready_ = true;
    stateMachine_.SetSurfaceSize(surfaceW_, surfaceH_);
    stateMachine_.SetDisplayRefreshRate(displayRefreshRate_);
    SpringDamperConfig cfg;
    stateMachine_.SetConfig(cfg);
    // 渲染回调：跨线程快照 → geometry → render backend
    stateMachine_.SetCallbacks(
        [this](const FrameRenderData& d) {
          // canonical 镜像发生在 NAPI 边界；此处 down/touch 已为 canonical
          GestureState gs;
          gs.downX = d.downX;
          gs.downY = d.downY;
          gs.touchX = d.touchX;
          gs.touchY = d.touchY;
          gs.radius = d.radius;
          gs.surfaceW = static_cast<float>(surfaceW_);
          gs.surfaceH = static_cast<float>(surfaceH_);
          gs.direction = d.direction;
          gs.spine = d.spine;
          // 模型选择（CYLINDER / CONE / HYBRID；Hybrid 由 blendFactor 驱动 GPU 混合）
          const CurlGeometryModel* geo = &cylinderGeometry_;
          if (d.model == CurlModel::CONE) {
            geo = &coneGeometry_;
          } else if (d.model == CurlModel::HYBRID) {
            geo = &hybridGeometry_;
          }
          CurlFieldParams params = geo->Compute(gs);
          // BeginFrame（makeCurrent soloist 线程）+ DrawCurl + EndFrame（swap）
          if (backend_.BeginFrame()) {
            backend_.DrawCurl(params, ctxFrontTex_, ctxBackTex_, d.direction, d.spine,
                              d.downX, d.downY);
            backend_.EndFrame();
          }
        },
        [this]() {
          // B1 清屏（0.11）
          backend_.ClearSurface();
        },
        [this](int32_t token, FlipResult result) {
          // 完成回调转发（TSFN 由 napi 层注册）
          if (completionCb_) {
            completionCb_(token, result);
          }
        });
    LOGI("OnSurfaceCreated: ready surface=%{public}dx%{public}d", surfaceW_, surfaceH_);
    // 建立 soloist 帧驱动（T024：soloist 帧回调触发；缺失会导致
    // stateMachine_.OnFrame 永不执行 → 收尾插值/900ms 超时/渲染全部失效）
    if (soloist_ == nullptr) {
      soloist_ = OH_DisplaySoloist_Create(true);
      if (soloist_ != nullptr) {
        SetSoloistFrameRate(soloist_, 1, displayRefreshRate_);
        const int32_t rc = OH_DisplaySoloist_Start(soloist_, OnSoloistFrameCb, this);
        LOGI("Soloist started rc=%{public}d", rc);
      } else {
        LOGE("Soloist create failed");
      }
    }
  } else {
    ready_ = false;
    LOGE("OnSurfaceCreated: backend init failed");
  }
}

void GlFlipEngine::OnSurfaceChanged(void* window, int surfaceW, int surfaceH) {
  (void)window;
  surfaceW_ = surfaceW;
  surfaceH_ = surfaceH;
  backend_.Resize(surfaceW, surfaceH);
  stateMachine_.SetSurfaceSize(surfaceW, surfaceH);
  LOGI("OnSurfaceChanged: %{public}dx%{public}d", surfaceW_, surfaceH_);
}

void GlFlipEngine::OnSurfaceDestroyed() {
  // Required Change 5：清理矩阵（状态机清当前操作/事务/定时器）
  stateMachine_.OnSurfaceDestroyed();
  backend_.Destroy();
  ready_ = false;
  ctxFrontTex_ = 0;
  ctxBackTex_ = 0;
  // 释放 soloist 帧驱动（surface 销毁后不再有 vsync）
  if (soloist_ != nullptr) {
    OH_DisplaySoloist_Stop(soloist_);
    OH_DisplaySoloist_Destroy(soloist_);
    soloist_ = nullptr;
  }
  LOGI("OnSurfaceDestroyed: cleaned");
}

// ── N-API 入口 ────────────────────────────────────────────────────────

void GlFlipEngine::SetDisplayRefreshRate(int refreshRate) {
  if (refreshRate >= 30 && refreshRate <= 240) {
    displayRefreshRate_ = refreshRate;
    stateMachine_.SetDisplayRefreshRate(refreshRate);
  }
}

void GlFlipEngine::SetTsfnAvailable(bool available) {
  stateMachine_.SetTsfnAvailable(available);
}

void GlFlipEngine::SetCompletionCallback(
    std::function<void(int32_t, FlipResult)> completionCb) {
  completionCb_ = std::move(completionCb);
}

TextureHandle GlFlipEngine::UploadTexture(const uint8_t* rgba, int w, int h) {
  return backend_.UploadTexture(rgba, w, h);
}

void GlFlipEngine::ReleaseTexture(TextureHandle tex) {
  backend_.ReleaseTexture(tex);
}

BeginGestureResult GlFlipEngine::BeginGesture(
    int32_t direction, SpineSide spine, float downX, float downY, CurlModel model,
    bool synthetic, int32_t pageGenerationSnapshot,
    TextureHandle frontTex, TextureHandle backTex,
    int32_t frontW, int32_t frontH, int32_t backW, int32_t backH) {
  ctxFrontTex_ = frontTex;
  ctxBackTex_ = backTex;
#ifdef FLIPGL_ENABLE_PERF
  // 第 1 类：Input-to-first-frame 起点（beginGesture 成功）
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  beginRequestNs_ = static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
  perf_.firstFrameLogged = false;
#endif
  BeginGestureResult r = stateMachine_.BeginGesture(direction, spine, downX, downY, model, synthetic,
                                                    pageGenerationSnapshot, frontTex, backTex,
                                                    frontW, frontH, backW, backH);
  return r;
}

void GlFlipEngine::UpdateGesture(int32_t token, float x, float y, int64_t timestampMs) {
  stateMachine_.UpdateGesture(token, x, y, timestampMs);
}

bool GlFlipEngine::EndGesture(int32_t token, float x, float y) {
  return stateMachine_.EndGesture(token, x, y);
}

bool GlFlipEngine::CancelGesture(int32_t token) {
  return stateMachine_.CancelGesture(token);
}

BeginGestureResult GlFlipEngine::BeginReboundRecovery(int32_t prevToken, int32_t direction) {
  return stateMachine_.BeginReboundRecovery(prevToken, direction);
}

bool GlFlipEngine::ReleaseTextureTransaction(int32_t token) {
  const bool ok = stateMachine_.ReleaseTextureTransaction(token);
  if (ok) {
    backend_.ReleaseTexture(ctxFrontTex_);
    backend_.ReleaseTexture(ctxBackTex_);
    ctxFrontTex_ = 0;
    ctxBackTex_ = 0;
  }
  return ok;
}

// ── soloist 帧驱动 ────────────────────────────────────────────────────

void GlFlipEngine::OnSoloistFrame(int64_t timestampNs) {
#ifdef FLIPGL_ENABLE_PERF
  // 第 4 类：Soloist 回调间隔（仅调度节奏指标，不冒充 GPU 耗时）
  if (perf_.lastSoloistNs > 0) {
    const int64_t intervalUs = (timestampNs - perf_.lastSoloistNs) / 1000LL;
    if (intervalUs <= 50000) {
      perf_.soloistInterval.Add(static_cast<float>(intervalUs));
    }
  }
  perf_.lastSoloistNs = timestampNs;
  // 第 1 类：输入到首帧（beginRequestNs 在 BeginGesture 成功时记录）
  if (!perf_.firstFrameLogged && beginRequestNs_ > 0) {
    perf_.inputToFirstFrameUs = (timestampNs - beginRequestNs_) / 1000LL;
    perf_.firstFrameLogged = true;
    LOGI("METRIC flip first-frame=%{public}lldus",
         static_cast<long long>(perf_.inputToFirstFrameUs));
  }
#endif
  // 跨线程状态快照 + 状态机推进（内部互斥）
  stateMachine_.OnFrame(timestampNs / 1000000LL);
}

void GlFlipEngine::RenderFrame(int64_t timestampNs) {
  OnSoloistFrame(timestampNs);
}

void GlFlipEngine::Destroy() {
  stateMachine_.OnSurfaceDestroyed();
  backend_.Destroy();
  ready_ = false;
  ctxFrontTex_ = 0;
  ctxBackTex_ = 0;
  if (soloist_ != nullptr) {
    OH_DisplaySoloist_Stop(soloist_);
    OH_DisplaySoloist_Destroy(soloist_);
    soloist_ = nullptr;
  }
}

}  // namespace flipgl
