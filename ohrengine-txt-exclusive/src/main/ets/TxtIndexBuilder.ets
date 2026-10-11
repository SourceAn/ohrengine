/**
 * TxtIndexBuilder — TXT 轻量索引构建器（Phase 9.1）
 *
 * 流式扫描：按窗口读文件 → 增量解码 → 逐行处理 → 运行与 eager 路径一致的
 * （章节检测 + 段落切分 + vchapter 切分）语义，仅记录偏移/长度，不保留正文。
 *
 * Pass 1：统计标题行数（决定 detected / fallback 模式）。
 * Pass 2：按模式建链，产出 TxtIndexData。
 *
 * 反作弊保证：
 *   - 不 readAll()，不会出现整文件 String；
 *   - 单行/单段超上限时降级切段（degraded），防止数百 MB 段落。
 */

import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { extractParagraphs } from 'ohrengine-common';
import { TxtEncodingDetector } from './TxtEncodingDetector.ets';
import { TxtChapterDetector } from './TxtChapterDetector.ets';
import { TxtLazyConfig } from './TxtLazyConfig.ets';
import { TxtConfig } from './TxtConfig.ets';
import { TxtIndexData, TxtOldChapterData, TxtVChapterData } from './TxtIndexData.ets';

/** 单行视图（byte 为源文件偏移；byteEnd 指向行终止符起点） */
export interface TxtLineView {
  text: string;
  byteStart: number;
  byteEnd: number;
}

/**
 * 换行感知的流式扫描器：按窗口读原始字节 → 定位换行单位 → 增量解码完整行。
 *
 * 换行单位（与 normalizeNewlines 语义一致）：
 *   - utf-8 / gb18030：0x0A（1 字节）或 0x0D/0x0D0A（CR/CRLF）
 *   - utf-16le / utf-16be：2 字节码元 0x0A 或 0x0D（偶数对齐）
 * 这些字节模式不会出现在多字节字符内部，因此字节定位精确。
 */
class TxtLineScanner {
  private readonly fd: number;
  private readonly fileSize: number;
  private readonly encoding: string;
  private pending: number[] = [];
  private pendingStart: number = 0;
  private readCursor: number = 0;
  private eof: boolean = false;
  private lines: TxtLineView[] = [];
  private lineIdx: number = 0;
  private decoder: util.TextDecoder;
  private charCursor: number = 0;

  constructor(fd: number, fileSize: number, encoding: string) {
    this.fd = fd;
    this.fileSize = fileSize;
    this.encoding = encoding;
    this.decoder = util.TextDecoder.create(encoding);
  }

  /** 单位长度：局部索引 pos 处是否换行单位起始 */
  private unitLenAt(pos: number): number {
    if (pos >= this.pending.length) {
      return -1;
    }
    if (this.encoding === 'utf-16le' || this.encoding === 'utf-16be') {
      if (pos + 1 >= this.pending.length) {
        return -1;
      }
      const lo: number = this.pending[pos];
      const hi: number = this.pending[pos + 1];
      const unit: number = this.encoding === 'utf-16le' ? (lo | (hi << 8)) : ((lo << 8) | hi);
      return (unit === 0x0A || unit === 0x0D) ? 2 : -1;
    }
    const b: number = this.pending[pos];
    if (b === 0x0A) {
      return 1;
    }
    if (b === 0x0D) {
      return (pos + 1 < this.pending.length && this.pending[pos + 1] === 0x0A) ? 2 : 1;
    }
    return -1;
  }

  /** 找到最后一个换行单位起始位置（局部偏移） */
  private lastUnitStart(): number {
    let last: number = -1;
    let i: number = 0;
    while (i < this.pending.length) {
      const len: number = this.unitLenAt(i);
      if (len > 0) {
        last = i;
        i += len;
      } else {
        i++;
      }
    }
    return last;
  }

  private async fill(): Promise<void> {
    while (!this.eof && this.pending.length < TxtLazyConfig.SCAN_WINDOW_BYTES) {
      const win: number = Math.min(TxtLazyConfig.SCAN_WINDOW_BYTES, this.fileSize - this.readCursor);
      if (win <= 0) {
        this.eof = true;
        break;
      }
      const buf: Uint8Array = new Uint8Array(win);
      const readLen: number = await fileIo.read(this.fd, buf.buffer, { offset: this.readCursor, length: win });
      if (readLen <= 0) {
        this.eof = true;
        break;
      }
      for (let i = 0; i < readLen; i++) {
        this.pending.push(buf[i]);
      }
      this.readCursor += readLen;
      if (this.readCursor >= this.fileSize) {
        this.eof = true;
      }
    }
  }

  /** 解码 [0, len)（起始/结束均对齐字符边界），返回文本 */
  private decodeRegion(len: number): string {
    const bytes: Uint8Array = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
      bytes[i] = this.pending[i];
    }
    return this.decoder.decodeToString(bytes);
  }

  /** 把已解码区域拆为行并加入队列 */
  private emitDecoded(decoded: string, regionLen: number): void {
    const normalized: string = decoded
      .replace(new RegExp('\\r\\n', 'g'), '\n')
      .replace(new RegExp('\\r', 'g'), '\n');
    const parts: string[] = normalized.split('\n');
    // 逐字节收集换行单位起始（仅完整单位；尾部分段待下轮）
    const units: number[] = [];
    let i: number = 0;
    while (i < regionLen) {
      const len: number = this.unitLenAt(i);
      if (len > 0) {
        units.push(i);
        i += len;
      } else {
        i++;
      }
    }
    // parts 数量应与 units 对齐：parts[n] 行文本 ↔ 第 n 个单位前
    const lineCount: number = Math.min(parts.length, units.length + 1);
    for (let n = 0; n < lineCount; n++) {
      const byteStart: number = this.pendingStart + (n === 0 ? 0 : units[n - 1] + this.unitLenAt(units[n - 1]));
      const byteEnd: number = this.pendingStart + (n < units.length ? units[n] : regionLen);
      this.lines.push({ text: parts[n], byteStart: byteStart, byteEnd: byteEnd });
    }
  }

  /** 取下一完整行；null = EOF */
  public async nextLine(): Promise<TxtLineView | null> {
    if (this.lineIdx < this.lines.length) {
      const l: TxtLineView = this.lines[this.lineIdx];
      this.lineIdx++;
      return l;
    }
    // 清空已消费
    this.lines = [];
    this.lineIdx = 0;
    const lastStart: number = this.lastUnitStart();
    if (lastStart < 0 && !this.eof) {
      await this.fill();
      const last2: number = this.lastUnitStart();
      if (last2 >= 0) {
        return this.processRegion(last2);
      }
      // EOF：处理剩余尾部
      if (this.eof && this.pending.length > 0) {
        return this.processTail();
      }
      if (this.pending.length === 0) {
        return null;
      }
      return null;
    }
    if (lastStart >= 0) {
      return this.processRegion(lastStart);
    }
    // eof 且无单位 → 尾部
    if (this.pending.length > 0) {
      return this.processTail();
    }
    return null;
  }

  private async processRegion(lastUnitLocal: number): Promise<TxtLineView | null> {
    const unitLen: number = this.unitLenAt(lastUnitLocal);
    const regionLen: number = lastUnitLocal + unitLen;
    const decoded: string = this.decodeRegion(regionLen);
    this.emitDecoded(decoded, regionLen);
    // 收缩 pending
    const remainStart: number = regionLen;
    const remain: number[] = [];
    for (let i = remainStart; i < this.pending.length; i++) {
      remain.push(this.pending[i]);
    }
    this.pending = remain;
    this.pendingStart += regionLen;
    // 首行
    if (this.lines.length > 0) {
      const l: TxtLineView = this.lines[this.lineIdx];
      this.lineIdx++;
      return l;
    }
    // 理论上不会发生（有单元必有行）；保险：继续
    return null;
  }

  private processTail(): TxtLineView | null {
    const regionLen: number = this.pending.length;
    if (regionLen === 0) {
      return null;
    }
    const decoded: string = this.decodeRegion(regionLen);
    this.emitDecoded(decoded, regionLen);
    this.pending = [];
    this.pendingStart += regionLen;
    if (this.lines.length > 0) {
      const l: TxtLineView = this.lines[this.lineIdx];
      this.lineIdx++;
      return l;
    }
    return null;
  }

  public getCharCursor(): number {
    return this.charCursor;
  }
}

/** 段落 + vchapter 流式引擎（与 eager 的 split + buildVChapters 语义一致） */
class TxtVchEngine {
  private readonly detectedMode: boolean;
  private oldChapters: TxtOldChapterData[] = [];
  private vchapters: TxtVChapterData[] = [];
  private vchGlobal: number = 0;
  private vchSeqInChapter: number = 0;
  private oldChapterIdx: number = 0;
  private oldChapterTitle: string = '';
  private oldChapterByteStart: number = 0;
  private oldChapterByteEnd: number = 0;
  private chapterHasContent: boolean = false;
  private inBlock: boolean = false;
  private blockBuffer: string = '';
  private paraByteStart: number = 0;
  private paraByteEnd: number = 0;
  private chapterParaCount: number = 0;
  private vchParaStart: number = 0;
  private vchChars: number = 0;
  private vchCharStart: number = 0;
  private vchByteStart: number = 0;
  private vchByteEnd: number = 0;
  private pendingCut: boolean = false;
  private pageParaCount: number = 0;

  constructor(detectedMode: boolean) {
    this.detectedMode = detectedMode;
  }

  public beginChapter(): void {
    this.inBlock = false;
    this.blockBuffer = '';
    this.paraByteStart = 0;
    this.paraByteEnd = 0;
    this.chapterParaCount = 0;
    this.chapterHasContent = false;
    this.vchParaStart = 0;
    this.vchChars = 0;
    this.pendingCut = false;
    this.pageParaCount = 0;
    this.oldChapterIdx = 0;
    this.oldChapterTitle = '';
    this.oldChapterByteStart = 0;
    this.oldChapterByteEnd = 0;
    this.vchSeqInChapter = 0;
    this.vchCharStart = 0;
  }

  private maxOldChapterIdx(): number {
    let max: number = -1;
    for (let i = 0; i < this.oldChapters.length; i++) {
      if (this.oldChapters[i].index > max) {
        max = this.oldChapters[i].index;
      }
    }
    return max;
  }

  /** 开始新章（index 递增），标题默认空，由调用方设置 */
  private newChapter(): void {
    this.inBlock = false;
    this.blockBuffer = '';
    this.paraByteStart = 0;
    this.paraByteEnd = 0;
    this.chapterParaCount = 0;
    this.chapterHasContent = false;
    this.vchParaStart = 0;
    this.vchChars = 0;
    this.pendingCut = false;
    this.pageParaCount = 0;
    this.oldChapterIdx = this.maxOldChapterIdx() + 1;
    this.oldChapterTitle = '';
    this.oldChapterByteStart = 0;
    this.oldChapterByteEnd = 0;
    this.vchSeqInChapter = 0;
    this.vchCharStart = 0;
  }

  public onLine(line: TxtLineView): void {
    if (this.detectedMode && TxtChapterDetector.isHeadingLineFor(line.text)) {
      // 标题行：结束旧章（含"开篇"或前一个真实章节），开始新章
      this.finishChapter();
      // 新章开始（标题行本身不属于正文，作为新章标题）
      this.newChapter();
      this.oldChapterTitle = line.text.trim();
      this.oldChapterByteStart = line.byteEnd;
      this.oldChapterByteEnd = line.byteEnd;
      return;
    }
    this.feedBody(line);
  }

  public finish(): void {
    this.finishChapter();
  }

  private feedBody(line: TxtLineView): void {
    // 空行 → 块结束，合并缓冲 flush
    if (this.isBlank(line.text)) {
      if (this.inBlock) {
        this.inBlock = false;
        this.flushParagraph();
      }
      this.oldChapterByteEnd = line.byteEnd;
      return;
    }
    if (!this.inBlock) {
      this.inBlock = true;
    }
    const trimmed: string = this.trimEdges(line.text);
    if (trimmed.length === 0) {
      this.oldChapterByteEnd = line.byteEnd;
      return;
    }
    // mergeBlockLines 语义：先判断（上一条缓冲 + 本条）
    if (this.blockBuffer.length > 0 &&
      (this.endsWithSentencePunct(this.blockBuffer) ||
        this.blockBuffer.length + trimmed.length > TxtLazyConfig.MAX_MERGED_PARAGRAPH_LENGTH)) {
      this.flushParagraph();
    }
    if (this.blockBuffer.length === 0) {
      this.paraByteStart = line.byteStart;
    }
    this.blockBuffer = this.blockBuffer + trimmed;
    this.paraByteEnd = line.byteEnd;
    this.oldChapterByteEnd = line.byteEnd;
    this.chapterHasContent = true;
    // 保护上限（degraded）
    if (this.blockBuffer.length > TxtLazyConfig.MAX_PARAGRAPH_CHARS) {
      this.flushParagraph();
      this.blockBuffer = '';
      this.paraByteStart = line.byteEnd;
      this.paraByteEnd = line.byteEnd;
    }
  }

  private flushParagraph(): void {
    if (this.blockBuffer.length === 0) {
      return;
    }
    const collapsed: string = this.collapsedOf(this.blockBuffer);
    this.blockBuffer = '';
    if (collapsed.length === 0) {
      return;
    }
    // 若已在可切状态，先关闭当前 vch
    if (this.pendingCut) {
      this.closeVch();
    }
    if (this.vchChars === 0) {
      this.vchByteStart = this.paraByteStart;
      this.vchParaStart = this.chapterParaCount;
    }
    this.vchByteEnd = this.paraByteEnd;
    this.vchChars += collapsed.length;
    this.chapterParaCount++;
    this.pageParaCount++;
    if (this.vchChars >= TxtLazyConfig.VCH_TARGET_CHARS) {
      this.pendingCut = true;
    }
    if (this.vchChars >= TxtLazyConfig.VCH_TARGET_CHARS + TxtLazyConfig.VCH_MAX_OVER) {
      this.closeVch();
    }
    // fallback：40 段一页
    if (!this.detectedMode && this.pageParaCount >= TxtLazyConfig.FALLBACK_PARAGRAPHS_PER_PAGE) {
      this.closeVch();
      this.finishChapter();
      this.newChapter();
      this.oldChapterTitle = 'Page ' + String(this.oldChapterIdx + 1);
    }
  }

  private closeVch(): void {
    if (this.vchChars === 0) {
      return;
    }
    const baseTitle: string = this.currentChapterTitle();
    const title: string = this.vchParaStart === 0 ? baseTitle : baseTitle + '（续）';
    const plainLen: number = this.plainLen(this.vchChars, this.chapterParaCount - this.vchParaStart);
    this.vchapters.push({
      // Phase 24（Issue A 根因修复 #2）：id 必须用全局序号 vchGlobal。
      // 旧实现用 vchSeqInChapter（每章归零），跨章 vchapter id 撞号
      // （每章第一条都是 vchapter_00000），resolveChapterId 按 id 数字
      // 解析 → 恢复永远落到前面的同名章（位置丢失回归）。
      id: this.vchId(this.vchGlobal),
      oldChapterIndex: this.oldChapterIdx,
      title: title,
      byteStart: this.vchByteStart,
      byteEnd: this.vchByteEnd,
      charStart: this.vchCharStart,
      charEnd: this.vchCharStart + this.vchChars,
      paraStart: this.vchParaStart,
      paraEnd: this.chapterParaCount - 1,
      plainTextLength: plainLen
    });
    this.vchGlobal++;
    this.vchSeqInChapter++;
    this.vchCharStart += this.vchChars;
    this.vchParaStart = this.chapterParaCount;
    this.vchChars = 0;
    this.pendingCut = false;
  }

  private emitEmptyVch(): void {
    this.vchapters.push({
      // Phase 24：同 closeVch——id 用全局序号，禁止每章归零的 vchSeqInChapter。
      id: this.vchId(this.vchGlobal),
      oldChapterIndex: this.oldChapterIdx,
      title: this.currentChapterTitle(),
      byteStart: this.oldChapterByteStart,
      byteEnd: this.oldChapterByteEnd,
      charStart: 0,
      charEnd: 0,
      paraStart: 0,
      paraEnd: -1,
      plainTextLength: 0
    });
    this.vchGlobal++;
    this.vchSeqInChapter++;
  }

  private finishChapter(): void {
    if (this.inBlock) {
      this.inBlock = false;
      this.flushParagraph();
    }
    const isEmpty: boolean = this.chapterParaCount === 0 && !this.chapterHasContent;
    const isPreHeading: boolean =
      this.detectedMode && this.oldChapterIdx === 0 && this.oldChapterTitle.length === 0;
    if (isEmpty) {
      if (isPreHeading) {
        // blockBuffer 未产生任何内容（文件开头连续空行等）→ 不产出章
        return;
      }
      if (this.detectedMode) {
        this.emitEmptyVch();
      } else {
        return;
      }
    } else {
      if (this.vchChars > 0) {
        this.closeVch();
      }
      if (this.oldChapterVchStart() === this.vchGlobal && this.chapterParaCount > 0) {
        // 理论不可达：所有段落折叠为空；保险
        this.emitEmptyVch();
      }
    }
    const vchStart: number = this.oldChapterVchStart();
    this.oldChapters.push({
      index: this.oldChapterIdx,
      title: this.currentChapterTitle(),
      byteStart: this.oldChapterByteStart,
      byteEnd: this.oldChapterByteEnd,
      vchStart: vchStart,
      vchCount: Math.max(1, this.vchGlobal - vchStart)
    });
  }

  private oldChapterVchStart(): number {
    let start: number = 0;
    for (let i = 0; i < this.oldChapters.length; i++) {
      start += this.oldChapters[i].vchCount;
    }
    return start;
  }

  private currentChapterTitle(): string {
    if (this.oldChapterTitle.length > 0) {
      return this.oldChapterTitle;
    }
    if (this.detectedMode) {
      // detected 模式首个未命名章 = 开篇前记（pre-heading）
      return this.oldChapterIdx === 0 ? '开篇' : '第' + String(this.oldChapterIdx + 1) + '章';
    }
    return 'Page ' + String(this.oldChapterIdx + 1);
  }

  public toIndex(fileSize: number, encoding: string): TxtIndexData {
    const index = new TxtIndexData();
    index.fileSize = fileSize;
    index.encoding = encoding;
    index.newlineMode = 'lf';
    index.detectedMode = this.detectedMode;
    index.oldChapters = this.oldChapters;
    index.vchapters = this.vchapters;
    let total: number = 0;
    for (let i = 0; i < this.vchapters.length; i++) {
      total += this.vchapters[i].plainTextLength;
    }
    index.totalPlainTextLength = total;
    return index;
  }

  private vchId(globalIdx: number): string {
    let num: string = String(globalIdx);
    while (num.length < 5) {
      num = '0' + num;
    }
    return 'vchapter_' + num;
  }

  private endsWithSentencePunct(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    const last: string = text.charAt(text.length - 1);
    return '。！？；…!?;"”』」〕）】›»'.indexOf(last) >= 0;
  }

  private collapsedOf(para: string): string {
    const escaped: string = para.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const paras: string[] = extractParagraphs('<p>' + escaped + '</p>');
    if (paras.length === 0) {
      return '';
    }
    return paras[0];
  }

  private plainLen(vchChars: number, paraCount: number): number {
    return vchChars + Math.max(0, paraCount - 1);
  }

  /** 空行判定：仅含空白字符（与 \s* 语义一致，避免每行正则） */
  private isBlank(text: string): boolean {
    for (let i = 0; i < text.length; i++) {
      const c: string = text.charAt(i);
      if (c !== ' ' && c !== '\t' && c !== '\r' && c !== '\n' && c !== '　' &&
        c !== '\u00a0' && c !== '\u3000') {
        return false;
      }
    }
    return true;
  }

  /** 高性能边沿裁剪：只裁 [　 \t]（与 TxtParagraphSplitter.toLines 一致） */
  private trimEdges(text: string): string {
    let start: number = 0;
    let end: number = text.length;
    while (start < end) {
      const c: string = text.charAt(start);
      if (c !== '　' && c !== ' ' && c !== '\t') {
        break;
      }
      start++;
    }
    while (end > start) {
      const c: string = text.charAt(end - 1);
      if (c !== '　' && c !== ' ' && c !== '\t') {
        break;
      }
      end--;
    }
    return (start === 0 && end === text.length) ? text : text.substring(start, end);
  }
}

export class TxtIndexBuilder {
  /**
   * 构建 TXT 轻量索引（构建失败返回 null，调用方回退 eager）。
   */
  public static async build(filePath: string): Promise<TxtIndexData | null> {
    let file: fileIo.File | null = null;
    try {
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      const fileSize: number = stat.size;
      if (fileSize <= 0) {
        return null;
      }
      file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const fd: number = file.fd;
      const sampleLen: number = Math.min(fileSize, 64 * 1024);
      const sample: Uint8Array = new Uint8Array(sampleLen);
      fileIo.readSync(fd, sample.buffer, { offset: 0, length: sampleLen });
      const encoding: string = TxtEncodingDetector.detect(sample);

      // Pass1：标题行计数（轻量快速通道：先做首字符/长度预过滤，减少正则调用）
      let headingCount: number = 0;
      const s1: TxtLineScanner = new TxtLineScanner(fd, fileSize, encoding);
      let l1: TxtLineView | null = await s1.nextLine();
      let pass1Regions: number = 0;
      while (l1 !== null) {
        if (TxtIndexBuilder.quickHeadingTest(l1.text) &&
          TxtChapterDetector.isHeadingLineFor(l1.text)) {
          headingCount++;
        }
        l1 = await s1.nextLine();
        pass1Regions++;
        if (pass1Regions % 64 === 0) {
          // 主动让出主线程，防止长文件索引构建 THREAD_BLOCK_6S
          await new Promise<void>((resolve: () => void): void => {
            setTimeout(resolve, 1);
          });
        }
      }
      const detectedMode: boolean = headingCount >= 2;

      // Pass2：全文建链
      const s2: TxtLineScanner = new TxtLineScanner(fd, fileSize, encoding);
      const engine: TxtVchEngine = new TxtVchEngine(detectedMode);
      engine.beginChapter();
      let l2: TxtLineView | null = await s2.nextLine();
      let pass2Regions: number = 0;
      while (l2 !== null) {
        engine.onLine(l2);
        l2 = await s2.nextLine();
        pass2Regions++;
        if (pass2Regions % 96 === 0) {
          await new Promise<void>((resolve: () => void): void => {
            setTimeout(resolve, 1);
          });
        }
      }
      engine.finish();

      const index: TxtIndexData = engine.toIndex(fileSize, encoding);
      return index;
    } catch (e) {
      hilog.error(0x0000, 'OhEngine', 'TXT-LAZY builder-exception: %{public}s', String(e));
      return null;
    } finally {
      if (file !== null) {
        try { fileIo.closeSync(file); } catch (_e) { }
      }
    }
  }

  /**
   * 快速标题预过滤：先用 O(1) 前缀/长度检查避开昂贵的 4 组正则。
   * 只用于 Pass1 计数（与 isHeadingLineFor 一致方向；少量边缘差异仅影响
   * 「>=2 标题」的总体门限，风险极低）。
   */
  private static quickHeadingTest(line: string): boolean {
    const trimmed: string = line.trim();
    if (trimmed.length === 0 || trimmed.length > TxtConfig.MAX_HEADING_LINE_LENGTH) {
      return false;
    }
    const c: string = trimmed.charAt(0);
    // 中文「第X章/回/节」或英文 Chapter 开头才可能命中，其余直接跳过
    if (c === '第') {
      return true;
    }
    if (c === 'C' || c === 'c') {
      const upper: string = trimmed.substring(0, 7).toLowerCase();
      return upper.startsWith('chapter');
    }
    if (/^[0-9]/.test(trimmed)) {
      return true;
    }
    // 序章/楔子/尾声/后记等（仅第一字命中）
    if ('序楔尾后附前自引'.indexOf(c) >= 0) {
      return true;
    }
    return false;
  }
}