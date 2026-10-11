/*
 * composite.frag.h — 合成/着色主体（纸背/褶皱阴影/高光/目标页投影）
 *
 * 该 fragment shader 文本在 Renderer（gles_render_backend）构建 shader 源码时
 * 与以下部分拼接：
 *   1. #version + uniform 声明（Renderer 内维护）
 *   2. shader_params.h 生成的 SP_* 宏（唯一真源，0.4/0.5）
 *   3. curl_field.common.glsl.h（唯一曲率场求值数学库，0.2）
 *   4. 本文件（合成 main）
 *
 * 全部视觉/模型调参项引用 SP_* 宏，不内嵌字面量（0.4 审查项）。
 * 本文件不包含卷曲几何推导（归 curl_field.common.glsl.h），仅负责合成。
 */
#pragma once

namespace flipgl {

constexpr const char* kCompositeFragGlsl = R"glsl(
// ── 合成主体（composite.frag）──────────────────────────────────────────

// 纹理采样统一翻转 V：PixelMap 行 0 为图像顶部，而 quad v=0 位于屏幕底部
vec4 flipgl_sample_tex(sampler2D tex, vec2 uv) {
  return texture(tex, vec2(uv.x, 1.0 - uv.y));
}

void main() {
  bool mirrorSpine = uSpine > 0.5;
  vec2 p = vUV * uResolution;
  // canonical 化：spine 镜像只在 Renderer/NAPI 边界发生一次（0.8）；
  // shader 侧 p 仍为 surface 坐标，此处对像素位置做唯一一次镜像归一化。
  vec2 canonicalTouch = uTouch;
  vec2 canonicalDown = uDown;
  if (mirrorSpine) {
    p.x = uResolution.x - p.x;
    canonicalTouch.x = uResolution.x - canonicalTouch.x;
    canonicalDown.x = uResolution.x - canonicalDown.x;
  }

  // 手势 → 卷曲方向/折叠轴（curl_field 公共数学库）
  vec2 drag = canonicalTouch - canonicalDown;
  float dragLength = length(drag);
  vec2 curlDir = flipgl_curl_dir(drag, dragLength, uDir);
  vec2 foldAxis = flipgl_fold_axis(curlDir);

  // 书脊留边（SP_* 宏，唯一真源）
  float spineEdge = clamp(uResolution.x * SP_SPINE_INSET_FRACTION, SP_SPINE_INSET_MIN, SP_SPINE_INSET_MAX);
  canonicalTouch.x = max(canonicalTouch.x, spineEdge);
  float s = dot(p - canonicalTouch, curlDir);
  float t = dot(p - canonicalTouch, foldAxis);
  float radius = max(uRadius, 1.0);
  float aa = max(1.0, min(uResolution.x, uResolution.y) * SP_CREASE_AA_COEFF);
  float dragProgress = clamp(length(uTouch - uDown) / max(uResolution.x, 1.0), 0.0, 1.0);

  // ══ 圆柱曲率场（唯一求值公式位于 curl_field.common.glsl.h）══
  float thetaCyl = flipgl_cylinder_theta(s, radius);
  vec2 srcPosCyl = flipgl_cylinder_src(canonicalTouch, curlDir, foldAxis, s, t, radius, thetaCyl);
  srcPosCyl.x = max(srcPosCyl.x, spineEdge);
  float flatWCyl = 0.0;
  float pageWCyl = 0.0;
  float curlWCyl = 0.0;
  flipgl_zone_weights(s, radius, aa, flatWCyl, pageWCyl, curlWCyl);

  // ══ Cone 曲率场（0.3 §5.1；uBlend > 0 时激活）══
  vec2 coneApex = uConeApex;
  vec2 coneU = uConeAxis;
  vec2 coneF = flipgl_fold_axis(coneU);
  // s0 = 折叠线距锥心距离：s0 = max(dot(canonicalTouch − apex, u), 2ε)（§4）
  float s0 = max(dot(canonicalTouch - coneApex, coneU), 2.0 * SP_CONE_EPSILON);
  float thetaCone = 0.0;
  vec2 srcPosCone = p;
  float sCone = 0.0;
  float tCone = 0.0;
  flipgl_cone_field(p, coneApex, coneU, coneF, s0, SP_CONE_OPENING, SP_CONE_EPSILON,
                    thetaCone, srcPosCone, sCone, tCone);
  // 锥面局部半径（三区权重的带宽）
  float rhoCone = flipgl_cone_radius(sCone, SP_CONE_EPSILON, SP_CONE_OPENING);
  float xCone = sCone - s0;
  float flatWCone = 0.0;
  float pageWCone = 0.0;
  float curlWCone = 0.0;
  flipgl_zone_weights(xCone, max(rhoCone, 1e-3), aa, flatWCone, pageWCone, curlWCone);

  // ══ 逐像素混合（0.2/0.3 §6.1：mix 两分支；blendFactor=0 → 纯 Cylinder）══
  float blend = uBlend;
  float theta = flipgl_blend_interp(thetaCyl, thetaCone, blend);
  vec2 srcPos = flipgl_blend_interp2(srcPosCyl, srcPosCone, blend);
  float flatW = flipgl_blend_interp(flatWCyl, flatWCone, blend);
  float pageW = flipgl_blend_interp(pageWCyl, pageWCone, blend);
  float curlW = flipgl_blend_interp(curlWCyl, curlWCone, blend);

  // 三区权重（flat/curl/page）——已按 blendFactor 混合；无楔形裁剪
  float flatWeight = flatW;
  float curlWeight = curlW;

  // 底页 = 目标页预览（最底层）
  vec4 bottomCol = flipgl_sample_tex(uBackTex, vUV);

  // flat 区：采样 front 纹理（V 翻转已处理）
  vec4 flatCol = flipgl_sample_tex(uFrontTex, vUV);
  float spineWidth = clamp(uResolution.x * SP_SPINE_WIDTH_FRACTION, SP_SPINE_WIDTH_MIN, SP_SPINE_WIDTH_MAX);
  float spineBand = 1.0 - smoothstep(0.0, spineWidth, p.x);
  flatCol.rgb *= 1.0 - SP_SPINE_DARKEN * spineBand;

  // curl 区：源 UV 反向映射（唯一一次 spine 还原）
  vec2 srcUV = clamp(srcPos / uResolution, vec2(0.0), vec2(1.0));
  if (mirrorSpine) {
    srcUV.x = 1.0 - srcUV.x;
  }
  vec4 curlCol = flipgl_sample_tex(uFrontTex, srcUV);

  // 纸背透出（iBooks 纸感）：底页经半透明白色纸基透出
  float backWeight = flipgl_back_weight(theta);
  vec4 backSource = flipgl_sample_tex(uBackTex, srcUV);
  float foldDist = clamp(abs(s) / radius, 0.0, 1.0);
  float paperLight = SP_PAPER_LIGHT_BASE + SP_PAPER_LIGHT_GAIN * pow(1.0 - foldDist, SP_PAPER_LIGHT_POW);
  vec3 paperBack = mix(vec3(SP_PAPER_BASE_R, SP_PAPER_BASE_G, SP_PAPER_BASE_B),
                       backSource.rgb, SP_PAPER_BACK_MIX) * paperLight;
  curlCol = mix(curlCol, vec4(paperBack, curlCol.a), backWeight);

  // 穹顶 Lambert 漫反射（源自圆柱几何）
  float diffuse = SP_DIFFUSE_MIN + SP_DIFFUSE_RANGE * sin(theta);
  float backAo = smoothstep(SP_BACK_AO_START, 1.0, theta / 3.14159265);
  float paperShade = mix(diffuse, SP_PAPER_SHADE_BASE - SP_PAPER_SHADE_AO_GAIN * backAo, backWeight);
  curlCol.rgb *= paperShade;

  // 褶皱接触阴影
  float creaseBand = 1.0 - smoothstep(0.0, max(SP_CREASE_BAND_MIN, radius * SP_CREASE_BAND_WIDTH_FACTOR),
                                      abs(s - (-radius)));
  float creaseShadow = SP_CREASE_SHADOW_STRENGTH * creaseBand *
      (SP_CREASE_SHADOW_BASE + SP_CREASE_SHADOW_PROGRESS_GAIN * dragProgress);
  curlCol.rgb *= 1.0 - creaseShadow;

  // 折叠高光（Fresnel 风格带，沿折叠线）
  float hl = pow(1.0 - clamp(abs(s) / max(radius * SP_HIGHLIGHT_WIDTH_FACTOR, SP_HIGHLIGHT_WIDTH_MIN),
                             0.0, 1.0), SP_HIGHLIGHT_POW);
  float foldHighlight = hl * (SP_HIGHLIGHT_MIN + SP_HIGHLIGHT_MAX * dragProgress) *
      (SP_HIGHLIGHT_THETA_BASE + SP_HIGHLIGHT_THETA_GAIN * sin(theta));
  curlCol.rgb += vec3(SP_HIGHLIGHT_R, SP_HIGHLIGHT_G, SP_HIGHLIGHT_B) * foldHighlight;

  // 目标页投影阴影（底页沿卷曲方向衰减）
  float reveal = smoothstep(radius - aa * 2.0, radius + aa * 2.0, s);
  float distPast = clamp((s - radius) / max(radius, 1.0), 0.0, 1.0);
  float shadowFall = exp(-distPast * SP_BOTTOM_SHADOW_FALLOFF);
  float shadowSpan = 1.0 - smoothstep(radius * SP_SHADOW_SPAN_START, radius * SP_SHADOW_SPAN_END, abs(t));
  float bottomShadow = SP_TARGET_PROJECTION_STRENGTH * reveal * shadowFall * shadowSpan *
      (SP_SHADOW_PROGRESS_BASE + SP_SHADOW_PROGRESS_GAIN * dragProgress);
  bottomCol.rgb *= 1.0 - bottomShadow;

  // 三区合成（bottom 基底 → flat → curl）
  vec4 color = bottomCol;
  color = mix(color, flatCol, flatWeight);
  color = mix(color, curlCol, curlWeight);
  fragColor = vec4(color.rgb, 1.0);
}
)glsl";

}  // namespace flipgl
