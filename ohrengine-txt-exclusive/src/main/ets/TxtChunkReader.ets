/**
 * TxtChunkReader — TXT 惰性 Chunk Reader（Phase 9.2）
 *
 * 职责：按字节偏移随机读取 + 解码 + 生命周期可控（打开/关闭/释放）。
 *
 * 设计：
 *   - 延迟打开 fd；readChunk/readRange 通过 fileIo.readSync(fd, buf, {offset, length})
 *     支持任意偏移随机访问；
 *   - 解码内存受控：不缓存整个文件；仅保留最近少量解码 chunk（LRU + 引用计数，
 *     正在被渲染的 chunk 不可淘汰 — 9.6 并发保护）；
 *   - 编码用 util.TextDecoder；BOM 仅文件首部处理；
 *   - 异常（文件被删/修改/越界等）不崩溃，返回失败/空。
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { TxtLazyConfig } from './TxtLazyConfig.ets';

/** 已解码 chunk（带引用计数，供 pin/unpin） */
class DecodedChunk {
  public key: number;
  public text: string;
  public refs: number;
  public lastUsed: number;

  constructor(key: number, text: string) {
    this.key = key;
    this.text = text;
    this.refs = 0;
    this.lastUsed = 0;
  }
}

export class TxtChunkReader {
  private readonly filePath: string;
  private readonly encoding: string;
  private file: fileIo.File | null = null;
  private opened: boolean = false;
  private readonly cache: Map<number, DecodedChunk> = new Map();
  private seq: number = 0;
  private readonly maxCache: number;
  /** BOM 字节数（UTF-8=3，UTF-16=2；其余 0） */
  private readonly bomLength: number;

  constructor(filePath: string, encoding: string) {
    this.filePath = filePath;
    this.encoding = encoding;
    this.maxCache = 6;
    this.bomLength = TxtChunkReader.detectBomLength(encoding);
  }

  private static detectBomLength(encoding: string): number {
    if (encoding === 'utf-8') {
      return 0; // TextDecoder 默认忽略 BOM
    }
    if (encoding === 'utf-16le' || encoding === 'utf-16be') {
      return 2;
    }
    return 0;
  }

  /** 确保 fd 打开（重复开启无害） */
  public ensureOpen(): boolean {
    if (this.opened && this.file !== null) {
      return true;
    }
    try {
      this.file = fileIo.openSync(this.filePath, fileIo.OpenMode.READ_ONLY);
      this.opened = true;
      return true;
    } catch (_e) {
      return false;
    }
  }

  /** 关闭 fd + 清空解码缓存 */
  public close(): void {
    if (this.opened && this.file !== null) {
      try { fileIo.closeSync(this.file); } catch (_e) { }
    }
    this.file = null;
    this.opened = false;
    this.cache.clear();
  }

  /** 按 chunk id 读取并解码（id 为索引 chunk 序号） */
  public readChunk(id: number, chunkStart: number, chunkEnd: number): string | undefined {
    if (!this.ensureOpen()) {
      return undefined;
    }
    const cached: DecodedChunk | undefined = this.cache.get(id);
    if (cached !== undefined) {
      cached.lastUsed = this.seq++;
      return cached.text;
    }
    const text: string | undefined = this.readRange(chunkStart, chunkEnd);
    if (text === undefined) {
      return undefined;
    }
    this.pin(id);
    this.cache.set(id, new DecodedChunk(id, text));
    this.evictIfNeeded();
    return text;
  }

  /** 按任意字节范围读取并解码（偏移随机访问） */
  public readRange(startByte: number, endByte: number): string | undefined {
    if (!this.ensureOpen() || this.file === null || endByte <= startByte) {
      return undefined;
    }
    try {
      const len: number = endByte - startByte;
      const bytes: Uint8Array = new Uint8Array(len);
      const readLen: number = fileIo.readSync(this.file.fd, bytes.buffer, { offset: startByte, length: len });
      if (readLen <= 0) {
        return undefined;
      }
      // BOM 仅在文件首部
      let offset: number = 0;
      if (startByte === 0 && this.bomLength > 0 && readLen >= this.bomLength) {
        offset = this.bomLength;
      }
      const body: Uint8Array = new Uint8Array(readLen - offset);
      for (let i = offset; i < readLen; i++) {
        body[i - offset] = bytes[i];
      }
      const decoder: util.TextDecoder = util.TextDecoder.create(this.encoding);
      return decoder.decodeToString(body);
    } catch (_e) {
      return undefined;
    }
  }

  /** 引用计数：标记正在使用（渲染期间禁止淘汰） */
  public pin(id: number): void {
    const c: DecodedChunk | undefined = this.cache.get(id);
    if (c !== undefined) {
      c.refs++;
    }
  }

  public unpin(id: number): void {
    const c: DecodedChunk | undefined = this.cache.get(id);
    if (c !== undefined && c.refs > 0) {
      c.refs--;
    }
  }

  /** 内存边界：超容量时淘汰未引用的最旧 chunk */
  public evictIfNeeded(): void {
    if (this.cache.size <= this.maxCache) {
      return;
    }
    // 找出最久未用且 refs==0 的
    let victim: DecodedChunk | undefined = undefined;
    const keys: number[] = [];
    this.cache.forEach((_v: DecodedChunk, k: number): void => {
      keys.push(k);
    });
    for (const k of keys) {
      const c: DecodedChunk | undefined = this.cache.get(k);
      if (c !== undefined && c.refs === 0) {
        if (victim === undefined || c.lastUsed < victim.lastUsed) {
          victim = c;
        }
      }
    }
    if (victim !== undefined) {
      this.cache.delete(victim.key);
    }
  }

  /** 清理所有可淘汰缓存（内存压力） */
  public purgeUnreferenced(): void {
    const keys: number[] = [];
    this.cache.forEach((_v: DecodedChunk, k: number): void => {
      keys.push(k);
    });
    for (const k of keys) {
      const c: DecodedChunk | undefined = this.cache.get(k);
      if (c !== undefined && c.refs === 0) {
        this.cache.delete(k);
      }
    }
  }

  public cacheEntries(): number {
    return this.cache.size;
  }
}