/*
 * render_backend.h — 渲染后端抽象接口（0.7 Vulkan 接口余量）
 *
 * 职责：EGL/GLES 生命周期 + 绘制调用编排的抽象层。签名**不暴露**
 * EGLContext/GLuint 等 GLES 专属类型（0.7 裁定），未来接入 Vulkan 只需新增
 * 一个后端实现。
 *
 * 本接口不感知卷曲数学（0.1）：Renderer 只负责把 Geometry 产出的
 * CurlFieldParams 灌入 uniform 并 draw，不内嵌任何曲率公式。
 *
 * ⚠️ 本文件禁止包含任何 GL/EGL/OHOS 头文件（纹理句柄使用不透明整数
 * TextureHandle），保证 host 端离线单测可编译。
 */
#pragma once

#include <cstdint>

#include "../geometry/curl_geometry.h"

namespace flipgl {

/**
 * RenderBackend — 渲染后端抽象。
 * 生命周期：Init(OnSurfaceCreated) → Resize / BeginFrame / DrawCurl /
 * EndFrame → Destroy(OnSurfaceDestroyed)。
 */
class RenderBackend {
public:
  virtual ~RenderBackend() = default;

  /** 初始化（EGL display/surface/context、shader、quad、初始透明帧）。 */
  virtual bool Init(void* nativeWindow, int surfaceW, int surfaceH) = 0;

  /** surface 尺寸变化时更新视口。 */
  virtual void Resize(int surfaceW, int surfaceH) = 0;

  /** 开始一帧（soloist 线程 makeCurrent + clear）。返回 false 表示帧不可渲染。 */
  virtual bool BeginFrame() = 0;

  /** 结束一帧（swap）。 */
  virtual void EndFrame() = 0;

  /** B1 清屏：clear 透明 + swap + 释放 EGL current。 */
  virtual void ClearSurface() = 0;

  /** 销毁全部 GL 资源。 */
  virtual void Destroy() = 0;

  /** 查询就绪状态（EGL surface 有效）。 */
  virtual bool IsReady() const = 0;

  /** 查询 surface 尺寸（px）。 */
  virtual int SurfaceWidth() const = 0;
  virtual int SurfaceHeight() const = 0;

  /**
   * 上传 front/bottom 纹理（双纹理集合 ping-pong 由 engine 层管理）。
   * @return 纹理句柄（不透明整数）；失败返回 0。
   */
  virtual TextureHandle UploadTexture(const uint8_t* rgba, int w, int h) = 0;

  /** 释放指定纹理句柄。 */
  virtual void ReleaseTexture(TextureHandle tex) = 0;

  /**
   * 绘制一帧卷曲。
   * @param params  Geometry 产出的统一曲率场参数（canonical 坐标系 px）
   * @param front   front 纹理句柄
   * @param back    bottom 纹理句柄
   * @param direction 翻页方向（1=FORWARD / -1=BACKWARD，意图级参数，非曲率数学）
   * @param spine   书脊方向（0=left / 1=right）
   * @param downX   按下点 canonical px（uniform 注入；0.8 唯一镜像点之后）
   * @param downY   按下点 canonical py
   */
  virtual void DrawCurl(const CurlFieldParams& params,
                        TextureHandle front, TextureHandle back,
                        int32_t direction, SpineSide spine,
                        float downX, float downY) = 0;
};

}  // namespace flipgl
