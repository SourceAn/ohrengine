/**
 * TxtIndexData — 可持久化的 TXT 轻量索引（Phase 9.1）
 *
 * 只记录偏移与元数据，不保存正文。结构兼容 schema v1：
 *   version / fileSize / encoding / newlineMode / fingerprint(size:mtime) /
 *   chunkSize / chunks[] / oldChapters[] / vchapters[]
 * 提供 toJson / fromJson 用于磁盘命中后复用（避免每次 open 重新扫描）。
 */

import { TxtLazyConfig } from './TxtLazyConfig.ets';

/** 单个 chunk（按换行对齐的字节范围） */
export interface TxtChunkData {
  id: number;
  startByte: number;
  endByte: number;
  startChar: number;
  endChar: number;
}

/** 旧章（第X章 / Page N）字节范围 + vch 映射 */
export interface TxtOldChapterData {
  index: number;
  title: string;
  byteStart: number;
  byteEnd: number;
  vchStart: number;
  vchCount: number;
}

/** vchapter（范围描述符，不含正文） */
export interface TxtVChapterData {
  id: string;
  oldChapterIndex: number;
  title: string;
  byteStart: number;
  byteEnd: number;
  charStart: number;
  charEnd: number;
  paraStart: number;
  paraEnd: number;
  plainTextLength: number;
}

export class TxtIndexData {
  public version: number = TxtLazyConfig.INDEX_VERSION;
  public fileSize: number = 0;
  public mtime: number = 0;
  public encoding: string = 'utf-8';
  public newlineMode: string = 'lf';
  public chunkSize: number = TxtLazyConfig.CHUNK_TARGET_BYTES;
  public detectedMode: boolean = true;
  public chunks: TxtChunkData[] = [];
  public oldChapters: TxtOldChapterData[] = [];
  public vchapters: TxtVChapterData[] = [];
  public totalPlainTextLength: number = 0;

  public toJson(): string {
    const payload: Record<string, Object> = {
      'version': this.version,
      'fileSize': this.fileSize,
      'mtime': this.mtime,
      'encoding': this.encoding,
      'newlineMode': this.newlineMode,
      'chunkSize': this.chunkSize,
      'detectedMode': this.detectedMode,
      'chunks': this.chunks,
      'oldChapters': this.oldChapters,
      'vchapters': this.vchapters,
      'totalPlainTextLength': this.totalPlainTextLength
    };
    return JSON.stringify(payload);
  }

  public static fromJson(json: string): TxtIndexData | null {
    try {
      const raw: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const idx = new TxtIndexData();
      idx.version = Number(raw['version']);
      if (idx.version !== TxtLazyConfig.INDEX_VERSION) {
        return null;
      }
      idx.fileSize = Number(raw['fileSize']);
      idx.mtime = Number(raw['mtime']);
      const enc: Object | undefined = raw['encoding'];
      if (enc === undefined) { return null; }
      idx.encoding = enc as string;
      const nl: Object | undefined = raw['newlineMode'];
      if (nl !== undefined) { idx.newlineMode = nl as string; }
      idx.chunkSize = Number(raw['chunkSize']);
      const dm: Object | undefined = raw['detectedMode'];
      if (dm !== undefined) { idx.detectedMode = Boolean(dm); }
      idx.chunks = (raw['chunks'] as Object[]).map((o: Object): TxtChunkData => {
        const r = o as Record<string, Object>;
        return {
          id: Number(r['id']),
          startByte: Number(r['startByte']),
          endByte: Number(r['endByte']),
          startChar: Number(r['startChar']),
          endChar: Number(r['endChar'])
        };
      });
      idx.oldChapters = (raw['oldChapters'] as Object[]).map((o: Object): TxtOldChapterData => {
        const r = o as Record<string, Object>;
        return {
          index: Number(r['index']),
          title: r['title'] as string,
          byteStart: Number(r['byteStart']),
          byteEnd: Number(r['byteEnd']),
          vchStart: Number(r['vchStart']),
          vchCount: Number(r['vchCount'])
        };
      });
      idx.vchapters = (raw['vchapters'] as Object[]).map((o: Object): TxtVChapterData => {
        const r = o as Record<string, Object>;
        return {
          id: r['id'] as string,
          oldChapterIndex: Number(r['oldChapterIndex']),
          title: r['title'] as string,
          byteStart: Number(r['byteStart']),
          byteEnd: Number(r['byteEnd']),
          charStart: Number(r['charStart']),
          charEnd: Number(r['charEnd']),
          paraStart: Number(r['paraStart']),
          paraEnd: Number(r['paraEnd']),
          plainTextLength: Number(r['plainTextLength'])
        };
      });
      idx.totalPlainTextLength = Number(raw['totalPlainTextLength']);
      return idx;
    } catch (_e) {
      return null;
    }
  }
}