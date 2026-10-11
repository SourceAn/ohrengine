/*
 * cone_curl_geometry.h — Cone Page Curl 几何模型（Phase B，T040）
 *
 * 依据：adr-cone-curl-geometry.md（评审通过的 0.3 设计说明，唯一编码依据）
 *  - §2 锥心选角：argmin_{四角} |down − corner|，平局取自由侧角
 *  - §3 锥轴 u = normalize(touch − apex)
 *  - §4 母线 ρ(s) = max(s, ε)·tanα；折叠线 s₀ = max(|touch−apex|, 2ε)
 *  - 填充 CurlFieldParams cone 参数组（coneApexX/Y、coneAxisX/Y、
 *    coneGeneratrixCoef、coneEpsilon）
 *
 * ⚠️ 禁止任何 GL/EGL/OHOS 头文件（host-compilable）。
 */
#pragma once

#include "curl_geometry.h"

namespace flipgl {

/** Cone 模型实现：输出纯 Cone 曲率场参数（blendFactor 恒为 1）。 */
class ConeCurlGeometry : public CurlGeometryModel {
public:
  CurlFieldParams Compute(const GestureState& gesture) const override;
  CurlModel Model() const override { return CurlModel::CONE; }
};

}  // namespace flipgl
