/*
 * hybrid_curl_geometry.cpp — Hybrid 混合几何实现（T043）
 *
 * 只做两件事（0.2）：
 *  1. 计算 blendFactor（§6.2 smoothstep 策略，依据按下点到最近书角距离）；
 *  2. 合并 CylinderCurlGeometry + ConeCurlGeometry 的参数到同一
 *     CurlFieldParams（cylinder 参数组 + cone 参数组，均不做插值）。
 */
#include "hybrid_curl_geometry.h"

#include <cmath>
#include <algorithm>

#include "cylinder_curl_geometry.h"
#include "cone_curl_geometry.h"
#include "shader/shader_params.h"

namespace flipgl {

namespace {

/** 平滑过渡：smoothstep(edge0, edge1, x)，线性区间外 0/1（与 GLSL smoothstep 一致） */
float SmoothStep(float edge0, float edge1, float x) {
  const float t = std::max(0.0f, std::min(1.0f, (x - edge0) / (edge1 - edge0)));
  return t * t * (3.0f - 2.0f * t);
}

}  // namespace

CurlFieldParams HybridCurlGeometry::Compute(const GestureState& gs) const {
  // 1. blendFactor（§6.2）：按下点到最近书角的距离
  const ShaderParams& sp = GetShaderParams();
  const float w = gs.surfaceW;
  const float h = gs.surfaceH;
  const float corners[4][2] = {{0.0f, 0.0f}, {w, 0.0f}, {0.0f, h}, {w, h}};
  float bestD = 1e30f;
  for (int i = 0; i < 4; i++) {
    const float dx = gs.downX - corners[i][0];
    const float dy = gs.downY - corners[i][1];
    const float d = std::sqrt(dx * dx + dy * dy);
    if (d < bestD) {
      bestD = d;
    }
  }
  const float dCorner = sp.cornerThreshold * std::min(w, h);
  const float raw = 1.0f - std::max(0.0f, std::min(1.0f, bestD / std::max(dCorner, 1e-4f)));
  const float blend = SmoothStep(0.5f - sp.blendTransitionWidth,
                                 0.5f + sp.blendTransitionWidth, raw);

  // 2. 合并两模型参数（均不做插值；逐像素混合归 GPU curl_field）
  CylinderCurlGeometry cyl;
  ConeCurlGeometry cone;
  CurlFieldParams p = cyl.Compute(gs);
  CurlFieldParams pc = cone.Compute(gs);

  p.blendFactor = blend;
  // cone 参数组原样合并
  p.coneApexX = pc.coneApexX;
  p.coneApexY = pc.coneApexY;
  p.coneAxisX = pc.coneAxisX;
  p.coneAxisY = pc.coneAxisY;
  p.coneGeneratrixCoef = pc.coneGeneratrixCoef;
  p.coneEpsilon = pc.coneEpsilon;
  // cylinder 锚点/轴在 Cone 分支中亦有语义（折叠线），合并后由渲染端选择
  return p;
}

}  // namespace flipgl
