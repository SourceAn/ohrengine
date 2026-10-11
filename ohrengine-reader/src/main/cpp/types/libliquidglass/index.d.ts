/*
 * libliquidglass.so 的 ArkTS 类型声明
 *
 * 实现来自 liquid-glass.html（经 Apple 原生输出标定并验证），
 * 不是旧失败项目。所有接口第一个参数是 XComponent 的 id。
 */

/** 每层 12 个 float：x,y,w,h,r,kind,opacity,amp,pressX,pressY,carried,pressR */
export const setLayers: (id: string, layers: ArrayBuffer) => void;

/** 13 个 float：blurSigma,specA,specW,sideA,rimK,rimW,refrA,refrW,defrK,sideGain,shadowA,shadowOff,shadowBlur */
export const setGlobal: (id: string, globals: ArrayBuffer) => void;

/** RGBA8888，行序自上而下（与 PixelMap 一致）。会导致模糊缓存失效。 */
export const updateBackground: (id: string, buffer: ArrayBuffer, width: number,
    height: number, rowStridePx: number) => void;

/** 出帧一次，返回是否真的画了 */
export const render: (id: string) => boolean;

/** [frameMs, drawCalls, layerCount, blurCacheHit, blurCacheMiss, programErrors] */
export const getStats: (id: string) => Float32Array;

/** surface 是否已就绪 */
export const isReady: (id: string) => boolean;

/** 释放该实例的 EGL/GL 资源 */
export const dispose: (id: string) => void;
