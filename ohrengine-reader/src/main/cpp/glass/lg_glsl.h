/*
 * lg_glsl.h — 液态玻璃着色器（与 liquid-glass.html 逐字一致）
 *
 * 这份是从经过 Apple 原生输出标定并验证过的实现里【原样】取出的，
 * 不是重写的。改这里之前先改 liquid-glass.html 并重新验证，再同步过来。
 *
 * 模型（见 glass/README.md）：
 *   全流程 sRGB 编码空间，不做线性化
 *   out = t1·lum + t2·lum² + t0
 *   col = out + (bg − lum)·chroma
 *   + 镜面倒角（上/下边亮、左/右边暗）  + 暗轮廓  + 边缘折射（斜面透镜）
 */

#ifndef LG_GLSL_H
#define LG_GLSL_H

namespace lg {
static const char* VS = R"GLSL(#version 300 es
precision highp float;
const vec2 V[3] = vec2[3](vec2(-1.,-1.), vec2(3.,-1.), vec2(-1.,3.));
void main(){ gl_Position = vec4(V[gl_VertexID], 0., 1.); })GLSL";
static const char* FS_BLUR = R"GLSL(#version 300 es
precision highp float;
uniform sampler2D uTex; uniform vec2 uTexel, uDir; uniform float uSigma;
out vec4 fragColor;
void main(){
  vec2 uv = gl_FragCoord.xy * uTexel;
  float sg = max(uSigma, 0.05);
  float inv = 1.0 / (2.0*sg*sg);
  // 覆盖 ±3σ。只覆盖 ±1.6σ 时截断+重归一化会把核变窄（实测有效 σ 只有设定值的 0.7）
  float stp = max(1.0, floor(sg/10.0));
  int R = int(min(ceil(sg*3.0/stp), 64.0));
  vec4 sum = texture(uTex, uv); float wsum = 1.0;
  for (int i=1;i<=64;i++){
    if (i>R) break;
    float o = float(i)*stp;
    float w = exp(-o*o*inv);
    sum += (texture(uTex, uv+uDir*o*uTexel) + texture(uTex, uv-uDir*o*uTexel)) * w;
    wsum += 2.0*w;
  }
  fragColor = sum / wsum;
})GLSL";
static const char* FS_COPY = R"GLSL(#version 300 es
precision highp float;
uniform sampler2D uTex; uniform vec2 uRes; uniform float uFlip;
out vec4 fragColor;
void main(){
  // uFlip=1 读上传的图片（row0 在顶部，要翻）；uFlip=0 读 FBO 纹理（绝不能翻）
  vec2 uv = gl_FragCoord.xy / uRes;
  fragColor = vec4(texture(uTex, uFlip > 0.5 ? vec2(uv.x, 1.0-uv.y) : uv).rgb, 1.0);
})GLSL";
static const char* FS_GLASS = R"GLSL(#version 300 es
precision highp float;
// 模型（全部由 Apple 原生输出实测反解，见 MEASUREMENT-LOG.md）：
//   out = t1·lum + t2·lum² + t0        （sRGB 编码空间，不做线性化）
//   col = out + (bg − lum)·chroma      （保留色度；纯标量仿射会把玻璃洗成灰）
//   + 层边界外 1px 的暗轮廓
uniform sampler2D uTex; uniform vec2 uRes, uCenter, uHalf;
uniform float uRadius, uT1, uT2, uT0, uChroma, uRimK, uRimW, uRimOff;
uniform float uSpecA, uSpecW, uSideA; uniform vec3 uSpecColor;
uniform float uSideGain;   // 侧边正向高光占比
uniform float uShadowA, uShadowOff, uShadowBlur;   // 外阴影：强度 / 外扩 / 模糊半径
uniform float uGlowA, uGlowR;  uniform vec3 uGlowColor;   // 按压光晕
// 形变：按压点凹陷 + 环状隆起（体积守恒）。法线随之改变，高光/折射自动跟着走
uniform vec2  uPress;    // 按压点（fragCoord）
uniform float uAmp;      // 总形变量（弹性 + 塑性），px，正=中心内凹
uniform float uRefrA;    // 边缘折射位移 px（透镜）
uniform float uRefrW;    // 折射衰减长度 px
uniform float uDefrK;    // 形变引起的额外折射系数
uniform float uPressR;   // 形变半径 px
out vec4 fragColor;
float sdb(vec2 p, vec2 b, float r){
  vec2 q = abs(p) - b + r;
  return min(max(q.x,q.y),0.0) + length(max(q,0.0)) - r;
}
void main(){
  vec2 px = gl_FragCoord.xy;
  vec2 uv = px / uRes;
  vec2 p = px - uCenter;
  float d = sdb(p, uHalf, uRadius);
  float specBoost = 0.0;

  // ---- 形变场 ----
  // 中心凹陷、外圈隆起 —— 不守恒的话看起来是"贴纸缩放"而不是"凝胶"
  // 位移梯度同时驱动折射：玻璃被压薄的地方放大率变化，透过去的内容跟着扭曲
  vec2  uvShift = vec2(0.0);
  if (abs(uAmp) > 0.01){
    vec2  pd = px - uPress;
    float pr = length(pd);
    float R  = max(uPressR, 1.0);
    float fall = exp(-(pr*pr)/(2.0*R*R));
    float ring = fall * (pr/R) * 1.55;          // 峰值在 r≈R
    // 形变量做了软限幅：不夹住的话凹陷会把边缘切穿，SDF 折出 V 形缺口（看起来像两个三角形）
    float amp = uAmp / (1.0 + abs(uAmp)/max(uHalf.y*0.35, 8.0));
    d += amp * (fall - ring*0.42);   // 形变移动轮廓 —— 果冻感的来源，不要拿掉
    specBoost = amp * fall * 0.006;   // 已带 fall，局部化
    // 形变场的梯度 → 折射位移（这才是"玻璃下方内容也跟着动"）
    // 单位是 px：|pd|=R 处位移 = amp*uDefrK（之前写成 pd/R² 只有 0.06px，等于没有）
    // 必须乘 fall：只按 pd/R 是【线性位移场】= 均匀剪切，
    // 剪切在形状边界被硬截断，就会在玻璃内部留下楔形接缝（看起来像两个三角形）
    uvShift = -(pd / R) * amp * uDefrK * fall;
  }

  // 抗锯齿宽度【必须夹上限】。
  // fwidth(d) 是 d 的屏幕空间梯度：形变往 d 上加了一整个场（amp≈12），
  // 它的梯度叠加到原本的单位梯度上会把 fwidth(d) 放大好几倍，
  // smoothstep 的斜坡就从 1px 被拉到 8px —— 表现为形状边界外多出一条
  // 半透明带，看起来像"外面还套着一个胶囊"。
  // 夹住之后无论形变多强，边缘都是清晰的。
  float aa = clamp(fwidth(d)*0.5, 0.75, 1.5);
  float shape = 1.0 - smoothstep(-aa, aa, d);

  // ---- 边缘折射（透镜）----
  // 贴边约 uRefrW 内，采样位置沿法线外移 —— 这是"厚玻璃板"的立体感来源，
  // 也是"玻璃下方有形变"的关键：内容而不只是轮廓在动。
  vec2 e2 = vec2(1.0,0.0);
  vec2 nrm = normalize(vec2(
      sdb(p+e2, uHalf, uRadius) - sdb(p-e2, uHalf, uRadius),
      sdb(p+vec2(0.,1.), uHalf, uRadius) - sdb(p-vec2(0.,1.), uHalf, uRadius)) + 1e-6);
  // 折射剖面必须是【单调衰减】的。
  //
  // 之前用斜面型（边界处 0 → 峰值 → 内部又回到 0），物理上确实对应"倒角两端相切"，
  // 但它会在玻璃内部画出【第二圈边界】：位移离开边界后归零，采样放大率在那里突变，
  // 看起来就是两个套在一起的胶囊。uRefrW=16px 时这个带占 140px 高按钮的 46%，非常明显。
  //
  // 改成从边界向内的单调指数衰减 —— 内部没有第二个零点，就不可能画出第二圈。
  float lens = uRefrA * exp(-max(-d, 0.0) / max(uRefrW, 0.1)) * shape;
  vec2 uvR = clamp(uv + (nrm*lens + uvShift) / uRes, vec2(0.0), vec2(1.0));

  vec3 bg = texture(uTex, uvR).rgb;
  float lum = dot(bg, vec3(0.2126,0.7152,0.0722));
  float lo = lum*uT1 + uT2*lum*lum + uT0;
  vec3 col = vec3(lo) + (bg - vec3(lum)) * uChroma;

  // 暗轮廓落在形状【外】，按"暗化下层"合成，否则会被自己的 discard 杀掉
  float rim = 1.0 - smoothstep(0.0, uRimW, abs(d - uRimOff));
  float rimA = rim * (1.0 - uRimK);

  // ---- 外阴影 ----
  // 用【形变后的 d】算，所以阴影会跟着果冻一起动（原来根本没有阴影通道，
  // 左列的系统材质自带阴影，对比时差得很明显）。
  // 合成方式同暗轮廓：预乘 (0,0,0,a) = 把下层压暗。
  float shadow = 1.0 - smoothstep(0.0, max(uShadowBlur, 0.5), d - uShadowOff);
  float shadowA = shadow * uShadowA * (1.0 - shape);

  // 镜面倒角：上/下边缘 +80 亮边，左/右边缘 −12 压暗（实测，这才像"玻璃"）
  // 必须用 |d|：深处 d 很负，max(d,0) 会恒为 0，高光会糊满整块
  float edge = exp(-abs(d)/max(uSpecW,0.1)) * shape;
  // ---- 边光方向性：按控件长宽比自动切换 ----
  //
  // 实测结论来自 Apple 控制中心那块 810×1080 的大面板（长宽比 1.33）：
  // 上/下边 +80 亮边、左/右边 −12 压暗。方向性很强。
  //
  // 但把它直接套到胶囊按钮上就错了 —— 按钮长宽比 7.5，
  // 沿边缘走一圈时法线不断变化，ny=abs(nrm.y) 从上边的 1 掉到圆角末端的 0，
  // 亮边在圆角处【断掉】。用户一眼就看出来了。
  //
  // 物理上：细长的玻璃棒光会绕着走，边光是均匀一圈的；大面板才有明显方向性。
  // 所以让 uni 随长宽比自动从 0(方向性) 过渡到 1(均匀)，
  // uSideGain 作为手动叠加，两者取较大者。
  float aspect = max(uHalf.x, uHalf.y) / max(min(uHalf.x, uHalf.y), 1.0);
  float uni = smoothstep(1.8, 4.0, aspect);              // 胶囊→1，方面板→0
  float nyEff = mix(abs(nrm.y), 1.0, clamp(uni + uSideGain, 0.0, 1.0));
  col += uSpecColor * (uSpecA * edge * nyEff);
  col -= uSideA * edge * (1.0 - nyEff);
  // 形变处的高光【单独加】，绝不能并进 edge：
  //   ny 来自【未形变】的 SDF 法线。矩形中轴两侧最近边不同，
  //   跨中轴时 nrm 翻转、ny 从 0 跳到 1，跳变边界是直线（把矩形分成 4 个三角区）。
  //   平时 edge≈0 掩盖了它；一旦把 specBoost 并进 edge，整片形变区都乘上跳变的 ny，
  //   就浮现 4 个三角楔 —— 这就是"两个三角形"的真正来源。
  col += uSpecColor * specBoost;

  // ---- 按压光晕 ----
  // 用一圈光晕把按压位置标出来。比"靠轮廓形变判断按在哪"直观得多，
  // 小控件（胶囊、圆形）上尤其明显。强度跟按压深度挂钩，松手自动淡出。
  {
    vec2  gd = px - uPress;
    float gr = length(gd);
    float Rg = max(uGlowR, 1.0);
    float glow = exp(-(gr*gr) / (2.0*Rg*Rg));
    float gk = clamp(uAmp / 6.0, 0.0, 1.0);      // 按下去才亮，松手淡出
    col += uGlowColor * (glow * uGlowA * gk * shape);
  }

  float a = shape;
  // 暗轮廓与阴影都是"压暗下层"，合并成一个等效 alpha
  float darkA = 1.0 - (1.0 - rimA) * (1.0 - shadowA);
  if (a < 0.003 && darkA < 0.003) discard;
  fragColor = vec4(col*a, clamp(a + darkA*(1.0-a), 0.0, 1.0));
})GLSL";

}  // namespace lg

#endif  // LG_GLSL_H
