/*
 * lg_renderer.cpp — 与 liquid-glass.html 的渲染循环一一对应
 *
 * 刻意不复用旧 glass/liquid_glass_renderer.cpp：那一版的效果是失败的
 * （见 AGENT.md「项目状态：已失败」）。这里只复用 EGL 管路，效果部分全部
 * 照搬已经标定并验证过的 HTML 实现。
 */

#include "lg/lg_renderer.h"
#include "glass/lg_glsl.h"

#include <hilog/log.h>
#include <chrono>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "LiquidGlass"
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO,  LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace lg {

/* 实测档位 —— 与 params.json / liquid-glass.html 的 KINDS 一致 */
const KindParams kKinds[KIND_COUNT] = {
    /* 控制中心·面板：非线性压缩（浅色端饱和，白色 255 → 192） */
    {1.578492f, -0.677146f, -0.149509f, 0.966f},
    /* 控制中心·模块：线性 */
    {0.6810f, 0.0f, 0.116510f, 0.966f},
    /* SDK .regular：透 52%、加大量自身的光 */
    {0.5201f, 0.0f, 0.4099f, 1.10f},
    /* SDK .clear */
    {0.6770f, 0.0f, 0.2786f, 1.10f},
};

static int64_t NowUs() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

void Renderer::Target::Destroy() {
    if (fbo) { glDeleteFramebuffers(1, &fbo); fbo = 0; }
    if (tex) { glDeleteTextures(1, &tex); tex = 0; }
    w = h = 0;
}

Renderer::~Renderer() { Dispose(); }

GLuint Renderer::CompileProgram(const char* vs, const char* fs, const char* tag) {
    auto compile = [&](GLenum type, const char* src, const char* what) -> GLuint {
        GLuint s = glCreateShader(type);
        glShaderSource(s, 1, &src, nullptr);
        glCompileShader(s);
        GLint ok = GL_FALSE;
        glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
        if (!ok) {
            char log[1024] = {0};
            glGetShaderInfoLog(s, sizeof(log) - 1, nullptr, log);
            OH_LOG_ERROR(LogType::LOG_APP, "[%{public}s] %{public}s 编译失败:\n%{public}s",
                         tag, what, log);
            ++programErrors_;
            glDeleteShader(s);
            return 0;
        }
        return s;
    };
    GLuint v = compile(GL_VERTEX_SHADER, vs, "vs");
    GLuint f = compile(GL_FRAGMENT_SHADER, fs, "fs");
    if (!v || !f) { return 0; }
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glLinkProgram(p);
    GLint ok = GL_FALSE;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024] = {0};
        glGetProgramInfoLog(p, sizeof(log) - 1, nullptr, log);
        OH_LOG_ERROR(LogType::LOG_APP, "[%{public}s] 链接失败:\n%{public}s", tag, log);
        ++programErrors_;
        glDeleteProgram(p);
        p = 0;
    }
    glDeleteShader(v);
    glDeleteShader(f);
    return p;
}

bool Renderer::Init(void* window, int32_t width, int32_t height) {
    if (window == nullptr || width <= 0 || height <= 0) { return false; }

    display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display_ == EGL_NO_DISPLAY) { return false; }
    EGLint major = 0, minor = 0;
    if (!eglInitialize(display_, &major, &minor)) { return false; }

    const EGLint attrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLint numConfig = 0;
    if (!eglChooseConfig(display_, attrs, &config_, 1, &numConfig) || numConfig < 1) { return false; }

    /* XComponent 的 NativeWindow 直接当 EGLNativeWindowType 用 */
    surface_ = eglCreateWindowSurface(display_, config_,
                                      reinterpret_cast<EGLNativeWindowType>(window), nullptr);
    if (surface_ == EGL_NO_SURFACE) { return false; }

    const EGLint ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT, ctxAttrs);
    if (context_ == EGL_NO_CONTEXT) { return false; }
    if (!eglMakeCurrent(display_, surface_, surface_, context_)) { return false; }

    surfaceW_ = width;
    surfaceH_ = height;

    /* 全屏三角形：无顶点缓冲，靠 gl_VertexID */
    glGenVertexArrays(1, &vao_);
    glBindVertexArray(vao_);

    progBlur_  = CompileProgram(lg::VS, lg::FS_BLUR,  "blur");
    progCopy_  = CompileProgram(lg::VS, lg::FS_COPY,  "copy");
    progGlass_ = CompileProgram(lg::VS, lg::FS_GLASS, "glass");
    if (!progBlur_ || !progCopy_ || !progGlass_) {
        OH_LOG_ERROR(LogType::LOG_APP, "着色器编译失败，效果必然不对");
        return false;
    }

    glDisable(GL_DEPTH_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_CULL_FACE);

    bgTex_ = 0;
    ready_ = true;
    return true;
}

void Renderer::Dispose() {
    if (display_ == EGL_NO_DISPLAY) { return; }
    eglMakeCurrent(display_, surface_, surface_, context_);
    rtA_.Destroy(); rtB_.Destroy(); rtC_.Destroy(); rtD_.Destroy();
    targetsValid_ = false;
    blurCacheValid_ = false;
    if (bgTex_) { glDeleteTextures(1, &bgTex_); bgTex_ = 0; }
    if (vao_) { glDeleteVertexArrays(1, &vao_); vao_ = 0; }
    if (progBlur_) { glDeleteProgram(progBlur_); progBlur_ = 0; }
    if (progCopy_) { glDeleteProgram(progCopy_); progCopy_ = 0; }
    if (progGlass_) { glDeleteProgram(progGlass_); progGlass_ = 0; }
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (surface_ != EGL_NO_SURFACE) { eglDestroySurface(display_, surface_); surface_ = EGL_NO_SURFACE; }
    if (context_ != EGL_NO_CONTEXT) { eglDestroyContext(display_, context_); context_ = EGL_NO_CONTEXT; }
    eglTerminate(display_);
    display_ = EGL_NO_DISPLAY;
    ready_ = false;
}

void Renderer::Resize(int32_t width, int32_t height) {
    if (width <= 0 || height <= 0) { return; }
    if (width == surfaceW_ && height == surfaceH_) { return; }
    surfaceW_ = width;
    surfaceH_ = height;
    eglMakeCurrent(display_, surface_, surface_, context_);
    targetsValid_ = false;
    blurCacheValid_ = false;
}

bool Renderer::CreateTarget(Target& t, int32_t w, int32_t h) {
    t.Destroy();
    glGenTextures(1, &t.tex);
    glBindTexture(GL_TEXTURE_2D, t.tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glGenFramebuffers(1, &t.fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, t.fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t.tex, 0);
    const GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (st != GL_FRAMEBUFFER_COMPLETE) {
        OH_LOG_ERROR(LogType::LOG_APP, "FBO 不完整 %{public}dx%{public}d: 0x%{public}x", w, h, st);
        return false;
    }
    t.w = w; t.h = h;
    return true;
}

void Renderer::EnsureTargets(bool force) {
    if (!force && targetsValid_ && rtA_.w == surfaceW_ && rtA_.h == surfaceH_) { return; }
    LOGI("EnsureTargets %{public}dx%{public}d", surfaceW_, surfaceH_);
    CreateTarget(rtA_, surfaceW_, surfaceH_);
    CreateTarget(rtB_, surfaceW_, surfaceH_);
    CreateTarget(rtC_, surfaceW_, surfaceH_);
    CreateTarget(rtD_, surfaceW_, surfaceH_);
    targetsValid_ = true;
    blurCacheValid_ = false;
}

void Renderer::UpdateBackground(const uint8_t* rgba, int32_t width, int32_t height,
                               int32_t rowStridePx) {
    if (rgba == nullptr || width <= 0 || height <= 0) { return; }
    if (!ready_) { return; }
    eglMakeCurrent(display_, surface_, surface_, context_);
    if (!bgTex_) { glGenTextures(1, &bgTex_); }
    glBindTexture(GL_TEXTURE_2D, bgTex_);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (rowStridePx == width || rowStridePx <= 0) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, rgba);
    } else {
        /* PixelMap 行距不紧凑时逐行上传，避免整块重排 */
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, nullptr);
        for (int32_t y = 0; y < height; ++y) {
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, y, width, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                            rgba + static_cast<size_t>(y) * rowStridePx * 4);
        }
    }
    bgW_ = width; bgH_ = height;
    hasBackground_ = true;
    blurCacheValid_ = false;   /* 背景变了，模糊缓存作废 */
}

void Renderer::SetLayers(const Layer* layers, int32_t count) {
    layers_.clear();
    if (layers != nullptr && count > 0) {
        layers_.assign(layers, layers + count);
    }
}

void Renderer::SetGlobal(float blurSigma, float specA, float specW, float sideA,
                         float rimK, float rimW, float refrA, float refrW, float defrK,
                         float sideGain, float shadowA, float shadowOff, float shadowBlur, float glowA) {
    blurSigma_ = blurSigma; specA_ = specA; specW_ = specW; sideA_ = sideA;
    rimK_ = rimK; rimW_ = rimW; refrA_ = refrA; refrW_ = refrW; defrK_ = defrK;
    sideGain_ = sideGain;
    shadowA_ = shadowA; shadowOff_ = shadowOff; shadowBlur_ = shadowBlur; glowA_ = glowA;
    blurCacheValid_ = false;
}

bool Renderer::RenderFrame() {
    if (!ready_) { LOGE("RenderFrame: ready_=false"); return false; }
    const int64_t t0 = NowUs();
    eglMakeCurrent(display_, surface_, surface_, context_);
    EnsureTargets(false);
    if (!targetsValid_) { LOGE("RenderFrame: targets 无效"); return false; }
    drawCalls_ = 0;

    const float W = static_cast<float>(surfaceW_);
    const float H = static_cast<float>(surfaceH_);

    /* ---------- 1) 背景 → rtCur（读上传图片，要翻 y） ---------- */
    glDisable(GL_BLEND);
    glBindFramebuffer(GL_FRAMEBUFFER, rtC_.fbo);
    glViewport(0, 0, surfaceW_, surfaceH_);
    if (hasBackground_) {
        glUseProgram(progCopy_);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, bgTex_);
        glUniform1i(glGetUniformLocation(progCopy_, "uTex"), 0);
        glUniform2f(glGetUniformLocation(progCopy_, "uRes"), W, H);
        glUniform1f(glGetUniformLocation(progCopy_, "uFlip"), 1.0f);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        ++drawCalls_;
    }

    Target* cur = &rtC_;
    Target* nxt = &rtD_;
    Target* tmp = &rtA_;
    Target* blur = &rtB_;

    /* ---------- 2) 逐层 ---------- */
    for (const Layer& L : layers_) {
        /* 2a) 模糊 cur → blur（只有背景变了才重算；模糊只是背景纹理的函数） */
        if (L.w <= 0 || L.h <= 0) { continue; }
        const bool needBlur = !blurCacheValid_ || blurCacheSigma_ != blurSigma_;
        if (needBlur) {
            glDisable(GL_BLEND);
            glUseProgram(progBlur_);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, cur->tex);
            glUniform1i(glGetUniformLocation(progBlur_, "uTex"), 0);
            glUniform2f(glGetUniformLocation(progBlur_, "uTexel"), 1.0f / W, 1.0f / H);
            glUniform1f(glGetUniformLocation(progBlur_, "uSigma"), blurSigma_);

            glBindFramebuffer(GL_FRAMEBUFFER, tmp->fbo);
            glViewport(0, 0, surfaceW_, surfaceH_);
            glUniform2f(glGetUniformLocation(progBlur_, "uDir"), 1.0f, 0.0f);
            glDrawArrays(GL_TRIANGLES, 0, 3); ++drawCalls_;

            glBindFramebuffer(GL_FRAMEBUFFER, blur->fbo);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, tmp->tex);
            glUniform2f(glGetUniformLocation(progBlur_, "uDir"), 0.0f, 1.0f);
            glDrawArrays(GL_TRIANGLES, 0, 3); ++drawCalls_;

            blurCacheValid_ = true;
            blurCacheSigma_ = blurSigma_;
            ++blurCacheMiss_;
        } else {
            ++blurCacheHit_;
        }

        /* 2b) 拷贝 cur → nxt 作底（读 FBO 纹理，不翻 y —— 翻了会逐层镜像） */
        glDisable(GL_BLEND);
        glBindFramebuffer(GL_FRAMEBUFFER, nxt->fbo);
        glViewport(0, 0, surfaceW_, surfaceH_);
        glUseProgram(progCopy_);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, cur->tex);
        glUniform1i(glGetUniformLocation(progCopy_, "uTex"), 0);
        glUniform2f(glGetUniformLocation(progCopy_, "uRes"), W, H);
        glUniform1f(glGetUniformLocation(progCopy_, "uFlip"), 0.0f);
        glDrawArrays(GL_TRIANGLES, 0, 3); ++drawCalls_;

        /* 2c) 画玻璃 */
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(progGlass_);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, blur->tex);
        GLuint p = progGlass_;
        glUniform1i(glGetUniformLocation(p, "uTex"), 0);
        glUniform2f(glGetUniformLocation(p, "uRes"), W, H);
        /* 参数是左上原点，gl_FragCoord 是左下原点 → y 取负 */
        glUniform2f(glGetUniformLocation(p, "uCenter"),
                    L.x + L.w * 0.5f, H - (L.y + L.h * 0.5f));
        glUniform2f(glGetUniformLocation(p, "uHalf"), L.w * 0.5f, L.h * 0.5f);
        glUniform1f(glGetUniformLocation(p, "uRadius"), L.r);

        const KindParams& kp = kKinds[(L.kind >= 0 && L.kind < KIND_COUNT) ? L.kind : 0];
        glUniform1f(glGetUniformLocation(p, "uT1"), kp.t1);
        glUniform1f(glGetUniformLocation(p, "uT2"), kp.t2);
        glUniform1f(glGetUniformLocation(p, "uT0"), kp.t0);
        glUniform1f(glGetUniformLocation(p, "uChroma"), kp.chroma);
        glUniform1f(glGetUniformLocation(p, "uOpacity"), L.opacity);

        glUniform1f(glGetUniformLocation(p, "uSpecA"), specA_);
        glUniform1f(glGetUniformLocation(p, "uSpecW"), specW_);
        glUniform1f(glGetUniformLocation(p, "uSideA"), sideA_);
        glUniform1f(glGetUniformLocation(p, "uSideGain"), sideGain_);
        glUniform1f(glGetUniformLocation(p, "uShadowA"), shadowA_);
        glUniform1f(glGetUniformLocation(p, "uShadowOff"), shadowOff_);
        glUniform1f(glGetUniformLocation(p, "uShadowBlur"), shadowBlur_);
        glUniform1f(glGetUniformLocation(p, "uGlowA"), glowA_);
        // 光晕半径跟着形变半径走，小控件上也铺得开
        const float pr = L.pressR > 1.0f ? L.pressR : 60.0f;
        glUniform1f(glGetUniformLocation(p, "uGlowR"), pr * 0.55f);
        glUniform3f(glGetUniformLocation(p, "uGlowColor"), 1.0f, 0.98f, 0.92f);
        glUniform3f(glGetUniformLocation(p, "uSpecColor"), 0.85f, 0.92f, 1.00f);
        glUniform1f(glGetUniformLocation(p, "uRimK"), rimK_);
        glUniform1f(glGetUniformLocation(p, "uRimW"), rimW_);
        glUniform1f(glGetUniformLocation(p, "uRimOff"), 1.0f);
        glUniform1f(glGetUniformLocation(p, "uRefrA"), refrA_);
        // 折射带宽度按控件短边收窄：16px 的带子在 140px 高的按钮上占 11%，
        // 再乘上剖面长度就是半块控件 —— 小控件必须按比例缩。
        const float shortSide = L.w < L.h ? L.w : L.h;
        float refrW = refrW_;
        const float cap = shortSide * 0.10f;
        if (refrW > cap) { refrW = cap; }
        glUniform1f(glGetUniformLocation(p, "uRefrW"), refrW);
        glUniform1f(glGetUniformLocation(p, "uDefrK"), defrK_);

        const float amp = L.amp + L.carried;
        glUniform2f(glGetUniformLocation(p, "uPress"), L.pressX, H - L.pressY);
        glUniform1f(glGetUniformLocation(p, "uAmp"), amp);
        glUniform1f(glGetUniformLocation(p, "uPressR"), L.pressR > 1.0f ? L.pressR : 60.0f);

        glDrawArrays(GL_TRIANGLES, 0, 3); ++drawCalls_;

        Target* t = cur; cur = nxt; nxt = t;
    }

    /* ---------- 3) 上屏（读 FBO 纹理，不翻 y） ---------- */
    glDisable(GL_BLEND);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, surfaceW_, surfaceH_);
    glUseProgram(progCopy_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, cur->tex);
    glUniform1i(glGetUniformLocation(progCopy_, "uTex"), 0);
    glUniform2f(glGetUniformLocation(progCopy_, "uRes"), W, H);
    glUniform1f(glGetUniformLocation(progCopy_, "uFlip"), 0.0f);
    glDrawArrays(GL_TRIANGLES, 0, 3); ++drawCalls_;

    const EGLBoolean sw = eglSwapBuffers(display_, surface_);
    LOGI("RenderFrame 完成: layers=%{public}zu draws=%{public}d swap=%{public}d eglErr=0x%{public}x",
         layers_.size(), drawCalls_, sw, eglGetError());
    frameMs_ = static_cast<float>(NowUs() - t0) / 1000.0f;
    ++frameIndex_;
    return true;
}

RendererStats Renderer::Stats() const {
    RendererStats s;
    s.frameMs = frameMs_;
    s.drawCalls = drawCalls_;
    s.layerCount = static_cast<int32_t>(layers_.size());
    s.blurCacheHit = blurCacheHit_;
    s.blurCacheMiss = blurCacheMiss_;
    s.programErrors = programErrors_;
    return s;
}

}  // namespace lg
