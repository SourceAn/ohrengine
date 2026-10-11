/*
 * cylinder_curl_geometry.cpp — Cylinder 曲率场参数计算实现
 */
#include "cylinder_curl_geometry.h"

#include <cmath>

namespace flipgl {

CurlFieldParams CylinderCurlGeometry::Compute(const GestureState& gs) const {
  CurlFieldParams p;
  p.blendFactor = 0.0f;  // 纯 Cylinder

  // 半径透传（由 spring_damper 手感配置计算并 clamp，见 0.4/T018）
  p.cylinderRadius = gs.radius;

  // 拖拽向量（canonical 坐标系）
  const float dx = gs.touchX - gs.downX;
  const float dy = gs.touchY - gs.downY;
  const float len = std::sqrt(dx * dx + dy * dy);

  // 卷曲方向 curlDir（弧长守恒圆柱的唯一方向语义）：
  //  - 有位移：normalize(drag)
  //  - 无位移（down==touch，如合成手势首帧）：按 direction 兜底，与 shader 一致
  float curlDirX = 0.0f;
  float curlDirY = 0.0f;
  if (len > 0.5f) {
    curlDirX = dx / len;
    curlDirY = dy / len;
  } else {
    curlDirX = gs.direction >= 0 ? -1.0f : 1.0f;
    curlDirY = 0.0f;
  }
  // 折叠轴 foldAxis = (-curlDir.y, curlDir.x)（与 gl_flip_shaders.h:71 一致）
  p.cylinderAxisX = -curlDirY;
  p.cylinderAxisY = curlDirX;

  // 锚点 = 折叠线中心 = 当前触摸点（canonical px）
  p.cylinderAnchorX = gs.touchX;
  p.cylinderAnchorY = gs.touchY;

  // 带宽 2R（圆柱卷曲带宽度）
  p.cylinderBandWidth = 2.0f * gs.radius;

  // cone 参数组：Phase B 预留，blendFactor=0 时不被消费；输出确定值避免 NaN
  p.coneApexX = 0.0f;
  p.coneApexY = 0.0f;
  p.coneAxisX = 0.0f;
  p.coneAxisY = 1.0f;
  p.coneGeneratrixCoef = 0.0f;
  p.coneEpsilon = 1e-3f;

  // strength 组：默认 1.0 透传（调参项唯一归属 shader_params.h）
  return p;
}

}  // namespace flipgl
