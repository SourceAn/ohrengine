/*
 * gles_render_backend.h — EGL + GLES3 渲染后端实现（T023）
 *
 * 从原 gl_flip_engine.cpp 拆出：EGL 生命周期、shader 构建、纹理管理、
 * 双缓冲纹理 ping-pong、绘制调用与 uniform 注入。实现 RenderBackend 抽象。
 *
 * 职责边界（0.1）：只负责把 CurlFieldParams 灌入 uniform 并 draw，**不内嵌**
 * 任何曲率数学（公式只存在于 shader/curl_field.common.glsl.h 与其 C++ 镜像）。
 */
#pragma once

#include "render_backend.h"

#include <cstdint>
#include <map>
#include <string>

// GLES 专属类型仅存在于实现头文件内部（接口不暴露，0.7）
#include <GLES3/gl3.h>

namespace flipgl {

/**
 * GLES3 RenderBackend 实现。
 * Init 在 OnSurfaceCreated 回调线程调用；DrawCurl/EndFrame 在 soloist 线程调用
 * （BeginFrame 时 makeCurrent）；Destroy 在 OnSurfaceDestroyed 调用。
 */
class GlesRenderBackend : public RenderBackend {
public:
  GlesRenderBackend() = default;
  ~GlesRenderBackend() override = default;

  bool Init(void* nativeWindow, int surfaceW, int surfaceH) override;
  void Resize(int surfaceW, int surfaceH) override;
  bool BeginFrame() override;
  void EndFrame() override;
  void ClearSurface() override;
  void Destroy() override;
  bool IsReady() const override;
  int SurfaceWidth() const override;
  int SurfaceHeight() const override;
  TextureHandle UploadTexture(const uint8_t* rgba, int w, int h) override;
  void ReleaseTexture(TextureHandle tex) override;
  void DrawCurl(const CurlFieldParams& params, TextureHandle front, TextureHandle back,
                int32_t direction, SpineSide spine, float downX, float downY) override;

private:
  bool BuildShaders();
  GLuint CreateTexture();
  void UploadTextureToGpu(GLuint tex, const uint8_t* rgba, int w, int h);

  // EGL / GL 句柄（GLES 专属类型仅存在于实现内部，不暴露到接口）
  void* eglDisplay_ = nullptr;
  void* eglSurface_ = nullptr;
  void* eglContext_ = nullptr;
  void* nativeWindow_ = nullptr;

  GLuint program_ = 0;
  GLuint frontTex_[2] = {0, 0};
  GLuint backTex_[2] = {0, 0};
  int activeTextureSet_ = 0;
  GLuint vao_ = 0;
  GLuint vbo_ = 0;
  // 纹理句柄（不透明 int32）→ GLuint 映射（0.12 纹理事务生命周期管理）
  std::map<TextureHandle, GLuint> textureMap_;
  int surfaceW_ = 0;
  int surfaceH_ = 0;
  bool ready_ = false;
  bool currentOnRenderThread_ = false;

  // uniform location
  GLint uResolution_ = -1;
  GLint uTouch_ = -1;
  GLint uDown_ = -1;
  GLint uRadius_ = -1;
  GLint uDir_ = -1;
  GLint uSpine_ = -1;
  GLint uBlend_ = -1;
  GLint uBandWidth_ = -1;
  GLint uConeApex_ = -1;
  GLint uConeAxis_ = -1;
  GLint uFrontTex_ = -1;
  GLint uBackTex_ = -1;
};

}  // namespace flipgl
