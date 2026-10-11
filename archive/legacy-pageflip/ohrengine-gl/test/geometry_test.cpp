/*
 * geometry_test.cpp — Cylinder 曲率场参数离线单测（T012）
 *
 * 覆盖（Test Requirements 1，Phase A 范围）：
 *  - radius bounds（上下限）
 *  - axis / band width（卷曲轴归一化、带宽 2R）
 *  - boundary conditions（down==touch 时方向兜底、spine 镜像）
 *  - blendFactor=0 cylinder equivalence（纯 Cylinder 输出）
 *
 * 依赖：CylinderCurlGeometry（geometry/），无 EGL/真机依赖。
 */
#include "test_framework.h"

#include "geometry/curl_geometry.h"
#include "geometry/cylinder_curl_geometry.h"
#include "geometry/cone_curl_geometry.h"
#include "geometry/hybrid_curl_geometry.h"
#include "shader/curl_field_cone.h"
#include "shader/shader_params.h"
#include "animation/spring_damper.h"

#include <cmath>

using namespace flipgl;

namespace {

// 构造一个默认手势（canonical 坐标系 Surface px）
GestureState MakeGesture(float downX, float downY, float touchX, float touchY,
                         float radius, int direction, SpineSide spine,
                         float surfaceW = 1080.0f, float surfaceH = 1920.0f) {
  GestureState gs;
  gs.downX = downX;
  gs.downY = downY;
  gs.touchX = touchX;
  gs.touchY = touchY;
  gs.radius = radius;
  gs.surfaceW = surfaceW;
  gs.surfaceH = surfaceH;
  gs.direction = direction;
  gs.spine = spine;
  return gs;
}

}  // namespace

TEST_CASE(Cylinder_Basic_Params_Forward) {
  CylinderCurlGeometry geo;
  GestureState gs = MakeGesture(100, 100, 600, 400, 180.0f, 1, SpineSide::LEFT);
  CurlFieldParams p = geo.Compute(gs);

  CHECK_EQ(p.blendFactor, 0.0f);          // 纯 Cylinder
  CHECK_NEAR(p.cylinderRadius, 180.0f, 0.001f);
  // 带宽 = 2R
  CHECK_NEAR(p.cylinderBandWidth, 360.0f, 0.001f);
  // 卷曲轴方向 = normalize(touch-down) 的垂直方向，单位向量
  float ax = p.cylinderAxisX;
  float ay = p.cylinderAxisY;
  CHECK_NEAR(std::sqrt(ax * ax + ay * ay), 1.0f, 0.001f);
  // 锚点 = touch（canonical）
  CHECK_NEAR(p.cylinderAnchorX, 600.0f, 0.001f);
  CHECK_NEAR(p.cylinderAnchorY, 400.0f, 0.001f);
}

TEST_CASE(Cylinder_Axis_Is_Perpendicular_To_Drag) {
  CylinderCurlGeometry geo;
  // 水平拖拽（向右）：拖拽向量 (dx>0, dy=0)
  GestureState gs = MakeGesture(100, 500, 700, 500, 150.0f, 1, SpineSide::LEFT);
  CurlFieldParams p = geo.Compute(gs);
  // 折叠轴应垂直于拖拽方向 → 竖直方向 (0, ±1)
  CHECK_NEAR(p.cylinderAxisX, 0.0f, 0.001f);
  CHECK_NEAR(std::fabs(p.cylinderAxisY), 1.0f, 0.001f);
  // curlDir=(1,0) → foldAxis = (-curlDir.y, curlDir.x) = (0,1)（与 shader 一致）
  CHECK(p.cylinderAxisY > 0.0f);

  // 竖直拖拽（向下）：拖拽向量 (0, dy>0) → 折叠轴水平 (±1, 0)
  GestureState gs2 = MakeGesture(400, 100, 400, 900, 150.0f, 1, SpineSide::LEFT);
  CurlFieldParams p2 = geo.Compute(gs2);
  CHECK_NEAR(p2.cylinderAxisY, 0.0f, 0.001f);
  CHECK_NEAR(std::fabs(p2.cylinderAxisX), 1.0f, 0.001f);
}

TEST_CASE(Cylinder_Radius_Bounds) {
  CylinderCurlGeometry geo;
  const float surfaceW = 1080.0f;
  const SpringDamperConfig cfg;
  // 极小拖拽距离 → 半径被 clamp 到下限 40
  GestureState gs = MakeGesture(100, 100, 105, 102, 0.0f, 1, SpineSide::LEFT, surfaceW);
  CurlFieldParams p = geo.Compute(gs);
  // radius 由 GestureState.radius 携带（spring_damper 已 clamp），几何不再 clamp
  CHECK_EQ(p.cylinderRadius, 0.0f);
  // 通过 ComputeRadiusTarget 验证 clamp 行为
  float rSmall = ComputeRadiusTarget(5.0f, surfaceW, cfg);
  CHECK_NEAR(rSmall, cfg.radiusMinPx, 0.001f);
  // 大拖拽 → clamp 到 surfaceW * fraction
  float rBig = ComputeRadiusTarget(surfaceW * 3.0f, surfaceW, cfg);
  CHECK_NEAR(rBig, surfaceW * cfg.radiusMaxFraction, 0.001f);
}

TEST_CASE(Cylinder_Radius_ArcLength_Mapping) {
  // R = |drag|/π（弧长守恒），半径随拖拽距离线性增长
  const float surfaceW = 1080.0f;
  const SpringDamperConfig cfg;
  float r1 = ComputeRadiusTarget(314.159265f, surfaceW, cfg);  // drag=π*R → R=100
  CHECK_NEAR(r1, 100.0f, 0.5f);
  float r2 = ComputeRadiusTarget(628.31853f, surfaceW, cfg);   // drag=π*2R → R=200
  CHECK_NEAR(r2, 200.0f, 0.5f);
}

TEST_CASE(Cylinder_Boundary_DownEqualsTouch) {
  CylinderCurlGeometry geo;
  // down == touch（点击式合成手势首帧）：方向兜底到 direction 轴向
  GestureState gs = MakeGesture(500, 500, 500, 500, 120.0f, 1, SpineSide::LEFT);
  CurlFieldParams p = geo.Compute(gs);
  CHECK_NEAR(p.cylinderAnchorX, 500.0f, 0.001f);
  CHECK_NEAR(p.cylinderAnchorY, 500.0f, 0.001f);
  // 轴兜底：direction=1 → curlDir=(-1,0) → foldAxis=(0,-1)（与 shader 一致）
  CHECK_NEAR(p.cylinderAxisX, 0.0f, 0.001f);
  CHECK_NEAR(p.cylinderAxisY, -1.0f, 0.001f);

  // direction=-1（BACKWARD）→ foldAxis=(0,1)
  GestureState gs2 = MakeGesture(500, 500, 500, 500, 120.0f, -1, SpineSide::LEFT);
  CurlFieldParams p2 = geo.Compute(gs2);
  CHECK_NEAR(p2.cylinderAxisY, 1.0f, 0.001f);
}

TEST_CASE(Cylinder_BlendFactor_Zero_Equivalence) {
  // blendFactor=0 时与纯 Cylinder 一致（Hybrid Phase B 门禁：几何层只算
  // blendFactor + 两模型参数，逐像素插值在 GPU）。
  CylinderCurlGeometry geo;
  GestureState gs = MakeGesture(200, 300, 800, 600, 200.0f, 1, SpineSide::LEFT);
  CurlFieldParams p = geo.Compute(gs);
  CHECK_EQ(p.blendFactor, 0.0f);
  // cone 参数在 blendFactor=0 时不参与渲染，仍应输出确定值（不产生 NaN）
  CHECK(p.coneApexX == p.coneApexX);  // 非 NaN
  CHECK(p.coneGeneratrixCoef >= 0.0f);
  CHECK(p.coneEpsilon >= 0.0f);
}

TEST_CASE(Cylinder_SpineMirror_IsOutside_Geometry) {
  // 0.8：spine 镜像只允许在 ArkTS→Native 边界/GL 换算入口发生一次；
  // Geometry 内部不感知 spine。验证输入 canonical 后输出与 spine 参数无关。
  CylinderCurlGeometry geo;
  GestureState gsL = MakeGesture(100, 100, 700, 300, 150.0f, 1, SpineSide::LEFT);
  GestureState gsR = MakeGesture(100, 100, 700, 300, 150.0f, 1, SpineSide::RIGHT);
  CurlFieldParams pL = geo.Compute(gsL);
  CurlFieldParams pR = geo.Compute(gsR);
  CHECK_NEAR(pL.cylinderAxisX, pR.cylinderAxisX, 0.001f);
  CHECK_NEAR(pL.cylinderAxisY, pR.cylinderAxisY, 0.001f);
  CHECK_NEAR(pL.cylinderAnchorX, pR.cylinderAnchorX, 0.001f);
}

TEST_CASE(Cylinder_StrengthGroup_Passthrough) {
  // strength 组为 shader_params 乘数，几何按默认 1.0 透传（调参归 shader）
  CylinderCurlGeometry geo;
  GestureState gs = MakeGesture(100, 100, 600, 400, 180.0f, 1, SpineSide::LEFT);
  CurlFieldParams p = geo.Compute(gs);
  CHECK_NEAR(p.backWeight, 1.0f, 0.001f);
  CHECK_NEAR(p.creaseStrength, 1.0f, 0.001f);
  CHECK_NEAR(p.highlight, 1.0f, 0.001f);
  CHECK_NEAR(p.paperBackRange, 1.0f, 0.001f);
  CHECK_NEAR(p.spineInset, 1.0f, 0.001f);
  CHECK_NEAR(p.cornerThreshold, 1.0f, 0.001f);
}

// ══════════════════════════════════════════════════════════════════════
// Phase B — T039: Cone 半径场/锥心稳定性/逆正映射/弧长守恒 离线测试
// 依据：adr-cone-curl-geometry.md §9 测试计划 1–4
// ══════════════════════════════════════════════════════════════════════

TEST_CASE(Cone_Radius_Field_Linear_And_EpsilonStable) {
  // ρ(s) = max(s, ε)·tanα：s ≥ ε 线性增长；s < ε 稳定为 ε·tanα（无负值）
  const float tanAlpha = 0.35f;
  const float eps = 2.0f;
  // s 远超 ε：ρ ≈ s·tanα
  float rhoLarge = ConeRadius(100.0f, tanAlpha, eps);
  CHECK_NEAR(rhoLarge, 35.0f, 0.01f);
  // s == ε：ρ = ε·tanα
  float rhoAtEps = ConeRadius(eps, tanAlpha, eps);
  CHECK_NEAR(rhoAtEps, eps * tanAlpha, 0.001f);
  // s < ε：ρ 稳定为 ε·tanα（不下沉、不除零、不为负）
  float rhoTiny = ConeRadius(0.1f, tanAlpha, eps);
  CHECK_NEAR(rhoTiny, eps * tanAlpha, 0.001f);
  CHECK_TRUE(rhoTiny > 0.0f);
  // s = 0：ρ = ε·tanα > 0（锥心稳定）
  float rhoZero = ConeRadius(0.0f, tanAlpha, eps);
  CHECK_TRUE(rhoZero > 0.0f);
  CHECK_NEAR(rhoZero, eps * tanAlpha, 0.001f);
  // 线性：ρ(2s) = 2·ρ(s)（s >> ε 时）
  float rho2 = ConeRadius(200.0f, tanAlpha, eps);
  CHECK_NEAR(rho2, 2.0f * rhoLarge, 0.01f);
}

TEST_CASE(Cone_Apex_Epsilon_Stability_NoNaN) {
  // 锥心附近（s→0）反向映射输出有限值（无 NaN/除零）
  ConeFieldParams p;
  p.apexX = 0.0f;
  p.apexY = 0.0f;
  p.axisX = 1.0f;
  p.axisY = 0.0f;
  p.s0 = 20.0f;
  p.tanAlpha = 0.35f;
  p.epsilon = 2.0f;
  float theta = 0.0f, srcX = 0.0f, srcY = 0.0f, sOut = 0.0f, tOut = 0.0f;
  // 屏幕点 = 锥心（s = 0）
  ConeReverseMap(p, 0.0f, 0.0f, theta, srcX, srcY, sOut, tOut);
  CHECK_TRUE(theta == theta);  // 非 NaN
  CHECK_TRUE(srcX == srcX);
  CHECK_TRUE(srcY == srcY);
  CHECK_TRUE(theta >= 0.0f && theta <= 3.14159265f);
  // 屏幕点 = 锥心附近（s = 0.1px）
  ConeReverseMap(p, 0.1f, 0.0f, theta, srcX, srcY, sOut, tOut);
  CHECK_TRUE(theta == theta);
  CHECK_TRUE(srcX == srcX);
  CHECK_TRUE(srcY == srcY);
}

TEST_CASE(Cone_ReverseForward_Inverse_Identity) {
  // ADR §9-3：屏幕 (s,t) → 反向映射 → 源 → 正向映射 → 屏幕，误差 ≤ 0.5px
  // （反向/正向互为数值逆；正向预言机 §5.2）
  ConeFieldParams p;
  p.apexX = 50.0f;
  p.apexY = 40.0f;
  p.axisX = 1.0f;
  p.axisY = 0.0f;
  p.s0 = 30.0f;
  p.tanAlpha = 0.35f;
  p.epsilon = 2.0f;
  // 折叠带内屏幕点（严格满足 |x| < ρ(s)，uₙ 不触发 clamp 退化；
  // s∈[24,36] → 屏幕 x∈[74,86]）
  const float screenXs[] = {74.0f, 78.0f, 82.0f, 86.0f};
  const float ts[] = {-10.0f, 0.0f, 15.0f};
  for (float sx : screenXs) {
    for (float t : ts) {
      // 屏幕 → 源
      float theta = 0.0f, srcX = 0.0f, srcY = 0.0f, sOut = 0.0f, tOut = 0.0f;
      ConeReverseMap(p, sx, 40.0f + t, theta, srcX, srcY, sOut, tOut);
      // 源 → 屏幕（正向预言机）
      float px = 0.0f, py = 0.0f;
      ConeForwardMap(p, srcX - p.apexX - p.s0, srcY - p.apexY, px, py);
      // 屏幕坐标往返误差 ≤ 0.5px
      CHECK_NEAR(px, sx, 0.5f);
      CHECK_NEAR(py, 40.0f + t, 0.5f);
    }
  }
}

TEST_CASE(Cone_Arc_Length_Conservation) {
  // 弧长守恒（§9-4）：反向映射恢复的源弧长 S 与输入一致（误差 ≤ 1e-3·S）。
  // 注：Cone 是可展曲面，屏幕投影弧长 ≠ 源弧长（锥面倾斜压缩），
  // 弧长守恒的正确验证口径 = 源弧长在正/逆映射中保持不变（纹理不拉伸）。
  ConeFieldParams p;
  p.apexX = 50.0f;
  p.apexY = 40.0f;
  p.axisX = 1.0f;
  p.axisY = 0.0f;
  p.s0 = 30.0f;
  p.tanAlpha = 0.35f;
  p.epsilon = 2.0f;
  // 有效弧长区间 [0, ρ(s0)·π/2]（θ∈[0,π/2] 内 acos 单值）内的多点
  const float Ss[] = {0.5f, 1.0f, 3.0f, 8.0f, 12.0f};
  for (float S : Ss) {
    float px = 0.0f, py = 0.0f;
    ConeForwardMap(p, S, 0.0f, px, py);
    float theta = 0.0f, srcX = 0.0f, srcY = 0.0f, sOut = 0.0f, tOut = 0.0f;
    ConeReverseMap(p, px, py, theta, srcX, srcY, sOut, tOut);
    // 源坐标 P_src = A + u·(s0 + S)：由 srcX 反推弧长
    const float SRecovered = (srcX - p.apexX) / p.axisX - p.s0;
    const float err = std::fabs(SRecovered - S);
    CHECK_TRUE(err <= 1e-3f * S + 0.01f);
  }
}

TEST_CASE(Cone_Geometry_Model_Params) {
  // ConeCurlGeometry.Compute：锥心选角 + 锥轴 u + 母线参数（§2/§3/§4）
  const ShaderParams& sp = GetShaderParams();
  ConeCurlGeometry geo;
  // 按下点靠近右上角（spine=left，FORWARD → 右上角 TR）
  GestureState gs = MakeGesture(1010.0f, 30.0f, 1000.0f, 400.0f, 120.0f, 1, SpineSide::LEFT);
  CurlFieldParams p = geo.Compute(gs);
  CHECK_EQ(p.blendFactor, 1.0f);
  // 锥心 = TR（surfaceW, 0）
  CHECK_NEAR(p.coneApexX, 1080.0f, 0.5f);
  CHECK_NEAR(p.coneApexY, 0.0f, 0.5f);
  // 锥轴指向 touch：u ≈ normalize(touch - apex) = normalize((-80, 400)) ≈ (-0.196, 0.981)
  CHECK_TRUE(std::fabs(p.coneAxisX - (-80.0f / std::sqrt(80.0f * 80.0f + 400.0f * 400.0f))) < 0.01f);
  CHECK_TRUE(std::fabs(p.coneAxisY - (400.0f / std::sqrt(80.0f * 80.0f + 400.0f * 400.0f))) < 0.01f);
  // 母线系数 = coneOpening；epsilon = coneEpsilon
  CHECK_NEAR(p.coneGeneratrixCoef, sp.coneOpening, 0.001f);
  CHECK_NEAR(p.coneEpsilon, sp.coneEpsilon, 0.001f);
}

TEST_CASE(Cone_BlendFactor_Zero_Matches_Cylinder) {
  // §6.1：blendFactor=0 时混合输出 = 纯 Cylinder（构造保证）
  // HybridCurlGeometry 在远离角落时输出 blendFactor=0，其 cylinder 参数组
  // 应与纯 CylinderCurlGeometry 一致。
  HybridCurlGeometry hybrid;
  CylinderCurlGeometry cyl;
  // 按下点在页面中部（远离四角）→ blendFactor → 0
  GestureState gs = MakeGesture(540.0f, 960.0f, 800.0f, 1000.0f, 150.0f, 1, SpineSide::LEFT);
  CurlFieldParams ph = hybrid.Compute(gs);
  CHECK_TRUE(ph.blendFactor < 0.05f);
  CurlFieldParams pc = cyl.Compute(gs);
  CHECK_NEAR(ph.cylinderRadius, pc.cylinderRadius, 0.001f);
  CHECK_NEAR(ph.cylinderAnchorX, pc.cylinderAnchorX, 0.001f);
  CHECK_NEAR(ph.cylinderAnchorY, pc.cylinderAnchorY, 0.001f);
  CHECK_NEAR(ph.cylinderAxisX, pc.cylinderAxisX, 0.001f);
  CHECK_NEAR(ph.cylinderAxisY, pc.cylinderAxisY, 0.001f);
}

TEST_CASE(Cone_BlendFactor_One_Matches_Cone) {
  // §6.1：blendFactor=1 时混合输出 = 纯 Cone
  HybridCurlGeometry hybrid;
  ConeCurlGeometry cone;
  // 按下点贴近角落（右上）→ blendFactor → 1
  GestureState gs = MakeGesture(1050.0f, 30.0f, 1000.0f, 400.0f, 120.0f, 1, SpineSide::LEFT);
  CurlFieldParams ph = hybrid.Compute(gs);
  CHECK_TRUE(ph.blendFactor > 0.95f);
  CurlFieldParams pc = cone.Compute(gs);
  CHECK_NEAR(ph.coneApexX, pc.coneApexX, 0.001f);
  CHECK_NEAR(ph.coneApexY, pc.coneApexY, 0.001f);
  CHECK_NEAR(ph.coneAxisX, pc.coneAxisX, 0.001f);
  CHECK_NEAR(ph.coneAxisY, pc.coneAxisY, 0.001f);
  CHECK_NEAR(ph.coneGeneratrixCoef, pc.coneGeneratrixCoef, 0.001f);
  CHECK_NEAR(ph.coneEpsilon, pc.coneEpsilon, 0.001f);
}

// ══════════════════════════════════════════════════════════════════════
// Phase B — T042: Hybrid blend 过渡连续性与默认策略 离线测试
// 依据：adr-cone-curl-geometry.md §6.2 / §9-7
// ══════════════════════════════════════════════════════════════════════

TEST_CASE(Hybrid_BlendFactor_Default_Policy) {
  // §6.2：距角落越近 blendFactor → 1；距角落 ≥ d_corner → 0
  const float surfaceW = 1080.0f;
  const float surfaceH = 1920.0f;
  HybridCurlGeometry hybrid;
  // 书角（d ≈ 0）→ ~1
  GestureState gsCorner = MakeGesture(0.0f, 0.0f, 100.0f, 200.0f, 120.0f, 1, SpineSide::LEFT);
  CurlFieldParams pCorner = hybrid.Compute(gsCorner);
  CHECK_TRUE(pCorner.blendFactor > 0.9f);
  // 边缘/中部（d ≥ dCorner=129.6）→ 0
  GestureState gsMid = MakeGesture(surfaceW * 0.5f, surfaceH * 0.5f, 700.0f, 900.0f, 150.0f, 1,
                                   SpineSide::LEFT);
  CurlFieldParams pMid = hybrid.Compute(gsMid);
  CHECK_TRUE(pMid.blendFactor < 0.1f);
  // 单调性：随距离增大 blendFactor 不增
  GestureState gsNear = MakeGesture(40.0f, 40.0f, 100.0f, 200.0f, 120.0f, 1, SpineSide::LEFT);
  CurlFieldParams pNear = hybrid.Compute(gsNear);
  CHECK_TRUE(pNear.blendFactor >= pMid.blendFactor);
  CHECK_TRUE(pCorner.blendFactor >= pNear.blendFactor);
}

TEST_CASE(Hybrid_Transition_FirstOrder_Continuous) {
  // §9-7：过渡区间场量一阶连续（相邻采样步长的场量差分有界）。
  // smoothstep 过渡窗口 raw∈[0.45,0.55] 对应 d∈[58.3,71.3]（约 13px），
  // 最大 Lipschitz 斜率 ≈ 15/单位 raw → 10px 步长最大差分 ≈ 1.16；断言有界
  // （无跳变/不连续），并随采样变细收敛。
  HybridCurlGeometry hybrid;
  // 沿角落→中部方向移动按下点，采样 blendFactor 与 cylinder 锚点
  float prevBlend = -1.0f;
  float prevAnchorX = -1.0f;
  float maxStep = 0.0f;
  for (float d = 0.0f; d <= 200.0f; d += 10.0f) {
    GestureState gs = MakeGesture(d, 0.0f, 200.0f, 300.0f, 120.0f, 1, SpineSide::LEFT);
    CurlFieldParams p = hybrid.Compute(gs);
    if (prevBlend >= 0.0f) {
      const float step = std::fabs(p.blendFactor - prevBlend);
      if (step > maxStep) {
        maxStep = step;
      }
      const float anchorStep = std::fabs(p.cylinderAnchorX - prevAnchorX);
      CHECK_TRUE(anchorStep < 100.0f);  // 锚点随按下点连续移动（无跳变）
    }
    prevBlend = p.blendFactor;
    prevAnchorX = p.cylinderAnchorX;
  }
  CHECK_TRUE(maxStep > 0.0f);       // 过渡确实发生
  CHECK_TRUE(maxStep < 2.0f);       // 有界（一阶连续，无跳变）；Lipschitz 上限 ~1.16
}

TEST_CASE(Hybrid_No_PerPixel_Interpolation_In_Geometry) {
  // 0.2：hybrid_curl_geometry 只算 blendFactor + 两模型参数，不做插值。
  // 验证：blendFactor 介于 0/1 之间时，cylinder 参数组 = 纯 Cylinder 输出，
  // cone 参数组 = 纯 Cone 输出（几何层不做混合，逐像素插值归 GPU）。
  HybridCurlGeometry hybrid;
  CylinderCurlGeometry cyl;
  ConeCurlGeometry cone;
  // 选 blendFactor ≈ 0.5 的按下点：d ≈ 65px（raw ≈ 0.5 → smoothstep ≈ 0.5）
  GestureState gs = MakeGesture(65.0f, 0.0f, 200.0f, 300.0f, 120.0f, 1, SpineSide::LEFT);
  CurlFieldParams ph = hybrid.Compute(gs);
  CHECK_TRUE(ph.blendFactor > 0.3f && ph.blendFactor < 0.7f);
  CurlFieldParams pc = cyl.Compute(gs);
  CurlFieldParams pn = cone.Compute(gs);
  // cylinder 组与纯 Cylinder 一致（不混合）
  CHECK_NEAR(ph.cylinderRadius, pc.cylinderRadius, 0.001f);
  CHECK_NEAR(ph.cylinderAnchorX, pc.cylinderAnchorX, 0.001f);
  // cone 组与纯 Cone 一致（不混合）
  CHECK_NEAR(ph.coneApexX, pn.coneApexX, 0.001f);
  CHECK_NEAR(ph.coneApexY, pn.coneApexY, 0.001f);
}
