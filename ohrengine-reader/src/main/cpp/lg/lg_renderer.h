/*
 * lg_renderer.h — 液态玻璃渲染器
 *
 * 与 liquid-glass.html 的渲染循环逐条对应，不引入 HTML 里没有的东西：
 *
 *   rtCur ← 背景                      （readTexture，一次 copy）
 *   for 每层:
 *       blur(rtCur, σ) → rtBlur        （横 → rtTmp，纵 → rtBlur，两个不同 FBO）
 *       copy(rtCur → rtNext)           （读 FBO 纹理，不翻 y）
 *       画玻璃到 rtNext（预乘混合）
 *       swap(rtCur, rtNext)
 *   最后 copy(rtCur → 默认帧缓冲)
 *
 * 缓冲分配（少一个就会别名，参数怎么调都不动）：
 *   rtCur / rtNext  合成双缓冲
 *   rtTmp / rtBlur  模糊中间与输出
 */

#ifndef LG_RENDERER_H
#define LG_RENDERER_H

#include <cstdint>
#include <string>
#include <vector>

#include <EGL/egl.h>
#include <GLES3/gl3.h>

namespace lg {

/** 档位 —— 参数见 params.json 的 kinds */
enum Kind : int32_t {
    KIND_SYS_PANEL  = 0,   // 控制中心·面板（实测，非线性压缩）
    KIND_SYS_MODULE = 1,   // 控制中心·模块（实测，线性）
    KIND_REGULAR    = 2,   // SDK glassEffect(.regular)
    KIND_CLEAR      = 3,   // SDK glassEffect(.clear)
    KIND_COUNT      = 4,
};

struct KindParams {
    float t1, t2, t0, chroma;
};

/** 实测档位表。改这里要同步改 params.json 与 liquid-glass.html 的 KINDS。 */
extern const KindParams kKinds[KIND_COUNT];

/** 一层玻璃。坐标是物理像素，左上原点（着色器内部转成左下原点）。 */
struct Layer {
    float x = 0, y = 0, w = 0, h = 0, r = 0;
    int32_t kind = KIND_SYS_PANEL;
    float opacity = 1.0f;

    /* 形变：按压点（左上原点 px）、总形变量 px（弹性 + 塑性）、形变半径 px */
    float pressX = 0, pressY = 0;
    float amp = 0, pressR = 60;

    /* 从上层传下来的形变（力传导），叠加到 amp 上 */
    float carried = 0;
};

struct RendererStats {
    int32_t fps = 0;
    float frameMs = 0;
    int32_t drawCalls = 0;
    int32_t layerCount = 0;
    int32_t blurCacheHit = 0;
    int32_t blurCacheMiss = 0;
    int32_t programErrors = 0;
};

class Renderer {
public:
    Renderer() = default;
    ~Renderer();

    bool Init(void* window, int32_t width, int32_t height);
    void Resize(int32_t width, int32_t height);
    void Dispose();

    /** 上传背景（RGBA8888，行序自上而下，与 PixelMap 一致）。会导致模糊缓存失效。 */
    void UpdateBackground(const uint8_t* rgba, int32_t width, int32_t height, int32_t rowStridePx);

    /** 一次性提交全部层。ArkUI 侧每帧或参数变化时调用。 */
    void SetLayers(const Layer* layers, int32_t count);

    /** 全局参数（模糊 σ、倒角、轮廓、折射）。 */
    void SetGlobal(float blurSigma, float specA, float specW, float sideA,
                   float rimK, float rimW, float refrA, float refrW, float defrK,
                   float sideGain, float shadowA, float shadowOff, float shadowBlur, float glowA);

    /** 出帧一次。返回是否真的画了。 */
    bool RenderFrame();

    RendererStats Stats() const;

    /** 该 id 的对象是否有待处理错误（着色器编译失败等）*/
    int32_t ProgramErrors() const { return programErrors_; }

private:
    struct Target {
        GLuint fbo = 0;
        GLuint tex = 0;
        int32_t w = 0, h = 0;
        bool Valid() const { return fbo != 0; }
        void Destroy();
    };

    bool CreateTarget(Target& t, int32_t w, int32_t h);
    void EnsureTargets(bool force);
    GLuint CompileProgram(const char* vs, const char* fs, const char* tag);

    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLContext context_ = EGL_NO_CONTEXT;
    EGLSurface surface_ = EGL_NO_SURFACE;
    EGLConfig  config_ = nullptr;

    int32_t surfaceW_ = 0, surfaceH_ = 0;

    GLuint vao_ = 0;
    GLuint progBlur_ = 0, progCopy_ = 0, progGlass_ = 0;
    int32_t programErrors_ = 0;

    GLuint bgTex_ = 0;
    int32_t bgW_ = 0, bgH_ = 0;
    bool hasBackground_ = false;

    Target rtA_, rtB_, rtC_, rtD_;   // A/B = 模糊中间与输出；C/D = 合成双缓冲
    bool targetsValid_ = false;

    /* 模糊缓存：模糊只是背景纹理的函数，背景没变就不该重算 */
    bool blurCacheValid_ = false;
    float blurCacheSigma_ = -1;
    int32_t blurCacheHit_ = 0, blurCacheMiss_ = 0;

    std::vector<Layer> layers_;

    /* 全局参数 */
    float blurSigma_ = 30.0f;
    float specA_ = 0.314f, specW_ = 2.0f, sideA_ = 0.047f;
    float sideGain_ = 0.0f;   // 侧边正向高光占比（小控件用 0.55）
    float shadowA_ = 0.0f, shadowOff_ = 0.0f, shadowBlur_ = 24.0f;
    float glowA_ = 0.35f;
    float rimK_ = 0.65f, rimW_ = 1.1f;
    float refrA_ = 22.0f, refrW_ = 16.0f, defrK_ = 0.9f;

    /* 字形表：5 个 float 一组 × KIND_COUNT */
    float kindTable_[KIND_COUNT * 4] = {};

    int32_t drawCalls_ = 0;
    float frameMs_ = 0;
    int32_t frameIndex_ = 0;

    bool ready_ = false;
};

}  // namespace lg

#endif  // LG_RENDERER_H
