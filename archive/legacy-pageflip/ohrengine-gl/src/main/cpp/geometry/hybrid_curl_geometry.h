/*
 * hybrid_curl_geometry.h — Hybrid 混合几何模型（Phase B，T043）
 *
 * 职责（0.2 收紧措辞）：**只**计算 blendFactor 与两个模型的专属参数
 * （cylinder + cone 参数组合并到同一 CurlFieldParams），**不做任何插值
 * 运算**；逐像素场插值（theta/位移/源 UV 在 Cylinder 与 Cone 分支间混合）
 * 完全由 shader/curl_field.common.glsl.h 在 GPU 完成。
 *
 * blendFactor 默认策略（adr-cone-curl-geometry.md §6.2）：
 *   d = |downPoint − apex|（按下点到最近书角距离）
 *   d_corner = cornerThreshold · min(surfaceW, surfaceH)
 *   raw = 1 − clamp(d / d_corner, 0, 1)
 *   blendFactor = smoothstep(0.5 − w, 0.5 + w, raw)，w = blendTransitionWidth
 *
 * ⚠️ 禁止任何 GL/EGL/OHOS 头文件（host-compilable）。
 */
#pragma once

#include "curl_geometry.h"

namespace flipgl {

/** Hybrid 模型实现：blendFactor（0→纯 Cylinder，1→纯 Cone）+ 合并参数。 */
class HybridCurlGeometry : public CurlGeometryModel {
public:
  CurlFieldParams Compute(const GestureState& gesture) const override;
  CurlModel Model() const override { return CurlModel::HYBRID; }
};

}  // namespace flipgl
