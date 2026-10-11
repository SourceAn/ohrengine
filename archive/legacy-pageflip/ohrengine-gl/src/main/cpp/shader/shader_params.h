/*
 * shader_params.h — 视觉/模型调参项唯一真源（native 内部，0.4/0.5）
 *
 * 范围界定（0.4）：
 *  - 必须集中管理、禁止裸写字面量：视觉调参项（阴影强度、高光强度、纸背渐变
 *    区间、书脊留边比例、褶皱宽度系数等）与几何模型调参项（角落判定阈值、
 *    半径上下限比例、混合过渡宽度等）。
 *  - 不受限制：数学恒等式中的 0/1/PI、归一化/单位向量运算、clamp 值域边界等
 *    纯算法常量。
 *
 * ArkTS 不允许直接引用本结构体（0.5）。所有具体视觉/物理系数取值由 native
 * 内部决定；Shader（GLSL）侧通过 BuildShaderParamDefines() 生成的 #define
 * 常量引用本表（单一真源）。
 */
#pragma once

#include <string>

namespace flipgl {

struct ShaderParams {
  // ── 书脊留边（spine inset） ─────────────────────────────────────────
  float spineInsetFraction = 0.012f;   // 相对内容宽度比例（原 shader 0.012）
  float spineInsetMinPx = 4.0f;        // 下限（px）
  float spineInsetMaxPx = 24.0f;       // 上限（px）
  // ── 卷曲带宽反走样 ─────────────────────────────────────────────────
  // aa = max(1, min(w,h) * coeff)。1/700 在 877px 宽度下仅 1.25px，折叠边缘
  // 过渡过锐，视觉上易被感知为撕裂/锯齿；放宽到 1/300（≈2.9px）柔和折痕。
  float creaseAACoeff = 1.0f / 300.0f;

  // ── 角落判定阈值（canonical 归一化距离） ────────────────────────────
  float cornerThreshold = 0.12f;       // 12% 判定角落模式

  // ── 纸背渐变区间（theta 弧度系数，×PI） ────────────────────────────
  float paperBackStart = 0.30f;        // PI*0.30
  float paperBackEnd = 0.78f;          // PI*0.78

  // ── 褶皱阴影 ───────────────────────────────────────────────────────
  float creaseShadowStrength = 0.26f;  // 强度系数
  float creaseBandWidthFactor = 0.25f; // 褶皱带宽度 = radius * factor
  float creaseBandMinPx = 10.0f;       // 褶皱带最小宽度（px）
  float creaseShadowBase = 0.30f;      // 阴影随拖拽进度增长基线
  float creaseShadowProgressGain = 0.70f;

  // ── 目标页投影阴影 ─────────────────────────────────────────────────
  float targetProjectionStrength = 0.36f; // 强度系数
  float bottomShadowFalloff = 2.5f;       // exp 衰减系数
  float shadowSpanStart = 0.5f;           // smoothstep 起点（radius 倍数）
  float shadowSpanEnd = 1.6f;             // smoothstep 终点（radius 倍数）
  float shadowProgressBase = 0.30f;
  float shadowProgressGain = 0.70f;

  // ── 高光 ───────────────────────────────────────────────────────────
  float highlightWidthFactor = 0.6f;   // 高光带宽度 = radius * factor
  float highlightWidthMinPx = 8.0f;    // 最小宽度（px）
  float highlightPow = 2.5f;           // 高光衰减幂
  float highlightMin = 0.08f;          // 最小强度
  float highlightMax = 0.18f;          // 随拖拽进度增长上限
  float highlightThetaBase = 0.35f;    // 随 theta 变化基线
  float highlightThetaGain = 0.65f;
  float highlightR = 1.0f;             // 高光颜色
  float highlightG = 0.97f;
  float highlightB = 0.90f;

  // ── 纸背基础色 / 透光 ──────────────────────────────────────────────
  float paperBaseR = 0.94f;
  float paperBaseG = 0.92f;
  float paperBaseB = 0.88f;
  float paperBackMix = 0.80f;          // 纸色与底页混合比例
  float paperLightBase = 0.94f;        // 亮度基线
  float paperLightGain = 0.06f;        // 亮度增益
  float paperLightPow = 1.4f;          // 亮度幂

  // ── 漫反射 / 环境遮蔽 ──────────────────────────────────────────────
  float diffuseMin = 0.40f;            // diffuse = min + range * sin(theta)
  float diffuseRange = 0.60f;
  float backAoStart = 0.55f;           // smoothstep 起点（theta/PI）
  float paperShadeBase = 0.88f;        // 纸背遮蔽基线
  float paperShadeAoGain = 0.18f;

  // ── 书脊阴影（flat 区） ────────────────────────────────────────────
  float spineWidthFraction = 0.018f;   // 书脊阴影带宽度比例
  float spineWidthMinPx = 8.0f;
  float spineWidthMaxPx = 30.0f;
  float spineDarken = 0.18f;           // 书脊压暗强度

  // ── 几何模型调参项 ─────────────────────────────────────────────────
  float radiusMinPx = 40.0f;           // 圆柱半径下限（px）
  float radiusMaxFraction = 0.35f;     // 半径上限 = surfaceW * fraction
  float blendTransitionWidth = 0.05f;  // blendFactor 过渡半宽（0.3 §6.1）

  // ── Cone 几何调参项（0.3/0.4，adr-cone-curl-geometry.md §8） ───────
  float coneEpsilon = 2.0f;            // 锥心半径下限 ε（px，数值稳定）
  float coneOpening = 0.35f;           // 锥张开参数 tanα ∈ (0,1)
  float coneOpeningMax = 0.9f;         // tanα 上限（避免锥面过宽退化）
};

/**
 * 生成 GLSL #define 前缀（单一真源 → GLSL）。
 * 在构建 fragment shader 源码时，将本参数表序列化为 `#define SP_XXX value`
 * 行，供 curl_field.common.glsl.h 与 composite.frag.h 引用。
 */
inline std::string BuildShaderParamDefines(const ShaderParams& p) {
  std::string s;
  auto add = [&s](const char* name, float v) {
    s += "#define SP_";
    s += name;
    s += " ";
    s += std::to_string(v);
    s += "\n";
  };
  add("SPINE_INSET_FRACTION", p.spineInsetFraction);
  add("SPINE_INSET_MIN", p.spineInsetMinPx);
  add("SPINE_INSET_MAX", p.spineInsetMaxPx);
  add("CREASE_AA_COEFF", p.creaseAACoeff);
  add("CORNER_THRESHOLD", p.cornerThreshold);
  add("PAPER_BACK_START", p.paperBackStart);
  add("PAPER_BACK_END", p.paperBackEnd);
  add("CREASE_SHADOW_STRENGTH", p.creaseShadowStrength);
  add("CREASE_BAND_WIDTH_FACTOR", p.creaseBandWidthFactor);
  add("CREASE_BAND_MIN", p.creaseBandMinPx);
  add("CREASE_SHADOW_BASE", p.creaseShadowBase);
  add("CREASE_SHADOW_PROGRESS_GAIN", p.creaseShadowProgressGain);
  add("TARGET_PROJECTION_STRENGTH", p.targetProjectionStrength);
  add("BOTTOM_SHADOW_FALLOFF", p.bottomShadowFalloff);
  add("SHADOW_SPAN_START", p.shadowSpanStart);
  add("SHADOW_SPAN_END", p.shadowSpanEnd);
  add("SHADOW_PROGRESS_BASE", p.shadowProgressBase);
  add("SHADOW_PROGRESS_GAIN", p.shadowProgressGain);
  add("HIGHLIGHT_WIDTH_FACTOR", p.highlightWidthFactor);
  add("HIGHLIGHT_WIDTH_MIN", p.highlightWidthMinPx);
  add("HIGHLIGHT_POW", p.highlightPow);
  add("HIGHLIGHT_MIN", p.highlightMin);
  add("HIGHLIGHT_MAX", p.highlightMax);
  add("HIGHLIGHT_THETA_BASE", p.highlightThetaBase);
  add("HIGHLIGHT_THETA_GAIN", p.highlightThetaGain);
  add("HIGHLIGHT_R", p.highlightR);
  add("HIGHLIGHT_G", p.highlightG);
  add("HIGHLIGHT_B", p.highlightB);
  add("PAPER_BASE_R", p.paperBaseR);
  add("PAPER_BASE_G", p.paperBaseG);
  add("PAPER_BASE_B", p.paperBaseB);
  add("PAPER_BACK_MIX", p.paperBackMix);
  add("PAPER_LIGHT_BASE", p.paperLightBase);
  add("PAPER_LIGHT_GAIN", p.paperLightGain);
  add("PAPER_LIGHT_POW", p.paperLightPow);
  add("DIFFUSE_MIN", p.diffuseMin);
  add("DIFFUSE_RANGE", p.diffuseRange);
  add("BACK_AO_START", p.backAoStart);
  add("PAPER_SHADE_BASE", p.paperShadeBase);
  add("PAPER_SHADE_AO_GAIN", p.paperShadeAoGain);
  add("SPINE_WIDTH_FRACTION", p.spineWidthFraction);
  add("SPINE_WIDTH_MIN", p.spineWidthMinPx);
  add("SPINE_WIDTH_MAX", p.spineWidthMaxPx);
  add("SPINE_DARKEN", p.spineDarken);
  add("RADIUS_MIN", p.radiusMinPx);
  add("RADIUS_MAX_FRACTION", p.radiusMaxFraction);
  add("BLEND_TRANSITION_WIDTH", p.blendTransitionWidth);
  add("CONE_EPSILON", p.coneEpsilon);
  add("CONE_OPENING", p.coneOpening);
  add("CONE_OPENING_MAX", p.coneOpeningMax);
  return s;
}

/** 获取默认调参表（native 内部唯一真源实例，0.5）。 */
inline const ShaderParams& GetShaderParams() {
  static const ShaderParams kParams;
  return kParams;
}

}  // namespace flipgl
