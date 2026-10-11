/*
 * curl_field.common.glsl.h — 唯一曲率场求值数学库（GLSL，0.2）
 *
 * 职责：被 composite.frag.h 文本拼接引用（经 Renderer 构建 shader 源码），
 * 提供与模型无关的隐式曲率场求值函数：
 *  - flipgl_curl_dir / flipgl_fold_axis：由手势向量推导卷曲方向与折叠轴
 *  - flipgl_cylinder_field：弧长守恒圆柱反解（theta=acos(s/R) 核心思路）
 *  - flipgl_corner_wedge：角落楔形裁剪权重（现状 cornerMode 近似，Phase B 由
 *    Cone 分支替换）
 *  - flipgl_zone_weights：三区（flat/curl/page）权重
 *  - flipgl_blend_interp：Cylinder/Cone 逐像素插值结构（Phase B 启用；
 *    blendFactor=0 时与纯 Cylinder 逐像素一致）
 *
 * 常量来源：全部视觉/模型调参项来自 shader_params.h（经 Renderer 生成的
 * SP_* 宏注入，0.4/0.5 唯一真源）。本文件**不内嵌**任何调参字面量。
 *
 * ⚠️ 本文件为纯 GLSL 文本（constexpr const char*），不是可编译 C++；
 * GLSL 端与 C++ 镜像（离线单测）共享同一份设计文档中的公式定义。
 */
#pragma once

namespace flipgl {

constexpr const char* kCurlFieldCommonGlsl = R"glsl(
// ── 曲率场公共数学库（curl_field.common）───────────────────────────────

// 由拖拽向量推导卷曲方向单位向量（无位移时按 direction 兜底）
vec2 flipgl_curl_dir(vec2 drag, float dragLength, float dirSign) {
  if (dragLength > 0.5) {
    return drag / dragLength;
  }
  return vec2(dirSign >= 0.0 ? -1.0 : 1.0, 0.0);
}

// 折叠轴 = 卷曲方向的垂直方向
vec2 flipgl_fold_axis(vec2 curlDir) {
  return vec2(-curlDir.y, curlDir.x);
}

// 角落楔形裁剪权重（现状 cornerMode 近似；Phase B 由 Cone 分支替换）
// canonicalDown 为已镜像的按下点；cornerW/cornerH 为角落判定窗口尺寸
float flipgl_corner_wedge(vec2 p, vec2 canonicalDown, vec2 curlDir, vec2 foldAxis,
                          float radius, float dragLength, float coneLen,
                          float aa, vec2 cornerWindow) {
  float apexS = dot(p - canonicalDown, curlDir);
  float apexT = dot(p - canonicalDown, foldAxis);
  float wedgeHalfW = radius * clamp(apexS / max(coneLen, 1e-4), 0.0, 1.0);
  float wedgeWeight = 1.0 - smoothstep(wedgeHalfW - aa, wedgeHalfW + aa, abs(apexT));
  if (apexS < -aa) {
    wedgeWeight = 0.0;
  }
  return wedgeWeight;
}

bool flipgl_is_corner(vec2 canonicalDown, vec2 cornerWindow) {
  if (canonicalDown.x < cornerWindow.x && canonicalDown.y < cornerWindow.y) {
    return true;
  }
  if (canonicalDown.x > 1.0 - cornerWindow.x && canonicalDown.y < cornerWindow.y) {
    return true;
  }
  if (canonicalDown.x < cornerWindow.x && canonicalDown.y > 1.0 - cornerWindow.y) {
    return true;
  }
  if (canonicalDown.x > 1.0 - cornerWindow.x && canonicalDown.y > 1.0 - cornerWindow.y) {
    return true;
  }
  return false;
}

// 弧长守恒圆柱反解：theta = acos(clamp(s/R, -1, 1))（0.2/FR-002）
float flipgl_cylinder_theta(float s, float radius) {
  return acos(clamp(s / max(radius, 1e-4), -1.0, 1.0));
}

// 圆柱源 UV 反向映射（弧长守恒：theta=0 处源为折叠线本身）
vec2 flipgl_cylinder_src(vec2 anchor, vec2 curlDir, vec2 foldAxis,
                         float s, float t, float radius, float theta) {
  return anchor + curlDir * (radius * theta) + foldAxis * t;
}

// ── Cone 曲率场（0.3 / adr-cone-curl-geometry.md §5.1，Phase B） ──────

// 母线半径场：ρ(s) = max(s, ε)·tanα（§4；s→0 时稳定为 ε·tanα > 0）
float flipgl_cone_radius(float s, float epsilon, float tanAlpha) {
  return max(s, epsilon) * tanAlpha;
}

// 锥心附近数值稳定下限（§7：s→0 除零防护）
float flipgl_cone_epsilon() {
  return SP_CONE_EPSILON;
}

// Cone 反向映射（§5.1）：屏幕像素 P → theta / 源坐标
//   A=锥心、u=锥轴、f=折叠轴、s0=折叠线距锥心距离、tanAlpha=coneOpening
void flipgl_cone_field(vec2 P, vec2 A, vec2 u, vec2 f,
                       float s0, float tanAlpha, float epsilon,
                       out float theta, out vec2 srcPos, out float sOut, out float tOut) {
  float s = dot(P - A, u);                 // 锥轴方向距离
  float t = dot(P - A, f);                 // 折叠轴方向横向偏移
  float x = s - s0;                        // 相对折叠线带内坐标
  float rho = flipgl_cone_radius(s, epsilon, tanAlpha);
  float rhoSafe = max(rho, 1e-4);
  float un = clamp(x / rhoSafe, -1.0, 1.0);
  theta = acos(un);                        // 卷曲角（与 cylinder 同构）
  float S = rho * theta;                   // 源弧长（弧长守恒）
  srcPos = A + u * (s0 + S) + f * t;       // P_src = A + u·(s₀+S) + f·t
  sOut = s;
  tOut = t;
}

// 三区权重（flat/curl/page），smoothstep 边缘无缝隙
void flipgl_zone_weights(float s, float radius, float aa,
                         out float flatW, out float pageW, out float curlW) {
  float bandStart = -radius;
  float bandEnd = radius;
  flatW = 1.0 - smoothstep(bandStart - aa, bandStart + aa, s);
  pageW = 1.0 - smoothstep(bandEnd - aa, bandEnd + aa, s);
  curlW = clamp(pageW - flatW, 0.0, 1.0);
}

// 纸背透出权重（theta 梯度，参数来自 shader_params）
float flipgl_back_weight(float theta) {
  return smoothstep(SP_PAPER_BACK_START * 3.14159265, SP_PAPER_BACK_END * 3.14159265, theta);
}

// Cylinder/Cone 逐像素插值结构（0.2/0.3 §6.1；blendFactor=0 时即纯 Cylinder）
float flipgl_blend_interp(float a, float b, float blendFactor) {
  return mix(a, b, blendFactor);
}

// 向量版本（源坐标/位移逐像素插值）
vec2 flipgl_blend_interp2(vec2 a, vec2 b, float blendFactor) {
  return mix(a, b, blendFactor);
}
)glsl";

}  // namespace flipgl
