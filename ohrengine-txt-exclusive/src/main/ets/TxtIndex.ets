/**
 * TxtIndex — TXT 轻量索引（Phase 9.1）
 *
 * 职责：只记录「如何快速找到 TXT 中某段数据」，不保存正文。
 *
 * 结构说明：
 *   - chunks[]: 按换行对齐的字节范围（~CHUNK_TARGET_BYTES），提供随机定位粒度；
 *   - oldChapters[]: TxtChapterDetector 产出的真实章节（含字节范围 + vch 映射）；
 *   - vchapters[]: 由段落流计算出的 vchapter（字节范围 + 旧章内字符偏移 + 标题），
 *     与 eager 路径 expandTxtToVChapters 的切分语义完全一致。
 *
 * 构建方式：流式扫描（顺序读文件 + 增量解码），不允许整文件 String。
 */

export const TXT_INDEX_VERSION: number = 1;

export class ChunkEntry {
  public id: number;
  public startByte: number;
  public endByte: number;
  public startChar: number;
  public endChar: number;

  constructor(id: number, startByte: number, endByte: number, startChar: number, endChar: number) {
    this.id = id;
    this.startByte = startByte;
    this.endByte = endByte;
    this.startChar = startChar;
    this.endChar = endChar;
  }
}

export class OldChapterEntry {
  public index: number;
  public title: string;
  public byteStart: number;
  public byteEnd: number;
  public vchStart: number;
  public vchCount: number;

  constructor(index: number, title: string, byteStart: number, byteEnd: number, vchStart: number, vchCount: number) {
    this.index = index;
    this.title = title;
    this.byteStart = byteStart;
    this.byteEnd = byteEnd;
    this.vchStart = vchStart;
    this.vchCount = vchCount;
  }
}

export class VChapterEntry {
  public id: string;
  public oldChapterIndex: number;
  public title: string;
  public byteStart: number;
  public byteEnd: number;
  public charStart: number;
  public charEnd: number;
  public paraStart: number;
  public paraEnd: number;
  public plainTextLength: number;

  constructor(id: string, oldChapterIndex: number, title: string,
    byteStart: number, byteEnd: number, charStart: number, charEnd: number,
    paraStart: number, paraEnd: number, plainTextLength: number) {
    this.id = id;
    this.oldChapterIndex = oldChapterIndex;
    this.title = title;
    this.byteStart = byteStart;
    this.byteEnd = byteEnd;
    this.charStart = charStart;
    this.charEnd = charEnd;
    this.paraStart = paraStart;
    this.paraEnd = paraEnd;
    this.plainTextLength = plainTextLength;
  }
}

/**
 * TXT 轻量索引（内存态）
 */
export class TxtIndex {
  public version: number = TXT_INDEX_VERSION;
  public fileSize: number = 0;
  public encoding: string = 'utf-8';
  public newlineMode: string = 'lf';
  public contentFingerprint: string = '';
  public chunkSize: number = 0;
  public chunks: ChunkEntry[] = [];
  public oldChapters: OldChapterEntry[] = [];
  public vchapters: VChapterEntry[] = [];
  public totalPlainTextLength: number = 0;
}