/*
 * cylinder_curl_geometry.h — Cylinder Page Curl 几何模型（Phase A，FR-002）
 *
 * 弧长守恒圆柱反向映射（theta=acos(s/R)）的 CPU 侧参数化：本模型**不**做
 * 逐像素计算（那属于 shader 的 curl_field.common.glsl.h），只把手势状态
 * 映射为统一曲率场参数结构体 CurlFieldParams（几十个 float）。
 *
 * 半径 R 的手感调参（R=|drag|/π、阻尼弹簧收敛、上下限）归属
 * animation/spring_damper.h 的可配置项（0.4/T018），本模型不内嵌任何
 * 调参常量，只透传 GestureState.radius。
 *
 * ⚠️ 禁止任何 GL/EGL/OHOS 头文件（host-compilable，离线单测）。
 */
#pragma once

#include "curl_geometry.h"

namespace flipgl {

/** Cylinder 模型实现：输出纯圆柱曲率场参数（blendFactor 恒为 0）。 */
class CylinderCurlGeometry : public CurlGeometryModel {
public:
  CurlFieldParams Compute(const GestureState& gesture) const override;
  CurlModel Model() const override { return CurlModel::CYLINDER; }
};

}  // namespace flipgl
