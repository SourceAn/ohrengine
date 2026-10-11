/*
 * curl_field_cone.h — Cone 曲率场 C++ 镜像实现（0.1/0.3，离线单测用）
 *
 * 与 shader/curl_field.common.glsl.h 的 Cone 分支共享同一份公式定义
 * （adr-cone-curl-geometry.md §4/§5）。本文件不参与线上渲染，仅用于：
 *  - 离线单测预言机（正向/反向映射互逆性、半径场、弧长守恒）；
 *  - geometry/cone_curl_geometry 的参数化辅助。
 *
 * ⚠️ 禁止任何 GL/EGL/OHOS 头文件（host-compilable）。
 */
#pragma once

#include <cmath>
#include <algorithm>

namespace flipgl {

/**
 * Cone 曲率场参数（CurlFieldParams cone 参数组 + 派生值）。
 * 坐标系：canonical px（spine 已在边界镜像一次）。
 */
struct ConeFieldParams {
  float apexX = 0.0f;          // 锥心（canonical 四角坐标）
  float apexY = 0.0f;
  float axisX = 0.0f;          // 锥轴单位向量 u（canonical）
  float axisY = 1.0f;
  float s0 = 0.0f;             // 折叠线距锥心距离（px，= max(|touch−apex|, 2ε)）
  float tanAlpha = 0.35f;      // 锥张开参数
  float epsilon = 2.0f;        // 锥心半径下限（px）
};

/** 折叠轴 f = (−u.y, u.x) */
inline void ConeFoldAxis(const ConeFieldParams& p, float& fX, float& fY) {
  fX = -p.axisY;
  fY = p.axisX;
}

/** 母线半径场：ρ(s) = max(s, ε)·tanα（§4；s→0 时稳定为 ε·tanα > 0） */
inline float ConeRadius(float s, float tanAlpha, float epsilon) {
  const float sSafe = std::max(s, epsilon);
  return sSafe * tanAlpha;
}

/**
 * §5.1 反向映射：屏幕像素 P → 卷曲场（theta / 源坐标 P_src）。
 * 输入：(px, py) canonical 屏幕坐标；输出：theta、源坐标、s/t 分量。
 */
inline void ConeReverseMap(const ConeFieldParams& p, float px, float py,
                           float& theta, float& srcX, float& srcY,
                           float& sOut, float& tOut) {
  const float dx = px - p.apexX;
  const float dy = py - p.apexY;
  const float s = dx * p.axisX + dy * p.axisY;      // 锥轴方向距离
  float fX = 0.0f, fY = 0.0f;
  ConeFoldAxis(p, fX, fY);
  const float t = dx * fX + dy * fY;                // 折叠轴方向横向偏移
  const float x = s - p.s0;                         // 相对折叠线带内坐标
  const float rho = ConeRadius(s, p.tanAlpha, p.epsilon);
  // uₙ = clamp(x/ρ, −1, 1)；θ = acos(uₙ)
  const float rhoSafe = std::max(rho, 1e-4f);
  const float un = std::max(-1.0f, std::min(1.0f, x / rhoSafe));
  theta = std::acos(un);
  const float S = rho * theta;                      // 源弧长（弧长守恒）
  // P_src = A + u·(s₀ + S) + f·t
  srcX = p.apexX + p.axisX * (p.s0 + S) + fX * t;
  srcY = p.apexY + p.axisY * (p.s0 + S) + fY * t;
  sOut = s;
  tOut = t;
}

/**
 * §5.2 正向映射（离线测试预言机）：源（自折叠线弧长 S，横向偏移 t）→ 屏幕坐标。
 *
 * 推导（θ 固定点，收敛稳于 x 迭代）：
 *   x = ρ·cosθ，S = ρ·θ，ρ = max(s₀+x, ε)·tanα
 *   记 k = tanα、s = s₀ + x：ρ = k·s
 *   x = ρ·cosθ → s = s₀ + k·s·cosθ → s(1 − k·cosθ) = s₀ → ρ = k·s₀/(1 − k·cosθ)
 *   S = ρ·θ → S·(1 − k·cosθ) = k·s₀·θ
 *   ⇒ θ 固定点：θ = S·(1 − k·cosθ)/(k·s₀)，初值 θ₀ = S/(k·s₀)，迭代 8 次。
 */
inline void ConeForwardMap(const ConeFieldParams& p, float S, float t,
                           float& px, float& py) {
  const float k = p.tanAlpha;
  const float s0Safe = std::max(p.s0, 1e-4f);
  // θ 固定点迭代
  float theta = S / (k * s0Safe);
  for (int i = 0; i < 8; i++) {
    theta = S * (1.0f - k * std::cos(theta)) / (k * s0Safe);
  }
  const float denom = std::max(1.0f - k * std::cos(theta), 1e-4f);
  const float rho = k * s0Safe / denom;
  const float x = rho * std::cos(theta);
  float fX = 0.0f, fY = 0.0f;
  ConeFoldAxis(p, fX, fY);
  px = p.apexX + p.axisX * (p.s0 + x) + fX * t;
  py = p.apexY + p.axisY * (p.s0 + x) + fY * t;
}

}  // namespace flipgl
