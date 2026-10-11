/**
 * OhEngineCore — Core Engine Lifecycle & Pipeline
 *
 * Refactored for HAR module: uses static ParserRegistry/StrategyRegistry
 * for plugin-based parser/router dispatch. Implements PageManagerHost
 * and PipelineManagerHost to break circular deps.
 *
 * This is NOT the public API entry point. Use OhEngine (facade)
 * for all external consumption.
 */

import { Publication, Annotation, TocItem, ParseCacheManager, PageCacheManager,
  ChapterData, createLinkWithTitle } from 'ohrengine-common';
import { extractParagraphs, buildVChapters, vchapterId } from 'ohrengine-common';
import type { VChapterDef } from 'ohrengine-common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { Book } from 'ohrengine-common';
import { HtmlParser, CssParser, StyleSource, FontFaceParser } from 'ohrengine-parsers';
import type { CssRuleSet, StyleSheet } from 'ohrengine-parsers';
import { DomNode, RenderNode } from 'ohrengine-common';
import type { LineBox } from 'ohrengine-common';
import type { FontFaceRule } from 'ohrengine-common';
import { PageSplitter, PaginatedChapter, PaginationConfig, Page, createDefaultPaginationConfig, createPaginatedChapter } from './layout/PageSplitter.ets';
import { StyleMapper } from './style/StyleMapper.ets';
import { TextBreaker } from './typography/TextBreaker.ets';
import { justify } from './typography/JustifyEngine.ets';
import { CompiledStylesheet, compileRuleSet } from './style/CssCompiler.ets';
import { CssStyleSet, createDefaultCssStyleSet } from 'ohrengine-common';
import { ReadingMetrics } from './typography/ReadingMetrics.ets';
import { font } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { FontLoader } from './typography/FontLoader.ets';
import { FontFallbackChain } from 'ohrengine-common';
import type { FontRegistrar } from 'ohrengine-common';
import { CssImportResolver } from './style/CssImportResolver.ets';
import { MediaConditionalCompiler, MediaContext } from './style/MediaQueryEvaluator.ets';
import { FullTextSearch } from 'ohrengine-feature';
import { ReadingHistoryManager } from 'ohrengine-feature';
import { ThemeManager } from 'ohrengine-feature';
import { ThemePreferenceStorage } from 'ohrengine-feature';
import { SelectionGestureHandler } from 'ohrengine-feature';
import { RemoteResourceLoader } from './layout/RemoteResourceLoader.ets';
import { AnnotationStorage } from 'ohrengine-feature';
import { FontThemeManager } from 'ohrengine-feature';
import { Theme, PRESET_THEMES, FontTheme, FONT_THEMES } from 'ohrengine-common';
import type { IReadingHistoryStore } from 'ohrengine-common';
import type { ReadingState } from 'ohrengine-common';
import { ReadingStateStore, MemoryPressureHub, CacheMigration,
         PAGE_CACHE_SCHEMA_VERSION, LAYOUT_ALGORITHM_VERSION } from 'ohrengine-common';
import { PageManager, PageManagerHost } from './core/PageManager.ets';
import { PipelineManager, PipelineManagerHost, LayoutPriority } from './core/PipelineManager.ets';
import { BACKGROUND_BATCH_CAP } from './core/PipelineManager.ets';
import { ParserRegistry, StrategyRegistry, RenderStrategy } from 'ohrengine-common';
import type { IMediaOverlayController } from 'ohrengine-common';
import { BookFormat, ParsedBook } from 'ohrengine-common';
import type { BookParser } from 'ohrengine-common';
import type { ParseMeta, ParseChapterIndex, ParseChapterChunk } from 'ohrengine-common';
import { EngineState, TurnDirection, PageSlot, EngineConfig, LayoutProfile,
         Margins, ChapterAnnotationGroup, createDefaultEngineConfig,
         FontSizeController, ParameterBus, PageReadyState } from 'ohrengine-common';
import type { CacheChapter, PageCacheContext, PageCountIndex } from 'ohrengine-common';
import type { PageSlot as PageSlotType } from 'ohrengine-common';
import type { TxtLazyDocument, TxtVChapterRef } from 'ohrengine-common';

/**
 * Optional options for OhEngineCore.open().
 */
export interface OpenOptions {
  /**
   * Absolute path of the source file.
   * Required for ZIP-based formats (EPUB): the bookBasePath is the extracted
   * directory whose mtime/size are not stable, so the fingerprint must be
   * computed against the original archive. For plain-file formats (TXT) the
   * source path defaults to bookBasePath and this option can be omitted.
   */
  sourcePath?: string;
  /**
   * 分页缓存独立目录（如 filesDir/cache/books/<书名>/）。
   * 不传时回退到解压目录内的 .pagecache（旧行为）。
   */
  cacheDir?: string;
  /**
   * 阅读状态独立目录（L1 critical state；需在 L2 缓存失效之外单独保存）。
   * 不传时不开持久化（ReadingState 仅在内存使用）。
   */
  readingStateDir?: string;
  /**
   * 持久目录（导入成果）：如 TXT 索引的正式存放位置。
   * 该目录不受 cache 清理 / 配额淘汰 / 版本迁移影响。不传时行为退回现状。
   */
  libraryDir?: string;
}

/**
 * Phase 11: open 前排版参数（prepareOpenTypography 输入）。
 * 与 ReaderSettings 持久化字段对齐；全部可选——缺省保持引擎默认。
 */
export interface OpenTypographyOptions {
  /** 用户字号（fx：FONT_SIZE_LEVELS 映射后的实际值） */
  fontSize?: number;
  /** 行距增量（LayoutProfile.lineSpacing） */
  lineSpacing?: number;
  /** 文本对齐（仅 'left'|'right'|'justify' 生效；'auto' 不传） */
  textAlign?: 'left' | 'right' | 'center' | 'justify';
}

/**
 * OhEngineCore — core engine state, layout pipeline, pagination, and persistence.
 * All fields are public for FeatureManager access.
 * NOT the public API — use OhEngine (facade) for external consumption.
 *
 * Implements PageManagerHost and PipelineManagerHost to break circular
 * dependencies between OhEngineCore ↔ PageManager ↔ PipelineManager.
 */
export class OhEngineCore implements PageManagerHost, PipelineManagerHost {
  /** P0-B: 引擎实例 SESSION 序号（进程内单调；一条书=一个新引擎实例=一个 Session） */
  private static nextSessionSerial: number = 0;
  /** 本 Session 序号（日志/异步结果失效判定用；复用 engine 实例=Session 语义，不另造概念） */
  readonly sessionSerial: number;
  /** 稳定书 ID：manifest.metadata.identifier 优先，回退标题 */
  static resolveBookId(pub: Publication): string {
    const id: string | undefined = pub.manifest.metadata.identifier;
    if (id !== undefined && id.length > 0) {
      return id;
    }
    return pub.getTitle();
  }

  /** Phase 2 (L2 hot cache): 首次打开同步分页的章节半窗半径（current ±N） */
  static readonly HOT_RANGE: number = 2;

  state: EngineState = EngineState.INITIALIZED;
  config: EngineConfig = createDefaultEngineConfig();
  publication: Publication | undefined = undefined;
  bookBasePath: string = '';
  htmlParser: HtmlParser = new HtmlParser();
  pageSplitter: PageSplitter = new PageSplitter();
  lastError: string | undefined = undefined;
  isFXL: boolean = false;
  /** Phase 9.4: TXT 惰性文档（lazy 路径持有；destroy 时释放） */
  txtLazyDoc: TxtLazyDocument | undefined = undefined;
  /** Page-cache context (undefined = caching disabled, e.g. FXL books) */
  pageCacheContext: PageCacheContext | undefined = undefined;
  mediaContext: MediaContext = {
    viewWidth: 720, viewHeight: 1080,
    orientation: 'portrait', colorScheme: 'light', type: 'screen',
    prefersContrast: 'no-preference', prefersReducedMotion: 'no-preference',
    colorGamut: 'srgb',
  };
  readonly searchEngine: FullTextSearch = new FullTextSearch();
  readonly readingHistory: ReadingHistoryManager = new ReadingHistoryManager();
  readonly themeManager: ThemeManager = new ThemeManager();
  readonly fontThemeManager: FontThemeManager = new FontThemeManager('sans-serif');
  readonly annotationStorage: AnnotationStorage = new AnnotationStorage();
  annotationSyncVersion: number = 0;
  epoch: number = 0;
  /** Phase 1 (L1): 阅读状态持久化目录（open 时由 opts.readingStateDir 注入） */
  private readingStateDir: string = '';
  // Phase 8.4 benchmark: 累计计时锚点（ms；destroy 时经命中率摘要输出）
  private benchOpenStart: number = 0;
  private benchRestoreStart: number = 0;
  /** open 热窗分页累计 ms（本次 session） */
  benchOpenMs: number = 0;
  /** restore 累计 ms（本次 session） */
  benchRestoreMs: number = 0;
  /** Phase 9.8: TXT lazy 索引构建/加载耗时 ms（本次 open） */
  benchTxtLazyIndexMs: number = 0;
  layoutProfile: LayoutProfile = {
    lineSpacing: ReadingMetrics.DEFAULT_LINE_SPACING,
    letterSpacing: ReadingMetrics.DEFAULT_LETTER_SPACING,
    wordSpacing: 0,
    textIndent: ReadingMetrics.DEFAULT_TEXT_INDENT,
    margins: { left: 10, right: 10, top: 30, bottom: 26 },
    paragraphSpacing: 0,
    textAlign: 'justify',
    theme: { backgroundColor: '#fffffff0', textColor: '#000000' }
  };
  readonly fontSizeController: FontSizeController;
  readonly paramBus: ParameterBus = new ParameterBus();

  readonly pageManager: PageManager;
  readonly pipelineManager: PipelineManager;

  // ==================== PageManagerHost implementation ====================

  get isReady(): boolean {
    return this.state === EngineState.READY;
  }

  /** Phase 12: 用户动画/拖拽进行中（Flip/Slide 置位；后台 reflow 据此推迟，避免污染动画帧） */
  userAnimating: boolean = false;

  getReadingHistory(): IReadingHistoryStore | undefined {
    return this.readingHistory;
  }

  /**
   * Phase 12: 置位/复位「用户动画进行中」。
   * FlipPageController.start → true；finishFlip/cancel/dispose → false。
   */
  public setUserAnimating(active: boolean): void {
    this.userAnimating = active;
  }

  /**
   * Phase 16.3: 惰性逐字几何生产化——按行恢复 charPositions/charWidths。
   * 仅当行缺失（Worker 传输已剔除）时重建；重建复用生产算法
   * （JustifyEngine.justify / TextBreaker.charSlotWidth），纯按行、无整章重算。
   * 就地写回行对象（该行从此常驻，重复访问 0 成本 = per-line cache）。
   */
  /** Phase 16.3: 惰性逐字几何恢复计数（Session 级；dispose 归零 → 隔离证据） */
  lazyGeometryRebuildCount: number = 0;

  public ensureLineGeometry(line: LineBox): void {
    if (line === undefined) {
      return;
    }
    const pos: number[] | undefined = line.charPositions;
    const wid: number[] | undefined = line.charWidths;
    if (pos !== undefined && pos.length > 0 && wid !== undefined && wid.length > 0) {
      return;
    }
    const text: string = line.text;
    const n: number = text.length;
    if (n === 0) {
      line.charPositions = [];
      line.charWidths = [];
      return;
    }
    const align: string = this.layoutProfile.textAlign;
    if (align === 'justify' && !line.isLastLineOfParagraph) {
      const fullWidth: number = this.config.viewWidth * 0.99;
      justify(line, Math.max(1, fullWidth - line.x), this.config.density);
      this.lazyGeometryRebuildCount++;
      return;
    }
    // 非两端对齐行：复刻 TextBreaker.fillCharPositions（measureWidth 单字符语义）。
    // fontSize 取行级源真相 line.ascent（= 布局时字号；与 justify 同一来源），
    // 避免与控制器快照产生微小漂移。
    const cwBase: number = line.ascent > 0 ? line.ascent : this.fontSizeController.baseFontSize;
    const letter: number = this.layoutProfile.letterSpacing;
    const word: number = this.layoutProfile.wordSpacing;
    const positions: number[] = new Array<number>(n);
    const widths: number[] = new Array<number>(n);
    let cursor: number = line.x;
    for (let i = 0; i < n; i++) {
      const ch: string = text[i];
      positions[i] = cursor;
      const cw: number = TextBreaker.charSlotWidth(ch, cwBase) + letter +
        ((ch === ' ' || ch === '\u00A0') ? word : 0);
      widths[i] = cw;
      cursor += cw;
    }
    line.charPositions = positions;
    line.charWidths = widths;
    this.lazyGeometryRebuildCount++;
  }

  /**
   * Phase 16.3: 当前页整页按行恢复（选择交互入口调用；保持 §P0-3 只到「当前页」粒度，
   * 行粒度由 SelectGesture 路径的 ensureLineGeometry 精确执行）。
   */
  public ensureCurrentPageGeometry(): void {
    const slot: PageSlot | undefined = this.pageManager.getCurrentPage();
    if (slot === undefined) {
      return;
    }
    for (let i = 0; i < slot.lines.length; i++) {
      this.ensureLineGeometry(slot.lines[i]);
    }
  }

  // ==================== Phase 1 (L1): ReadingState host hooks ====================

  getBookId(): string {
    if (this.publication === undefined) {
      return '';
    }
    return OhEngineCore.resolveBookId(this.publication);
  }

  getLayoutSignature(): string {
    const ctx: PageCacheContext | undefined = this.pageCacheContext;
    if (ctx !== undefined) {
      return ctx.signature;
    }
    return '';
  }

  getContentFingerprint(): string {
    // 与 PageCacheManager 的指纹口径一致：源文件 size:mtime（毫秒）。
    const ctx: PageCacheContext | undefined = this.pageCacheContext;
    if (ctx === undefined) {
      return '';
    }
    try {
      const stat = fileIo.statSync(ctx.sourcePath);
      return stat.size + ':' + stat.mtime;
    } catch (_e) {
      return '';
    }
  }

  saveReadingState(state: ReadingState): void {
    if (this.readingStateDir.length === 0 || state.bookId.length === 0) {
      return;
    }
    ReadingStateStore.save(this.readingStateDir, state.bookId, state);
  }

  /**
   * Phase 24 (Issue B)：统一分页模型估算参数——单页正文 UTF-16 字符数。
   * 派生自 viewport（config） + 排版参数（margins/lineSpacing） + 字体参数
   * （baseFontSize），不区分 EPUB/TXT/PDF。CJK 全角字形宽度 ≈ 字号，
   * 行高 ≈ 1.5em + lineSpacing 增量，与 TextBreaker/LayoutEngine 口径一致。
   */
  getCharsPerPage(): number {
    const fs: number = Math.max(1, this.fontSizeController.baseFontSize);
    const m = this.layoutProfile.margins;
    const contentH: number = Math.max(1, this.config.viewHeight - m.top - m.bottom);
    const contentW: number = Math.max(1, this.config.viewWidth - m.left - m.right);
    const lineHeight: number = fs * 1.5 + Math.max(0, this.layoutProfile.lineSpacing);
    const linesPerPage: number = Math.max(1, Math.floor(contentH / lineHeight));
    const charsPerLine: number = Math.max(1, Math.floor(contentW / fs));
    return Math.max(1, charsPerLine * linesPerPage);
  }

  /**
   * Phase 3 (L3): memory pressure 收缩。
   * 应用内存告警时调用：L3 内存页缓存缩到 1–2 章（保留 visible/next/previous），
   * 丢弃后可回退 L2/Layout，不影响正确性。
   * @param level 0=normal,1=moderate,2=critical(需激进收缩),3+=background
   */
  public shrinkMemoryCaches(level: number): void {
    if (level >= 2) {
      // CRITICAL/后台：激进缩到 1 章（仅可见页）
      this.pipelineManager.memoryPageCache.shrinkToVisible(1);
    } else if (level === 1) {
      // MODERATE：缩到 2 章（当前 ±1）
      this.pipelineManager.memoryPageCache.shrinkToVisible(2);
    }
  }

  /**
   * Phase 3 (L3): 订阅应用内存压力广播（EntryAbility.onMemoryLevel → publish）。
   * open 时注册，destroy 时注销，防止跨书残留回调。
   */
  public subscribeMemoryPressure(): void {
    MemoryPressureHub.subscribe((level: number): void => {
      this.shrinkMemoryCaches(level);
    });
  }

  public unsubscribeMemoryPressure(): void {
    MemoryPressureHub.unsubscribe();
  }

  public getMemoryPageCacheStats(): string {
    const c = this.pipelineManager.memoryPageCache;
    return 'L3 chapters=' + c.size() + ' bytes~=' + c.estimatedBytes();
  }

  /**
   * Phase 10: 动画窗口保护——pin 指定章节的 L3 内存缓存（不参与 LRU 逐出/收缩）。
   * 仅保护动画生命周期，动画结束立即 unpin（非永久缓存）。
   */
  public pinChapters(chunkIndexes: number[]): void {
    const c = this.pipelineManager.memoryPageCache;
    for (let i: number = 0; i < chunkIndexes.length; i++) {
      if (chunkIndexes[i] >= 0) {
        c.pin(chunkIndexes[i]);
      }
    }
  }

  /** Phase 10: 解除动画窗口 pin */
  public unpinChapters(chunkIndexes: number[]): void {
    const c = this.pipelineManager.memoryPageCache;
    for (let i: number = 0; i < chunkIndexes.length; i++) {
      if (chunkIndexes[i] >= 0) {
        c.unpin(chunkIndexes[i]);
      }
    }
  }

  /**
   * Phase 4 gate: 返回 L3/L2 命中率 + 实时分页摘要（Benchmark/一致性观测）。
   */
  public getCacheHitSummary(): string {
    return this.pipelineManager.getCacheHitSummary() +
      ' | ' + this.getMemoryPageCacheStats();
  }

  public logCacheHitSummary(tag: string): void {
    hilog.info(0x0000, 'OhEngine', 'CacheStats[%{public}s] %{public}s openMs=%{public}d restoreMs=%{public}d txtLazyIdxMs=%{public}d',
      tag, this.getCacheHitSummary(), this.benchOpenMs, this.benchRestoreMs, this.benchTxtLazyIndexMs);
  }

  /** 返回本进程 PageCacheManager 保存统计（诊断用） */
  public getPageCacheSaveStats(): string {
    return 'savedN=' + PageCacheManager.savedCounter +
      ' lastDir=' + PageCacheManager.savedLastDir +
      ' lastIdx=' + PageCacheManager.savedLastIndex;
  }

  /**
   * Phase 7 consistency: 计算当前可见页的 logical page text（比较起点）。
   * Cache ON/OFF 一致性验证时，以 logical page text hash、charRange、startAnchor/
   * endAnchor 为比较对象；不依赖 screenshot hash。
   */
  public computeCurrentPageLogicalTextHash(): string {
    const slot: PageSlot | undefined = this.pageManager.getCurrentPage();
    if (slot === undefined) {
      return '';
    }
    let text: string = '';
    for (let i: number = 0; i < slot.lines.length; i++) {
      const t: string | undefined = slot.lines[i].text;
      if (t !== undefined) {
        text += t;
      }
    }
    if (text.length === 0) {
      return '';
    }
    let h: number = 0x811c9dc5;
    for (let i: number = 0; i < text.length; i++) {
      h ^= text.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h.toString(16) + ':' + text.length;
  }

  /**
   * 恢复上次阅读位置（冷启动/重开书时调用）。
   * 内部按 schemaVersion→contentFingerprint→chapter→paragraphHash→charOffset
   * 顺序校验与定位；失败安全回退，不抛错。
   */
  public restoreLastReadingState(): boolean {
    if (this.readingStateDir.length === 0) {
      return false;
    }
    const bookId: string = this.getBookId();
    if (bookId.length === 0) {
      return false;
    }
    const state: ReadingState | null = ReadingStateStore.load(this.readingStateDir, bookId);
    if (state === null) {
      return false;
    }
    return this.pageManager.restoreReadingState(state);
  }

  /**
   * Phase 2 (L2 hot cache): 读取持久化 ReadingState 的目标章节索引，
   * 用于 open 时决定热窗中心；不可用（无状态/无书）回退 0。
   */
  private peekReadingStateChapter(): number {
    const bookId: string = this.getBookId();
    if (bookId.length === 0 || this.readingStateDir.length === 0) {
      return 0;
    }
    const state: ReadingState | null = ReadingStateStore.load(this.readingStateDir, bookId);
    if (state === null || state.schemaVersion !== 1) {
      return 0;
    }
    const idx: number = this.pageManager.resolveChapterId(state.anchor.chapterId);
    return idx >= 0 ? idx : 0;
  }

  // ==================== PipelineManagerHost implementation ====================

  get pageSlots(): PageSlotType[] {
    return this.pageManager.pageSlots;
  }

  get currentGlobalPage(): number {
    return this.pageManager.currentGlobalPage;
  }

  rebuildPageSlots(): void {
    this.pageManager.rebuildPageSlots();
  }

  relayoutCurrentPageOnly(): void {
    this.pageManager.relayoutCurrentPageOnly();
  }

  /**
   * Construct OhEngineCore with injected dependencies.
   *
   * @param pageManager - Pre-configured PageManager instance
   * @param pipelineManager - Pre-configured PipelineManager instance
   */
  constructor(
    pageManager?: PageManager,
    pipelineManager?: PipelineManager
  ) {
    if (pageManager !== undefined && pipelineManager !== undefined) {
      this.pageManager = pageManager;
      this.pipelineManager = pipelineManager;
    } else {
      // Auto-create internal dependencies (backward compat for no-arg construction)
      const readingMetrics: ReadingMetrics = new ReadingMetrics();
      this.pipelineManager = new PipelineManager(this.htmlParser, this.pageSplitter, this);
      this.pageManager = new PageManager(this.pipelineManager, this.pageSplitter, readingMetrics, this);
    }
    // Phase 12: 后台 reflow 读用户动画状态（推迟后台章处理，避免污染动画帧）
    this.pipelineManager.userAnimating = (): boolean => {
      return this.userAnimating;
    };
    // P0-B: Session 序号 + 创建日志
    OhEngineCore.nextSessionSerial++;
    this.sessionSerial = OhEngineCore.nextSessionSerial;
    hilog.info(0x0000, 'OhEngine', 'SESSION_CREATE id=%{public}d', this.sessionSerial);
    this.fontSizeController = new FontSizeController((): void => {
      this.onFontSizeChanged();
    });
    this.state = EngineState.INITIALIZED;
    // Auto-register default parsers and routers
    this.pipelineManager.styleMapper.loadDefaultStyles();
    this.themeManager.onThemeChange((t: Theme): void => {
      this.layoutProfile.theme.backgroundColor = t.backgroundColor;
      this.layoutProfile.theme.textColor = t.textColor;
      this.paramBus.publish('theme', t);
    });
    this.fontThemeManager.onThemeChange((t: FontTheme): void => {
      this.layoutProfile.fontFamily = t.fontFamily;
      if (t.fontSizePreset !== undefined) {
        this.fontSizeController.setUserFontSize(t.fontSizePreset);
      }
      if (t.lineSpacingPreset !== undefined) {
        this.layoutProfile.lineSpacing = t.lineSpacingPreset;
      }
      if (t.loadingStrategy === 'loadable' && t.loadPath !== undefined && t.loadPath.length > 0) {
        this.pipelineManager.fontLoader.loadFontFaces(
          [{ familyName: t.fontFamily, src: [{ url: t.loadPath }] }],
          '',
          this.bookBasePath
        );
      }
      this.onFontSizeChanged();
    });
  }

  // ==================== Forwarded sub-component accessors ====================

  public getFontLoader(): FontLoader {
    return this.pipelineManager.fontLoader;
  }

  /**
   * 注入字体注册器（ENG-002）：必须由 UI 线程组件调用，
   * 内部使用 UIContext.getFont().registerFont() 替代废弃的 font.registerFont()。
   * 调用时机应在页面 aboutToAppear 之后、字体首次加载之前。
   */
  public setFontRegistrar(registrar: FontRegistrar | null): void {
    this.pipelineManager.fontLoader.setFontRegistrar(registrar);
  }

  public getRemoteResourceLoader(): RemoteResourceLoader {
    return this.pipelineManager.remoteResourceLoader;
  }

  public getMediaOverlayController(): IMediaOverlayController {
    return this.pipelineManager.mediaOverlayController;
  }

  public getFontFallbackChain(): FontFallbackChain {
    return this.pipelineManager.fontFallbackChain;
  }

  // ==================== Configuration ====================

  public configure(cfg: Partial<EngineConfig>): void {
    if (cfg.viewWidth !== undefined) {
      this.config.viewWidth = cfg.viewWidth;
    }
    if (cfg.viewHeight !== undefined) {
      this.config.viewHeight = cfg.viewHeight;
    }
    if (cfg.density !== undefined) {
      this.config.density = cfg.density;
    }
    this.pipelineManager.layoutEngine.setViewport(this.config.viewWidth, this.config.viewHeight);
    this.mediaContext.viewWidth = cfg.viewWidth ?? this.mediaContext.viewWidth;
    this.mediaContext.viewHeight = cfg.viewHeight ?? this.mediaContext.viewHeight;
    this.pipelineManager.layoutEngine.setBaseFontSize(this.fontSizeController.baseFontSize);
    this.pipelineManager.layoutEngine.setDensity(this.config.density);
    this.pipelineManager.layoutEngine.setTextAlign(this.layoutProfile.textAlign);
    this.pipelineManager.layoutEngine.setLetterSpacing(this.layoutProfile.letterSpacing);
    this.pipelineManager.layoutEngine.setWordSpacing(this.layoutProfile.wordSpacing);
    // 首行缩进：保持 TextBreaker 默认 2em（2 个汉字宽，随字号联动）。
    // 不再显式调用 setTextIndent，避免固定 vp 覆盖 2em 联动。
    this.pageSplitter.setConfig(
      createDefaultPaginationConfig(this.config.viewWidth, this.config.viewHeight)
    );
    SelectionGestureHandler.reset();
  }

  public getMargins(): Margins {
    return this.layoutProfile.margins;
  }

  /**
   * Phase 11: open 前置排版参数（必须在 open() 前调用；成功打开一本书一次）。
   *
   * 目的：把「持久化的字号/行距/对齐」在解析与热窗分页**之前**应用到引擎，
   * 使 open 时 computeLayoutSignature 与磁盘 L2/L3 写入时的 signature 一致
   * → 热窗章节直接缓存命中，冷启动不再需要「字号恢复 → 全量同步 reflow」。
   *
   * 约束：不触发 reflow、不隐式作废缓存（reflow 回调路径被 pageManager/pipeline
   * 的 publication===undefined 守卫挡住，refreshPageCacheForSettingsChange 同样
   * 以 pageCacheContext 未建为由短路）。mid-book 调用行为等同直接钳制（无副作用）。
   */
  public prepareOpenTypography(opts: OpenTypographyOptions): void {
    if (opts.fontSize !== undefined) {
      this.fontSizeController.setUserFontSize(opts.fontSize);
    }
    if (opts.lineSpacing !== undefined) {
      this.layoutProfile.lineSpacing = opts.lineSpacing;
      this.pipelineManager.layoutEngine.setLineSpacing(opts.lineSpacing);
    }
    if (opts.textAlign !== undefined) {
      this.layoutProfile.textAlign = opts.textAlign;
      this.pipelineManager.layoutEngine.setTextAlign(opts.textAlign);
    }
    this.pipelineManager.layoutEngine.setBaseFontSize(this.fontSizeController.baseFontSize);
    // CSS 把 baseFontSize/line-height 烘焙进 :root/body/p 规则——必须按新参数重编译，
    // 否则 open 的 layout 用旧字号度量断行。
    this.pipelineManager.loadAndCompileCss();
  }

  /**
   * Phase 11: 首帧后启动后台增量 reflow。
   * 所有「尚未分页（stub）」的章节入 P4_BACKGROUND 队列，逐个以 50ms 间隔处理：
   *   - 缓存命中则直接装载（processNextInQueue 内不 rebuild pageSlots，除非翻入该章）；
   *   - 未命中则实时 parse+layout+split，write-through 到 L2/L3。
   * 不阻塞 UI；不替换动画页；不触发全书同步。
   * @returns 入队章节数（0=全书已就绪）
   */
public scheduleBackgroundReflow(): number {
    const pcs = this.pipelineManager.paginatedChapters;
    const total: number = pcs.length;
    // Phase 21: 后台锚=当前（restore 后）阅读位置章节；首批填锚邻窗，而非固定前缀。
    const anchorCh: number = this.pageManager.getCurrentChapterIndex();
    this.pipelineManager.recenterBackgroundWindow(anchorCh);
    this.pipelineManager.backgroundReflowActive = true;
    this.pipelineManager.backgroundDelayMs = 150;
    const queued: number = this.pipelineManager.enqueueBackgroundContinuation();
    hilog.info(0x0000, 'OhEngine',
      'COLDSTART BACKGROUND_REFLOW_START queued=%{public}d total=%{public}d anchor=%{public}d capped=%{public}d',
      queued, total, anchorCh, BACKGROUND_BATCH_CAP);
    if (queued > 0) {
      hilog.info(0x0000, 'OhEngine', 'SESSION_BACKGROUND_START id=%{public}d queued=%{public}d',
        this.sessionSerial, queued);
    }
    return queued;
  }

  /**
   * Phase 21: restore 成功后按最终阅读位置同步 materialization 窗口。
   * 当前页若为 stub → 该章以 'high' 立即入队；并把后台锚重定位到最终位置。
   */
  public syncWindowAfterRestore(): void {
    const ch: number = this.pageManager.getCurrentChapterIndex();
    this.pipelineManager.recenterBackgroundWindow(ch);
    const slot: PageSlot | undefined = this.pageManager.getCurrentPage();
    if (slot !== undefined && slot.state === 'stub') {
      this.pipelineManager.queueChunkLayout(ch, 'high');
    }
  }

  /**
   * Phase 11: 冷启动阶段日志（Anchor 定位/就绪观测；ReaderHost 首帧配合输出）。
   */
  public logColdStartAnchorResolved(): void {
    const page: PageSlot | undefined = this.pageManager.getCurrentPage();
    const ready: number = page !== undefined && page.readyState !== undefined
      ? page.readyState
      : PageReadyState.NOT_READY;
    hilog.info(0x0000, 'OhEngine',
      'COLDSTART ANCHOR_RESOLVED page=%{public}d ch=%{public}d ready=%{public}d gen=%{public}d',
      this.pageManager.currentGlobalPage, this.pageManager.getCurrentChapterIndex(),
      ready, this.pageManager.getPageGeneration());
  }

  /**
   * Phase 25（真实总页数）：open 期装载「每章真实页数」到 PageManager。
   *
   * 1) 读 pgcount.json（签名校验）：该缓存代已逐章记录过页数（分页写盘时同步）；
   * 2) 缺项回填：旧构建产出的完整 chapter_{i}.json 缓存没有 pgcount，此时逐章
   *    轻量读取真实页数补全并写回（一次性；补齐后再次 open 零扫描）；
   * 3) 全部注入 PageManager——未物化章不再用估算，总页数/页码即时精确。
   *
   * @param pageCacheDir L2 缓存目录
   * @param totalChapters 当前书章节数
   * @param signature 当前布局签名（与缓存代一致才可用）
   */
  private loadPageCountIndex(pageCacheDir: string, totalChapters: number,
    signature: string): void {
    if (totalChapters <= 0 || pageCacheDir.length === 0 || signature.length === 0) {
      this.pageManager.setCachedChapterCounts(null);
      return;
    }
    let counts: number[] = [];
    try {
      const idx: PageCountIndex | null = PageCacheManager.readPageCountIndex(pageCacheDir);
      if (idx !== null && idx.layoutSignature === signature) {
        counts = idx.chapterCounts.slice();
      }
    } catch (_e) {
      counts = [];
    }
    let changed: boolean = false;
    while (counts.length < totalChapters) {
      counts.push(-1);
    }
    for (let ci: number = 0; ci < totalChapters; ci++) {
      if (counts[ci] > 0) {
        continue;
      }
      const c: number = PageCacheManager.readChapterPageCount(pageCacheDir, ci);
      if (c > 0) {
        counts[ci] = c;
        changed = true;
      }
    }
    if (changed) {
      const bId: string = this.pageCacheContext !== undefined
        ? (this.pageCacheContext.bookId !== undefined ? this.pageCacheContext.bookId : '') : '';
      const fp: string = this.pageCacheContext !== undefined
        ? (this.pageCacheContext.contentFingerprint !== undefined
          ? this.pageCacheContext.contentFingerprint : '') : '';
      for (let ci: number = 0; ci < totalChapters; ci++) {
        if (counts[ci] > 0) {
          PageCacheManager.updatePageCount(pageCacheDir, ci, counts[ci], signature, bId, fp);
        }
      }
    }
    let real: number = 0;
    for (let ci: number = 0; ci < counts.length; ci++) {
      if (counts[ci] > 0) {
        real += counts[ci];
      }
    }
    hilog.info(0x0000, 'OhEngine',
      'PAGECOUNT_INDEX loaded=%{public}d total=%{public}d realPages=%{public}d sig=%{public}d',
      counts.length, totalChapters, real, signature.length);
    this.pageManager.setCachedChapterCounts(counts);
  }

  public getLayoutProfile(): LayoutProfile {
    return this.layoutProfile;
  }

  // ==================== Lifecycle ====================

  public getState(): EngineState {
    return this.state;
  }

  public getPublication(): Publication | undefined {
    return this.publication;
  }

  public getTableOfContents(): TocItem[] {
    if (this.publication === undefined) {
      return [];
    }
    return this.publication.getToc();
  }

  public getChapterCount(): number {
    if (this.publication !== undefined) {
      return this.publication.getChapterCount();
    }
    return 0;
  }

  public getLineSpacing(): number {
    return this.layoutProfile.lineSpacing;
  }

  // ==================== Open / Destroy ====================

  /**
   * Open a book from a directory path.
   *
   * Uses ParserRegistry to resolve the correct parser by file extension
   * and StrategyRegistry to dispatch rendering to the correct router.
   * No hardcoded parser or switch(strategy) — fully plugin-based.
   *
   * @param bookBasePath extracted book directory (EPUB) or the source file
   *   itself (TXT / other non-ZIP formats)
   * @param opts optional options; for EPUB pass opts.sourcePath = original
   *   .epub file path so the page-cache fingerprint is stable
   */
  public async open(bookBasePath: string, opts?: OpenOptions): Promise<Book | undefined> {
    this.state = EngineState.LOADING;
    this.bookBasePath = bookBasePath;
    this.publication = undefined;
    this.benchOpenStart = Date.now();
    // P0-B: Session 打开日志
    hilog.info(0x0000, 'OhEngine', 'SESSION_OPEN id=%{public}d book=%{public}s', this.sessionSerial, bookBasePath);
    // Phase 6: 重新打开书籍时重置协作式取消令牌（上次 destroy 可能置位）。
    this.pipelineManager.cancellationToken.reset();
    // Phase 24（Router 生命周期修复）：open 入口显式重置 engine 层全书索引
    // （chunkPlainTextLengths / TXT vchapter 映射 / 段落缓存）。此前这些索引
    // 在填充后被 ReflowRouter.render → pageManager.clearAll() 整体清空，
    // 导致本 session 全局字符定位失效、TXT 旧锚点解析错章。
    // 同时清空上一本的章节分页产物（此前由 Router 的 clearAll 隐式覆盖）。
    this.pipelineManager.paginatedChapters = [];
    this.pageManager.resetCharIndices();

    try {
      // Step 1: Resolve parser by file extension
      const extIndex: number = bookBasePath.lastIndexOf('.');
      const ext: string = extIndex >= 0 ? bookBasePath.substring(extIndex).toLowerCase() : '';
      let parser: BookParser | undefined = ParserRegistry.resolveByExtension(ext);

      // Fallback: try to detect format from directory contents (e.g. extracted EPUB)
      if (parser === undefined) {
        try {
          const stat = fileIo.statSync(bookBasePath);
          if (stat.isDirectory()) {
            // Check for EPUB container.xml
            try {
              fileIo.statSync(bookBasePath + '/META-INF/container.xml');
              parser = ParserRegistry.resolve(BookFormat.EPUB);
            } catch (_e) {
              // Not an EPUB directory — fall through to comic-image detection
            }
            if (parser === undefined && this.isComicImageDir(bookBasePath)) {
              // Index.ets 对 .cbz 走 SecureArchive 解压后以 extractDir（无扩展名
              // 目录）打开；CbzParser.parse 支持已解压目录输入，直接扫描图片。
              parser = ParserRegistry.resolve(BookFormat.CBZ);
            }
          }
        } catch (_e) {
          // Path doesn't exist or can't be accessed
        }
      }

      if (parser === undefined) {
        throw new Error('No parser registered for extension: ' + ext);
      }

      // Step 2: Parse the book
      // 解析缓存（仅 EPUB，FR-005）：L0 分块缓存（Phase 8 D1）优先——
      // cold start 只反序列化 metadata（TOC/chapterIndex/offset index），章节内容
      // 按需从 parse/chapter_{i}.json 加载；旧版整书 .parsed.json 作为回退。
      // 缓存目录 = opts.cacheDir（独立缓存目录）或回退 bookBasePath（解压目录内）。
      const parseCacheDir: string = (opts !== undefined && opts.cacheDir !== undefined && opts.cacheDir.length > 0)
        ? opts.cacheDir
        : bookBasePath;
      const parseSourcePath: string = (opts !== undefined && opts.sourcePath !== undefined)
        ? opts.sourcePath
        : bookBasePath;
      let parsedBook: ParsedBook | null = null;
      // Phase 8 D1: 分块缓存命中（meta 完整 + 源指纹匹配）→ 只加载 meta + 章节索引。
      const chunkedValid: boolean = parser.format === BookFormat.EPUB &&
        ParseCacheManager.isChunkedValid(parseCacheDir, parseSourcePath);
      if (chunkedValid) {
        const meta: ParseMeta | null = ParseCacheManager.loadParseMeta(parseCacheDir);
        if (meta !== null) {
          // 从 meta 重建最小 ParsedBook：chapters 内容为空串，
          // title/href/offset index（plainTextLength）来自 meta；内容由 provider 按章加载。
          const chapters: ChapterData[] = [];
          for (let i = 0; i < meta.chapters.length; i++) {
            const ci: ParseChapterIndex = meta.chapters[i];
            chapters.push({ title: ci.title, href: ci.href, content: '' } as ChapterData);
          }
          const book: Publication | null = ParseCacheManager.rehydrateBook(meta.book);
          parsedBook = new ParsedBook(
            meta.format as BookFormat,
            meta.strategy as RenderStrategy,
            book,
            chapters,
            meta.cssTexts,
            meta.imagePaths
          );
          // L0 惰性 provider：按章读 parse/chapter_{i}.json
          this.pipelineManager.chapterHtmlProvider = (chapterIndex: number): string | undefined => {
            const chunk: ParseChapterChunk | null =
              ParseCacheManager.loadParseChapter(parseCacheDir, chapterIndex);
            return chunk !== null ? chunk.content : undefined;
          };
          // offset index → chunkPlainTextLengths（无需章内容）；chunkPlainTexts 置空
          for (let i = 0; i < meta.chapters.length; i++) {
            this.pageManager.chunkPlainTextLengths.push(meta.chapters[i].plainTextLength);
            this.pageManager.chunkPlainTexts.push('');
          }
        }
      }
      if (parsedBook === null) {
        // 回退：旧版整书缓存 / 无分块缓存 → 全量 parse（或旧格式缓存命中）。
        if (parser.format === BookFormat.EPUB) {
          parsedBook = ParseCacheManager.loadParsedBook(parseCacheDir);
        }
// Phase 9.4: TXT Lazy 分支——优先使用轻量索引 + 惰性 chunk 读取。
      // 适用于开启 TxtLazyConfig 且 parser 实现 openTxtLazyDocument 的情况。
      // 回退：任意失败（索引损坏/IO 异常/开关关闭）→ 走下方 eager parse。
      if (parser.format === BookFormat.TXT) {
        // Phase 9.8: benchmark 打点 T0=open 已开始（benchOpenStart），T1=索引就绪
        const tLazyStart: number = Date.now();
        const lazyOpen: ((filePath2: string, cacheDir2: string, libraryDir2?: string) => Promise<TxtLazyDocument | undefined>) | undefined =
          parser.openTxtLazyDocument;
        const lazyLibraryDir: string = (opts !== undefined && opts.libraryDir !== undefined) ? opts.libraryDir : '';
        if (lazyOpen !== undefined) {
          let lazyDoc: TxtLazyDocument | undefined = undefined;
          try {
            lazyDoc = await lazyOpen(bookBasePath, parseCacheDir, lazyLibraryDir);
          } catch (_e) {
            lazyDoc = undefined;
          }
          this.benchTxtLazyIndexMs = Date.now() - tLazyStart;
          // P0-B: Session 已销毁（exit 打断异步索引构建/打开）→ 释放文档、丢弃结果
          if (this.pipelineManager.destroyed) {
            if (lazyDoc !== undefined) {
              lazyDoc.release();
            }
            hilog.info(0x0000, 'OhEngine', 'SESSION_TASK_DROP id=%{public}d task=txtLazyOpen old', this.sessionSerial);
            return undefined;
          }
          if (lazyDoc !== undefined && lazyDoc.getVChapterCount() > 0) {
            this.txtLazyDoc = lazyDoc;
            // 用 vchapter 描述符构造 ParsedBook：content 留空，由 provider 按需提供。
            const lazyChapters: ChapterData[] = [];
            for (let i: number = 0; i < lazyDoc.getVChapterCount(); i++) {
              const vref: TxtVChapterRef | undefined = lazyDoc.getVChapterRange(i);
              const href: string = vref !== undefined ? vref.id : vchapterId(i);
              lazyChapters.push({
                title: lazyDoc.getVChapterTitle(i),
                href: href,
                content: ''
              } as ChapterData);
            }
            parsedBook = new ParsedBook(
              BookFormat.TXT, RenderStrategy.REFLOW, null, lazyChapters, []);
            // Lazy provider：按 vch 序号读取 chunk 重建 HTML。
            this.pipelineManager.chapterHtmlProvider = (chapterIndex: number): string | undefined => {
              if (this.txtLazyDoc === undefined) {
                return undefined;
              }
              const html: string | undefined = this.txtLazyDoc.getVChapterHtml(chapterIndex);
              // Phase 9.6 内存边界：清除远处已加载的 vch HTML（按需可重建），
              // 防止 chapterHtmlCache 随阅读进度线性增长。当前正在使用的
              // 章节不会被清（其在渲染期间由调用方持有引用）。
              const keepRadius: number = 16;
              const cache: string[] = this.pipelineManager.chapterHtmlCache;
              for (let c = 0; c < cache.length; c++) {
                if (c !== chapterIndex && Math.abs(c - chapterIndex) > keepRadius) {
                  cache[c] = '';
                }
              }
              return html;
            };
            // Offsets：plainTextLength 直接来自索引（无需 extractPlainText 全文）。
            for (let i: number = 0; i < lazyDoc.getVChapterCount(); i++) {
              this.pageManager.chunkPlainTextLengths.push(lazyDoc.getPlainTextLength(i));
              this.pageManager.chunkPlainTexts.push('');
            }
            // 旧章 → vchapter 映射（ReadingAnchor 迁移用）。
            this.pageManager.oldChapterToVchapterStart = lazyDoc.getOldChapterToVchapterStart();
            this.pageManager.oldChapterVchapterCounts = lazyDoc.getOldChapterVchapterCounts();
            hilog.info(0x0000, 'OhEngine', 'TXT-LAZY open chapters=%{public}d vchs=%{public}d idx=size=%{public}d',
              lazyDoc.index.oldChapterCount, lazyDoc.getVChapterCount(), lazyDoc.index.fileSize);
          }
        }
      }
      if (parsedBook === null) {
        // 回退：旧版整书缓存 / 无分块缓存 → 全量 parse（或旧格式缓存命中）。
        if (parser.format === BookFormat.EPUB) {
          parsedBook = ParseCacheManager.loadParsedBook(parseCacheDir);
        }
        if (parsedBook === null) {
          parsedBook = await parser.parse(bookBasePath);
          // P0-B: Session 已销毁 → 丢弃解析结果（退出打断的异步 parse）
          if (this.pipelineManager.destroyed) {
            hilog.info(0x0000, 'OhEngine', 'SESSION_TASK_DROP id=%{public}d task=parse old', this.sessionSerial);
            return undefined;
          }
          if (parser.format === BookFormat.EPUB) {
            // 写分块格式（Phase 8 D1）；写失败不阻断打开（内部捕获异常）
            ParseCacheManager.saveParsedBookChunked(parseCacheDir, parseSourcePath, parsedBook);
          }
        }
      }
        // Step 3: Fill chapter HTML cache from ParsedBook（全量展开路径，非 chunked 命中）
        // Phase 8 D2: TXT → vchapter 展开（不重写 TxtParser；引擎层展开，分片让步）
        if (parsedBook === null) {
          throw new Error('open() failed to parse book');
        }
        if (parser.format === BookFormat.TXT) {
          parsedBook = await this.expandTxtToVChapters(parsedBook);
          if (this.pipelineManager.destroyed) {
            hilog.info(0x0000, 'OhEngine', 'SESSION_TASK_DROP id=%{public}d task=expand old', this.sessionSerial);
            return undefined;
          }
          hilog.info(0x0000, 'OhEngine', 'OPEN_M2 expanded id=%{public}d chapters=%{public}d',
            this.sessionSerial, parsedBook.chapters.length);
        }
        const totalChapters0: number = parsedBook.chapters.length;
        this.pipelineManager.chapterHtmlCache = [];
        for (let i: number = 0; i < totalChapters0; i++) {
          const html: string = parsedBook.chapters[i].content;
          this.pipelineManager.chapterHtmlCache.push(html);
          // Compute plain text length for char-offset navigation
          const plainText: string = this.extractPlainText(html);
          this.pageManager.chunkPlainTexts.push(plainText);
          this.pageManager.chunkPlainTextLengths.push(plainText.length);
        }
      } else {
        // chunked 命中路径：chapterHtmlCache 预分配（内容惰性回填）
        this.pipelineManager.chapterHtmlCache = [];
        for (let i: number = 0; i < parsedBook.chapters.length; i++) {
          this.pipelineManager.chapterHtmlCache.push('');
        }
      }

      // Publication 解析（ParsedBook.book 为 Publication 时复用；纯文本构造最小 Publication）
      if (parsedBook.book !== null) {
        this.publication = parsedBook.book as Publication;
        this.isFXL = this.publication.layout === 'pre-paginated';
      } else {
        // 纯文本书（TXT/PDF 解析器不产出 Publication 对象）：构造最小
        // Publication 接入布局管线——layoutAllChaptersSync / ensureChapterReady /
        // relayoutSingleChunk 等均以 publication 存在为前提，缺失时全书停留在
        // stub 占位页（无真实内容、无真实分页），翻页/缓存/页码全部失真。
        this.publication = this.buildPlainPublication(parsedBook);
        this.isFXL = false;
      }
      const totalChapters: number = parsedBook.chapters.length;

      // Step 4: Resolve rendering strategy and dispatch
      const router = StrategyRegistry.resolve(parsedBook.strategy);
      if (router === undefined) {
        throw new Error('No router registered for strategy: ' + parsedBook.strategy);
      }
      hilog.info(0x0000, 'OhEngine', 'OPEN_M3 router id=%{public}d chapters=%{public}d',
        this.sessionSerial, parsedBook.chapters.length);
      router.render(parsedBook);
      hilog.info(0x0000, 'OhEngine', 'OPEN_M4 router-done id=%{public}d', this.sessionSerial);

      hilog.info(0x0000, 'OhEngine', 'OPEN_M1 book-model id=%{public}d chapters=%{public}d',
        this.sessionSerial, parsedBook.chapters.length);
      // Step 4.5: Page Cache — resolve the cache context before chapter layout.
      // Reflow books only: FXL (pre-paginated) books keep their fixed pages
      // and are excluded from pagination caching.
      let pageCacheEnabled: boolean = false;
      let pageCacheDir: string = '';
      let pageCacheSourcePath: string = '';
      let pageCacheSignature: string = '';
      if (!this.isFXL) {
        if (parser.format === BookFormat.EPUB) {
          const src: string | undefined = opts !== undefined ? opts.sourcePath : undefined;
          if (src !== undefined && src.length > 0) {
            pageCacheEnabled = true;
            // 优先使用调用方指定的独立缓存目录（filesDir/cache/books/<名>/），
            // 回退到解压目录内的 .pagecache（旧行为）。
            pageCacheDir = (opts !== undefined && opts.cacheDir !== undefined && opts.cacheDir.length > 0)
              ? opts.cacheDir
              : bookBasePath + '/.pagecache';
            pageCacheSourcePath = src;
          }
        } else {
          // Non-ZIP formats (e.g. TXT): the base path IS the source file,
          // so it can be stat'ed directly for the fingerprint.
          pageCacheEnabled = true;
          pageCacheDir = (opts !== undefined && opts.cacheDir !== undefined && opts.cacheDir.length > 0)
            ? opts.cacheDir
            : bookBasePath + '.pagecache';
          pageCacheSourcePath = bookBasePath;
        }
      }
      if (pageCacheEnabled) {
        pageCacheSignature = PageCacheManager.computeLayoutSignature(this.config, this.layoutProfile,
          this.fontSizeController.baseFontSize);
        // Phase 2 CacheKey: bookId + contentFingerprint 进入缓存键；
        // contentFingerprint = getContentFingerprint()（源文件 size:mtime）。
        // 先建 context（getContentFingerprint 依赖 pageCacheContext.sourcePath），
        // 再补 bookId / contentFingerprint 字段。
        this.pageCacheContext = {
          cacheDir: pageCacheDir,
          sourcePath: pageCacheSourcePath,
          signature: pageCacheSignature
        };
        const contextBookId: string = this.getBookId();
        const contextFp: string = this.getContentFingerprint();
        this.pageCacheContext.bookId = contextBookId;
        this.pageCacheContext.contentFingerprint = contextFp;
        // Sync to PipelineManager — it owns the per-chapter cache read/write
        // (layoutAllChaptersSync / processNextInQueue use its own field).
        this.pipelineManager.pageCacheContext = this.pageCacheContext;
      } else {
        this.pageCacheContext = undefined;
        this.pipelineManager.pageCacheContext = undefined;
      }

      this.readingStateDir = (opts !== undefined && opts.readingStateDir !== undefined)
        ? opts.readingStateDir
        : '';

      // Phase 2 (L2 hot cache): 首次打开只同步分页「目标章 ± HOT_RANGE」热窗，
      // 其余章节保持 stub，翻页到具体章时按需同步分页（ensureChapterReady），
      // 相邻章节由翻页后的异步预取填充（queueChunkLayout low）。
      // 消除「open → 整本同步分页 + 整本写盘」。
      if (totalChapters > 0) {
        // Phase 7 Migration: 显式清除旧结构缓存（旧 version/schema/algo），
        // 失败即删除受影响缓存→重建；不无限 retry，不阻塞 open。
        if (pageCacheEnabled) {
          CacheMigration.clearStalePageCache(pageCacheDir, PageCacheManager.getCacheVersion());
          CacheMigration.clearIncompatibleSchema(pageCacheDir, PAGE_CACHE_SCHEMA_VERSION,
            LAYOUT_ALGORITHM_VERSION);
        }
        // Stale cache (meta missing / fingerprint changed / layout signature
        // changed): drop it so the first saveChapter re-writes meta.json.
        if (pageCacheEnabled &&
          !PageCacheManager.isCacheValid(pageCacheDir, pageCacheSourcePath, pageCacheSignature,
            this.getBookId(), this.getContentFingerprint())) {
          PageCacheManager.invalidate(pageCacheDir);
        }
        // 目标章：优先恢复位置所在章，其次第 0 章。
        const targetChapter: number = this.peekReadingStateChapter();
        const hotFrom: number = Math.max(0, targetChapter - OhEngineCore.HOT_RANGE);
        const hotTo: number = Math.min(totalChapters - 1, targetChapter + OhEngineCore.HOT_RANGE);
        this.pipelineManager.layoutRangeSync(hotFrom, hotTo);
        hilog.info(0x0000, 'OhEngine', 'OPEN_M6 layoutRangeSync-done id=%{public}d target=%{public}d',
          this.sessionSerial, targetChapter);
        // Phase 25（真实总页数）：热窗就绪后装载/回填每章真实页数 → 未物化章
        // 总数也精确（二次打开首帧即真实 318/318，而非估算 305）。
        if (pageCacheEnabled) {
          this.loadPageCountIndex(pageCacheDir, totalChapters, pageCacheSignature);
        } else {
          this.pageManager.setCachedChapterCounts(null);
        }
      }

      // Phase 3 (L3): 注册内存压力订阅（shrink L3 to 1–2 章）。
      this.subscribeMemoryPressure();
      // Phase 4 gate: 采样 open 后 / destroy 前命中率。
      this.logCacheHitSummary('open');
      // Phase 8.4 benchmark: open 热窗分页耗时打点
      this.benchOpenMs += Date.now() - this.benchOpenStart;

      // Phase 1 (L1): 冷启动/重开书位置恢复（ReadingAnchor 级，非 pageIndex）。
      // 全部失败安全回退到首页；不阻塞 open 返回。
      // 先置 READY 再恢复——goToChapter/导航守卫依赖 host.isReady。
      this.state = EngineState.READY;
      if (this.readingStateDir.length > 0) {
        this.benchRestoreStart = Date.now();
        const restored: boolean = this.restoreLastReadingState();
        this.benchRestoreMs += Date.now() - this.benchRestoreStart;
        hilog.info(0x0000, 'OhEngine', 'READING_POSITION_RESTORE ok=%{public}d page=%{public}d ch=%{public}d',
          restored ? 1 : 0, this.pageManager.currentGlobalPage,
          this.pageManager.getCurrentChapterIndex());
        // Phase 21: 恢复成功后按最终位置同步 materialization 窗口（统一链路，无格式特判）
        if (restored) {
          this.syncWindowAfterRestore();
        }
      }
      // Phase 11: Anchor 定位完成观测（首帧前置消费）
      this.logColdStartAnchorResolved();
      hilog.info(0x0000, 'OhEngine', 'OPEN_M5 restore-done id=%{public}d', this.sessionSerial);

      if (this.publication !== undefined) {
        return this.publication;
      }
      // For plain-text parsers (TXT) that don't produce a Publication object,
      // the book was opened successfully with loaded chapters — return undefined.
      if (parsedBook.chapters.length > 0) {
        return undefined;
      }
      throw new Error('open() succeeded but publication is null');
    } catch (e) {
      this.state = EngineState.ERROR;
      this.lastError = String(e);
      throw new Error(String(e));
    }
  }

  public destroy(): void {
    // P0-B: 幂等防护（ReaderHost.aboutToDisappear 可能多次触发）
    if (this.state === EngineState.DESTROYED) {
      return;
    }
    hilog.info(0x0000, 'OhEngine', 'SESSION_DISPOSE_START id=%{public}d', this.sessionSerial);
    // Phase 4 gate: 记录本 session 的 L3/L2 命中摘要（Benchmark 观测）。
    this.logCacheHitSummary('destroy');
    // Phase 3 (L3): 注销内存压力订阅，防止销毁后回调残留。
    this.unsubscribeMemoryPressure();
    // P0-B: 解除本引擎 bus 的全部监听（pageReady/fontSize → 旧 ReaderHost 闭包）
    this.paramBus.clear();
    // Phase 1 (L1): 销毁前兜底落盘一次 ReadingState（防抖窗口未到时丢失位置）。
    this.pageManager.persistCurrentReadingState();
    // Phase 9.4: 释放 TXT lazy 文档（关闭 fd / 清解码缓存）。
    if (this.txtLazyDoc !== undefined) {
      this.txtLazyDoc.release();
      this.txtLazyDoc = undefined;
    }
    // shutdown 置位 destroyed 并作废在途排版任务（ENG-005），保证销毁后
    // setTimeout 后台回调不再更新页面。
    this.pipelineManager.shutdown();
    this.pageManager.clearAll();
    this.state = EngineState.DESTROYED;
    this.publication = undefined;
    this.searchEngine.buildIndex([]);
    this.pipelineManager.mediaOverlayController.stop();
    hilog.info(0x0000, 'OhEngine', 'SESSION_DISPOSE_END id=%{public}d', this.sessionSerial);
  }

  /**
   * 为无出版元数据的纯文本书（TXT/PDF）构造最小 Publication：
   * 章节 → readingOrder/toc（与各解析器 getBook 同构），使布局管线可用。
   */
  private buildPlainPublication(parsed: ParsedBook): Publication {
    const publication: Publication = new Publication(this.titleFromPath());
    for (let i: number = 0; i < parsed.chapters.length; i++) {
      const chapter: ChapterData = parsed.chapters[i];
      publication.manifest.readingOrder.push(
        createLinkWithTitle(chapter.href, 'text/plain', chapter.title));
      const item: TocItem = { title: chapter.title, href: chapter.href };
      publication.toc.push(item);
    }
    return publication;
  }

  /**
   * Phase 8 D2: TXT → vchapter 展开（引擎层，不重写 TxtParser）。
   *
   * 将 `chapter-N`/`page-N` 真实章节的 HTML 内容按「5000–10000 chars + 段落边界」
   * 切为 `vchapter_XXXXX`，产出新 ParsedBook（chapters 为 vchapter 序列，href 为 vchapter id）。
   * 切分确定性 → 缓存键稳定；ReadingState 恢复走旧 chapter-N → vchapter 映射。
   */
  /**
   * Phase 8 D2: TXT → vchapter 展开（引擎层，不重写 TxtParser；**分片让步**）。
   *
   * 大书（数百万字符）同步全量展开会阻塞主线程（THREAD_BLOCK_6S，Benchmark 实测）。
   * 展开按「每 5 章让步一次」分片：每批处理完重新进入事件循环（setTimeout 0），
   * 避免单次展开阻塞可见页。
   */
  private expandTxtToVChapters(parsed: ParsedBook): Promise<ParsedBook> {
    return new Promise<ParsedBook>((resolve: (v: ParsedBook) => void): void => {
      const vchapters: ChapterData[] = [];
      this.pageManager.oldChapterToVchapterStart = [];
      this.pageManager.oldChapterVchapterCounts = [];
      let globalIdx: number = 0;
      const total: number = parsed.chapters.length;
      let idx: number = 0;
      const step = (): void => {
        // 处理 5 章后让出事件循环（避免 3.96M chars 大书同步阻塞主线程）
        for (let done: number = 0; done < 5 && idx < total; done++, idx++) {
          const ci: number = idx;
          const ch: ChapterData = parsed.chapters[ci];
          const paragraphs: string[] = extractParagraphs(ch.content);
          const texts: string[] = [];
          for (let p = 0; p < paragraphs.length; p++) {
            texts.push('<p>' + paragraphs[p] + '</p>');
          }
          // Phase 24（Issue A 根因修复 #2）：传入全局 id 偏移，保证 vchapter id
          // 全局唯一（旧实现每次调用内部从 0 重计，跨旧章 id 撞号 → 恢复错章）。
          const defs: VChapterDef[] = buildVChapters(globalIdx, paragraphs, texts, globalIdx);
          this.pageManager.oldChapterToVchapterStart.push(globalIdx);
          this.pageManager.oldChapterVchapterCounts.push(defs.length);
          for (let v = 0; v < defs.length; v++) {
            const d: VChapterDef = defs[v];
            const title: string = v === 0 ? ch.title : ch.title + '（续）';
            vchapters.push({
              title: title,
              content: d.html,
              href: d.id
            } as ChapterData);
            globalIdx++;
          }
        }
        if (idx < total) {
          // 让出主线程后再继续（P0 可见页优先）
          setTimeout(() => {
            if (this.pipelineManager.cancellationToken.isCancelled()) {
              // 已取消/销毁：返回不完整展开（安全兜底，调用方见空章不崩溃）
              const partial: ParsedBook = new ParsedBook(
                parsed.format, parsed.strategy, parsed.book, vchapters,
                parsed.cssTexts, parsed.imagePaths);
              resolve(partial);
              return;
            }
            step();
          }, 0);
        } else {
          const expanded: ParsedBook = new ParsedBook(
            parsed.format, parsed.strategy, parsed.book, vchapters,
            parsed.cssTexts, parsed.imagePaths);
          resolve(expanded);
        }
      };
      step();
    });
  }

  /** 从 bookBasePath 提取书名（去掉目录与扩展名） */
  private titleFromPath(): string {
    const path: string = this.bookBasePath;
    const lastSlash: number = path.lastIndexOf('/');
    const fileName: string = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    const dot: number = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  /** 目录内是否存在漫画图片（CBZ 解压目录判定，供 open 的目录回退使用） */
  private isComicImageDir(dirPath: string): boolean {
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(dirPath);
    } catch (_e) {
      return false;
    }
    const imageExts: string[] = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'];
    for (let i: number = 0; i < entries.length; i++) {
      const lower: string = entries[i].toLowerCase();
      for (let e: number = 0; e < imageExts.length; e++) {
        if (lower.endsWith(imageExts[e])) {
          return true;
        }
      }
    }
    return false;
  }

  // ==================== Page Navigation (Delegation to PageManager) ====================

  public getCurrentPage(): PageSlot | undefined {
    return this.pageManager.getCurrentPage();
  }

  /**
   * 页槽代次（0.13/FR-011）：只读访问 PageManager.pageGeneration，
   * 用于翻页 B2 提交前的跨层快照校验。
   */
  public getPageGeneration(): number {
    return this.pageManager.getPageGeneration();
  }

  /**
   * 按全局页索引获取页面（用于图片预取等场景）
   * @param globalIndex 全局页索引（0-based）
   */
  public getPageByGlobalIndex(globalIndex: number): PageSlot | undefined {
    const slots: PageSlotType[] = this.pageManager.pageSlots;
    if (globalIndex >= 0 && globalIndex < slots.length) {
      return slots[globalIndex];
    }
    return undefined;
  }

  /**
   * 按相对偏移获取页面（不改变当前页，用于翻页预览）
   * @param offset 相对当前页的偏移（1=下一页，-1=上一页）
   */
  public getPageByOffset(offset: number): PageSlot | undefined {
    return this.pageManager.getPageByOffset(offset);
  }

  /**
   * Phase 10 诊断：单页就绪快照（供翻页动画入口/测试断言）。
   * 输出紧凑字段：g=全局页 ch=章 pg=章内页 state=stub/ready ready=PageReadyState数值
   * lines=行数 tH=首行文本FNV-ish hash img=含图行数 src=L3/L2/live/stub gen=构建代次。
   */
  public describePage(slot: PageSlot): string {
    const gen: number = slot.generation !== undefined ? slot.generation : -1;
    const globalIdx: number = slot.globalIndex !== undefined ? slot.globalIndex : -1;
    const ready: number = slot.readyState !== undefined ? slot.readyState : PageReadyState.NOT_READY;
    const imgTotal: number = slot.imageCount !== undefined ? slot.imageCount : 0;
    let firstText: string = '';
    for (let i: number = 0; i < slot.lines.length; i++) {
      const t: string | undefined = slot.lines[i].text;
      if (t !== undefined && t.length > 0) {
        firstText = t;
        break;
      }
    }
    let h: number = 0;
    for (let i: number = 0; i < firstText.length; i++) {
      h = (h * 31 + firstText.charCodeAt(i)) >>> 0;
    }
    return 'g=' + globalIdx + ' ch=' + slot.chunkIndex + ' pg=' + slot.pageNumber +
      ' state=' + slot.state + ' ready=' + ready + ' lines=' + slot.lines.length +
      ' tH=' + h.toString(16) + ' img=' + imgTotal +
      ' src=' + this.pipelineManager.getChapterOrigin(slot.chunkIndex) +
      ' gen=' + gen;
  }

  /**
   * Phase 10 诊断：N-1/N/N+1 三页就绪快照（Benchmark B / 冷启动就绪观测）。
   * 只读页面槽数组，不触发任何就绪/ensure 副作用。
   */
  public describeNeighborWindow(): string {
    const curIdx: number = this.pageManager.currentGlobalPage;
    const slots: PageSlotType[] = this.pageManager.pageSlots;
    const prevIdx: number = curIdx - 1;
    const nextIdx: number = curIdx + 1;
    const prev: PageSlot | undefined = prevIdx >= 0 && prevIdx < slots.length ? slots[prevIdx] : undefined;
    const cur: PageSlot | undefined = curIdx >= 0 && curIdx < slots.length ? slots[curIdx] : undefined;
    const next: PageSlot | undefined = nextIdx >= 0 && nextIdx < slots.length ? slots[nextIdx] : undefined;
    const fmt = (s: PageSlot | undefined): string => {
      return s !== undefined ? this.describePage(s) : 'none';
    };
    return 'curN=' + curIdx + ' prev=' + fmt(prev) + ' cur=' + fmt(cur) + ' next=' + fmt(next);
  }

  /**
   * 预览 turnPage(direction) 将到达的页面（不改变当前页，带 RTL 映射）
   */
  public peekPage(direction: TurnDirection): PageSlot | undefined {
    return this.pageManager.peekPage(direction);
  }

  public turnPage(direction: TurnDirection): boolean {
    if (this.state !== EngineState.READY) {
      return false;
    }
    return this.pageManager.turnPage(direction);
  }

  public goToPage(pageIndex: number): boolean {
    if (this.state !== EngineState.READY || this.publication === undefined) {
      return false;
    }
    return this.pageManager.goToPage(pageIndex);
  }

  public goToChapter(chapterIndex: number): boolean {
    if (this.state !== EngineState.READY || this.publication === undefined) {
      return false;
    }
    return this.pageManager.goToChapter(chapterIndex);
  }

  public goToProgress(progress: number): boolean {
    if (this.state !== EngineState.READY || this.publication === undefined) {
      return false;
    }
    return this.pageManager.goToProgress(progress);
  }

  public getTotalPages(): number {
    return this.pageManager.getTotalPages();
  }

  /** Phase 24 (Issue B)：已物化页数（诊断对照用；用户可见总页数走 getTotalPages） */
  public getMaterializedPages(): number {
    return this.pageManager.getMaterializedPages();
  }

  /** Phase 24 最小状态表达：该章是否 LOADING（导航目标已入队等待 commit） */
  public isChunkLoading(chunkIndex: number): boolean {
    return this.pageManager.isChunkLoading(chunkIndex);
  }

  /** Phase 24 最小状态表达：该章是否 FAILED（章节内容不可得） */
  public isChunkLayoutFailed(chunkIndex: number): boolean {
    return this.pageManager.isChunkLayoutFailed(chunkIndex);
  }

  public getCurrentChapterIndex(): number {
    return this.pageManager.getCurrentChapterIndex();
  }

  public getCurrentPageIndex(): number {
    return this.pageManager.getCurrentPageIndex();
  }

  public getGlobalPageNumber(): number {
    return this.pageManager.getGlobalPageNumber();
  }

  /** Phase 24 (Issue B)：文档空间页码（1-based，与 getTotalPages 同空间） */
  public getDocumentPageNumber(): number {
    return this.pageManager.getDocumentPageNumber();
  }

  public goToTocItem(item: TocItem): boolean {
    if (this.publication === undefined) {
      return false;
    }
    return this.pageManager.goToTocItem(item);
  }

  public getChapterPageCount(chapterIndex: number): number {
    return this.pageManager.getChapterPageCount(chapterIndex);
  }

  public goToAnnotation(ann: Annotation): boolean {
    return this.pageManager.goToAnnotation(ann);
  }

  // ==================== Annotation Methods ====================

  public getAnnotationGroups(): ChapterAnnotationGroup[] {
    const pub: Publication | undefined = this.publication;
    if (pub === undefined) {
      return [];
    }
    const anns: Annotation[] = pub.annotations;
    if (anns === undefined || anns.length === 0) {
      return [];
    }
    const map: Map<number, ChapterAnnotationGroup> = new Map();
    const toc: TocItem[] | undefined = pub.getToc();
    for (const ann of anns) {
      if (ann.isVisible === 0) {
        continue;
      }
      const idx: number = ann.chapterIndex !== undefined ? ann.chapterIndex : 0;
      let group: ChapterAnnotationGroup | undefined = map.get(idx);
      if (group === undefined) {
        let title: string = 'Chapter ' + String(idx);
        if (toc !== undefined && idx < toc.length) {
          title = toc[idx].title;
        }
        group = new ChapterAnnotationGroup(idx, title, []);
        map.set(idx, group);
      }
      group.annotations.push(ann);
    }
    const groups: ChapterAnnotationGroup[] = [];
    const keysArr: number[] = [];
    map.forEach((_val: ChapterAnnotationGroup, key: number): void => {
      keysArr.push(key);
    });
    keysArr.sort((a: number, b: number): number => a - b);
    for (const key of keysArr) {
      const entry: ChapterAnnotationGroup | undefined = map.get(key);
      if (entry !== undefined) {
        groups.push(entry);
      }
    }
    return groups;
  }

  public getAnnotations(): Annotation[] {
    if (this.publication === undefined) {
      return [];
    }
    return this.publication.annotations;
  }

  public syncAnnotations(annotations: Annotation[]): void {
    if (this.publication === undefined) {
      return;
    }
    this.publication.annotations = annotations;
  }

  // ==================== Layout / Reflow Helpers ====================

  /**
   * 排版参数变更后刷新分页缓存签名。
   *
   * 签名（字号/行距/边距等）在 open() 时计算并写入 pageCacheContext；
   * 运行时变更排版参数后若不刷新，后台重排队列会按旧签名命中旧分页
   * 缓存，把旧度量的页面原样加载回来——这是「调整字号/行距后内容
   * 超出内容区」的根因之一。签名变化时同步更新上下文并作废旧缓存，
   * 后续逐章实时重排 + write-through 会以新签名重建缓存。
   */
  private refreshPageCacheForSettingsChange(): void {
    if (this.pageCacheContext === undefined) {
      return;
    }
    const newSignature: string = PageCacheManager.computeLayoutSignature(
      this.config, this.layoutProfile, this.fontSizeController.baseFontSize);
    if (newSignature.length === 0 || newSignature === this.pageCacheContext.signature) {
      return;
    }
    this.pageCacheContext.signature = newSignature;
    this.pipelineManager.pageCacheContext = this.pageCacheContext;
    PageCacheManager.invalidate(this.pageCacheContext.cacheDir);
    // Phase 25：签名变化 → 已缓存页数表失效（新缓存代逐章重建 pgcount 前
    // 不得混用旧代计数，否则给出虚假总数）
    this.pageManager.setCachedChapterCounts(null);
  }

  public onFontSizeChanged(): void {
    this.pipelineManager.layoutEngine.setBaseFontSize(this.fontSizeController.baseFontSize);
    this.pipelineManager.layoutEngine.setLineSpacing(this.layoutProfile.lineSpacing);
    hilog.info(0x0000, 'OhEngine', 'TXTREFLOW onFontSizeChanged base=%{public}d spacing=%{public}d',
      this.fontSizeController.baseFontSize, this.layoutProfile.lineSpacing);
    // 关键：UA 样式表在编译期把 baseFontSize 烘焙进 :root/body/p 的
    // font-size 声明（PipelineManager.loadAndCompileCss）。不重编译的话，
    // buildRenderTree 产出的 computedStyle 仍是旧字号 → TextBreaker 按
    // 旧字号断行（每行字符数不变），而绘制端按新字号渲染 → 大字号
    // 溢出右边界、小字号填不满一行。必须以新字号重建样式表后再重排。
    this.pipelineManager.loadAndCompileCss();
    this.refreshPageCacheForSettingsChange();
    this.pageManager.reflowAllChapters();
    hilog.info(0x0000, 'OhEngine', 'TXTREFLOW after-reflow totalPages=%{public}d',
      this.pageManager.getTotalPages());
  }

  public setLayoutProfile(profile: Partial<LayoutProfile>): void {
    let affectsPagination: boolean = false;
    let needsCssRecompile: boolean = false;
    if (profile.lineSpacing !== undefined) {
      this.layoutProfile.lineSpacing = profile.lineSpacing;
      this.pipelineManager.layoutEngine.setLineSpacing(profile.lineSpacing);
      affectsPagination = true;
    }
    if (profile.letterSpacing !== undefined) {
      this.layoutProfile.letterSpacing = profile.letterSpacing;
      this.pipelineManager.layoutEngine.setLetterSpacing(profile.letterSpacing);
      affectsPagination = true;
    }
    if (profile.wordSpacing !== undefined) {
      this.layoutProfile.wordSpacing = profile.wordSpacing;
      this.pipelineManager.layoutEngine.setWordSpacing(profile.wordSpacing);
      // word-spacing 编译进 p 规则，需重编译样式表
      needsCssRecompile = true;
      affectsPagination = true;
    }
    if (profile.textIndent !== undefined) {
      this.layoutProfile.textIndent = profile.textIndent;
      // 缩进语义 = 2 个汉字宽（随字号联动），TextBreaker 默认已实现；
      // 此处仅记录配置值，不再覆盖 2em 联动。
      affectsPagination = true;
    }
    if (profile.margins !== undefined) {
      this.layoutProfile.margins = profile.margins;
      // margin 编译进 --margin-* CSS 变量
      needsCssRecompile = true;
      affectsPagination = true;
    }
    if (profile.textAlign !== undefined) {
      this.layoutProfile.textAlign = profile.textAlign;
      this.pipelineManager.layoutEngine.setTextAlign(profile.textAlign);
      // text-align 编译进 p 规则
      needsCssRecompile = true;
    }
    if (profile.theme !== undefined) {
      this.layoutProfile.theme.backgroundColor = profile.theme.backgroundColor;
      this.layoutProfile.theme.textColor = profile.theme.textColor;
    }
    if (profile.paragraphSpacing !== undefined) {
      this.layoutProfile.paragraphSpacing = profile.paragraphSpacing;
      affectsPagination = true;
    }
    if (profile.fontFamily !== undefined) {
      this.layoutProfile.fontFamily = profile.fontFamily;
      this.pipelineManager.layoutEngine.setFontFamily(profile.fontFamily);
      // font-family 编译进 body 规则；字体度量变化影响断行宽度
      needsCssRecompile = true;
      affectsPagination = true;
    }
    if (affectsPagination || needsCssRecompile) {
      if (needsCssRecompile) {
        this.pipelineManager.loadAndCompileCss();
      }
      // 全局排版参数变更影响所有章节的分页度量：刷新页缓存签名并
      // 从第 0 章全量重排（仅重排当前章会给前文留下旧分页 → 溢出）。
      this.refreshPageCacheForSettingsChange();
      this.pageManager.reflowAllChapters();
    } else {
      this.pageManager.relayoutCurrentPageOnly();
    }
  }

  public recompileCss(): void {
    this.pipelineManager.loadAndCompileCss();
    this.pageManager.reflowFromCurrentPage();
  }

  /**
   * 仅按当前主题重编译 CSS 颜色，不触发重新排版 / 重分页。
   * 用于主题（深色/明亮）切换时保持分页不变、仅重绘颜色，
   * 避免 recompileCss() 的 reflow 导致页面内容重排。
   */
  public applyThemeCss(): void {
    this.pipelineManager.loadAndCompileCss();
  }

  // ==================== Text Helpers ====================

  public extractPlainText(html: string): string {
    let text: string = html;
    text = text.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '');
    text = text.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '');
    text = text.replace(/<\/(p|div|h[1-6]|li|blockquote|tr|br)\s*>/gi, '\n');
    text = text.replace(/<br\s*\/?>/gi, '\n');
    text = text.replace(/<[^>]*>/g, '');
    text = text.replace(/&nbsp;/g, ' ');
    text = text.replace(/&amp;/g, '&');
    text = text.replace(/&lt;/g, '<');
    text = text.replace(/&gt;/g, '>');
    text = text.replace(/&quot;/g, '"');
    text = text.replace(/&#39;/g, "'");
    text = text.replace(/\s+/g, ' ').trim();
    return text;
  }
}
