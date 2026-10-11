/*
 * gles_render_backend.cpp — EGL + GLES3 渲染后端实现（自原 gl_flip_engine.cpp 拆出）
 *
 * 从原 GlFlipEngine 迁移：InitEGL/QuerySurfaceSize/BuildShaders/CreateTexture/
 * UploadTexture/RenderFrame 中的 GL 部分（makeCurrent、draw、swap、清屏）。
 * 本文件是唯一允许包含 GLES 专属头文件的模块之一（另一个为 engine 编排层
 * 所需的 soloist 生命周期）。
 */
#include "gles_render_backend.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <hilog/log.h>
#include <native_window/external_window.h>

#include <algorithm>
#include <cstring>
#include <map>
#include <utility>

#include "shader/curl_field.common.glsl.h"
#include "shader/composite.frag.h"
#include "shader/shader_params.h"

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "OhEngineGL"
#define LOG_DOMAIN 0x3900
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace flipgl {

namespace {
constexpr int32_t kEglConfigAttribs[] = {
    EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
    EGL_RED_SIZE, 8,
    EGL_GREEN_SIZE, 8,
    EGL_BLUE_SIZE, 8,
    EGL_ALPHA_SIZE, 8,
    EGL_NONE};
constexpr int32_t kEglContextAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};

constexpr const char* kVertexShaderSrc = R"(#version 300 es
layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aUV;
out vec2 vUV;
void main() {
  gl_Position = vec4(aPos, 0.0, 1.0);
  vUV = aUV;
}
)";

constexpr const char* kFragmentShaderHeader = R"(#version 300 es
precision highp float;
in vec2 vUV;
out vec4 fragColor;
uniform vec2 uResolution;
uniform vec2 uTouch;
uniform vec2 uDown;
uniform float uRadius;
uniform float uDir;
uniform float uSpine;
uniform float uBlend;
uniform float uBandWidth;
uniform vec2 uConeApex;
uniform vec2 uConeAxis;
uniform sampler2D uFrontTex;
uniform sampler2D uBackTex;
const float PI = 3.<phone>979;
)";
}  // namespace

// ── EGL / GL 生命周期 ────────────────────────────────────────────────

bool GlesRenderBackend::Init(void* nativeWindow, int surfaceW, int surfaceH) {
  if (nativeWindow == nullptr) {
    LOGE("InitEGL: window null");
    return false;
  }
  nativeWindow_ = nativeWindow;
  surfaceW_ = surfaceW;
  surfaceH_ = surfaceH;

  EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (display == EGL_NO_DISPLAY) {
    LOGE("InitEGL: no display");
    return false;
  }
  EGLint major = 0, minor = 0;
  if (eglInitialize(display, &major, &minor) != EGL_TRUE) {
    LOGE("InitEGL: initialize failed");
    return false;
  }
  EGLConfig config = nullptr;
  EGLint numConfigs = 0;
  if (eglChooseConfig(display, kEglConfigAttribs, &config, 1, &numConfigs) != EGL_TRUE ||
      numConfigs == 0) {
    LOGE("InitEGL: choose config failed");
    return false;
  }
  EGLSurface surface = eglCreateWindowSurface(
      display, config, reinterpret_cast<EGLNativeWindowType>(nativeWindow_), nullptr);
  if (surface == EGL_NO_SURFACE) {
    LOGE("InitEGL: create surface failed: 0x%x", eglGetError());
    return false;
  }
  EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, kEglContextAttribs);
  if (context == EGL_NO_CONTEXT) {
    LOGE("InitEGL: create context failed");
    return false;
  }
  if (eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
    LOGE("InitEGL: make current failed");
    return false;
  }

  EGLint w = 0, h = 0;
  eglQuerySurface(display, surface, EGL_WIDTH, &w);
  eglQuerySurface(display, surface, EGL_HEIGHT, &h);
  surfaceW_ = w;
  surfaceH_ = h;
  eglDisplay_ = display;
  eglSurface_ = surface;
  eglContext_ = context;
  LOGI("InitEGL: surface %{public}dx%{public}d", w, h);

  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

  if (!BuildShaders()) {
    LOGE("InitEGL: build shaders failed");
    return false;
  }
  for (int i = 0; i < 2; i++) {
    frontTex_[i] = CreateTexture();
    backTex_[i] = CreateTexture();
  }
  glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
  glViewport(0, 0, surfaceW_, surfaceH_);
  glClear(GL_COLOR_BUFFER_BIT);
  eglSwapBuffers(display, surface);
  LOGI("InitEGL: initial transparent frame swapped");

  // 全屏 quad 顶点（常量，初始化一次）
  const float vertices[] = {
      -1.0f, -1.0f, 0.0f, 0.0f,  //
      1.0f,  -1.0f, 1.0f, 0.0f,  //
      -1.0f, 1.0f,  0.0f, 1.0f,  //
      1.0f,  1.0f,  1.0f, 1.0f,  //
  };
  glGenVertexArrays(1, &vao_);
  glGenBuffers(1, &vbo_);
  glBindVertexArray(vao_);
  glBindBuffer(GL_ARRAY_BUFFER, vbo_);
  glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), reinterpret_cast<void*>(0));
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                        reinterpret_cast<void*>(2 * sizeof(float)));
  glBindVertexArray(0);
  glBindBuffer(GL_ARRAY_BUFFER, 0);

  // 释放当前线程（OnSurfaceCreated 回调线程）的 EGL current，使 context/surface
  // 可被 soloist 独占线程安全接管。
  eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  ready_ = true;
  return true;
}

void GlesRenderBackend::Resize(int surfaceW, int surfaceH) {
  surfaceW_ = surfaceW;
  surfaceH_ = surfaceH;
  LOGI("Resize: %{public}dx%{public}d", surfaceW_, surfaceH_);
}

bool GlesRenderBackend::BuildShaders() {
  auto compile = [](GLenum type, const char* src) -> GLuint {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, nullptr);
    glCompileShader(sh);
    GLint ok = GL_FALSE;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (ok != GL_TRUE) {
      char log[512] = {0};
      glGetShaderInfoLog(sh, sizeof(log), nullptr, log);
      LOGE("shader compile failed: %{public}s", log);
      glDeleteShader(sh);
      return 0;
    }
    return sh;
  };

  GLuint vs = compile(GL_VERTEX_SHADER, kVertexShaderSrc);
  if (vs == 0) {
    return false;
  }
  // fragment 源码 = 头部(uniform) + shader_params SP_* 宏 + curl_field 库 + 合成主体
  const ShaderParams& sp = GetShaderParams();
  const std::string paramDefines = BuildShaderParamDefines(sp);
  const std::string fsSource = std::string(kFragmentShaderHeader) + paramDefines +
      std::string(kCurlFieldCommonGlsl) + std::string(kCompositeFragGlsl);
  GLuint fs = compile(GL_FRAGMENT_SHADER, fsSource.c_str());
  if (fs == 0) {
    glDeleteShader(vs);
    return false;
  }
  program_ = glCreateProgram();
  glAttachShader(program_, vs);
  glAttachShader(program_, fs);
  glLinkProgram(program_);
  GLint ok = GL_FALSE;
  glGetProgramiv(program_, GL_LINK_STATUS, &ok);
  glDeleteShader(vs);
  glDeleteShader(fs);
  if (ok != GL_TRUE) {
    char log[512] = {0};
    glGetProgramInfoLog(program_, sizeof(log), nullptr, log);
    LOGE("program link failed: %{public}s", log);
    return false;
  }

  uResolution_ = glGetUniformLocation(program_, "uResolution");
  uTouch_ = glGetUniformLocation(program_, "uTouch");
  uDown_ = glGetUniformLocation(program_, "uDown");
  uRadius_ = glGetUniformLocation(program_, "uRadius");
  uDir_ = glGetUniformLocation(program_, "uDir");
  uSpine_ = glGetUniformLocation(program_, "uSpine");
  uBlend_ = glGetUniformLocation(program_, "uBlend");
  uBandWidth_ = glGetUniformLocation(program_, "uBandWidth");
  uConeApex_ = glGetUniformLocation(program_, "uConeApex");
  uConeAxis_ = glGetUniformLocation(program_, "uConeAxis");
  uFrontTex_ = glGetUniformLocation(program_, "uFrontTex");
  uBackTex_ = glGetUniformLocation(program_, "uBackTex");
  return true;
}

GLuint GlesRenderBackend::CreateTexture() {
  GLuint tex = 0;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindTexture(GL_TEXTURE_2D, 0);
  return tex;
}

void GlesRenderBackend::UploadTextureToGpu(GLuint tex, const uint8_t* rgba, int w, int h) {
  glBindTexture(GL_TEXTURE_2D, tex);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
  glBindTexture(GL_TEXTURE_2D, 0);
}

// ── RenderBackend 接口实现 ───────────────────────────────────────────

bool GlesRenderBackend::BeginFrame() {
  if (!ready_ || eglDisplay_ == nullptr || eglSurface_ == nullptr || eglContext_ == nullptr) {
    return false;
  }
  if (!currentOnRenderThread_) {
    if (eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_),
                       static_cast<EGLSurface>(eglSurface_),
                       static_cast<EGLSurface>(eglSurface_),
                       static_cast<EGLContext>(eglContext_)) != EGL_TRUE) {
      LOGE("BeginFrame: eglMakeCurrent failed eglError=0x%x", eglGetError());
      return false;
    }
    currentOnRenderThread_ = true;
  }
  glViewport(0, 0, surfaceW_, surfaceH_);
  glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  return true;
}

void GlesRenderBackend::EndFrame() {
  if (!ready_ || eglDisplay_ == nullptr || eglSurface_ == nullptr) {
    return;
  }
  eglSwapBuffers(static_cast<EGLDisplay>(eglDisplay_), static_cast<EGLSurface>(eglSurface_));
}

void GlesRenderBackend::ClearSurface() {
  // B1 清屏（0.11）：clear 透明 + swap + 释放 EGL current
  if (!ready_ || eglDisplay_ == nullptr || eglSurface_ == nullptr || eglContext_ == nullptr) {
    return;
  }
  if (eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_),
                     static_cast<EGLSurface>(eglSurface_),
                     static_cast<EGLSurface>(eglSurface_),
                     static_cast<EGLContext>(eglContext_)) == EGL_TRUE) {
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    eglSwapBuffers(static_cast<EGLDisplay>(eglDisplay_),
                   static_cast<EGLSurface>(eglSurface_));
    eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_), EGL_NO_SURFACE, EGL_NO_SURFACE,
                   EGL_NO_CONTEXT);
    currentOnRenderThread_ = false;
  } else {
    LOGE("ClearSurface: make current failed eglError=0x%x", eglGetError());
  }
}

TextureHandle GlesRenderBackend::UploadTexture(const uint8_t* rgba, int w, int h) {
  if (!ready_ || rgba == nullptr || w <= 0 || h <= 0) {
    return 0;
  }
  // 上传纹理前临时 makeCurrent（UI 线程）
  bool currentOk = false;
  if (eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_),
                     static_cast<EGLSurface>(eglSurface_),
                     static_cast<EGLSurface>(eglSurface_),
                     static_cast<EGLContext>(eglContext_)) == EGL_TRUE) {
    currentOk = true;
  }
  if (!currentOk) {
    LOGE("UploadTexture: make current failed eglError=0x%x", eglGetError());
    return 0;
  }
  while (glGetError() != GL_NO_ERROR) {
  }
  GLuint tex = CreateTexture();
  UploadTextureToGpu(tex, rgba, w, h);
  const GLenum err = glGetError();
  eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_), EGL_NO_SURFACE, EGL_NO_SURFACE,
                 EGL_NO_CONTEXT);
  currentOnRenderThread_ = false;
  if (err != GL_NO_ERROR) {
    glDeleteTextures(1, &tex);
    LOGE("UploadTexture: upload failed error=0x%x", err);
    return 0;
  }
  static TextureHandle nextHandle = 1;
  TextureHandle handle = nextHandle++;
  textureMap_[handle] = tex;
  return handle;
}

void GlesRenderBackend::ReleaseTexture(TextureHandle tex) {
  auto it = textureMap_.find(tex);
  if (it == textureMap_.end()) {
    return;
  }
  GLuint glTex = it->second;
  textureMap_.erase(it);
  if (eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_),
                     static_cast<EGLSurface>(eglSurface_),
                     static_cast<EGLSurface>(eglSurface_),
                     static_cast<EGLContext>(eglContext_)) == EGL_TRUE) {
    glDeleteTextures(1, &glTex);
    eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_), EGL_NO_SURFACE, EGL_NO_SURFACE,
                   EGL_NO_CONTEXT);
    currentOnRenderThread_ = false;
  } else {
    LOGE("ReleaseTexture: make current failed");
  }
}

void GlesRenderBackend::DrawCurl(const CurlFieldParams& params,
                                 TextureHandle front, TextureHandle back,
                                 int32_t direction, SpineSide spine,
                                 float downX, float downY) {
  if (!ready_ || program_ == 0) {
    return;
  }
  auto fit = textureMap_.find(front);
  auto bit = textureMap_.find(back);
  if (fit == textureMap_.end() || bit == textureMap_.end()) {
    return;
  }
  glUseProgram(program_);
  glUniform2f(uResolution_, static_cast<float>(surfaceW_), static_cast<float>(surfaceH_));
  // Geometry 已产出 canonical 坐标；anchor = 折叠线中心（canonical px）
  glUniform2f(uTouch_, params.cylinderAnchorX, params.cylinderAnchorY);
  glUniform2f(uDown_, downX, downY);
  glUniform1f(uRadius_, params.cylinderRadius);
  glUniform1f(uDir_, static_cast<float>(direction));
  glUniform1f(uSpine_, spine == SpineSide::RIGHT ? 1.0f : 0.0f);
  glUniform1f(uBlend_, params.blendFactor);
  glUniform1f(uBandWidth_, params.cylinderBandWidth);
  // Cone 曲率场参数（0.3 §2/§3；canonical 坐标）
  glUniform2f(uConeApex_, params.coneApexX, params.coneApexY);
  glUniform2f(uConeAxis_, params.coneAxisX, params.coneAxisY);

  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, fit->second);
  glUniform1i(uFrontTex_, 0);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, bit->second);
  glUniform1i(uBackTex_, 1);

  glBindVertexArray(vao_);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glBindVertexArray(0);

  glBindTexture(GL_TEXTURE_2D, 0);
  glUseProgram(0);
}

void GlesRenderBackend::Destroy() {
  if (!ready_) {
    return;
  }
  ready_ = false;
  bool releaseCurrent = false;
  if (eglDisplay_ != nullptr && eglSurface_ != nullptr && eglContext_ != nullptr) {
    releaseCurrent = eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_),
                                    static_cast<EGLSurface>(eglSurface_),
                                    static_cast<EGLSurface>(eglSurface_),
                                    static_cast<EGLContext>(eglContext_)) == EGL_TRUE;
  }
  for (int i = 0; i < 2; i++) {
    if (frontTex_[i] != 0) {
      glDeleteTextures(1, &frontTex_[i]);
      frontTex_[i] = 0;
    }
    if (backTex_[i] != 0) {
      glDeleteTextures(1, &backTex_[i]);
      backTex_[i] = 0;
    }
  }
  for (auto& kv : textureMap_) {
    glDeleteTextures(1, &kv.second);
  }
  textureMap_.clear();
  if (program_ != 0) {
    glDeleteProgram(program_);
    program_ = 0;
  }
  if (vbo_ != 0) {
    glDeleteBuffers(1, &vbo_);
    vbo_ = 0;
  }
  if (vao_ != 0) {
    glDeleteVertexArrays(1, &vao_);
    vao_ = 0;
  }
  if (eglDisplay_ != nullptr) {
    if (releaseCurrent) {
      eglMakeCurrent(static_cast<EGLDisplay>(eglDisplay_), EGL_NO_SURFACE, EGL_NO_SURFACE,
                     EGL_NO_CONTEXT);
    }
    if (eglContext_ != nullptr) {
      eglDestroyContext(static_cast<EGLDisplay>(eglDisplay_), static_cast<EGLContext>(eglContext_));
      eglContext_ = nullptr;
    }
    if (eglSurface_ != nullptr) {
      eglDestroySurface(static_cast<EGLDisplay>(eglDisplay_), static_cast<EGLSurface>(eglSurface_));
      eglSurface_ = nullptr;
    }
    eglTerminate(static_cast<EGLDisplay>(eglDisplay_));
    eglDisplay_ = nullptr;
  }
  currentOnRenderThread_ = false;
}

bool GlesRenderBackend::IsReady() const { return ready_; }
int GlesRenderBackend::SurfaceWidth() const { return surfaceW_; }
int GlesRenderBackend::SurfaceHeight() const { return surfaceH_; }

}  // namespace flipgl
