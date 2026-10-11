/*
 * curl_geometry.h — Geometry 层统一契约（0.1/0.2）
 *
 * 本头文件是 Geometry 层的核心契约，定义：
 *  - CurlModel：模型选择枚举（CYLINDER/CONE/HYBRID，Phase B 预留）
 *  - GestureState：Geometry 的输入（canonical 坐标系 Surface px，spine 已镜像）
 *  - CurlFieldParams：统一曲率场参数结构体（CPU 每帧产出，几十个 float）
 *  - CurlGeometryModel：抽象接口 compute(GestureState) -> CurlFieldParams
 *
 * ⚠️ 硬约束（0.1/FR-016）：本文件与 geometry/ 下所有实现 **禁止包含任何
 * GL / EGL / OHOS 头文件**，保证 host 端离线单测可编译。曲率场逐像素求值
 * 公式只存在于 shader/curl_field.common.glsl.h（GLSL）及其 C++ 镜像实现
 * （离线单测），Renderer（core/ + engine/）不内嵌曲率数学。
 */
#pragma once

#include <cstdint>

namespace flipgl {

/**
 * 不透明纹理句柄（int32，0=无效）。避免在 Geometry/animation 头文件中引入
 * GLES 专属类型（GLuint），保证 host 端离线单测可编译；GLES 实现内部维护
 * 句柄 → GLuint 映射。
 */
using TextureHandle = int32_t;

/** 模型选择枚举（值必须与 ArkTS 侧 CurlModel 枚举一致：0/1/2） */
enum class CurlModel : int32_t {
  CYLINDER = 0,
  CONE = 1,
  HYBRID = 2,
};

/** 书脊方向（0=left 1=right，与现有 spine 参数一致） */
enum class SpineSide : int32_t {
  LEFT = 0,
  RIGHT = 1,
};

/**
 * GestureState — Geometry 的输入状态。
 * 坐标空间：canonical 坐标系（Surface px，spine 已在 ArkTS→Native 边界
 * 镜像一次，见 adr-coordinate-contract.md）。所有数值为 float px。
 */
struct GestureState {
  float downX = 0.0f;       // 按下点（canonical px）
  float downY = 0.0f;
  float touchX = 0.0f;      // 当前触摸点（canonical px）
  float touchY = 0.0f;
  float releaseX = 0.0f;    // 松手点（canonical px，endGesture 时有效）
  float releaseY = 0.0f;
  float radius = 120.0f;    // 有效半径 R（px，由 spring_damper 手感配置计算传入；
                            //   R=|drag|/π 弧长守恒语义，几何层不内嵌调参常量，0.4/T018）
  float surfaceW = 0.0f;    // surface 宽（px）
  float surfaceH = 0.0f;    // surface 高（px）
  int32_t direction = 1;    // 翻页方向：1=FORWARD，-1=BACKWARD（beginGesture 锁定）
  SpineSide spine = SpineSide::LEFT;
};

/**
 * CurlFieldParams — 统一曲率场参数结构体（0.1/0.2/0.5）。
 * CPU Geometry 每帧只计算这一组参数（量级几十个 float），通过 uniform
 * 交给 GPU 逐像素消费；Shader 侧 curl_field.common.glsl.h 根据
 * blendFactor 在 Cylinder/Cone 两条数学分支之间插值。
 * 所有视觉/模型调参项来自 shader_params.h（0.4/0.5），此处不重复定义取值。
 */
struct CurlFieldParams {
  /** 模型混合权重：0=纯 Cylinder，1=纯 Cone（Cylinder 恒为 0） */
  float blendFactor = 0.0f;

  // ── cylinder 参数组 ──────────────────────────────────────────────
  float cylinderRadius = 120.0f;     // 有效半径 R（px）
  float cylinderAxisX = 0.0f;        // 卷曲轴单位向量（fold axis，canonical）
  float cylinderAxisY = 1.0f;
  float cylinderAnchorX = 0.0f;      // 锚点（折叠线中心，canonical px）
  float cylinderAnchorY = 0.0f;
  float cylinderBandWidth = 0.0f;    // 卷曲带宽 2R（px）

  // ── cone 参数组（Phase B 预留，Cone 几何评审通过前不启用） ───────
  float coneApexX = 0.0f;            // 锥心（canonical 四角坐标之一）
  float coneApexY = 0.0f;
  float coneAxisX = 0.0f;            // 锥轴方向单位向量
  float coneAxisY = 1.0f;
  float coneGeneratrixCoef = 0.0f;   // 母线函数系数
  float coneEpsilon = 0.0f;          // 锥心 epsilon 下限（数值稳定）

  // ── strength 组（视觉/模型调参项，取值为 shader_params.h 的乘数） ──
  float backWeight = 1.0f;           // 纸背透出权重
  float creaseStrength = 1.0f;       // 褶皱阴影强度乘数
  float highlight = 1.0f;            // 高光强度乘数
  float paperBackRange = 1.0f;       // 纸背渐变区间乘数
  float spineInset = 1.0f;           // 书脊留边乘数
  float cornerThreshold = 1.0f;      // 角落阈值乘数
};

/**
 * CurlGeometryModel — Geometry 抽象接口。
 * 输入手势状态，输出统一曲率场参数结构体。实现类：CylinderCurlGeometry
 * （Phase A）、ConeCurlGeometry / HybridCurlGeometry（Phase B）。
 * 禁止任何 GL/EGL 符号。
 */
class CurlGeometryModel {
public:
  virtual ~CurlGeometryModel() = default;

  /** 计算曲率场参数。gesture 坐标必须为 canonical 坐标系（spine 已镜像）。 */
  virtual CurlFieldParams Compute(const GestureState& gesture) const = 0;

  /** 返回本模型类型（用于调试/日志与验证） */
  virtual CurlModel Model() const = 0;
};

}  // namespace flipgl
