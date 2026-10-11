/*
 * cone_curl_geometry.cpp — Cone 曲率场参数计算实现（T040）
 *
 * 依据：adr-cone-curl-geometry.md（0.3 设计说明，评审通过）
 *  - 锥心选角：argmin_{c ∈ 四角} |downPoint − c|；平局取自由侧角
 *    （spine=left 且 direction=FORWARD → 右上角；spine=left/BACKWARD → 左下；
 *     spine=right/FORWARD → 左上；spine=right/BACKWARD → 右下，即与 spine
 *     相对、符合 direction 语义的一侧）
 *  - 锥轴 u = normalize(touchPoint − apex)；|touch−apex| < 1px 时按 direction 兜底
 *  - 母线 ρ(s) = max(s, ε)·tanα；s₀ = max(|touch−apex|, 2ε)
 *  - CurlFieldParams：blendFactor=1（纯 Cone），cone 参数组填充
 */
#include "cone_curl_geometry.h"

#include <cmath>

#include "shader/shader_params.h"
#include "shader/curl_field_cone.h"

namespace flipgl {

namespace {

/**
 * 选角（§2）：argmin_{四角} |down − corner|，平局取自由侧角。
 * canonical 四角：TL(0,0) TR(surfaceW,0) BL(0,surfaceH) BR(surfaceW,surfaceH)。
 * 自由侧规则：spine=left → 自由侧在右（FORWARD→TR，BACKWARD→BL）；
 *             spine=right → 自由侧在左（FORWARD→TL，BACKWARD→BR）。
 */
void SelectApex(const GestureState& gs, float& apexX, float& apexY) {
  const float w = gs.surfaceW;
  const float h = gs.surfaceH;
  const float corners[4][2] = {{0.0f, 0.0f}, {w, 0.0f}, {0.0f, h}, {w, h}};
  const bool forward = gs.direction >= 0;
  const bool leftSpine = gs.spine == SpineSide::LEFT;
  // 自由侧优先级（平局时使用）：[free corner, opposite free, near corner, spine corner]
  int order[4] = {0, 1, 2, 3};
  // 自由侧角：spine=left & FORWARD → TR(1)；spine=left & BACKWARD → BL(2)；
  //           spine=right & FORWARD → TL(0)；spine=right & BACKWARD → BR(3)
  int freeIdx = -1;
  if (leftSpine) {
    freeIdx = forward ? 1 : 2;   // TR / BL
  } else {
    freeIdx = forward ? 0 : 3;   // TL / BR
  }
  const int oppositeIdx = (freeIdx + 2) % 4;  // 对角
  order[0] = freeIdx;
  order[1] = oppositeIdx;
  // 剩余两个按索引序
  int k = 2;
  for (int i = 0; i < 4; i++) {
    if (i != freeIdx && i != oppositeIdx) {
      order[k++] = i;
    }
  }
  // 计算各角距离并选最小（平局 → 顺序优先 = 自由侧）
  float bestDist = 1e30f;
  int best = freeIdx;
  for (int i = 0; i < 4; i++) {
    const int idx = order[i];
    const float dx = gs.downX - corners[idx][0];
    const float dy = gs.downY - corners[idx][1];
    const float d = std::sqrt(dx * dx + dy * dy);
    // 平局（差异 < 1px）保持 order 优先级；更近则更新
    if (d < bestDist - 1.0f) {
      bestDist = d;
      best = idx;
    }
  }
  apexX = corners[best][0];
  apexY = corners[best][1];
}

}  // namespace

CurlFieldParams ConeCurlGeometry::Compute(const GestureState& gs) const {
  const ShaderParams& sp = GetShaderParams();
  CurlFieldParams p;
  p.blendFactor = 1.0f;  // 纯 Cone

  // §2 锥心
  float apexX = 0.0f, apexY = 0.0f;
  SelectApex(gs, apexX, apexY);
  p.coneApexX = apexX;
  p.coneApexY = apexY;

  // §3 锥轴 u = normalize(touch − apex)；|touch−apex| < 1px 时按 direction 兜底
  float dx = gs.touchX - apexX;
  float dy = gs.touchY - apexY;
  const float len = std::sqrt(dx * dx + dy * dy);
  if (len < 1.0f) {
    // FORWARD → u = (−1, 0)；BACKWARD → u = (1, 0)（canonical 书脊在左）
    dx = gs.direction >= 0 ? -1.0f : 1.0f;
    dy = 0.0f;
  } else {
    dx /= len;
    dy /= len;
  }
  p.coneAxisX = dx;
  p.coneAxisY = dy;

  // §4 母线参数：ρ(s) = max(s, ε)·tanα；s₀ = max(|touch−apex|, 2ε)
  const float s0 = std::max(len, 2.0f * sp.coneEpsilon);
  p.coneGeneratrixCoef = sp.coneOpening;   // tanα
  p.coneEpsilon = sp.coneEpsilon;

  // 折叠线位置（诊断/与 Cylinder anchor 语义对齐）：fold = A + u·s₀
  // CurlFieldParams 无独立 s₀ 字段，折叠线坐标供渲染端推导
  p.cylinderAnchorX = apexX + dx * s0;
  p.cylinderAnchorY = apexY + dy * s0;
  // 折叠轴 = (−u.y, u.x)（与 ConeFoldAxis 一致，诊断用）
  p.cylinderAxisX = -dy;
  p.cylinderAxisY = dx;

  // strength 组默认透传（调参归 shader_params.h）
  return p;
}

}  // namespace flipgl
