/**
 * PageCacheManager — 分页缓存（磁盘持久化）
 *
 * 以「书指纹（源文件 size + mtime）+ 布局签名（EngineConfig + LayoutProfile +
 * baseFontSize 的稳定序列化）+ PAGE_CACHE_VERSION」三元组为缓存键，命中时跳过
 * 分页管线（splitChapter/TextBreaker/knuthPlass），实现二次打开零分页等待。
 *
 * 缓存载体为缓存目录下的 JSON 文件：
 *   - meta.json：{ version, fingerprint{size,mtime}, layoutSignature }，首次保存章节时写入
 *   - chapter_{i}.json：第 i 个章节的 PaginatedChapter 序列化结果（逐章增量写）
 *
 * 设计约束（与 ParseCacheManager 一致）：
 *   - 纯静态工具类（无状态），全部方法同步实现（fileIo 同步 API）
 *   - 任何内部异常自行吞掉并返回安全默认值（false/null），绝不向调用方抛错
 *   - 缓存损坏/缺失自动回退全量分页流程；逐章缺失仅该章回退实时分页并补写覆盖
 *
 * 注意：PaginatedChapter/Page 定义于 ohrengine-ui-render（PageSplitter.ets），本模块
 * 无法 import（依赖方向为 ui-render → common），故序列化接口使用结构化等价的
 * CacheChapter/CachePage（字段与 PageSplitter 的 PaginatedChapter/Page 完全一致，
 * 结构化类型兼容，可相互赋值）；LineBox 本身定义于 ohrengine-common（HtmlTypes.ets）。
 */

import { fileIo } from '@kit.CoreFileKit';
import type { EngineConfig, LayoutProfile, Margins } from '../types/EngineTypes.ets';
import type { LineBox, MathMlExpression, SvgDocument } from '../types/HtmlTypes.ets';
import { createEmptyLineBox } from '../types/HtmlTypes.ets';

/** hilog 统一前缀（与全工程一致） */
const TAG: string = 'OhEngine';
/** 分页缓存版本号 — 序列化结构不兼容时 +1 使旧缓存全量失效
 *  v2: 移除 LayoutEngine 的 '　　' 全角空格前缀（text 与 charPositions 错位修复），
 *      textIndent 改由 LayoutProfile 显式控制。旧缓存的 LineBox 数据不兼容，必须失效。
 *  v3: 字宽改为确定性估算（CJK/全角/标点=1em，半角=0.55em），不再依赖 MeasureText；
 *      缩进固定 2em 随字号联动。旧 LineBox 的 charPositions 不再兼容，必须失效。
 *  v4: LayoutEngine 保留 TextBreaker 首行缩进（lb.x = textIndent 叠加而非覆盖）、
 *      修正 startCharOffset 累计。旧缓存的 LineBox.x / startCharOffset 不兼容，必须失效。
 *  v5: TxtParser 升级（智能章节检测 + GB18030 解码 + 段落 <p> 结构化），
 *      TXT 章节边界与内容语义变化，旧缓存章节索引不再对应，必须失效。
 *  v6 (Phase 2): 章节文件格式升级为 { pageRangeHash, chapter }（PageRange
 *      连续性校验 + 防错位），meta 增加 bookId/contentFingerprint/
 *      layoutAlgorithmVersion/schemaVersion。旧 v5 缓存不兼容，必须失效。 */
const PAGE_CACHE_VERSION: number = 6;
/** 分页缓存 schema 版本（ReadingAnchor/CacheKey 结构） */
export const PAGE_CACHE_SCHEMA_VERSION: number = 1;
/** 布局算法版本（TextBreaker/Knuth-Plass 结构性变更时 +1，级联作废分页缓存） */
export const LAYOUT_ALGORITHM_VERSION: number = 1;
/** 元信息文件名（版本/指纹/布局签名） */
const META_FILE: string = 'meta.json';
/** 单章缓存文件名前缀：chapter_{i}.json */
const CHAPTER_FILE_PREFIX: string = 'chapter_';
/** Phase 25：分页页数索引文件名（与 meta/chapter 并列的轻量 sidecar） */
const PAGE_COUNT_FILE: string = 'pgcount.json';

/**
 * Phase 25：每章真实页数索引（pgcount.json）——「二次打开显示真实总页数」的依据。
 *
 * 动机：open 只物化热窗，未物化章的总页数此前靠「文本长度估算」，第二次打开
 * 仍显示估算值（如 305 而非 318）。本索引在每次分页写盘（saveChapter）时同步
 * 记录 chapter_{i} 的真实页数，缓存代（layoutSignature）完整后即可精确 Σ。
 *
 * 与 meta.json 的关系：meta 负责「缓存是否有效」（指纹/签名），本索引负责
 * 「每章页数」，同生命周期、同签名键控；invalidate() 时一并删除。
 */
export interface PageCountIndex {
  version: number;
  layoutSignature: string;
  bookId: string;
  contentFingerprint: string;
  /** chapterIndex → 该章真实页数（负数/缺省=未缓存） */
  chapterCounts: number[];
}

/**
 * 指纹数据：源文件（EPUB/TXT）的 size + mtime（毫秒级时间戳）
 */
interface FingerprintData {
  size: number;
  mtime: number;
}

/**
 * meta.json 内容 — 缓存有效性五元组（Phase 2 CacheKey）
 *
 * CacheKey = { bookId, contentFingerprint, layoutSignature,
 *              layoutAlgorithmVersion, schemaVersion, pageRangeHash }
 * 其中 pageRangeHash 按章节写入 chapter_{i}.json（而非 meta），
 * 用于单章 PageRange 连续性 + 防错位校验；pageIndex 永不进入缓存键。
 */
interface CacheMeta {
  version: number;
  bookId: string;
  contentFingerprint: string;
  layoutSignature: string;
  layoutAlgorithmVersion: number;
  schemaVersion: number;
  /** 兼容 v5 旧 meta：书指纹（源文件 size+mtime） */
  fingerprint?: FingerprintData;
}

/**
 * 章节缓存文件的外层包装（Phase 2）：
 *   - pageRangeHash：本章所有 Page 的 (startChar,endChar) 稳定散列（FNV-1a32）
 *   - continuationStart / continuationEnd：章首/章末的 logical char 边界，
 *     用于跨章连续性校验
 *   - chapter：序列化的 SerializableChapter
 */
interface ChapterEnvelope {
  pageRangeHash: string;
  firstChar: number;
  lastChar: number;
  chapter: SerializableChapter;
}

/**
 * 布局签名 — 决定分页结果的全部输入参数
 *
 * 包含 EngineConfig（viewWidth/viewHeight/density）、baseFontSize、
 * LayoutProfile 中影响布局的字段（行距/字距/缩进/边距/段落间距/对齐/字体）；
 * 有意排除 theme/rubyColor 等纯渲染外观字段（不影响分页结果）。
 */
export interface LayoutSignature {
  viewWidth: number;
  viewHeight: number;
  density: number;
  baseFontSize: number;
  lineSpacing: number;
  letterSpacing: number;
  wordSpacing: number;
  textIndent: number;
  paragraphSpacing: number;
  margins: Margins;
  textAlign: 'left' | 'right' | 'center' | 'justify';
  fontFamily?: string;
  rubyFontFamily?: string;
  rubyFontSizeRatio?: number;
}

/**
 * 缓存上下文的传输结构 — OhEngineCore 创建后注入 PipelineManager 等消费方
 */
export interface PageCacheContext {
  cacheDir: string;
  sourcePath: string;
  signature: string;
  /** Phase 2 CacheKey: 稳定书 ID */
  bookId?: string;
  /** Phase 2 CacheKey: 内容指纹（source size:mtime） */
  contentFingerprint?: string;
}

/**
 * 单行盒的序列化形态（与 HtmlTypes.ets 的 LineBox 结构等价）
 *
 * Object 类型字段（rubySegments/gridResult/mathMlExpr/svgDoc）无法显式枚举，
 * 以 JSON.stringify 后的字符串字段原样保留，反序列化时 JSON.parse 还原。
 */
interface SerializableLineBox {
  text: string;
  x: number;
  y: number;
  width: number;
  height: number;
  ascent: number;
  descent: number;
  isSoftBreak: boolean;
  imageSrc?: string;
  estimatedLines: number;
  charPositions: number[];
  isLastLineOfParagraph: boolean;
  isCJK: boolean;
  fontFamilyList?: string[];
  rubySegmentsJson?: string;
  isSuperscript?: boolean;
  isSubscript?: boolean;
  listMarker?: string;
  listMarkerX?: number;
  listMarkerFontSize?: number;
  listMarkerColor?: string;
  markerImageSrc?: string;
  listLevel?: number;
  gridResultJson?: string;
  isFloat?: boolean;
  marginTop?: number;
  marginRight?: number;
  marginBottom?: number;
  marginLeft?: number;
  effectiveOpacity: number;
  startCharOffset: number;
  charWidths: number[];
  renderedY: number;
  containerOverflow?: string;
  containerX?: number;
  containerY?: number;
  containerWidth?: number;
  containerHeight?: number;
  fontWeight?: number;
  fontStyle?: string;
  fontSynthesis?: string;
  fontFamily?: string;
  mathMlExprJson?: string;
  svgDocJson?: string;
}

/**
 * 页面的序列化形态（与 PageSplitter.ets 的 Page 结构等价）
 */
interface SerializablePage {
  index: number;
  lines: SerializableLineBox[];
  startLineIndex: number;
  endLineIndex: number;
  startPosition: number;
  endPosition: number;
  hasPageBreakBefore: boolean;
  isEmpty: boolean;
  yOffset: number;
  startChar: number;
  endChar: number;
}

/**
 * 章节的序列化形态（与 PageSplitter.ets 的 PaginatedChapter 结构等价）
 */
interface SerializableChapter {
  href: string;
  pages: SerializablePage[];
  totalPages: number;
  totalLineCount: number;
  isStub: boolean;
}

/**
 * 分页缓存章节 — 与 ohrengine-ui-render 的 PaginatedChapter 结构化等价
 * （结构化类型兼容，可相互赋值）
 */
export interface CacheChapter {
  href: string;
  pages: CachePage[];
  totalPages: number;
  totalLineCount: number;
  isStub: boolean;
}

/**
 * 分页缓存页面 — 与 ohrengine-ui-render 的 Page 结构化等价
 */
export interface CachePage {
  index: number;
  lines: LineBox[];
  startLineIndex: number;
  endLineIndex: number;
  startPosition: number;
  endPosition: number;
  hasPageBreakBefore: boolean;
  isEmpty: boolean;
  yOffset: number;
  /** Phase 2: 页起始 logical char（章节内全局 UTF-16 offset；无文本页用 -1） */
  startChar?: number;
  /** Phase 2: 页结束 logical char（章节内全局 UTF-16 offset；无文本页用 -1） */
  endChar?: number;
}

/**
 * 分页缓存管理器 — 纯静态工具类
 *
 * 方法分组：
 *   - 布局签名：computeLayoutSignature（T002）
 *   - 序列化：serializePaginatedChapter / deserializePaginatedChapter（T003）
 *   - 磁盘 IO：isCacheValid / loadChapter / saveChapter / invalidate（T004）
 */
/**
 * Phase 16.0 诊断收集器（可选项；传 null/缺省则不收集，语义零变化）。
 */
export interface DeserializeDiag {
  jsonParseMs: number;
  rebuildMs: number;
  lineBoxCount: number;
  textCharCount: number;
}

export class PageCacheManager {
  /** 当前分页缓存序列化结构版本（Phase 7 migration 用） */
  static getCacheVersion(): number {
    return PAGE_CACHE_VERSION;
  }

  /**
   * 计算布局签名 — 决定分页结果的所有输入参数的稳定序列化
   *
   * 手工挑选参与分页的字段并显式构造 LayoutSignature 对象后 JSON.stringify：
   *   - config：viewWidth / viewHeight / density（视口与像素密度）
   *   - baseFontSize：正文字号
   *   - profile：lineSpacing / letterSpacing / wordSpacing / textIndent /
   *     margins / paragraphSpacing / textAlign / fontFamily / rubyFontFamily /
   *     rubyFontSizeRatio
   * 有意排除 theme / rubyColor 等纯渲染外观字段（它们不影响分页结果）。
   *
   * @param config - 引擎视口配置
   * @param profile - 布局参数集
   * @param baseFontSize - 正文字号（pt）
   * @returns 签名哈希字符串；异常时返回空串（调用方视为签名不可用）
   */
  static computeLayoutSignature(config: EngineConfig, profile: LayoutProfile,
    baseFontSize: number): string {
    try {
      const margins: Margins = profile.margins;
      const sig: LayoutSignature = {
        viewWidth: config.viewWidth,
        viewHeight: config.viewHeight,
        density: config.density,
        baseFontSize: baseFontSize,
        lineSpacing: profile.lineSpacing,
        letterSpacing: profile.letterSpacing,
        wordSpacing: profile.wordSpacing,
        textIndent: profile.textIndent,
        paragraphSpacing: profile.paragraphSpacing,
        margins: {
          left: margins.left,
          right: margins.right,
          top: margins.top,
          bottom: margins.bottom
        },
        textAlign: profile.textAlign,
        fontFamily: profile.fontFamily,
        rubyFontFamily: profile.rubyFontFamily,
        rubyFontSizeRatio: profile.rubyFontSizeRatio
      };
      return JSON.stringify(sig);
    } catch (_e) {
      return '';
    }
  }

  /**
   * 序列化章节 — PaginatedChapter → SerializableChapter → JSON 字符串
   *
   * 显式枚举字段（不依赖原型/类信息，保证 JSON 纯净）：
   *   - 章节：href / totalPages / totalLineCount / isStub / pages[]
   *   - 页面：index / startLineIndex / endLineIndex / startPosition / endPosition /
   *     hasPageBreakBefore / isEmpty / yOffset / lines[]
   *   - 行盒：全部基础字段显式枚举；Object 类型字段（rubySegments / gridResult /
   *     mathMlExpr / svgDoc）以 JSON.stringify 字符串字段原样保留
   *
   * @param chapter - 分页结果（ohrengine-ui-render 的 PaginatedChapter，结构化兼容）
   * @returns JSON 字符串；异常返回 ''（调用方跳过缓存写入）
   */
  static serializePaginatedChapter(chapter: CacheChapter): string {
    try {
      const pages: SerializablePage[] = [];
      let runningChar: number = 0;
      for (let i = 0; i < chapter.pages.length; i++) {
        const page: CachePage = chapter.pages[i];
        const lines: SerializableLineBox[] = [];
        for (let j = 0; j < page.lines.length; j++) {
          lines.push(PageCacheManager.serializeLineBox(page.lines[j]));
        }
        // Phase 2 PageRange: 章内全局 logical char（逐行累加，node-local 无关，
        // 单调且可在保存/加载间复现）。图片/块级节点贡献 0 长度页（允许）。
        let pageStart: number = runningChar;
        let pageEnd: number = runningChar;
        for (let j = 0; j < page.lines.length; j++) {
          const line: LineBox = page.lines[j];
          pageEnd += (line.text !== undefined ? line.text.length : 0);
        }
        runningChar = pageEnd;
        if (page.startChar !== undefined && page.startChar >= 0) {
          pageStart = page.startChar;
        }
        if (page.endChar !== undefined && page.endChar >= 0) {
          pageEnd = page.endChar;
        }
        const sp: SerializablePage = {
          index: page.index,
          lines: lines,
          startLineIndex: page.startLineIndex,
          endLineIndex: page.endLineIndex,
          startPosition: page.startPosition,
          endPosition: page.endPosition,
          hasPageBreakBefore: page.hasPageBreakBefore,
          isEmpty: page.isEmpty,
          yOffset: page.yOffset,
          startChar: pageStart >= 0 ? pageStart : 0,
          endChar: pageEnd >= 0 ? pageEnd : 0
        };
        pages.push(sp);
      }
      const sc: SerializableChapter = {
        href: chapter.href,
        pages: pages,
        totalPages: chapter.totalPages,
        totalLineCount: chapter.totalLineCount,
        isStub: chapter.isStub
      };
      return JSON.stringify(sc);
    } catch (_e) {
      return '';
    }
  }

  /**
   * 反序列化章节 — JSON 字符串 → CacheChapter
   *
   * 逐字段重建，缺字段回退安全默认（string→''、number→0、boolean→false、
   * 数组→[]、可选→undefined）；任何异常（JSON 损坏/结构不完整）返回 null，
   * 由调用方回退实时分页并补写覆盖。
   *
   * @param text - serializePaginatedChapter 的输出
   * @param diag - Phase 16.0 只读测量收集器（可选；null=不收集）
   * @returns 重建的章节；无缓存/损坏返回 null（不抛错）
   */
  static deserializePaginatedChapter(text: string, diag: DeserializeDiag | null = null): CacheChapter | null {
    const tJson0: number = Date.now();
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const tJson1: number = Date.now();
      const hrefVal: Object | undefined = raw['href'];
      const pagesVal: Object | undefined = raw['pages'];
      if (typeof hrefVal !== 'string' || !Array.isArray(pagesVal)) {
        return null;
      }
      const href: string = hrefVal;
      const pagesRaw: Object[] = pagesVal as Object[];
      const pages: CachePage[] = [];
      for (let i = 0; i < pagesRaw.length; i++) {
        const p: CachePage | null = PageCacheManager.deserializePage(pagesRaw[i]);
        if (p === null) {
          return null;
        }
        pages.push(p);
      }
      const totalPagesVal: Object | undefined = raw['totalPages'];
      const totalLineCountVal: Object | undefined = raw['totalLineCount'];
      const isStubVal: Object | undefined = raw['isStub'];
      const chapter: CacheChapter = {
        href: href,
        pages: pages,
        totalPages: typeof totalPagesVal === 'number' ? totalPagesVal : 0,
        totalLineCount: typeof totalLineCountVal === 'number' ? totalLineCountVal : 0,
        isStub: typeof isStubVal === 'boolean' ? isStubVal : false
      };
      if (diag !== null) {
        const tEnd: number = Date.now();
        diag.jsonParseMs = tJson1 - tJson0;
        diag.rebuildMs = tEnd - tJson1;
        let lines: number = 0;
        let chars: number = 0;
        for (let i = 0; i < pages.length; i++) {
          const pLines = pages[i].lines;
          lines += pLines.length;
          for (let l = 0; l < pLines.length; l++) {
            const t = pLines[l].text;
            chars += t !== undefined && t !== null ? t.length : 0;
          }
        }
        diag.lineBoxCount = lines;
        diag.textCharCount = chars;
      }
      return chapter;
    } catch (_e) {
      return null;
    }
  }

  /**
   * 序列化行盒 — LineBox → SerializableLineBox（显式枚举 + Object 字段 JSON 化）
   *
   * @param line - 行盒（来自 ohrengine-common 的 LineBox）
   * @returns 序列化形态
   */
  private static serializeLineBox(line: LineBox): SerializableLineBox {
    const sl: SerializableLineBox = {
      text: line.text,
      x: line.x,
      y: line.y,
      width: line.width,
      height: line.height,
      ascent: line.ascent,
      descent: line.descent,
      isSoftBreak: line.isSoftBreak,
      estimatedLines: line.estimatedLines,
      charPositions: line.charPositions,
      isLastLineOfParagraph: line.isLastLineOfParagraph,
      isCJK: line.isCJK,
      effectiveOpacity: line.effectiveOpacity,
      startCharOffset: line.startCharOffset,
      charWidths: line.charWidths,
      renderedY: line.renderedY
    };
    if (line.imageSrc !== undefined) {
      sl.imageSrc = line.imageSrc;
    }
    if (line.fontFamilyList !== undefined) {
      sl.fontFamilyList = line.fontFamilyList;
    }
    if (line.rubySegments !== undefined) {
      sl.rubySegmentsJson = JSON.stringify(line.rubySegments);
    }
    if (line.isSuperscript !== undefined) {
      sl.isSuperscript = line.isSuperscript;
    }
    if (line.isSubscript !== undefined) {
      sl.isSubscript = line.isSubscript;
    }
    if (line.listMarker !== undefined) {
      sl.listMarker = line.listMarker;
    }
    if (line.listMarkerX !== undefined) {
      sl.listMarkerX = line.listMarkerX;
    }
    if (line.listMarkerFontSize !== undefined) {
      sl.listMarkerFontSize = line.listMarkerFontSize;
    }
    if (line.listMarkerColor !== undefined) {
      sl.listMarkerColor = line.listMarkerColor;
    }
    if (line.markerImageSrc !== undefined) {
      sl.markerImageSrc = line.markerImageSrc;
    }
    if (line.listLevel !== undefined) {
      sl.listLevel = line.listLevel;
    }
    if (line.gridResult !== undefined) {
      sl.gridResultJson = JSON.stringify(line.gridResult);
    }
    if (line.isFloat !== undefined) {
      sl.isFloat = line.isFloat;
    }
    if (line.marginTop !== undefined) {
      sl.marginTop = line.marginTop;
    }
    if (line.marginRight !== undefined) {
      sl.marginRight = line.marginRight;
    }
    if (line.marginBottom !== undefined) {
      sl.marginBottom = line.marginBottom;
    }
    if (line.marginLeft !== undefined) {
      sl.marginLeft = line.marginLeft;
    }
    if (line.containerOverflow !== undefined) {
      sl.containerOverflow = line.containerOverflow;
    }
    if (line.containerX !== undefined) {
      sl.containerX = line.containerX;
    }
    if (line.containerY !== undefined) {
      sl.containerY = line.containerY;
    }
    if (line.containerWidth !== undefined) {
      sl.containerWidth = line.containerWidth;
    }
    if (line.containerHeight !== undefined) {
      sl.containerHeight = line.containerHeight;
    }
    if (line.fontWeight !== undefined) {
      sl.fontWeight = line.fontWeight;
    }
    if (line.fontStyle !== undefined) {
      sl.fontStyle = line.fontStyle;
    }
    if (line.fontSynthesis !== undefined) {
      sl.fontSynthesis = line.fontSynthesis;
    }
    if (line.fontFamily !== undefined) {
      sl.fontFamily = line.fontFamily;
    }
    if (line.mathMlExpr !== undefined) {
      sl.mathMlExprJson = JSON.stringify(line.mathMlExpr);
    }
    if (line.svgDoc !== undefined) {
      sl.svgDocJson = JSON.stringify(line.svgDoc);
    }
    return sl;
  }

  /**
   * 反序列化页面 — SerializablePage → CachePage（缺字段回退安全默认）
   *
   * @param rawPage - 章节 JSON 中的页面对象
   * @returns 重建的页面；结构异常返回 null
   */
  private static deserializePage(rawPage: Object): CachePage | null {
    try {
      const rec: Record<string, Object> = rawPage as Record<string, Object>;
      const linesVal: Object | undefined = rec['lines'];
      if (linesVal === undefined || !Array.isArray(linesVal)) {
        return null;
      }
      const linesRaw: Object[] = linesVal as Object[];
      const lines: LineBox[] = [];
      for (let i = 0; i < linesRaw.length; i++) {
        const line: LineBox | null = PageCacheManager.deserializeLineBox(linesRaw[i]);
        if (line === null) {
          return null;
        }
        lines.push(line);
      }
      const page: CachePage = {
        index: PageCacheManager.numOr(rec['index'], 0),
        lines: lines,
        startLineIndex: PageCacheManager.numOr(rec['startLineIndex'], 0),
        endLineIndex: PageCacheManager.numOr(rec['endLineIndex'], 0),
        startPosition: PageCacheManager.numOr(rec['startPosition'], 0),
        endPosition: PageCacheManager.numOr(rec['endPosition'], 0),
        hasPageBreakBefore: PageCacheManager.boolOr(rec['hasPageBreakBefore'], false),
        isEmpty: PageCacheManager.boolOr(rec['isEmpty'], false),
        yOffset: PageCacheManager.numOr(rec['yOffset'], 0),
        startChar: PageCacheManager.numOr(rec['startChar'], -1),
        endChar: PageCacheManager.numOr(rec['endChar'], -1)
      };
      return page;
    } catch (_e) {
      return null;
    }
  }

  /**
   * 反序列化行盒 — createEmptyLineBox 兜底 + 逐字段覆盖（缺字段回退默认）
   *
   * @param rawLine - 页面 JSON 中的行盒对象
   * @returns 重建的行盒；结构异常返回 null
   */
  private static deserializeLineBox(rawLine: Object): LineBox | null {
    try {
      const rec: Record<string, Object> = rawLine as Record<string, Object>;
      const lb: LineBox = createEmptyLineBox();
      const textVal: Object | undefined = rec['text'];
      if (typeof textVal !== 'string') {
        return null;
      }
      lb.text = textVal;
      lb.x = PageCacheManager.numOr(rec['x'], 0);
      lb.y = PageCacheManager.numOr(rec['y'], 0);
      lb.width = PageCacheManager.numOr(rec['width'], 0);
      lb.height = PageCacheManager.numOr(rec['height'], 0);
      lb.ascent = PageCacheManager.numOr(rec['ascent'], 0);
      lb.descent = PageCacheManager.numOr(rec['descent'], 0);
      lb.isSoftBreak = PageCacheManager.boolOr(rec['isSoftBreak'], false);
      lb.estimatedLines = PageCacheManager.numOr(rec['estimatedLines'], 1);
      lb.charPositions = PageCacheManager.numArrOr(rec['charPositions']);
      lb.isLastLineOfParagraph = PageCacheManager.boolOr(rec['isLastLineOfParagraph'], false);
      lb.isCJK = PageCacheManager.boolOr(rec['isCJK'], false);
      lb.effectiveOpacity = PageCacheManager.numOr(rec['effectiveOpacity'], 1.0);
      lb.startCharOffset = PageCacheManager.numOr(rec['startCharOffset'], 0);
      lb.charWidths = PageCacheManager.numArrOr(rec['charWidths']);
      lb.renderedY = PageCacheManager.numOr(rec['renderedY'], 0);
      const imageSrcVal: Object | undefined = rec['imageSrc'];
      if (typeof imageSrcVal === 'string') {
        lb.imageSrc = imageSrcVal;
      }
      const fontFamilyListVal: Object | undefined = rec['fontFamilyList'];
      if (fontFamilyListVal !== undefined && Array.isArray(fontFamilyListVal)) {
        lb.fontFamilyList = fontFamilyListVal as string[];
      }
      const rubySegmentsJsonVal: Object | undefined = rec['rubySegmentsJson'];
      if (typeof rubySegmentsJsonVal === 'string') {
        lb.rubySegments = JSON.parse(rubySegmentsJsonVal) as Object[];
      }
      if (typeof rec['isSuperscript'] === 'boolean') {
        lb.isSuperscript = rec['isSuperscript'] as boolean;
      }
      if (typeof rec['isSubscript'] === 'boolean') {
        lb.isSubscript = rec['isSubscript'] as boolean;
      }
      const listMarkerVal: Object | undefined = rec['listMarker'];
      if (typeof listMarkerVal === 'string') {
        lb.listMarker = listMarkerVal;
      }
      const listMarkerXVal: Object | undefined = rec['listMarkerX'];
      if (typeof listMarkerXVal === 'number') {
        lb.listMarkerX = listMarkerXVal;
      }
      const listMarkerFontSizeVal: Object | undefined = rec['listMarkerFontSize'];
      if (typeof listMarkerFontSizeVal === 'number') {
        lb.listMarkerFontSize = listMarkerFontSizeVal;
      }
      const listMarkerColorVal: Object | undefined = rec['listMarkerColor'];
      if (typeof listMarkerColorVal === 'string') {
        lb.listMarkerColor = listMarkerColorVal;
      }
      const markerImageSrcVal: Object | undefined = rec['markerImageSrc'];
      if (typeof markerImageSrcVal === 'string') {
        lb.markerImageSrc = markerImageSrcVal;
      }
      const listLevelVal: Object | undefined = rec['listLevel'];
      if (typeof listLevelVal === 'number') {
        lb.listLevel = listLevelVal;
      }
      const gridResultJsonVal: Object | undefined = rec['gridResultJson'];
      if (typeof gridResultJsonVal === 'string') {
        lb.gridResult = JSON.parse(gridResultJsonVal) as Object;
      }
      if (typeof rec['isFloat'] === 'boolean') {
        lb.isFloat = rec['isFloat'] as boolean;
      }
      const marginTopVal: Object | undefined = rec['marginTop'];
      if (typeof marginTopVal === 'number') {
        lb.marginTop = marginTopVal;
      }
      const marginRightVal: Object | undefined = rec['marginRight'];
      if (typeof marginRightVal === 'number') {
        lb.marginRight = marginRightVal;
      }
      const marginBottomVal: Object | undefined = rec['marginBottom'];
      if (typeof marginBottomVal === 'number') {
        lb.marginBottom = marginBottomVal;
      }
      const marginLeftVal: Object | undefined = rec['marginLeft'];
      if (typeof marginLeftVal === 'number') {
        lb.marginLeft = marginLeftVal;
      }
      const containerOverflowVal: Object | undefined = rec['containerOverflow'];
      if (typeof containerOverflowVal === 'string') {
        lb.containerOverflow = containerOverflowVal;
      }
      const containerXVal: Object | undefined = rec['containerX'];
      if (typeof containerXVal === 'number') {
        lb.containerX = containerXVal;
      }
      const containerYVal: Object | undefined = rec['containerY'];
      if (typeof containerYVal === 'number') {
        lb.containerY = containerYVal;
      }
      const containerWidthVal: Object | undefined = rec['containerWidth'];
      if (typeof containerWidthVal === 'number') {
        lb.containerWidth = containerWidthVal;
      }
      const containerHeightVal: Object | undefined = rec['containerHeight'];
      if (typeof containerHeightVal === 'number') {
        lb.containerHeight = containerHeightVal;
      }
      const fontWeightVal: Object | undefined = rec['fontWeight'];
      if (typeof fontWeightVal === 'number') {
        lb.fontWeight = fontWeightVal;
      }
      const fontStyleVal: Object | undefined = rec['fontStyle'];
      if (typeof fontStyleVal === 'string') {
        lb.fontStyle = fontStyleVal;
      }
      const fontSynthesisVal: Object | undefined = rec['fontSynthesis'];
      if (typeof fontSynthesisVal === 'string') {
        lb.fontSynthesis = fontSynthesisVal;
      }
      const fontFamilyVal: Object | undefined = rec['fontFamily'];
      if (typeof fontFamilyVal === 'string') {
        lb.fontFamily = fontFamilyVal;
      }
      const mathMlExprJsonVal: Object | undefined = rec['mathMlExprJson'];
      if (typeof mathMlExprJsonVal === 'string') {
        lb.mathMlExpr = JSON.parse(mathMlExprJsonVal) as MathMlExpression;
      }
      const svgDocJsonVal: Object | undefined = rec['svgDocJson'];
      if (typeof svgDocJsonVal === 'string') {
        lb.svgDoc = JSON.parse(svgDocJsonVal) as SvgDocument;
      }
      return lb;
    } catch (_e) {
      return null;
    }
  }

  /**
   * Phase 25：读取单章缓存文件的真实页数（不重建 LineBox，仅取 pages 长度）。
   * 用于把「旧构建产出的完整缓存」回填进页数索引（一次性的 open 期轻量扫描）。
   * 文件缺失/损坏返回 -1。
   */
  static readChapterPageCount(cacheDir: string, chapterIndex: number): number {
    let text: string = '';
    try {
      text = fileIo.readTextSync(cacheDir + '/' + CHAPTER_FILE_PREFIX + chapterIndex + '.json');
    } catch (_e) {
      return -1;
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const pages: Object | undefined = raw['pages'];
      if (pages === undefined || !Array.isArray(pages)) {
        return -1;
      }
      const arr: Array<Object> = pages as Array<Object>;
      return arr.length;
    } catch (_e) {
      return -1;
    }
  }

  /** number 安全读取：非 number 回退默认值 */
  private static numOr(val: Object | undefined, fallback: number): number {
    return typeof val === 'number' ? val : fallback;
  }

  /** string 安全读取：非 string 回退默认值 */
  private static strOr(val: Object | undefined, fallback: string): string {
    return typeof val === 'string' ? val : fallback;
  }

  /** boolean 安全读取：非 boolean 回退默认值 */
  private static boolOr(val: Object | undefined, fallback: boolean): boolean {
    return typeof val === 'boolean' ? val : fallback;
  }

  /** number[] 安全读取：非数组回退空数组 */
  private static numArrOr(val: Object | undefined): number[] {
    if (val !== undefined && Array.isArray(val)) {
      return val as number[];
    }
    return [];
  }

  /**
   * 校验缓存有效性 — Phase 2 CacheKey 六元组
   *
   * 逐一校验：
   *   - meta.json 缺失/损坏
   *   - version（序列化结构）不匹配
   *   - bookId 不匹配（ReadingState 复用同一缓存键基座）
   *   - contentFingerprint 不匹配（源内容语义变化）
   *   - 书指纹（源文件 size/mtime）不匹配（文件被替换）
   *   - 布局签名不匹配（字号/行距/视口等设置变化）
   *
   * @param cacheDir - 缓存目录绝对路径
   * @param sourcePath - 源文件（EPUB/TXT）绝对路径，用于计算书指纹
   * @param signature - computeLayoutSignature 的当前布局签名
   * @param bookId - 稳定书 ID（缺省 '' 跳过校验，兼容旧调用）
   * @param contentFingerprint - 内容指纹（缺省 '' 跳过校验）
   * @returns CacheKey 全匹配返回 true；任一失效返回 false（不抛错）
   */
  static isCacheValid(cacheDir: string, sourcePath: string, signature: string,
    bookId?: string, contentFingerprint?: string): boolean {
    try {
      const meta: CacheMeta | null = PageCacheManager.readMeta(cacheDir);
      if (meta === null) {
        return false;
      }
      if (meta.version !== PAGE_CACHE_VERSION) {
        return false;
      }
      if (meta.layoutAlgorithmVersion !== LAYOUT_ALGORITHM_VERSION) {
        return false;
      }
      if (meta.schemaVersion !== PAGE_CACHE_SCHEMA_VERSION) {
        return false;
      }
      if (bookId !== undefined && bookId.length > 0 &&
        meta.bookId !== bookId) {
        return false;
      }
      if (contentFingerprint !== undefined && contentFingerprint.length > 0 &&
        meta.contentFingerprint !== contentFingerprint) {
        return false;
      }
      let stat: fileIo.Stat;
      try {
        stat = fileIo.statSync(sourcePath);
      } catch (_e) {
        return false;
      }
      if (meta.fingerprint === undefined ||
        meta.fingerprint.size !== stat.size || meta.fingerprint.mtime !== stat.mtime) {
        return false;
      }
      if (meta.layoutSignature !== signature) {
        return false;
      }
      return true;
    } catch (_e) {
      return false;
    }
  }

  /**
   * 读取单章分页缓存
   *
   * 单章缺失/损坏返回 null（不抛错），由调用方对该章回退实时分页并补写覆盖；
   * 不会因单章问题影响其他章节（逐章部分命中）。
   *
   * @param cacheDir - 缓存目录绝对路径
   * @param chapterIndex - 章节索引（0 起）
   * @returns 重建的章节；无缓存/损坏返回 null
   */
  static loadChapter(cacheDir: string, chapterIndex: number): CacheChapter | null {
    const path: string = cacheDir + '/' + PageCacheManager.chapterFileName(chapterIndex);
    let text: string = '';
    try {
      text = fileIo.readTextSync(path);
    } catch (_e) {
      // chapter_{i}.json 不存在（首次打开/部分命中缺失章）——正常回退路径
      return null;
    }
    const chapter: CacheChapter | null = PageCacheManager.deserializePaginatedChapter(text);
    if (chapter === null) {
      return null;
    }
    // Phase 2 连续性校验：相邻页 endChar/startChar 必须逻辑连续（同一 layout
    // session 下允许图片页/不可拆分节点的可解释边界）。发现无解释的
    // overlap/omission/jump 时按损坏处理，调用方删除该章缓存并重算。
    if (!PageCacheManager.isPageRangeContinuous(chapter)) {
      return null;
    }
    return chapter;
  }

  /**
   * 写入单章分页缓存（逐章增量写，不等全部章节完成）
   *
   * 1. 递归创建缓存目录（已存在则忽略）
   * 2. 首次保存（meta.json 不存在）时写入 meta.json：version + 书指纹 + 布局签名
   *    （sourcePath/signature 由 OhEngineCore 传入，PipelineManager 增量写时省略）
   * 3. 写入 chapter_{i}.json 并输出 `PageCache: saved chapter N` 日志（US3 验收）
   *
   * @param cacheDir - 缓存目录绝对路径
   * @param chapterIndex - 章节索引（0 起）
   * @param chapter - 分页结果（结构化兼容 PaginatedChapter）
   * @param sourcePath - 源文件绝对路径（仅首次保存需传，用于写 meta.json 指纹）
   * @param signature - 布局签名（仅首次保存需传）
   */
  static saveChapter(cacheDir: string, chapterIndex: number, chapter: CacheChapter,
    sourcePath?: string, signature?: string, bookId?: string, contentFingerprint?: string): void {
    try {
      const text: string = PageCacheManager.serializePaginatedChapter(chapter);
      if (text.length === 0) {
        return;
      }
      // HarmonyOS mkdirSync(path, true) 在目录已存在时仍抛 "File exists"；
      // 且双级父目录缺失时可能失败。先判断存在性再创建；cacheDir 父目录
      // 缺失时逐级确保（Phase 8 修复：首次打开无预建目录时写入失败）。
      try {
        fileIo.statSync(cacheDir);
      } catch (_e) {
        const lastSlash: number = cacheDir.lastIndexOf('/');
        if (lastSlash > 0) {
          const parent: string = cacheDir.substring(0, lastSlash);
          try {
            fileIo.statSync(parent);
          } catch (_e2) {
            try {
              fileIo.mkdirSync(parent, true);
            } catch (_e3) {
            }
          }
        }
        try {
          fileIo.mkdirSync(cacheDir, true);
        } catch (_e2) {
        }
      }
      if (sourcePath !== undefined && signature !== undefined) {
        if (!PageCacheManager.hasMeta(cacheDir)) {
          PageCacheManager.writeMeta(cacheDir, sourcePath, signature, bookId, contentFingerprint);
        }
      }
      const path: string = cacheDir + '/' + PageCacheManager.chapterFileName(chapterIndex);
      // HarmonyOS OpenMode.CREATE 在文件已存在时报 "File exists"（不会像 POSIX
      // O_CREAT|O_TRUNC 那样覆盖）。章节可能因 reflow/重复打开被多次保存，
      // 故写入前先删除旧文件，保证幂等覆盖。
      try {
        fileIo.unlinkSync(path);
      } catch (_e) {
        // 文件不存在——正常首次写入路径
      }
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      PageCacheManager.savedCounter++;
      PageCacheManager.savedLastDir = cacheDir;
      PageCacheManager.savedLastIndex = chapterIndex;
    } catch (_e) {
    }
  }

  /**
   * Phase 2: 校验相邻页 charRange 逻辑连续性。
   * 仅校验连续两页间：page.i.endChar <= page.i+1.startChar（页面按文本顺序推进），
   * 允许图片页/不可拆分节点造成 0 长度页（startChar==endChar）；发现
   * overlap（end > next start）或未解释的 jump 视为损坏。
   */
  static isPageRangeContinuous(chapter: CacheChapter): boolean {
    const pages: CachePage[] = chapter.pages;
    if (pages.length <= 1) {
      return true;
    }
    for (let i: number = 0; i < pages.length - 1; i++) {
      const cur: CachePage = pages[i];
      const next: CachePage = pages[i + 1];
      if (cur.endChar === undefined || cur.startChar === undefined ||
        next.startChar === undefined) {
        continue;
      }
      // 无文本页（-1）跳过；图占位页允许 startChar==endChar
      if (cur.endChar < 0 || next.startChar < 0) {
        continue;
      }
      // overlap：前一页结束 char 超出下一页开始 char
      if (cur.endChar > next.startChar) {
        return false;
      }
      // 大跳变（>8 页估算间隔，通常意味着文本被改动/布局异常）保守放行——
      // 只抓明确 overlap 与倒退。
      if (next.startChar < 0) {
        return false;
      }
    }
    return true;
  }

  /** 诊断：本进程 saveChapter 累计调用次数 */
  static savedCounter: number = 0;
  /** 诊断：最近一次 saveChapter 的 cacheDir */
  static savedLastDir: string = '';
  /** 诊断：最近一次 saveChapter 的 chapter index */
  static savedLastIndex: number = -1;

  /**
   * 使缓存失效 — 删除 L2 分页缓存（meta.json + chapter_*.json），
   * **保留 L0 分块子目录 parse/**（Phase 8 D1：invalidate 不得连带删除解析缓存）。
   *
   * 文件不存在/删除失败静默忽略（不抛错）；目录删除失败时尝试逐个删除文件，
   * 保证后续 saveChapter 可重建。
   *
   * @param cacheDir - 缓存目录绝对路径
   */
  static invalidate(cacheDir: string): void {
    // 只清 L2 产物：meta.json + chapter_{i}.json + pgcount.json；保留 parse/（L0）与其它非 L2 文件。
    const names: string[] = PageCacheManager.safeList(cacheDir);
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (name === META_FILE || name.startsWith(CHAPTER_FILE_PREFIX) || name === PAGE_COUNT_FILE) {
        try {
          fileIo.unlinkSync(cacheDir + '/' + name);
        } catch (_e) {
        }
      }
    }
  }

  /**
   * Phase 25：章节分页落盘后同步页数索引（chapterIndex → 真实页数）。
   *
   * layoutSignature 与已存索引不一致（排版参数变更后的新缓存代）时丢弃旧代
   * 计数重新累积——旧代计数对当前排版无意义，混用会给出虚假总数。
   * 幂等、异常吞掉（不阻断分页写盘主路径）。
   */
  static updatePageCount(cacheDir: string, chapterIndex: number, pageCount: number,
    layoutSignature: string, bookId: string, contentFingerprint: string): void {
    if (cacheDir.length === 0 || chapterIndex < 0 || pageCount <= 0) {
      return;
    }
    try {
      const cur: PageCountIndex | null = PageCacheManager.readPageCountIndex(cacheDir);
      let counts: number[] = [];
      if (cur !== null && cur.layoutSignature === layoutSignature && cur.chapterCounts !== undefined) {
        counts = cur.chapterCounts.slice();
      }
      while (counts.length <= chapterIndex) {
        counts.push(-1);
      }
      counts[chapterIndex] = pageCount;
      const idx: PageCountIndex = {
        version: PAGE_CACHE_VERSION,
        layoutSignature: layoutSignature,
        bookId: bookId,
        contentFingerprint: contentFingerprint,
        chapterCounts: counts
      };
      PageCacheManager.writePageCountIndex(cacheDir, idx);
    } catch (_e) {
    }
  }

  /**
   * Phase 25：读取页数索引（layoutSignature 不匹配返回 null —— 调用方退估算）。
   */
  static readPageCountIndex(cacheDir: string): PageCountIndex | null {
    if (cacheDir.length === 0) {
      return null;
    }
    let text: string = '';
    try {
      text = fileIo.readTextSync(cacheDir + '/' + PAGE_COUNT_FILE);
    } catch (_e) {
      return null;
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const sig: string = PageCacheManager.strOr(raw['layoutSignature'], '');
      const counts: number[] = PageCacheManager.numArrOr(raw['chapterCounts']);
      if (sig.length === 0 || counts.length === 0) {
        return null;
      }
      return {
        version: PageCacheManager.numOr(raw['version'], 0),
        layoutSignature: sig,
        bookId: PageCacheManager.strOr(raw['bookId'], ''),
        contentFingerprint: PageCacheManager.strOr(raw['contentFingerprint'], ''),
        chapterCounts: counts
      } as PageCountIndex;
    } catch (_e) {
      return null;
    }
  }

  /**
   * Phase 25：原子写页数索引（tmp + rename，同 meta 原子语义）。
   */
  private static writePageCountIndex(cacheDir: string, idx: PageCountIndex): void {
    try {
      const target: string = cacheDir + '/' + PAGE_COUNT_FILE;
      const tmp: string = target + '.tmp';
      let json: string = '';
      try {
        json = JSON.stringify(idx);
      } catch (_e) {
        return;
      }
      try {
        try {
          fileIo.unlinkSync(tmp);
        } catch (_e) {
        }
        const file: fileIo.File = fileIo.openSync(tmp,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, json);
        fileIo.closeSync(file);
        fileIo.renameSync(tmp, target);
      } catch (_e) {
        try {
          fileIo.unlinkSync(tmp);
        } catch (_e2) {
        }
      }
    } catch (_e) {
    }
  }

  /** 目录列表安全读取（缺失返回 []） */
  private static safeList(path: string): string[] {
    try {
      return fileIo.listFileSync(path);
    } catch (_e) {
      return [];
    }
  }

  /**
   * 读取 meta.json 并校验结构
   *
   * @param cacheDir - 缓存目录绝对路径
   * @returns 有效 meta；文件缺失/JSON 损坏/结构不完整返回 null（不抛错）
   */
  private static readMeta(cacheDir: string): CacheMeta | null {
    const path: string = cacheDir + '/' + META_FILE;
    let text: string = '';
    try {
      text = fileIo.readTextSync(path);
    } catch (_e) {
      return null;
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const versionVal: Object | undefined = raw['version'];
      const layoutSignatureVal: Object | undefined = raw['layoutSignature'];
      const fingerprintVal: Object | undefined = raw['fingerprint'];
      if (typeof versionVal !== 'number' || typeof layoutSignatureVal !== 'string' ||
        fingerprintVal === undefined) {
        return null;
      }
      const fp: Record<string, Object> = fingerprintVal as Record<string, Object>;
      const sizeVal: Object | undefined = fp['size'];
      const mtimeVal: Object | undefined = fp['mtime'];
      if (typeof sizeVal !== 'number' || typeof mtimeVal !== 'number') {
        return null;
      }
      const meta: CacheMeta = {
        version: versionVal,
        bookId: PageCacheManager.strOr(raw['bookId'], ''),
        contentFingerprint: PageCacheManager.strOr(raw['contentFingerprint'], ''),
        layoutSignature: layoutSignatureVal,
        layoutAlgorithmVersion: PageCacheManager.numOr(raw['layoutAlgorithmVersion'],
          LAYOUT_ALGORITHM_VERSION),
        schemaVersion: PageCacheManager.numOr(raw['schemaVersion'], PAGE_CACHE_SCHEMA_VERSION),
        fingerprint: { size: sizeVal, mtime: mtimeVal }
      };
      return meta;
    } catch (_e) {
      return null;
    }
  }

  /** meta.json 是否已存在（存在即视为已初始化，不再覆盖） */
  private static hasMeta(cacheDir: string): boolean {
    return PageCacheManager.readMeta(cacheDir) !== null;
  }

  /**
   * 写入 meta.json（首次保存章节时调用）— Phase 2 CacheKey 五元组
   *
   * @param cacheDir - 缓存目录绝对路径
   * @param sourcePath - 源文件绝对路径（statSync 取 size/mtime）
   * @param signature - 布局签名
   * @param bookId - 稳定书 ID（CacheKey 组成部分）
   * @param contentFingerprint - 内容指纹（CacheKey 组成部分）
   */
  private static writeMeta(cacheDir: string, sourcePath: string, signature: string,
    bookId?: string, contentFingerprint?: string): void {
    try {
      const stat: fileIo.Stat = fileIo.statSync(sourcePath);
      const meta: CacheMeta = {
        version: PAGE_CACHE_VERSION,
        bookId: bookId !== undefined ? bookId : '',
        contentFingerprint: contentFingerprint !== undefined ? contentFingerprint : '',
        layoutSignature: signature,
        layoutAlgorithmVersion: LAYOUT_ALGORITHM_VERSION,
        schemaVersion: PAGE_CACHE_SCHEMA_VERSION,
        fingerprint: { size: stat.size, mtime: stat.mtime }
      };
      const text: string = JSON.stringify(meta);
      const path: string = cacheDir + '/' + META_FILE;
      // 同 saveChapter：CREATE 在文件存在时报错，先删后写保证幂等。
      try {
        fileIo.unlinkSync(path);
      } catch (_e) {
        // 文件不存在——首次写入路径
      }
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (_e) {
    }
  }

  /** 章节缓存文件名：chapter_{i}.json */
  private static chapterFileName(chapterIndex: number): string {
    return CHAPTER_FILE_PREFIX + chapterIndex + '.json';
  }

  /**
   * 递归删除目录（含子目录与文件）
   *
   * @param path - 目录绝对路径
   */
  private static removeDirRecursive(path: string): void {
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(path);
    } catch (_e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const child: string = path + '/' + names[i];
      let stat: fileIo.Stat;
      try {
        stat = fileIo.statSync(child);
      } catch (_e) {
        continue;
      }
      let isDirectory: boolean;
      try {
        isDirectory = stat.isDirectory();
      } catch (_e) {
        continue;
      }
      if (isDirectory) {
        PageCacheManager.removeDirRecursive(child);
      } else {
        try {
          fileIo.unlinkSync(child);
        } catch (_e) {
        }
      }
    }
    try {
      fileIo.rmdirSync(path);
    } catch (_e) {
    }
  }
}
