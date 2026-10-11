/**
 * PdfParser — PDF text-extraction parser (reflowable)
 *
 * 将 PDF 解析为可重排（REFLOW）的 ParsedBook：对每个页面提取文本内容
 * 并作为一章（纯文本，与 TxtParser 同消费路径），供 ReflowRouter 布局分页。
 *
 * 解析策略（自包含，不依赖第三方库）：
 *   1. 全文件读入 → 按 `N G obj ... endobj` 扫描对象（无需有效 xref，兼容
 *      增量式保存/线性化后的 PDF）。
 *   2. 从 trailer `/Root` 定位 Catalog → 沿 /Pages /Kids 遍历页面树。
 *   3. 解码内容流（FlateDecode zlib.uncompress；无 /Filter 的明文流直接
 *      使用），解析 BT/ET 块中的 Tj / TJ / ' / " 文本算子。
 *   4. 通过 /Resources /Font 的 /ToUnicode CMap 把字形码映射回 Unicode
 *      （beginbfchar / beginbfrange，按 codespacerange 判定的 1/2/4 字节
 *      码宽均支持）；无 ToUnicode 的拉丁字体回退 Windows-1252 基础映射。
 *
 * 限制（后续可扩展）：扫描 PDF（纯图像无文本层）提取为空页；不支持的
 * 滤镜（LZW/ASCII85 等）跳过对应流。
 */

import { BookParser, BookFormat, ParsedBook, RenderStrategy,
  ChapterData, Book, Publication, TocItem, createLinkWithTitle } from 'ohrengine-common';
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';

/** 原始 PDF 对象（num 索引） */
interface PdfRawObject {
  num: number;
  gen: number;
  /** 'obj' 之后的文本偏移（与字节偏移一致，latin1 1:1） */
  bodyStart: number;
  /** 对象体文本（'obj' 之后到 'stream' 之前的字典部分） */
  body: string;
  /** 解压前的原始流字节；无流时为 null */
  streamData: Uint8Array | null;
}

/** 字体资源：资源名 → (ToUnicode 码→Unicode 映射 或 null) */
interface FontInfo {
  codeMap: Map<number, string> | null;
  /** 字形码宽度（字节）：1/2/4，由 CMap codespacerange 判定 */
  codeWidth: number;
}

export class PdfParser implements BookParser {
  readonly format: BookFormat = BookFormat.PDF;

  async parse(filePath: string): Promise<ParsedBook> {
    const bytes: Uint8Array = this.readFileBytes(filePath);
    const text: string = this.bytesToLatin1(bytes);
    const objects: Map<number, PdfRawObject> = this.scanObjects(text, bytes);
    if (objects.size === 0) {
      throw new Error('PdfParser.parse: 未在文件中找到任何 PDF 对象：' + filePath);
    }
    const rootRef: number = this.findRootRef(text);
    const pageRefs: number[] = this.collectPages(objects, rootRef);

    const chapters: ChapterData[] = [];
    for (let p = 0; p < pageRefs.length; p++) {
      const pageObj: PdfRawObject | undefined = objects.get(pageRefs[p]);
      if (pageObj === undefined) {
        continue;
      }
      const pageText: string = await this.extractPageText(pageObj, objects);
      if (pageText.length === 0) {
        continue;
      }
      const chapter: ChapterData = {
        title: 'Page ' + (p + 1),
        content: pageText,
        href: 'pdf-page-' + (p + 1)
      };
      chapters.push(chapter);
    }

    if (chapters.length === 0) {
      throw new Error('PdfParser.parse: 未能从 PDF 提取到文本（可能为扫描版）：' + filePath);
    }
    return new ParsedBook(BookFormat.PDF, RenderStrategy.REFLOW, null, chapters, []);
  }

  async getBook(filePath: string): Promise<Book> {
    const parsed: ParsedBook = await this.parse(filePath);
    const publication: Publication = new Publication(this.titleFromPath(filePath));
    for (let i = 0; i < parsed.chapters.length; i++) {
      const chapter: ChapterData = parsed.chapters[i];
      publication.manifest.readingOrder.push(
        createLinkWithTitle(chapter.href, 'text/plain', chapter.title));
      const item: TocItem = { title: chapter.title, href: chapter.href };
      publication.toc.push(item);
    }
    return publication;
  }

  // ==================== 文件读取 ====================

  /**
   * 整读文件为 Uint8Array（内存考量：>20MB 的 PDF 以图像/扫描页为主，
   * 文本层字节占比小；latin1 镜像与 bytes 1:1 供正则/逐字节扫描，双份
   * 内存仅出现在解析期间，可接受。后续如需支持超大文本型 PDF，可改为
   * 分段扫描对象边界，但收益低、复杂度高，暂不为该场景优化。）
   */
  private readFileBytes(filePath: string): Uint8Array {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
    } catch (e) {
      throw new Error('PdfParser: open failed: ' + (e instanceof Error ? e.message : String(e)));
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      const readLen: number = fileIo.readSync(file.fd, buf, { offset: 0, length: stat.size });
      return new Uint8Array(buf.slice(0, readLen));
    } catch (e) {
      throw new Error('PdfParser: read failed: ' + (e instanceof Error ? e.message : String(e)));
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_e) {
        }
      }
    }
  }

  /** 字节 → latin1 字符串（与字节偏移 1:1，供正则/逐字节扫描） */
  private bytesToLatin1(bytes: Uint8Array): string {
    const chunkSize: number = 8192;
    const parts: string[] = [];
    let i: number = 0;
    while (i < bytes.length) {
      const end: number = Math.min(i + chunkSize, bytes.length);
      let s: string = '';
      for (let j = i; j < end; j++) {
        s += String.fromCharCode(bytes[j]);
      }
      parts.push(s);
      i = end;
    }
    return parts.join('');
  }

  private titleFromPath(filePath: string): string {
    const lastSlash: number = filePath.lastIndexOf('/');
    const fileName: string = lastSlash >= 0 ? filePath.substring(lastSlash + 1) : filePath;
    const dot: number = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  // ==================== 对象扫描 ====================

  private scanObjects(text: string, bytes: Uint8Array): Map<number, PdfRawObject> {
    const map: Map<number, PdfRawObject> = new Map();
    const re: RegExp = /(\d+)\s+(\d+)\s+obj/gi;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text)) !== null) {
      const num: number = parseInt(m[1], 10);
      const gen: number = parseInt(m[2], 10);
      const bodyStart: number = m.index + m[0].length;
      const endIdx: number = text.indexOf('endobj', bodyStart);
      const end: number = endIdx < 0 ? text.length : endIdx;
      // 字典部分：到 'stream' 关键字为止
      const relBody: string = text.substring(bodyStart, end);
      const sIdx: number = relBody.indexOf('stream');
      const dictBody: string = sIdx >= 0 ? relBody.substring(0, sIdx) : relBody;
      let streamData: Uint8Array | null = null;
      if (sIdx >= 0) {
        let contentStart: number = bodyStart + sIdx + 6; // 'stream'
        if (text[contentStart] === '\r') {
          contentStart++;
        }
        if (text[contentStart] === '\n') {
          contentStart++;
        }
        const esIdx: number = text.indexOf('endstream', contentStart);
        const streamEnd: number = esIdx < 0 ? Math.min(text.length, contentStart + 1048576) : esIdx;
        // 流数据保持到 endstream 为止（含尾部 EOL）：压缩字节可能恰好以
        // \n/\r 结尾，此处剥尾会截断 zlib 流；EOL 剥离交给 decodeStream
        // 在解压失败时按需重试。
        if (streamEnd > contentStart) {
          streamData = bytes.subarray(contentStart, streamEnd);
        }
      }
      const obj: PdfRawObject = {
        num: num,
        gen: gen,
        bodyStart: bodyStart,
        body: dictBody,
        streamData: streamData
      };
      map.set(num, obj);
    }
    return map;
  }

  // ==================== 结构遍历 ====================

  /** 从 trailer /Root 找到 Catalog 对象号 */
  private findRootRef(text: string): number {
    const m: RegExpExecArray | null = /\/Root\s+(\d+)\s+(\d+)\s+R/i.exec(text);
    return m !== null ? parseInt(m[1], 10) : -1;
  }

  /** 解析对象体字典中指定键的间接引用 `/key N G R` */
  private resolveKeyRef(body: string, key: string): number {
    const m: RegExpExecArray | null = new RegExp('/' + key + '\\s+(\\d+)\\s+(\\d+)\\s+R').exec(body);
    return m !== null ? parseInt(m[1], 10) : -1;
  }

  /**
   * 解析数组中的间接引用列表。优先 `/Kids [N 0 R M 0 R ...]`
   * （页对象的 MediaBox/CropBox 等普通数组不含间接引用，直接取首个
   * `[...]` 会误读），退化为取首个数组。
   */
  private parseRefArray(body: string): number[] {
    const out: number[] = [];
    let arrMatch: RegExpExecArray | null = /\/Kids\s*\[([^\]]*)\]/.exec(body);
    if (arrMatch === null) {
      arrMatch = /\[([^\]]*)\]/.exec(body);
    }
    if (arrMatch === null) {
      return out;
    }
    const re: RegExp = /(\d+)\s+(\d+)\s+R/g;
    let mm: RegExpExecArray | null;
    while ((mm = re.exec(arrMatch[1])) !== null) {
      out.push(parseInt(mm[1], 10));
    }
    return out;
  }

  /** 收集全部页面对象号（沿 Pages/Catalog 树） */
  private collectPages(objects: Map<number, PdfRawObject>, rootRef: number): number[] {
    const pages: number[] = [];
    const visited: Set<number> = new Set();
    if (rootRef < 0) {
      objects.forEach((obj: PdfRawObject) => {
        if (obj.body.indexOf('/Type /Page') >= 0 && obj.body.indexOf('/Type /Pages') < 0) {
          pages.push(obj.num);
        }
      });
      return pages;
    }
    const queue: number[] = [rootRef];
    while (queue.length > 0) {
      const ref: number = queue[0];
      queue.shift();
      if (visited.has(ref)) {
        continue;
      }
      visited.add(ref);
      const obj: PdfRawObject | undefined = objects.get(ref);
      if (obj === undefined) {
        continue;
      }
      const body: string = obj.body;
      const typeM: RegExpExecArray | null = /\/Type\s+\/(\w+)/.exec(body);
      const type: string = typeM !== null ? typeM[1] : '';
      if (type === 'Catalog') {
        const pagesRefM: RegExpExecArray | null = /\/Pages\s+(\d+)\s+(\d+)\s+R/.exec(body);
        if (pagesRefM !== null) {
          queue.push(parseInt(pagesRefM[1], 10));
        }
      } else if (type === 'Pages') {
        const kids: number[] = this.parseRefArray(body);
        for (let k = 0; k < kids.length; k++) {
          queue.push(kids[k]);
        }
      } else if (type === 'Page') {
        pages.push(obj.num);
      }
    }
    return pages;
  }

  // ==================== 页面文本提取 ====================

  private async extractPageText(pageObj: PdfRawObject, objects: Map<number, PdfRawObject>): Promise<string> {
    const pageBody: string = pageObj.body;
    const contentsRefs: number[] = this.parseContentsRefs(pageBody);
    const fonts: Map<string, FontInfo> = await this.parseFonts(pageBody, objects);

    const lines: string[] = [];
    for (let c = 0; c < contentsRefs.length; c++) {
      const contentObj: PdfRawObject | undefined = objects.get(contentsRefs[c]);
      if (contentObj === undefined) {
        continue;
      }
      const decoded: Uint8Array | null = await this.decodeStream(contentObj);
      if (decoded === null || decoded.length === 0) {
        continue;
      }
      const pageText: string = this.parseContentOperators(decoded, fonts);
      if (pageText.length > 0) {
        lines.push(pageText);
      }
    }
    return lines.join('\n');
  }

  /** 解析页对象 /Contents（单个引用或数组），误读 MediaBox/Parent 等 */
  private parseContentsRefs(pageBody: string): number[] {
    const out: number[] = [];
    const arrM: RegExpExecArray | null = /\/Contents\s*\[([^\]]*)\]/.exec(pageBody);
    if (arrM !== null) {
      const re: RegExp = /(\d+)\s+(\d+)\s+R/g;
      let mm: RegExpExecArray | null;
      while ((mm = re.exec(arrM[1])) !== null) {
        out.push(parseInt(mm[1], 10));
      }
      return out;
    }
    const singleM: RegExpExecArray | null = /\/Contents\s+(\d+)\s+(\d+)\s+R/.exec(pageBody);
    if (singleM !== null) {
      out.push(parseInt(singleM[1], 10));
    }
    return out;
  }

  /**
   * 解析 /Resources（内联或引用）→ /Font → ToUnicode CMap 映射。
   * 页对象无 /Resources 时沿 /Parent 链向上继承（Resources 为可继承键，
   * 多页共享字体的大文档常挂在 Pages 节点上；限 8 层并防环）。
   */
  private async parseFonts(pageBody: string, objects: Map<number, PdfRawObject>): Promise<Map<string, FontInfo>> {
    const fonts: Map<string, FontInfo> = new Map();
    const visited: Set<number> = new Set();
    let refBody: string = pageBody;
    for (let depth: number = 0; depth < 8; depth++) {
      // 间接引用：/Resources N G R
      const resM: RegExpExecArray | null = /\/Resources\s+(\d+)\s+(\d+)\s+R/.exec(refBody);
      if (resM !== null) {
        const resObj: PdfRawObject | undefined = objects.get(parseInt(resM[1], 10));
        if (resObj !== undefined) {
          await this.parseFontDict(resObj.body, objects, fonts);
          return fonts;
        }
        // 引用存在但对象缺失 → 不再向上（字典已有 Resources 声明）
        return fonts;
      }
      // 内联字典：/Resources << ... >>
      const resInline: string = this.extractDictSection(refBody, 'Resources');
      if (resInline.length > 0) {
        await this.parseFontDict(resInline, objects, fonts);
        return fonts;
      }
      // 无 Resources → 沿 /Parent 上溯（仅接受 Pages 类型的父节点）
      const parentM: RegExpExecArray | null = /\/Parent\s+(\d+)\s+(\d+)\s+R/.exec(refBody);
      if (parentM === null) {
        break;
      }
      const parentRef: number = parseInt(parentM[1], 10);
      if (visited.has(parentRef)) {
        break;
      }
      visited.add(parentRef);
      const parentObj: PdfRawObject | undefined = objects.get(parentRef);
      if (parentObj === undefined) {
        break;
      }
      const parentType: RegExpExecArray | null = /\/Type\s+\/(\w+)/.exec(parentObj.body);
      if (parentType === null || parentType[1] !== 'Pages') {
        break;
      }
      refBody = parentObj.body;
    }
    return fonts;
  }

  private async parseFontDict(resBody: string, objects: Map<number, PdfRawObject>, fonts: Map<string, FontInfo>): Promise<void> {
    if (resBody.length === 0) {
      return;
    }
    const fontSection: string = this.extractDictSection(resBody, 'Font');
    const re: RegExp = /\/(\w+)\s+(\d+)\s+(\d+)\s+R/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(fontSection)) !== null) {
      const name: string = m[1];
      const fontRef: number = parseInt(m[2], 10);
      const fontObj: PdfRawObject | undefined = objects.get(fontRef);
      if (fontObj === undefined) {
        continue;
      }
      const toUni: number = this.resolveKeyRef(fontObj.body, 'ToUnicode');
      let codeMap: Map<number, string> | null = null;
      let codeWidth: number = 1;
      if (toUni >= 0) {
        const cmapObj: PdfRawObject | undefined = objects.get(toUni);
        if (cmapObj !== undefined) {
          const decodedCmap: Uint8Array | null = await this.decodeStream(cmapObj);
          if (decodedCmap !== null) {
            const cmap: string = this.bytesToLatin1(decodedCmap);
            codeMap = this.parseToUnicodeCmap(cmap);
            codeWidth = this.cmapCodeWidth(cmap);
          }
        }
      }
      fonts.set(name, { codeMap: codeMap, codeWidth: codeWidth });
    }
  }

  /** 提取字典中某个键对应的子树（`/Key <<...>>` 或 `/Key N 0 R`） */
  private extractDictSection(body: string, key: string): string {
    const m: RegExpExecArray | null = new RegExp('/' + key + '\\s+').exec(body);
    if (m === null) {
      return '';
    }
    const start: number = m.index + m[0].length;
    // 跳过空白
    let i: number = start;
    while (i < body.length && (body[i] === ' ' || body[i] === '\t' || body[i] === '\n' || body[i] === '\r')) {
      i++;
    }
    if (i >= body.length) {
      return '';
    }
    if (body[i] === '<' && body[i + 1] === '<') {
      return this.collectBalanced(body, i, '<<', '>>');
    }
    // 间接引用
    const refM: RegExpExecArray | null = /(\d+)\s+(\d+)\s+R/.exec(body.substring(i));
    if (refM !== null) {
      return body.substring(i);
    }
    return body.substring(i);
  }

  /** 提取以 open 起始、到平衡 close 的整段 */
  private collectBalanced(s: string, start: number, open: string, close: string): string {
    let depth: number = 0;
    let i: number = start;
    const startIdx: number = start;
    while (i < s.length - 1) {
      if (s[i] === open[0] && s[i + 1] === open[1]) {
        depth++;
        i += 2;
        continue;
      }
      if (s[i] === close[0] && s[i + 1] === close[1]) {
        depth--;
        i += 2;
        if (depth === 0) {
          break;
        }
        continue;
      }
      i++;
    }
    return s.substring(startIdx, Math.min(i, s.length));
  }

  /** 括号匹配：返回与 open 对应的 close 下标 */
  private findMatching(s: string, from: number, open: string, close: string): number {
    let depth: number = 0;
    for (let i = from; i < s.length; i++) {
      if (s[i] === open) {
        depth++;
      } else if (s[i] === close) {
        depth--;
        if (depth === 0) {
          return i;
        }
      }
    }
    return s.length - 1;
  }

  /** 解析 ToUnicode CMap：建立 码值(int) → Unicode(string) */
  private parseToUnicodeCmap(cmap: string): Map<number, string> {
    const result: Map<number, string> = new Map();
    this.parseBfChar(cmap, result);
    this.parseBfRange(cmap, result);
    return result;
  }

  private parseBfChar(cmap: string, result: Map<number, string>): void {
    const m: RegExpExecArray | null = /beginbfchar([\s\S]*?)endbfchar/i.exec(cmap);
    if (m === null) {
      return;
    }
    const re: RegExp = /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/g;
    let mm: RegExpExecArray | null;
    while ((mm = re.exec(m[1])) !== null) {
      const code: number = this.hexToInt(mm[1]);
      result.set(code, this.hexUtf16ToString(mm[2]));
    }
  }

  private parseBfRange(cmap: string, result: Map<number, string>): void {
    const m: RegExpExecArray | null = /beginbfrange([\s\S]*?)endbfrange/i.exec(cmap);
    if (m === null) {
      return;
    }
    const re: RegExp = /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(?:<([0-9A-Fa-f]+)>|\[([\s\S]*?)\])/g;
    let mm: RegExpExecArray | null;
    while ((mm = re.exec(m[1])) !== null) {
      const lo: number = this.hexToInt(mm[1]);
      const hi: number = this.hexToInt(mm[2]);
      if (mm[3] !== undefined) {
        // 起始目标字符 + 递增
        let destStr: string = this.hexUtf16ToString(mm[3]);
        for (let code: number = lo; code <= hi; code++) {
          result.set(code, destStr);
          destStr = this.incrementUtf16(destStr);
        }
      } else if (mm[4] !== undefined) {
        const arrRe: RegExp = /<([0-9A-Fa-f]+)>/g;
        const dests: string[] = [];
        let am: RegExpExecArray | null;
        while ((am = arrRe.exec(mm[4])) !== null) {
          dests.push(this.hexUtf16ToString(am[1]));
        }
        for (let code: number = lo; code <= hi; code++) {
          if (code - lo < dests.length) {
            result.set(code, dests[code - lo]);
          }
        }
      }
    }
  }

  /**
   * 从 CMap 的 codespacerange 段推断字形码宽度（字节数：1/2/4）。
   * 覆盖全部 begincodespacerange..endcodespacerange 段（规范允许多段声明）
   * 与段内全部范围端点；限定在段内读取，避免误匹配后续 bfchar/bfrange
   * 的 4 位 UTF-16BE 目标（<XXXX>）。取最大宽度（多范围并存时按最宽分组）。
   */
  private cmapCodeWidth(cmap: string): number {
    const segRe: RegExp = /begincodespacerange([\s\S]*?)endcodespacerange/ig;
    let maxWidth: number = 1;
    let m: RegExpExecArray | null;
    while ((m = segRe.exec(cmap)) !== null) {
      const rangeRe: RegExp = /<([0-9A-Fa-f]+)>/g;
      let mm: RegExpExecArray | null;
      while ((mm = rangeRe.exec(m[1])) !== null) {
        // 码宽 = hex 字符数 / 2（范围端点 `<00> <FF>` → 1 字节；`<0000> <FFFF>` → 2 字节）
        const width: number = Math.floor(mm[1].length / 2);
        if (width > maxWidth) {
          maxWidth = width;
        }
      }
    }
    return maxWidth;
  }

  private hexToInt(hex: string): number {
    let v: number = 0;
    for (let i = 0; i < hex.length; i++) {
      v = v * 16 + parseInt(hex[i], 16);
    }
    return v;
  }

  /** UTF-16BE 十六进制串 → string（每 4 个十六进制位 = 一个码元） */
  private hexUtf16ToString(hex: string): string {
    let out: string = '';
    let i: number = 0;
    while (i + 3 < hex.length) {
      const code: number = this.hexToInt(hex.substring(i, i + 4));
      out += String.fromCharCode(code);
      i += 4;
    }
    return out;
  }

  /** 递增 UTF-16 单字符（bfrange 连续映射） */
  private incrementUtf16(s: string): string {
    if (s.length === 0) {
      return s;
    }
    const last: number = s.charCodeAt(s.length - 1);
    const prefix: string = s.substring(0, s.length - 1);
    return prefix + String.fromCharCode(last + 1);
  }

  // ==================== 内容流解码 ====================

  /**
   * 内容流解码：FlateDecode → zlib 解压；无 /Filter（明文流）→ 原样使用；
   * 其他滤镜或解压失败 → null（单条流失败不拖垮整页/整书解析）。
   * 解压失败时剥离尾部 EOL 重试：endstream 前的 EOL 不属于流数据，但
   * 压缩字节也可能恰好以 \n/\r 结尾，直接剥尾会截断 zlib 流。
   */
  private async decodeStream(obj: PdfRawObject): Promise<Uint8Array | null> {
    if (obj.streamData === null) {
      return null;
    }
    // 无 /Filter 键 = 明文内容流（未压缩），直接可用（不少简单导出器产出）
    if (obj.body.indexOf('/Filter') < 0) {
      return obj.streamData;
    }
    const hasFlate: boolean = obj.body.indexOf('/FlateDecode') >= 0;
    if (!hasFlate && obj.body.indexOf('/Filter /Fl') < 0) {
      return null;
    }
    let data: Uint8Array = obj.streamData;
    for (let attempt: number = 0; attempt < 3; attempt++) {
      try {
        return await this.zlibInflate(data);
      } catch (_e) {
        if (data.length > 0 && (data[data.length - 1] === 10 || data[data.length - 1] === 13)) {
          data = data.subarray(0, data.length - 1);
          continue;
        }
        return null;
      }
    }
    return null;
  }

  private zlibInflate(source: Uint8Array): Promise<Uint8Array> {
    const srcBuf: ArrayBuffer = this.moveToArrayBuffer(source);
    let size: number = Math.max(4096, source.length * 4);
    const cap: number = 64 * 1024 * 1024;
    return new Promise<Uint8Array>((resolve, reject) => {
      const attempt = (): void => {
        if (size > cap) {
          reject(new Error('zlib inflate: buffer limit exceeded'));
          return;
        }
        const dest: ArrayBuffer = new ArrayBuffer(size);
        zlib.createZip().then((zip: zlib.Zip) => {
          return zip.uncompress(dest, srcBuf);
        }).then((info: zlib.ZipOutputInfo) => {
          const out: Uint8Array = new Uint8Array(dest);
          if (info.status === zlib.ReturnStatus.OK) {
            resolve(out.subarray(0, info.destLen));
          } else if (info.status === zlib.ReturnStatus.BUF_ERROR || info.status === zlib.ReturnStatus.MEM_ERROR) {
            size = size * 4;
            attempt();
          } else {
            reject(new Error('zlib inflate failed, status=' + String(info.status)));
          }
        }).catch((_e: Error) => {
          size = size * 4;
          attempt();
        });
      };
      attempt();
    });
  }

  private moveToArrayBuffer(src: Uint8Array): ArrayBuffer {
    const buf: ArrayBuffer = new ArrayBuffer(src.length);
    new Uint8Array(buf).set(src);
    return buf;
  }

  // ==================== 文本算子解析 ====================

  /** 从解码后的内容流中提取文本（Tj/TJ/'/" 算子 + 换行指令） */
  private parseContentOperators(decoded: Uint8Array, fonts: Map<string, FontInfo>): string {
    const textStr: string = this.bytesToLatin1(decoded);
    const s: string = textStr.replace(/%[^\n\r]*/g, '');
    const len: number = s.length;
    let i: number = 0;
    let out: string = '';
    let currentFont: FontInfo | null = null;
    const fallback: FontInfo = { codeMap: null, codeWidth: 1 };
    while (i < len) {
      const c: string = s[i];
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        i++;
        continue;
      }
      if (c === '<') {
        if (i + 1 < len && s[i + 1] === '<') {
          i = this.skipDict(s, i);
          continue;
        }
        // 十六进制字符串 <...>
        const endH: number = s.indexOf('>', i);
        const hexBody: string = endH < 0 ? s.substring(i + 1) : s.substring(i + 1, endH);
        const hexOut: string = this.decodeHexContent(hexBody, currentFont !== null ? currentFont : fallback);
        if (hexOut.length > 0) {
          out += hexOut;
        }
        i = endH < 0 ? len : endH + 1;
        continue;
      }
      if (c === '(') {
        const parsed: ParseStringResult = this.parseLiteralString(s, i);
        const decodedStr: string = this.decodeBytesToText(parsed.content, currentFont !== null ? currentFont : fallback);
        if (decodedStr.length > 0) {
          out += decodedStr;
        }
        i = parsed.end;
        continue;
      }
      if (c === '/') {
        // PDF 名称（如 /F4 /TT1 /C1）：'/name' 原子 token + 匹配字体资源
        let j: number = i + 1;
        while (j < len && !this.isNameEnd(s[j])) {
          j++;
        }
        const name: string = s.substring(i + 1, j);
        i = j;
        if (name.length > 0) {
          const f: FontInfo | undefined = fonts.get(name);
          if (f !== undefined) {
            currentFont = f;
          }
        }
        continue;
      }
      if (c === '[') {
        // TJ 数组：提取其中的字符串并按字距插入空格（负字距绝对值大 → 词间空格）
        const tres: TjArrayResult = this.collectTjArray(s, i, currentFont !== null ? currentFont : fallback);
        out += tres.text;
        i = tres.end;
        continue;
      }
      // 关键字 / 数字（Tf/Tj/Td/Tm/T* 等）
      let j: number = i;
      while (j < len && !this.isDelimiter(s[j])) {
        j++;
      }
      const token: string = s.substring(i, j);
      i = j;
      if (token === 'T*' || token === 'ET' || token === "'" || token === '"') {
        // T*（显式换行）、ET（文本块结束）与 ' / "（换行后显示文本）均断行；
        // Tm/Td 是定位指令，Chrome-Skia 等每字形独立 Tm 定位，若按 Tm 断行会一个字一行
        if (out.length > 0 && !out.endsWith('\n')) {
          out += '\n';
        }
        continue;
      }
      // 数字、Tf/Tj/TJ/Td/Tm 等忽略（文本已在字符串解析时收集）
    }
    return this.normalizeLines(out);
  }

  /**
   * 处理 TJ 数组 `[ ... ]`：按序读取字符串（字面量/十六进制）与字距数字，
   * 负字距绝对值 ≥ ABS_KERN 时插入空格（拉丁词间空隙）。
   * @returns 处理结果（'[' 之后到 ']' 之后的结束下标 + 提取文本）
   */
  private collectTjArray(s: string, start: number, font: FontInfo): TjArrayResult {
    const ABS_KERN: number = 150;
    let i: number = start + 1;
    const len: number = s.length;
    let text: string = '';
    let spacePending: boolean = false;
    while (i < len) {
      const c: string = s[i];
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        i++;
        continue;
      }
      if (c === ']') {
        i++;
        break;
      }
      if (c === '(') {
        const parsed: ParseStringResult = this.parseLiteralString(s, i);
        const dec: string = this.decodeBytesToText(parsed.content, font);
        if (dec.length > 0) {
          if (spacePending) {
            text += ' ';
            spacePending = false;
          }
          text += dec;
        }
        i = parsed.end;
        continue;
      }
      if (c === '<') {
        if (i + 1 < len && s[i + 1] === '<') {
          i = this.skipDict(s, i);
        } else {
          const endH: number = s.indexOf('>', i);
          const hb: string = endH < 0 ? s.substring(i + 1) : s.substring(i + 1, endH);
          const dec: string = this.decodeHexContent(hb, font);
          if (dec.length > 0) {
            if (spacePending) {
              text += ' ';
              spacePending = false;
            }
            text += dec;
          }
          i = endH < 0 ? len : endH + 1;
        }
        continue;
      }
      if (c === '/') {
        i = this.skipName(s, i);
        continue;
      }
      if (c === '-') {
        // 负字距
        let j: number = i + 1;
        while (j < len && (s[j] === '.' || (s[j] >= '0' && s[j] <= '9'))) {
          j++;
        }
        const numStr: string = s.substring(i, j);
        const kern: number = parseFloat(numStr);
        if (!isNaN(kern) && Math.abs(kern) >= ABS_KERN) {
          spacePending = true;
        }
        i = j;
        continue;
      }
      // 其他（正数字、关键字）→ 跳过 token
      let j: number = i;
      while (j < len && !this.isDelimiter(s[j])) {
        j++;
      }
      i = Math.max(i + 1, j);
    }
    return { end: i, text: text };
  }

  /** 跳过 PDF 名称 token（返回其后的下标） */
  private skipName(s: string, start: number): number {
    let j: number = start + 1;
    const len: number = s.length;
    while (j < len && !this.isNameEnd(s[j])) {
      j++;
    }
    return j;
  }

  /** 解码一个十六进制字符串为文本 */
  private decodeHexContent(hexBody: string, font: FontInfo): string {
    const bytes: number[] = [];
    for (let i = 0; i + 1 < hexBody.length; i += 2) {
      const hi: number = this.hexVal(hexBody[i]);
      const lo: number = this.hexVal(hexBody[i + 1]);
      bytes.push((hi << 4) | lo);
    }
    return this.decodeBytesToText(Uint8Array.from(bytes), font);
  }

  private hexVal(ch: string): number {
    const code: number = ch.charCodeAt(0);
    if (code >= 48 && code <= 57) {
      return code - 48;
    }
    if (code >= 65 && code <= 70) {
      return code - 55;
    }
    if (code >= 97 && code <= 102) {
      return code - 87;
    }
    return 0;
  }

  private parseLiteralString(s: string, start: number): ParseStringResult {
    const bytes: number[] = [];
    let i: number = start + 1;
    const len: number = s.length;
    let depth: number = 1;
    while (i < len && depth > 0) {
      const c: string = s[i];
      if (c === '\\') {
        const nxt: string = s[i + 1];
        if (nxt === 'n') { bytes.push(10); i += 2; continue; }
        if (nxt === 'r') { bytes.push(13); i += 2; continue; }
        if (nxt === 't') { bytes.push(9); i += 2; continue; }
        if (nxt === 'b') { bytes.push(8); i += 2; continue; }
        if (nxt === 'f') { bytes.push(12); i += 2; continue; }
        if (nxt === '(') { bytes.push(40); i += 2; continue; }
        if (nxt === ')') { bytes.push(41); i += 2; continue; }
        if (nxt === '\\') { bytes.push(92); i += 2; continue; }
        if (nxt >= '0' && nxt <= '7') {
          let oct: string = '';
          let k: number = 0;
          while (k < 3 && i + 1 + k < len && s[i + 1 + k] >= '0' && s[i + 1 + k] <= '7') {
            oct += s[i + 1 + k];
            k++;
          }
          bytes.push(parseInt(oct, 8));
          i += 1 + k;
          continue;
        }
        if (nxt === '\r' || nxt === '\n') {
          i += 1;
          if (i < len && (s[i] === '\r' || s[i] === '\n')) {
            i += 1;
          }
          continue;
        }
        i += 2;
        continue;
      }
      if (c === '(') {
        depth++;
        bytes.push(40);
        i++;
        continue;
      }
      if (c === ')') {
        depth--;
        if (depth === 0) {
          i++;
          break;
        }
        bytes.push(41);
        i++;
        continue;
      }
      bytes.push(s.charCodeAt(i) & 0xFF);
      i++;
    }
    return { end: Math.min(i, len), content: Uint8Array.from(bytes) };
  }

  /** 将内容字符串的字节序列解码为文本（按 CMap 码宽分组，带 CMap 或 WinAnsi 回退） */
  private decodeBytesToText(bytes: Uint8Array, font: FontInfo): string {
    if (bytes.length === 0) {
      return '';
    }
    const map: Map<number, string> = font.codeMap !== null ? font.codeMap : new Map();
    const width: number = font.codeWidth;
    let out: string = '';
    let i: number = 0;
    while (i < bytes.length) {
      const take: number = bytes.length - i >= width ? width : bytes.length - i;
      let code: number = 0;
      for (let k: number = 0; k < take; k++) {
        code = code * 256 + bytes[i + k];
      }
      i += take;
      const mapped: string | undefined = map.get(code);
      if (mapped !== undefined) {
        out += mapped;
      } else if (take === 1) {
        out += this.winAnsiChar(code);
      } else {
        // 未映射的多字节 CID 码：直接输出码点（保底不丢字）
        out += String.fromCharCode(code);
      }
    }
    return out;
  }

  /**
   * Windows-1252 基础映射：0x20-0x7E/0xA0-0xFF 与 latin1 一致；0x80-0x9F
   * 是 WinAnsi 特有区（弯引号/破折号/欧元等），未定义码点（0x81/0x8D/
   * 0x8F/0x90/0x9D）输出空，避免 latin1 直通产生乱码。
   */
  private static readonly WIN_1252_HIGH: string[] = [
    '\u20AC', '', '\u201A', '\u0192', '\u201E', '\u2026', '\u2020', '\u2021',
    '\u02C6', '\u2030', '\u0160', '\u2039', '\u0152', '', '\u017D', '',
    '', '\u2018', '\u2019', '\u201C', '\u201D', '\u2022', '\u2013', '\u2014',
    '\u02DC', '\u2122', '\u0161', '\u203A', '\u0153', '', '\u017E', '\u0178'
  ];

  private winAnsiChar(code: number): string {
    if (code < 32 || code === 127) {
      return '';
    }
    if (code >= 0x80 && code <= 0x9F) {
      return PdfParser.WIN_1252_HIGH[code - 0x80];
    }
    return String.fromCharCode(code);
  }

  /** 跳过 <<...>> 字典（含嵌套数组） */
  private skipDict(s: string, start: number): number {
    let i: number = start + 2;
    let depth: number = 1;
    const len: number = s.length;
    while (i < len && depth > 0) {
      if (i + 1 < len && s[i] === '<' && s[i + 1] === '<') {
        depth++;
        i += 2;
        continue;
      }
      if (i + 1 < len && s[i] === '>' && s[i + 1] === '>') {
        depth--;
        i += 2;
        continue;
      }
      if (s[i] === '[') {
        const endB: number = this.findMatching(s, i, '[', ']');
        i = endB + 1;
        continue;
      }
      i++;
    }
    return i;
  }

  private isDelimiter(ch: string): boolean {
    return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' ||
      ch === '(' || ch === ')' || ch === '<' || ch === '>' ||
      ch === '[' || ch === ']' || ch === '/' || ch === '%';
  }

  /** PDF 名称终止符：空白与定界符（注意不含 '/'，名称本身以 '/' 起始） */
  private isNameEnd(ch: string): boolean {
    return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' ||
      ch === '(' || ch === ')' || ch === '<' || ch === '>' ||
      ch === '[' || ch === ']' || ch === '%';
  }

  private normalizeLines(text: string): string {
    const parts: string[] = text.split('\n');
    const clean: string[] = [];
    for (let p = 0; p < parts.length; p++) {
      const trimmed: string = parts[p].trim();
      if (trimmed.length > 0) {
        clean.push(trimmed);
      }
    }
    return clean.join('\n');
  }
}

/** 字面字符串解析结果 */
interface ParseStringResult {
  end: number;
  content: Uint8Array;
}

/** TJ 数组解析结果 */
interface TjArrayResult {
  end: number;
  text: string;
}
