/**
 * RemoteResourceLoader — 远程资源加载器
 *
 * 职责：
 * - 通过 @ohos.net.http 发起 HTTP/HTTPS GET 请求
 * - 提供内存缓存（Map<string, CacheEntry>）
 * - 支持图片、CSS、字体等二进制/文本资源
 * - 超时控制（默认 5s）
 * - 失败时返回 null 而不阻塞页面渲染
 *
 * 安全约束（ENG-013）：
 * - 默认仅允许 HTTPS（allowHttp 可显式放开，默认关闭）
 * - 单次响应体大小上限（二进制/文本）
 * - 缓存条目数与总字节数上限，超出自动淘汰
 * - 支持通过 abortSignal 取消请求（页面销毁时回收）
 * - 不把完整 URL / 响应正文写入普通日志
 */

import http from '@ohos.net.http';
import { image } from '@kit.ImageKit';

/**
 * 缓存条目
 */
export interface CacheEntry {
  /** 响应数据（文本或二进制） */
  data: Object;
  /** 内容类型 */
  mimeType: string;
  /** 缓存时间戳 */
  timestamp: number;
  /** 是否为二进制数据 */
  isBinary: boolean;
  /** 数据字节数（用于总容量控制） */
  size: number;
}

/**
 * 加载结果
 */
export interface LoadResult {
  success: boolean;
  data: Object | null;
  mimeType: string;
  fromCache: boolean;
}

/**
 * 请求取消令牌（ENG-013）：页面销毁时调用 abort()，进行中的请求会被中止。
 * ArkTS SDK 未提供标准 AbortSignal，使用最小自实现。
 */
export class RequestCanceller {
  private abortedFlag: boolean = false;
  private listeners: Array<() => void> = [];

  get aborted(): boolean {
    return this.abortedFlag;
  }

  /** 触发取消：调用所有监听器（底层 httpRequest.destroy） */
  public abort(): void {
    if (this.abortedFlag) {
      return;
    }
    this.abortedFlag = true;
    for (let i = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i]();
      } catch (_e) {
        // 忽略单个监听器异常
      }
    }
    this.listeners = [];
  }

  /** 注册取消回调；已取消时立即触发 */
  public addEventListener(cb: () => void): void {
    if (this.abortedFlag) {
      cb();
      return;
    }
    this.listeners.push(cb);
  }
}

/**
 * 远程资源加载器
 */
export class RemoteResourceLoader {
  /** 默认缓存 TTL：5 分钟 */
  private static readonly CACHE_TTL_MS: number = 5 * 60 * 1000;
  /** 单次响应体最大字节数（ENG-013）：16 MB */
  private static readonly MAX_RESPONSE_BYTES: number = 16 * 1024 * 1024;
  /** 缓存最大条目数（ENG-013） */
  private static readonly MAX_CACHE_ENTRIES: number = 128;
  /** 缓存总字节数上限（ENG-013）：64 MB */
  private static readonly MAX_CACHE_BYTES: number = 64 * 1024 * 1024;

  private cache: Map<string, CacheEntry> = new Map();
  private pendingRequests: Map<string, Promise<LoadResult>> = new Map();

  /** 是否允许 http://（ENG-013：默认关闭，仅 HTTPS） */
  private allowHttp: boolean = false;

  /**
   * 配置是否允许 http:// 明文请求（ENG-013）。
   * 默认关闭；仅当明确需要兼容老旧远程资源时开启。
   */
  public setAllowHttp(allow: boolean): void {
    this.allowHttp = allow;
  }

  /**
   * 获取二进制资源（如图片）
   *
   * @param url 资源 URL
   * @param signal 可选取消信号（页面销毁时中止请求）
   * @returns 加载结果
   */
  public async fetchBinary(url: string, signal?: RequestCanceller): Promise<LoadResult> {
    return this.fetch(url, true, signal);
  }

  /**
   * 获取文本资源（如 CSS）
   *
   * @param url 资源 URL
   * @param signal 可选取消信号
   * @returns 加载结果
   */
  public async fetchText(url: string, signal?: RequestCanceller): Promise<LoadResult> {
    return this.fetch(url, false, signal);
  }

  /**
   * 获取图片资源并解码为 PixelMap
   *
   * @param url 图片 URL
   * @param signal 可选取消信号
   * @returns PixelMap 或 null
   */
  public async fetchImage(url: string, signal?: RequestCanceller): Promise<image.PixelMap | null> {
    const result: LoadResult = await this.fetch(url, true, signal);
    if (!result.success || result.data === null) {
      return null;
    }
    // 尝试将 ArrayBuffer 解码为 PixelMap
    try {
      const rawData: ArrayBuffer = result.data as ArrayBuffer;
      if (rawData === undefined || rawData.byteLength === 0) {
        return null;
      }
      const imageSource: image.ImageSource = image.createImageSource(rawData);
      const pixelMap: image.PixelMap = await imageSource.createPixelMap();
      imageSource.release();
      // 将解码后的 PixelMap 更新到缓存中
      const mimeType: string = RemoteResourceLoader.extractMimeTypeFromCache(this.cache, url);
      this.cache.set(url, {
        data: pixelMap,
        mimeType: mimeType,
        timestamp: Date.now(),
        isBinary: true,
        size: rawData.byteLength
      });
      return pixelMap;
    } catch (e) {
      return null;
    }
  }

  /**
   * 从缓存中提取 MIME 类型
   */
  private static extractMimeTypeFromCache(cache: Map<string, CacheEntry>, url: string): string {
    const entry: CacheEntry | undefined = cache.get(url);
    if (entry !== undefined) {
      return entry.mimeType;
    }
    return '';
  }

  /**
   * 清除所有缓存
   */
  public clearCache(): void {
    this.cache.clear();
  }

  /**
   * 移除指定 URL 的缓存
   */
  public invalidate(url: string): void {
    this.cache.delete(url);
  }

  /**
   * 获取缓存大小
   */
  public getCacheSize(): number {
    return this.cache.size;
  }

  /**
   * 核心 fetch 方法
   */
  private async fetch(url: string, isBinary: boolean, signal?: RequestCanceller): Promise<LoadResult> {
    // 0. 协议校验（ENG-013）：默认仅 HTTPS
    const lower: string = url.toLowerCase();
    if (!lower.startsWith('https://') && !(this.allowHttp && lower.startsWith('http://'))) {
      return { success: false, data: null, mimeType: '', fromCache: false };
    }

    // 0.5 若已取消，直接返回
    if (signal !== undefined && signal.aborted) {
      return { success: false, data: null, mimeType: '', fromCache: false };
    }

    // 1. 检查缓存
    const cached: CacheEntry | undefined = this.cache.get(url);
    if (cached !== undefined) {
      const age: number = Date.now() - cached.timestamp;
      if (age < RemoteResourceLoader.CACHE_TTL_MS) {
        return {
          success: true,
          data: cached.data,
          mimeType: cached.mimeType,
          fromCache: true
        };
      }
      // 缓存过期，移除
      this.cache.delete(url);
    }

    // 2. 检查是否有正在进行的相同请求
    const pending: Promise<LoadResult> | undefined = this.pendingRequests.get(url);
    if (pending !== undefined) {
      return pending;
    }

    // 3. 发起新请求
    const requestPromise: Promise<LoadResult> = this.doFetch(url, isBinary, signal);
    this.pendingRequests.set(url, requestPromise);

    try {
      const result: LoadResult = await requestPromise;
      return result;
    } finally {
      this.pendingRequests.delete(url);
    }
  }

  /**
   * 执行实际的 HTTP 请求
   */
  private async doFetch(url: string, isBinary: boolean, signal?: RequestCanceller): Promise<LoadResult> {
    let httpRequest: http.HttpRequest | null = null;
    try {
      httpRequest = http.createHttp();

      // 注册取消：signal 触发时 destroy 底层请求（ENG-013）
      if (signal !== undefined) {
        signal.addEventListener(() => {
          if (httpRequest !== null) {
            httpRequest.destroy();
          }
        });
      }

      const response: http.HttpResponse = await httpRequest.request(
        url,
        {
          method: http.RequestMethod.GET,
          connectTimeout: 5000,
          readTimeout: 5000,
          header: {
            'User-Agent': 'OhEngine/1.0',
            'Accept': isBinary ? '*/*' : 'text/css,text/plain,*/*'
          },
          // 二进制资源使用 ArrayBuffer，文本使用 string
          expectDataType: isBinary ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING
        }
      );

      const statusCode: number = response.responseCode;
      if (statusCode < 200 || statusCode >= 300) {
        if (httpRequest !== null) {
          httpRequest.destroy();
          httpRequest = null;
        }
        return { success: false, data: null, mimeType: '', fromCache: false };
      }

      let resultData: Object | null = null;
      let mimeType: string = '';

      // 解析响应头
      const headers: Object = response.header;
      // 从 headers 中提取 content-type
      mimeType = RemoteResourceLoader.extractMimeType(headers);

      // 处理响应数据：对二进制资源不再在这里解码（延迟到 fetchImage）
      if (isBinary) {
        const rawData: ArrayBuffer = response.result as ArrayBuffer;
        if (rawData !== undefined && rawData.byteLength > 0) {
          // 响应体大小上限（ENG-013）
          if (rawData.byteLength > RemoteResourceLoader.MAX_RESPONSE_BYTES) {
            if (httpRequest !== null) {
              httpRequest.destroy();
              httpRequest = null;
            }
            return { success: false, data: null, mimeType: '', fromCache: false };
          }
          resultData = rawData;
        }
      } else {
        const textData: string = response.result as string;
        if (textData !== undefined && textData.length > 0) {
          // 文本按 UTF-8 字节估算上限（ENG-013）
          const textBytes: number = textData.length * 2;
          if (textBytes > RemoteResourceLoader.MAX_RESPONSE_BYTES) {
            if (httpRequest !== null) {
              httpRequest.destroy();
              httpRequest = null;
            }
            return { success: false, data: null, mimeType: '', fromCache: false };
          }
          resultData = textData;
        }
      }

      if (httpRequest !== null) {
        httpRequest.destroy();
        httpRequest = null;
      }

      if (resultData !== null) {
        const size: number = isBinary
          ? (resultData as ArrayBuffer).byteLength
          : (resultData as string).length * 2;
        // 写入缓存（含容量控制）
        this.cache.set(url, {
          data: resultData,
          mimeType: mimeType,
          timestamp: Date.now(),
          isBinary: isBinary,
          size: size
        });
        this.enforceCacheLimits();
      }

      return {
        success: resultData !== null,
        data: resultData,
        mimeType: mimeType,
        fromCache: false
      };
    } catch (e) {
      // 不记录完整 URL/正文（ENG-013）
      return { success: false, data: null, mimeType: '', fromCache: false };
    } finally {
      if (httpRequest !== null) {
        try {
          httpRequest.destroy();
        } catch (_e) {
          // 忽略销毁失败
        }
      }
    }
  }

  /**
   * 缓存容量控制（ENG-013）：条目数 / 总字节数超限时按插入顺序淘汰最旧条目。
   */
  private enforceCacheLimits(): void {
    // 先淘汰超出总字节数上限的条目
    let totalBytes: number = 0;
    this.cache.forEach((entry: CacheEntry) => {
      totalBytes += entry.size;
    });
    const keys: string[] = [];
    this.cache.forEach((_entry: CacheEntry, key: string) => {
      keys.push(key);
    });
    let idx: number = 0;
    while ((this.cache.size > RemoteResourceLoader.MAX_CACHE_ENTRIES ||
      totalBytes > RemoteResourceLoader.MAX_CACHE_BYTES) && idx < keys.length) {
      const key: string = keys[idx];
      const removed: CacheEntry | undefined = this.cache.get(key);
      if (removed !== undefined) {
        this.cache.delete(key);
        totalBytes -= removed.size;
      }
      idx++;
    }
  }

  /**
   * 从响应头中提取 MIME 类型
   */
  private static extractMimeType(headers: Object): string {
    try {
      const headerMap: Record<string, string> = headers as Record<string, string>;
      const keys: string[] = Object.keys(headerMap);
      for (let i: number = 0; i < keys.length; i++) {
        if (keys[i].toLowerCase() === 'content-type') {
          const val: string = headerMap[keys[i]];
          const semiIdx: number = val.indexOf(';');
          if (semiIdx >= 0) {
            return val.substring(0, semiIdx).trim();
          }
          return val.trim();
        }
      }
    } catch (_e) {
    }
    return '';
  }
}
