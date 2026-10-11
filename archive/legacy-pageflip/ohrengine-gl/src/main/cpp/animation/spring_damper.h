/*
 * spring_damper.h — 阻尼弹簧/低通滤波/惯性预估/速度估算（0.6/0.14）
 *
 * 归属：native（animation/ 模块），是完成/回弹阈值判定所需末速度估算的
 * 唯一实现处。ArkTS 不再计算/传递速度（endGesture 无 velX/velY 参数）。
 *
 * 单位契约（0.14）：所有位置为 Surface px，速度为 px/ms，时间戳为单调
 * 时钟 ms。本文件为纯数学实现，**禁止任何 GL/EGL/OHOS 头文件**，
 * 保证 host 端离线单测可编译。
 */
#pragma once

#include <cstdint>
#include <cmath>

namespace flipgl {

constexpr float kPi = 3.<phone>979323846f;

/**
 * 动画/手感参数配置（0.6/0.14 可配置项，替代现状硬编码系数）。
 * 视觉调参项归 shader_params.h；本表只含动画物理/手感项。
 */
struct SpringDamperConfig {
  /** 触摸低通滤波系数（跟手平滑，原 0.5） */
  float filterLerp = 0.5f;
  /** 半径阻尼弹簧每帧收敛系数（原 0.35） */
  float radiusSpringK = 0.35f;
  /** 惯性预估时间窗（ms，原 250ms） */
  float inertiaTimeMs = 250.0f;
  /** 临界阻尼曲线参数 k：1 - (1 + kt)e^(-kt)（原 6） */
  float criticalDampingK = 6.0f;
  /** 半径下限（px，原 40） */
  float radiusMinPx = 40.0f;
  /** 半径上限 = surfaceW * fraction（原 0.35） */
  float radiusMaxFraction = 0.35f;
  /** 收尾动画时长下限（ms，原 220） */
  float settleMinMs = 220.0f;
  /** 收尾动画时长增量区间（ms，原 220：220+ratio*220） */
  float settleRangeMs = 220.0f;

  // ── 完成/回弹阈值判定（0.6 native 唯一归属） ────────────────────────
  /** 越过中线判定：x > surfaceW * fraction 视为越过（原 midX=contentW/2） */
  float completeThresholdFraction = 0.5f;
  /** 最小横向位移（px，原 30 vp，此处按 px 的通用下限） */
  float minHorizontalCommitPx = 60.0f;
  /** 纵向位移相对权重（横向位移须 ≥ 纵向 × 权重，原 0.15） */
  float verticalWeightRatio = 0.15f;
  /** 末速度辅助判定阈值（px/ms，方向与完成方向一致且超过此值判完成） */
  float velocityAssistThreshold = 0.7f;
  /** 速度估算环形缓冲大小 */
  int velocityRingSize = 8;
};

/**
 * 临界阻尼曲线：1 - (1 + kt)·e^(-kt)，t ∈ [0,1]。
 * 收尾/回弹动画统一使用（无终点速度突变）。
 */
inline float CriticalDampingCurve(float t, float k) {
  if (t >= 1.0f) {
    return 1.0f;
  }
  if (t <= 0.0f) {
    return 0.0f;
  }
  return 1.0f - (1.0f + k * t) * std::exp(-k * t);
}

/**
 * 圆柱半径目标值：R = |drag| / π（弧长守恒唯一曲率语义），clamp 到
 * [radiusMinPx, surfaceW * radiusMaxFraction]。
 */
inline float ComputeRadiusTarget(float dragLen, float surfaceW,
                                 const SpringDamperConfig& cfg) {
  float r = dragLen / kPi;
  float maxR = surfaceW * cfg.radiusMaxFraction;
  if (r < cfg.radiusMinPx) {
    r = cfg.radiusMinPx;
  }
  if (r > maxR) {
    r = maxR;
  }
  return r;
}

/**
 * 一阶低通滤波器（触摸跟手平滑，替代原 SetTouch 内硬编码 lerp 0.5）。
 */
class LowPassFilter {
public:
  LowPassFilter() = default;

  void Reset() {
    initialized_ = false;
    valueX_ = 0.0f;
    valueY_ = 0.0f;
  }

  /** 更新滤波器，返回滤波后的位置。首帧直接采用样本值（基线初始化）。 */
  void Update(float x, float y, float lerp) {
    if (!initialized_) {
      valueX_ = x;
      valueY_ = y;
      initialized_ = true;
    } else {
      valueX_ += (x - valueX_) * lerp;
      valueY_ += (y - valueY_) * lerp;
    }
  }

  float X() const { return valueX_; }
  float Y() const { return valueY_; }

private:
  bool initialized_ = false;
  float valueX_ = 0.0f;
  float valueY_ = 0.0f;
};

/**
 * 速度估算器：位置-时间环形缓冲（Surface px/ms，0.14）。
 * updateGesture 每帧写入 (x, y, timestampMs)；endGesture 时估算末速度。
 * 估算口径：最近两样本间的平均速度（若时间差>0）。
 */
class VelocityEstimator {
public:
  explicit VelocityEstimator(int ringSize = 8) : ringSize_(ringSize > 0 ? ringSize : 8) {
    Reset();
  }

  void Reset() {
    count_ = 0;
    head_ = 0;
    for (int i = 0; i < 32 && i < ringSize_; i++) {
      xs_[i] = 0.0f;
      ys_[i] = 0.0f;
      ts_[i] = 0;
    }
  }

  /** 写入一个位置-时间样本（UI 线程调用，无锁要求：调用方负责串行化）。 */
  void AddSample(float x, float y, int64_t timestampMs) {
    int idx = head_ % ringSize_;
    xs_[idx] = x;
    ys_[idx] = y;
    ts_[idx] = timestampMs;
    head_++;
    if (count_ < ringSize_) {
      count_++;
    }
  }

  /** 估算末速度（px/ms）。返回最近两样本间速度；不足 2 样本返回 0。 */
  void Estimate(float& vx, float& vy) const {
    vx = 0.0f;
    vy = 0.0f;
    if (count_ < 2) {
      return;
    }
    int iNew = (head_ - 1) % ringSize_;
    int iOld = (head_ - 2) % ringSize_;
    int64_t dt = ts_[iNew] - ts_[iOld];
    if (dt <= 0) {
      return;
    }
    vx = (xs_[iNew] - xs_[iOld]) / static_cast<float>(dt);
    vy = (ys_[iNew] - ys_[iOld]) / static_cast<float>(dt);
  }

  int SampleCount() const { return count_; }

private:
  static constexpr int kMaxRing = 32;
  float xs_[32] = {0.0f};
  float ys_[32] = {0.0f};
  int64_t ts_[32] = {0};
  int ringSize_ = 8;
  int count_ = 0;
  int head_ = 0;
};

}  // namespace flipgl
