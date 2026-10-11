/**
 * PipelineManager — Layout Pipeline, CSS Compilation, and Font Loading
 *
 * Holds all layout engine state, CSS/style pipeline, chapter pagination cache,
 * layout queue processing, and font loading.
 *
 * Decoupled from OhEngineCore via constructor injection of HtmlParser,
 * PageSplitter, PageManager, and a PipelineManagerHost callback interface.
 *
 * This is NOT the public API entry point. Use OhEngine (facade) for all external consumption.
 */

import { PaginatedChapter, Page, PageSplitter, createPaginatedChapter, createEmptyPage } from '../layout/PageSplitter.ets';
import { HtmlParser, CssParser, StyleSource, createCssRuleSet } from 'ohrengine-parsers';
import type { DomNode, RenderNode, LayoutProfile, EngineConfig } from 'ohrengine-common';
import type { StyleSheet, CssRuleSet } from 'ohrengine-parsers';
import { compileRuleSet, CompiledStylesheet } from '../style/CssCompiler.ets';
import { StyleMapper } from '../style/StyleMapper.ets';
import { LayoutEngine } from '../layout/LayoutEngine.ets';
import { FontLoader } from '../typography/FontLoader.ets';
import { FontFallbackChain } from 'ohrengine-common';
import type { IMediaOverlayController } from 'ohrengine-common';
import { DefaultMediaOverlayController } from './DefaultMediaOverlayController.ets';
import { RemoteResourceLoader } from '../layout/RemoteResourceLoader.ets';
import { MediaConditionalCompiler } from '../style/MediaQueryEvaluator.ets';
import { ParameterBus, Publication, FontSizeController, PageCacheManager,
         MemoryPageCache, CancellationToken } from 'ohrengine-common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';
import { layoutChapterConcurrent } from '../layout/LayoutChapterWorker.ets';
import type { ChapterLayoutSnapshot } from '../layout/LayoutChapterWorker.ets';
import type { CacheChapter, PageCacheContext, DeserializeDiag } from 'ohrengine-common';
import type { PageSlot, IFontThemeProvider, Link } from 'ohrengine-common';

/**
 * Callback interface grouping external state that PipelineManager needs
 * from its host (OhEngineCore or equivalent facade).
 *
 * Breaking the circular OhEngineCore ↔ PipelineManager → PageManager
 * dependency: PageManager methods are exposed via callbacks on this interface
 * instead of a direct PageManager import.
 */
export interface PipelineManagerHost {
  /** The currently open book */
  publication: Publication | undefined;
  /** Font theme provider (provides currentTheme, loadFontFaces support) */
  fontThemeManager: IFontThemeProvider;
  /** Font size controller (provides baseFontSize) */
  fontSizeController: FontSizeController;
  /** Reading layout profile (font family, alignment, margins, etc.) */
  layoutProfile: LayoutProfile;
  /** Engine configuration (view size, profiles, etc.) */
  config: EngineConfig;
  /** Base path for resolving relative resources (e.g. font files) */
  bookBasePath: string;
  /** Event bus for publishing pipeline events (pageReady, theme, etc.) */
  paramBus: ParameterBus;
  /** --- PageManager bridge (breaks circular dependency) --- */
  /** Current page slots array */
  readonly pageSlots: PageSlot[];
  /** Current global page index */
  readonly currentGlobalPage: number;
  /** Rebuild page slots from paginated chapters */
  rebuildPageSlots(): void;
  /** Relayout only the current visible page */
  relayoutCurrentPageOnly(): void;
}

/**
 * Phase 6 任务优先级：P0 可见页，P1 下一页，P2 上一页，P3 cache write，
 * P4 background。存入 layoutQueue 时高优先级 unshift 插头，低优先级 push 尾。
 * Phase 14：新增 P0_USER_JUMP（用户主动导航目标，高于一切后台任务）。
 */
export enum LayoutPriority {
  P0_USER_JUMP = 0,
  P0_VISIBLE = 1,
  P1_NEXT = 2,
  P2_PREVIOUS = 3,
  P3_CACHE_WRITE = 4,
  P4_BACKGROUND = 5
}

/**
 * Phase 20.1: 后台分页窗口延续的单批上限（与 open 时首批一致）。
 * 每次 drain 后最多再入队该数目的 stub 章，递增推进整本分页；
 * 由 backgroundDelayMs 节流 + userAnimating 互斥保护主线程。
 */
export const BACKGROUND_BATCH_CAP: number = 32;

export class PipelineManager {
  private readonly htmlParser: HtmlParser;
  private readonly pageSplitter: PageSplitter;
  private readonly host: PipelineManagerHost;

  // ==================== Pipeline / Layout Fields ====================
  layoutEngine: LayoutEngine = new LayoutEngine();
  cssParser: CssParser = new CssParser();
  styleMapper: StyleMapper = new StyleMapper();
  compiledSheet: CompiledStylesheet = new CompiledStylesheet();
  paginatedChapters: PaginatedChapter[] = [];
  chapterHtmlCache: string[] = [];
  /**
   * Phase 8 D1: 章节 HTML 惰性提供器（L0 分块缓存命中时注册）。
   * 返回 undefined 表示该章内容缺失（视为空章）。命中后回填 chapterHtmlCache。
   */
  chapterHtmlProvider: ((chapterIndex: number) => string | undefined) | undefined = undefined;
  layoutQueue: number[] = [];
  isProcessing: boolean = false;
  rippleAborted: boolean = false;
  // Phase 6: 协作式取消令牌——销毁/重排时 cancel，后台逐章任务在边界检查。
  cancellationToken: CancellationToken = new CancellationToken();
  // 排版任务代数（ENG-005）：每次重排/销毁都会递增。scheduleNext 捕获发起时的
  // 代数，setTimeout 回调若发现代数已变则丢弃过期任务，防止旧布局覆盖新布局。
  layoutEpoch: number = 0;
  // 销毁标记（ENG-005）：destroy() 后不再调度/执行排版任务，后台回调直接丢弃。
  destroyed: boolean = false;
  readingDirection: number = 1;
  readingSpeed: number = 250;
  fontFaceCssTexts: string[] = [];
  fontLoader: FontLoader = new FontLoader();
  fontFallbackChain: FontFallbackChain = new FontFallbackChain();
  mediaOverlayController: IMediaOverlayController = new DefaultMediaOverlayController();
  remoteResourceLoader: RemoteResourceLoader = new RemoteResourceLoader();
  fullCssText: string = '';
  mediaCompiler: MediaConditionalCompiler = new MediaConditionalCompiler();

  // ==================== Page Cache ====================
  /**
   * Page-cache context injected by OhEngineCore after open().
   * When defined, each chapter is written to the cache right after its
   * pagination completes (incremental write), and is loaded from the cache
   * before re-parsing (per-chapter hit).
   * undefined disables the cache (e.g. FXL books).
   */
  pageCacheContext: PageCacheContext | undefined = undefined;

  /**
   * Phase 3 (L3): 运行时内存页缓存（有界 LRU + byte budget）。
   * 命中跳过「磁盘读 + JSON 反序列化」；memory pressure 时 shrinkToVisible。
   * 非 correctness source——丢失可回退 L2/Layout。
   */
  readonly memoryPageCache: MemoryPageCache = new MemoryPageCache();

  /**
   * Phase 10: 每章分页来源（诊断：pageSlots 中真实页来自哪一层）。
   * 'L3' | 'L2' = 缓存命中载入；'live' = 实时 parse+layout+split；'stub' = 未分页。
   */
  private chapterOriginMap: Map<number, string> = new Map();

  /** Phase 11: 后台增量 reflow 进行中（scheduleBackgroundReflow 置位；队列清空复位） */
  backgroundReflowActive: boolean = false;
  /** Phase 11: 后台章节处理节流（后台 100ms/章；前台 50ms/章），防主线程长占用 */
  backgroundDelayMs: number = 50;
  /** Phase 21: 后台窗口锚（当前阅读位置所在章）与双向游标（向后/向前边界） */
  backgroundWindowAnchor: number = 0;
  backgroundWindowLow: number = 0;
  backgroundWindowHigh: number = 0;
  backgroundWindowInited: boolean = false;
  /** Phase 12: 用户动画进行中查询（Flip/Slide 由 ReaderHost 经 engine.setUserAnimating 置位）。
   * 后台章在动画期间推迟处理，避免 81–145ms/章 的主线程分页工作破坏动画帧。 */
  userAnimating: () => boolean = () => false;

  /** Phase 10: 查询章节分页来源（诊断用；未知/未分页返回 'stub'） */
  public getChapterOrigin(chunkIndex: number): string {
    const v: string | undefined = this.chapterOriginMap.get(chunkIndex);
    return v !== undefined ? v : 'stub';
  }

  private markChapterOrigin(chunkIndex: number, origin: string): void {
    this.chapterOriginMap.set(chunkIndex, origin);
  }

  constructor(
    htmlParser: HtmlParser,
    pageSplitter: PageSplitter,
    host: PipelineManagerHost
  ) {
    this.htmlParser = htmlParser;
    this.pageSplitter = pageSplitter;
    this.host = host;
  }

  // ==================== Font Loading ====================
  /**
   * Load font-face declarations from the current theme
   */
  public loadFontFaces(fontFamily: string): string {
    const fontThemeManager = this.host.fontThemeManager;
    const currentTheme = fontThemeManager.currentTheme;
    if (currentTheme.loadingStrategy === 'none' || currentTheme.loadingStrategy === 'built-in') {
      return '';
    }
    if (currentTheme.loadPath === undefined || currentTheme.loadPath.length === 0) {
      return '';
    }
    // Generate @font-face CSS for loadable fonts
    let cssText: string = '';
    const resourceBase: string = this.host.bookBasePath;
    const resolved: string = this.resolveCssRelativePath(currentTheme.loadPath, resourceBase);
    cssText += `@font-face { font-family: "${fontFamily}"; src: url("${resolved}"); }\n`;
    return cssText;
  }

  // ==================== CSS Compilation ====================

  /**
   * Load and compile the full CSS stylesheet
   */
  public loadAndCompileCss(): CompiledStylesheet {
    this.cssParser = new CssParser();
    this.styleMapper = new StyleMapper();
    this.compiledSheet = new CompiledStylesheet();

    const baseFontSize: number = this.host.fontSizeController.baseFontSize;
    const marginLeft: number = this.host.layoutProfile.margins.left;
    const marginRight: number = this.host.layoutProfile.margins.right;
    const marginTop: number = this.host.layoutProfile.margins.top;
    const marginBottom: number = this.host.layoutProfile.margins.bottom;
    const isJustify: boolean = this.host.layoutProfile.textAlign === 'justify';

    // Default readability styles
    // NOTE(layout): 不得把 lineSpacing 烘焙为 line-height —— lineSpacing 是
    // 行高的「增量」，由 TextBreaker.setLineSpacing 在 line.height 上单独叠加；
    // 若写成 line-height: <lineSpacing>（如 2/4/6），resolveLineHeight 会把
    // 这个 unitless 数当像素行高，行盒高度≈行距，远小于字形尺寸，
    // 直接造成行与行文字重叠。缺省 normal ⇒ resolveLineHeight 返回
    // fontSize × ReadingMetrics.LINE_HEIGHT_RATIO（1.5em）。
    let cssText: string = `:root {
  font-size: ${baseFontSize}px;
  --margin-left: ${marginLeft}px;
  --margin-right: ${marginRight}px;
  --margin-top: ${marginTop}px;
  --margin-bottom: ${marginBottom}px;
}
body {
  font-family: ${this.host.layoutProfile.fontFamily ?? 'sans-serif'};
  font-size: ${baseFontSize}px;
  line-height: normal;
  margin: 0;
  padding: 0;
}
p {
  margin: 0 0 ${baseFontSize * 0.5}px 0;
  line-height: normal;
  text-align: ${isJustify ? 'justify' : 'left'};
  word-spacing: ${isJustify ? '0.05em' : 'normal'};
}
h1 { font-size: ${baseFontSize * 1.5}px; font-weight: bold; margin: ${baseFontSize}px 0 ${baseFontSize * 0.5}px 0; }
h2 { font-size: ${baseFontSize * 1.3}px; font-weight: bold; margin: ${baseFontSize * 0.8}px 0 ${baseFontSize * 0.4}px 0; }
h3 { font-size: ${baseFontSize * 1.15}px; font-weight: bold; margin: ${baseFontSize * 0.6}px 0 ${baseFontSize * 0.3}px 0; }
img { max-width: 100%; height: auto; display: block; margin: ${baseFontSize * 0.5}px auto; }
figure { margin: ${baseFontSize}px 0; text-align: center; }
figcaption { font-size: ${baseFontSize * 0.85}px; font-style: italic; text-align: center; }
blockquote {
  margin: ${baseFontSize}px ${baseFontSize}px;
  padding: 0 ${baseFontSize}px;
  border-left: 3px solid #ccc;
  font-style: italic;
}
a { color: #0066cc; text-decoration: underline; }
`;

    // Load font-face declarations from theme
    const fontCss: string = this.loadFontFaces(this.host.layoutProfile.fontFamily ?? 'sans-serif');
    if (fontCss !== '') {
      cssText = fontCss + '\n' + cssText;
    }

    // Append chapter-specific CSS from EPUB
    const chapterCssMap: Map<string, string> = this.extractCssFromChapters();
    const keys: string[] = Array.from(chapterCssMap.keys());
    for (let i = 0; i < keys.length; i++) {
      const cssContent: string = chapterCssMap.get(keys[i]) as string;
      if (cssContent !== '') {
        cssText += '\n/* Chapter CSS */\n' + cssContent;
      }
    }

    this.fullCssText = cssText;
    const styleSheet: StyleSheet = this.cssParser.parseStyleSheet(cssText, StyleSource.USER_AGENT);
    this.styleMapper.loadUserAgentStyleSheet(cssText);
    const ruleSet: CssRuleSet = createCssRuleSet();
    for (let i = 0; i < styleSheet.rules.length; i++) {
      ruleSet.rules.push(styleSheet.rules[i]);
    }
    this.compiledSheet = compileRuleSet(ruleSet, StyleSource.USER_AGENT);
    return this.compiledSheet;
  }

  // ==================== Chapter HTML (Phase 8 D1 lazy accessor) ====================

  /**
   * 读取章节 HTML（惰性）：缓存命中直接返回；未缓存且注册了 provider 时
   * 从 L0 分块缓存按章加载并回填 chapterHtmlCache。缺章/未注册返回 undefined。
   */
  public getChapterHtml(chapterIndex: number): string | undefined {
    if (chapterIndex < 0) {
      return undefined;
    }
    if (chapterIndex < this.chapterHtmlCache.length) {
      const cached: string | undefined = this.chapterHtmlCache[chapterIndex];
      // 空串视为未加载（D1 chunked 命中时预分配为 ''）：尝试 provider 按章加载
      if (cached !== undefined && cached.length > 0) {
        return cached;
      }
    }
    if (this.chapterHtmlProvider !== undefined && chapterIndex < this.chapterHtmlCache.length) {
      const loaded: string | undefined = this.chapterHtmlProvider(chapterIndex);
      if (loaded !== undefined && loaded.length > 0) {
        this.chapterHtmlCache[chapterIndex] = loaded;
        return loaded;
      }
    }
    return undefined;
  }

  /**
   * Load CSS extracted from a specific chapter's HTML
   */
  public loadCssFromChapterHtml(chapterIndex: number): string {
    const html: string | undefined = this.getChapterHtml(chapterIndex);
    if (html === undefined || html === '') {
      return '';
    }
    const cssBlocks: string[] = [];
    const styleRe: RegExp = /<style[^>]*>([\s\S]*?)<\/style>/gi;
    let match: RegExpExecArray | null = styleRe.exec(html);
    while (match !== null) {
      if (match[1] !== undefined && match[1].trim() !== '') {
        cssBlocks.push(match[1].trim());
      }
      match = styleRe.exec(html);
    }
    return cssBlocks.join('\n');
  }

  /**
   * Extract CSS from all chapters
   */
  public extractCssFromChapters(): Map<string, string> {
    const result: Map<string, string> = new Map();
    if (this.host.publication === undefined) {
      return result;
    }
    for (let i: number = 0; i < this.host.publication.getChapterCount(); i++) {
      // P0-A 修复：纯文本章（mediaType=text/plain，TXT/PDF lazy）不可能嵌入 <style>。
      // 跳过可避免 loadAndCompileCss 对全书章节逐一读取 chunk（8703 章 × 读盘 +
      // 重建 HTML + 污染 chapterHtmlCache）——200MB TXT 打开 THREAD_BLOCK 的主因之一。
      const link: Link | undefined = this.host.publication.getChapterLink(i);
      if (link !== undefined && link.mediaType === 'text/plain') {
        continue;
      }
      const cssText: string = this.loadCssFromChapterHtml(i);
      if (cssText !== '') {
        result.set(String(i), cssText);
      }
    }
    return result;
  }

  /**
   * Resolve a relative CSS path against a base href
   */
  public resolveCssRelativePath(relativePath: string, baseHref: string): string {
    if (relativePath.startsWith('http://') || relativePath.startsWith('https://') ||
        relativePath.startsWith('/')) {
      return relativePath;
    }
    // Simple path resolution: strip filename from baseHref and append relative
    const lastSlash: number = baseHref.lastIndexOf('/');
    if (lastSlash >= 0) {
      const baseDir: string = baseHref.substring(0, lastSlash + 1);
      // Normalize `..` segments
      const resolved: string = baseDir + relativePath;
      return resolved.replace(/\/[^/]+\/\.\.\//g, '/');
    }
    return relativePath;
  }

  /**
   * Phase 3 (L3): 章节分页读取——L3 内存命中 > L2 磁盘（反序列化）> 未命中。
   * 命中后写入 L3（LRU + byte budget）。非 correctness source，失败回退 null。
   */
  private loadChapterCached(chapterIndex: number): CacheChapter | null {
    const pageCtx: PageCacheContext | undefined = this.pageCacheContext;
    if (pageCtx === undefined) {
      return null;
    }
    // L3 命中：跳过磁盘读 + JSON 反序列化
    const memHit: CacheChapter | undefined = this.memoryPageCache.get(chapterIndex);
    if (memHit !== undefined) {
      this.statsL3Hits++;
      this.markChapterOrigin(chapterIndex, 'L3');
      return memHit;
    }
    // L2 磁盘：反序列化后写入 L3
    const diskHit: CacheChapter | null = PageCacheManager.loadChapter(pageCtx.cacheDir, chapterIndex);
    if (diskHit !== null) {
      this.memoryPageCache.put(chapterIndex, diskHit);
      this.statsL2Hits++;
      this.markChapterOrigin(chapterIndex, 'L2');
    } else {
      this.statsL2Miss++;
    }
    return diskHit;
  }

  // ==================== Cache Hit-Rate Observability (spec §Observability) ====================
  /** L3（内存）命中次数 */
  statsL3Hits: number = 0;
  /** L2（磁盘）命中次数 */
  statsL2Hits: number = 0;
  /** L2 未命中（实时分页）次数 */
  statsL2Miss: number = 0;
  /** 实时分页（layout/parse/split）次数——由 processNextInQueue/layoutSync 递增 */
  statsLiveLayouts: number = 0;
  /** 上一 session 的布局耗时累计（ms，hilog 采样） */
  statsLayoutMs: number = 0;

  /** 采样一次构建 L3/L2 命中摘要（供 Debug/Benchmark 日志） */
  getCacheHitSummary(): string {
    const total: number = this.statsL3Hits + this.statsL2Hits + this.statsL2Miss;
    const rate: number = total > 0 ? Math.round((this.statsL3Hits + this.statsL2Hits) / total * 100) : 0;
    return 'L3hits=' + this.statsL3Hits + ' L2hits=' + this.statsL2Hits +
      ' L2miss=' + this.statsL2Miss + ' liveLayout=' + this.statsLiveLayouts +
      ' hitRate=' + rate + '% layoutMs=' + this.statsLayoutMs;
  }

  // ==================== Layout Queue ====================

  /**
   * Queue a chunk for layout
   * @param priority LayoutPriority 或兼容的 'high'/'low' 字符串
   */
  public queueChunkLayout(chunkIndex: number, priority: LayoutPriority | string): void {
    if (chunkIndex < 0) {
      return;
    }
    // Avoid duplicates
    if (this.layoutQueue.indexOf(chunkIndex) >= 0) {
      return;
    }
    const urgent: boolean = priority === LayoutPriority.P0_USER_JUMP ||
      priority === LayoutPriority.P0_VISIBLE ||
      priority === LayoutPriority.P1_NEXT ||
      priority === LayoutPriority.P2_PREVIOUS ||
      priority === 'high';
    if (urgent) {
      this.layoutQueue.unshift(chunkIndex);
    } else {
      this.layoutQueue.push(chunkIndex);
    }
    this.scheduleNext();
  }

  /**
   * Schedule next layout in queue
   */
  public scheduleNext(): void {
    if (this.isProcessing) {
      return;
    }
    if (this.layoutQueue.length === 0) {
      // Phase 20.1: 后台窗口延续（cache-hit 提前 return 也能触发）。
      // 队列空且后台活动 → 找下一批 stub 章入队；无 stub → 结束。
      if (this.backgroundReflowActive && !this.destroyed && !this.cancellationToken.isCancelled()) {
        const contQueued: number = this.enqueueBackgroundContinuation();
        if (contQueued > 0) {
          hilog.info(0x0000, 'OhEngine',
            'COLDSTART BACKGROUND_CONTINUE queued=%{public}d', contQueued);
        } else {
          this.backgroundReflowActive = false;
          hilog.info(0x0000, 'OhEngine', 'COLDSTART BACKGROUND_REFLOW_END');
          hilog.info(0x0000, 'OhEngine', 'SESSION_BACKGROUND_STOP');
        }
      }
      if (this.layoutQueue.length === 0) {
        return;
      }
    }
    if (this.cancellationToken.isCancelled()) {
      return;
    }
    // Use setTimeout to yield to the UI thread.
    // 50ms 间隔防止多章布局一次性同步执行阻塞主线程（此前 0ms 导致 30 章布局
    // 在 Index.ets 的 await 间隙内连续执行，主线程阻塞 ~3.6s 无响应）。
    const epoch: number = this.layoutEpoch;
    const delay: number = this.backgroundReflowActive ? this.backgroundDelayMs : 50;
    setTimeout(() => {
      // 引擎已销毁 / 布局代数已变化 / 任务已取消 → 丢弃过期任务（ENG-005）
      if (this.destroyed || epoch !== this.layoutEpoch ||
        this.cancellationToken.isCancelled()) {
        return;
      }
      // Phase 12: 动画/拖拽进行中 → 推迟后台章（不污染动画帧；动画结束由下一次 task 恢复）
      if (this.backgroundReflowActive && this.userAnimating() && this.layoutQueue.length > 0) {
        this.scheduleNext();
        return;
      }
      this.processNextInQueue();
    }, delay);
  }

  /**
   * 递增布局代数：使所有已调度/在途的 setTimeout 排版任务作废（ENG-005）。
   * 在重排（relayoutAllChapters/rippleOutward）、清空（clearAll/destroy）时调用。
   */
  public bumpLayoutEpoch(): void {
    this.layoutEpoch++;
  }

  /**
   * Process the next item in the layout queue
   */
  public async processNextInQueue(): Promise<void> {
    if (this.destroyed) {
      return;
    }
    if (this.cancellationToken.isCancelled()) {
      return;
    }
    if (this.isProcessing) {
      return;
    }
    const chunkIndex: number | undefined = this.layoutQueue.shift();
    if (chunkIndex === undefined) {
      this.isProcessing = false;
      return;
    }
    this.isProcessing = true;
    this.rippleAborted = false;
    const bgT0: number = Date.now();

    try {
      const pages = this.host.pageSlots;
      const curGlobal = this.host.currentGlobalPage;
      const publication = this.host.publication;

      if (publication === undefined) {
        this.isProcessing = false;
        this.scheduleNext();
        return;
      }

      // If the chapter hasn't been parsed yet, skip (should be pre-loaded)
      if (chunkIndex >= this.chapterHtmlCache.length) {
        this.isProcessing = false;
        this.scheduleNext();
        return;
      }

      const chapterHtml: string | undefined = this.getChapterHtml(chunkIndex);
      if (chapterHtml === undefined || chapterHtml === '') {
        this.isProcessing = false;
        this.scheduleNext();
        return;
      }
      const html: string = chapterHtml;

      // Page Cache: per-chapter hit — reuse the cached pagination instead of
      // re-running parse/layout/split (incremental hit, US1/US3).
      const pageCtx: PageCacheContext | undefined = this.pageCacheContext;
      if (pageCtx !== undefined) {
        const cached: CacheChapter | null = this.loadChapterCached(chunkIndex);
        if (cached !== null) {
          const cachedChapter: PaginatedChapter = cached as PaginatedChapter;
          cachedChapter.isStub = false;
          if (chunkIndex < this.paginatedChapters.length) {
            this.paginatedChapters[chunkIndex] = cachedChapter;
          } else {
            this.paginatedChapters.push(cachedChapter);
          }
          // Same stub-to-real notification as the live pagination path below
          if (curGlobal < pages.length) {
            const curSlot = pages[curGlobal];
            if (curSlot.chunkIndex === chunkIndex && curSlot.state === 'stub') {
              this.host.rebuildPageSlots();
              this.host.paramBus.publish('pageReady', chunkIndex);
            }
          } else {
            this.host.rebuildPageSlots();
            this.host.paramBus.publish('pageReady', chunkIndex);
          }
          this.isProcessing = false;
          this.scheduleNext();
          return;
        }
      }

      // Parse HTML to DOM, then build render tree with styles applied
      // Phase 15：后台章走 TaskPool 纯布局（Worker 只计算；主线程验证+提交）。
      const chapterHref: string = publication.getChapterLink(chunkIndex)?.href ?? '';
      let paginated: PaginatedChapter | null = null;
      let livePath: string = 'main';
      if (this.backgroundReflowActive) {
        paginated = await this.layoutChapterInPool(chunkIndex, html, chapterHref);
        livePath = paginated !== null ? 'worker' : 'main';
        if (paginated === null && !this.destroyed) {
          // worker 不可用/失败 → 主线程回退（保持正确性）
          hilog.info(0x0000, 'OhEngine', 'LAYOUT_WORKER_FALLBACK ch=%{public}d reason=null-path', chunkIndex);
        }
      }
      if (paginated === null) {
        const parseT0: number = Date.now();
        const domTree: DomNode = this.htmlParser.parse(html);
        const renderTree: RenderNode[] = this.htmlParser.buildRenderTree(domTree, this.compiledSheet, this.styleMapper, undefined);
        this.statsLiveLayouts++;
        this.markChapterOrigin(chunkIndex, 'live');
        const t0: number = Date.now();
        // Phase 14 观测：分阶段耗时（load/parse/layout/split/save），定位 135–180ms 构成
        if (renderTree.length === 0) {
          // Create a placeholder page for empty chapter
          const emptyChapter: PaginatedChapter = createPaginatedChapter(chapterHref);
          emptyChapter.isStub = false;
          const emptyPage: Page = createEmptyPage(0);
          emptyChapter.pages.push(emptyPage);
          emptyChapter.totalPages = 1;
          emptyChapter.totalLineCount = 0;
          if (chunkIndex < this.paginatedChapters.length) {
            this.paginatedChapters[chunkIndex] = emptyChapter;
          } else {
            this.paginatedChapters.push(emptyChapter);
          }
          this.host.rebuildPageSlots();
          this.host.paramBus.publish('pageReady', chunkIndex);
          this.isProcessing = false;
          this.scheduleNext();
          return;
        }

        // Layout the render tree (computes lineBoxes/images) before splitting
        const layoutT0: number = Date.now();
        this.layoutEngine.setViewport(this.host.config.viewWidth, this.host.config.viewHeight);
        this.layoutEngine.layout(renderTree);
        const layoutMs: number = Date.now() - layoutT0;

        // Split into pages
        const splitT0: number = Date.now();
const pageSplitter: PageSplitter = this.pageSplitter;
        pageSplitter.setConfig({
          viewWidth: this.host.config.viewWidth,
          viewHeight: this.host.config.viewHeight,
          orphanLines: 2,
          widowLines: 2,
          avoidBreakInside: true
        });
        paginated = pageSplitter.splitChapter(renderTree, chapterHref);
        const splitMs: number = Date.now() - splitT0;
        this.statsLayoutMs += Date.now() - t0;
        const parseMs: number = t0 - parseT0;
      }

      // ============ 统一提交点（main commit；worker 与主线程回退共用） ============
      const commitT0: number = Date.now();
      if (paginated === null) {
        this.isProcessing = false;
        this.scheduleNext();
        return;
      }
      if (livePath === 'worker') {
        this.statsLiveLayouts++;
        this.markChapterOrigin(chunkIndex, 'live');
      }
      const commitChapter: PaginatedChapter = paginated;
      if (chunkIndex < this.paginatedChapters.length) {
        this.paginatedChapters[chunkIndex] = commitChapter;
      } else {
        this.paginatedChapters.push(commitChapter);
      }

      // Page Cache: incremental write — persist each chapter as soon as its
      // pagination completes (never stub; empty chapters return above).
      if (this.pageCacheContext !== undefined && !commitChapter.isStub) {
        PageCacheManager.saveChapter(this.pageCacheContext.cacheDir, chunkIndex,
          commitChapter as CacheChapter,
          this.pageCacheContext.sourcePath, this.pageCacheContext.signature,
          this.pageCacheContext.bookId, this.pageCacheContext.contentFingerprint);
        // Phase 25: 页数索引同步（chapterIndex → 真实页数，二次打开总页数精确化的依据）
        PageCacheManager.updatePageCount(this.pageCacheContext.cacheDir, chunkIndex,
          commitChapter.pages.length, this.pageCacheContext.signature,
          this.pageCacheContext.bookId !== undefined ? this.pageCacheContext.bookId : '',
          this.pageCacheContext.contentFingerprint !== undefined
            ? this.pageCacheContext.contentFingerprint : '');
        // Phase 3 (L3): 实时分页结果写内存缓存，回读跳过反序列化。
        this.memoryPageCache.put(chunkIndex, commitChapter as CacheChapter);
      }
      const commitMs: number = Date.now() - commitT0;
      if (this.backgroundReflowActive) {
        hilog.info(0x0000, 'OhEngine',
          'LAYOUT_COMMIT ch=%{public}d path=%{public}s commit=%{public}dms',
          chunkIndex, livePath, commitMs);
      } else if (livePath === 'main') {
        hilog.info(0x0000, 'OhEngine',
          'LAYOUT_CHAPTER ch=%{public}d parse=%{public}dms layout=%{public}dms split=%{public}dms commit=%{public}dms total=%{public}dms',
          chunkIndex, 0, 0, 0, commitMs, Date.now() - bgT0);
      }

      // If current page was a stub for this chunk, update navigation
      if (curGlobal < pages.length) {
        const curSlot = pages[curGlobal];
        if (curSlot.chunkIndex === chunkIndex && curSlot.state === 'stub') {
          this.host.rebuildPageSlots();
          this.host.paramBus.publish('pageReady', chunkIndex);
        }
      } else {
        this.host.rebuildPageSlots();
        this.host.paramBus.publish('pageReady', chunkIndex);
      }
    } catch (_e) {
    }

    this.isProcessing = false;
    // Phase 11 观测：后台章耗时 >50ms 打点（continuation 与 END 决策统一在 scheduleNext）
    if (this.backgroundReflowActive) {
      const bgMs: number = Date.now() - bgT0;
      if (bgMs > 50) {
        hilog.info(0x0000, 'OhEngine', 'COLDSTART BACKGROUND_CHAPTER ch=%{public}d ms=%{public}d', chunkIndex, bgMs);
      }
    }
    this.scheduleNext();
  }

  /**
   * Phase 21: 以最终阅读位置为锚重定位后台窗口（restore 成功后 / open 前设置）。
   */
  public recenterBackgroundWindow(anchorChapter: number): void {
    this.backgroundWindowAnchor = Math.max(0, anchorChapter);
    this.backgroundWindowLow = this.backgroundWindowAnchor;
    this.backgroundWindowHigh = this.backgroundWindowAnchor;
    this.backgroundWindowInited = true;
  }

  /**
   * Phase 20.1/21: 后台窗口延续——以当前阅读锚为中心，双向游标向外推进；
   * 首批=锚邻窗（restore 后位置），后续每批向两侧各推进至 cap；两侧到边界即 END。
   * 不再固定前缀扫描（"起点=当前窗口"）。
   */
  public enqueueBackgroundContinuation(): number {
    if (this.destroyed || this.cancellationToken.isCancelled()) {
      return 0;
    }
    const pcs = this.paginatedChapters;
    if (!this.backgroundWindowInited) {
      this.recenterBackgroundWindow(0);
    }
    let queued: number = 0;
    // 向后：锚左侧最近阅读史优先
    while (this.backgroundWindowLow > 0 && queued < BACKGROUND_BATCH_CAP) {
      const li: number = this.backgroundWindowLow - 1;
      const pc = pcs[li];
      if (pc === undefined || pc.isStub || pc.pages.length === 0) {
        this.queueChunkLayout(li, LayoutPriority.P4_BACKGROUND);
        queued++;
      }
      this.backgroundWindowLow = li;
    }
    // 向前：锚右侧推进
    while (this.backgroundWindowHigh + 1 < pcs.length && queued < BACKGROUND_BATCH_CAP) {
      const hi: number = this.backgroundWindowHigh + 1;
      const pc = pcs[hi];
      if (pc === undefined || pc.isStub || pc.pages.length === 0) {
        this.queueChunkLayout(hi, LayoutPriority.P4_BACKGROUND);
        queued++;
      }
      this.backgroundWindowHigh = hi;
    }
    return queued;
  }

  // ==================== Phase 15: TaskPool Layout Worker ====================

  /**
   * Phase 15: 后台章 TaskPool 纯布局。
   * 边界：Worker 只计算；结果在主线程验证（destroyed/epoch/cancellation）后返回。
   * 返回 null = 结果被丢弃或 worker 失败（调用方回退主线程路径）。
   */
  public async layoutChapterInPool(chunkIndex: number, html: string, href: string): Promise<PaginatedChapter | null> {
    const epochAt: number = this.layoutEpoch;
    const cfg = this.host.config;
    const profile = this.host.layoutProfile;
    const snapshot: ChapterLayoutSnapshot = {
      html: html,
      cssText: this.fullCssText,
      baseFontSize: this.host.fontSizeController.baseFontSize,
      lineSpacing: profile.lineSpacing,
      letterSpacing: profile.letterSpacing,
      wordSpacing: profile.wordSpacing,
      textAlign: profile.textAlign,
      fontFamily: profile.fontFamily !== undefined ? profile.fontFamily : '',
      viewWidth: cfg.viewWidth,
      viewHeight: cfg.viewHeight,
      href: href,
      density: cfg.density,
      measureOnce: chunkIndex === 3
    };
    const tSnap: number = Date.now();
    const inputJson: string = JSON.stringify(snapshot);
    const snapMs: number = Date.now() - tSnap;
    hilog.info(0x0000, 'OhEngine',
      'LAYOUT_WORKER_START ch=%{public}d snap=%{public}dms input=%{public}d epoch=%{public}d',
      chunkIndex, snapMs, inputJson.length, epochAt);
    const tExec: number = Date.now();
    let out: Object | null = null;
    try {
      out = await taskpool.execute(layoutChapterConcurrent, inputJson);
    } catch (_e) {
      hilog.info(0x0000, 'OhEngine', 'LAYOUT_WORKER_FALLBACK ch=%{public}d reason=execute-fail', chunkIndex);
      return null;
    }
    const execMs: number = Date.now() - tExec;
    // 主线程验证（§7/§26）：Session/epoch/cancel 任一失效 → DROP
    if (this.destroyed || epochAt !== this.layoutEpoch || this.cancellationToken.isCancelled()) {
      hilog.info(0x0000, 'OhEngine',
        'LAYOUT_RESULT_DROP ch=%{public}d epoch=%{public}d destroyed=%{public}d',
        chunkIndex, epochAt, this.destroyed ? 1 : 0);
      return null;
    }
    if (typeof out !== 'string' || out.length === 0) {
      hilog.info(0x0000, 'OhEngine', 'LAYOUT_WORKER_FALLBACK ch=%{public}d reason=null-output', chunkIndex);
      return null;
    }
    const tDeser: number = Date.now();
    const diag: DeserializeDiag = { jsonParseMs: 0, rebuildMs: 0, lineBoxCount: 0, textCharCount: 0 };
    const chapter: CacheChapter | null = PageCacheManager.deserializePaginatedChapter(out, diag);
    const deserMs: number = Date.now() - tDeser;
    if (chapter === null) {
      hilog.info(0x0000, 'OhEngine', 'LAYOUT_WORKER_FALLBACK ch=%{public}d reason=deserialize-null', chunkIndex);
      return null;
    }
    const pc: PaginatedChapter = chapter as PaginatedChapter;
    pc.isStub = false;
    const outBytes: number = out.length;
    hilog.info(0x0000, 'OhEngine',
      'LAYOUT_WORKER_END ch=%{public}d exec=%{public}dms deser=%{public}dms jsonParse=%{public}dms rebuild=%{public}dms in=%{public}d out=%{public}d pages=%{public}d lines=%{public}d chars=%{public}d',
      chunkIndex, execMs, deserMs, diag.jsonParseMs, diag.rebuildMs, inputJson.length, outBytes,
      pc.pages.length, diag.lineBoxCount, diag.textCharCount);
    return pc;
  }

  // ==================== Chapter Layout ====================

  /**
   * Layout all chapters (full layout)
   */
  public layoutAllChapters(): void {
    const publication = this.host.publication;
    if (publication === undefined) {
      return;
    }
    const totalChapters: number = publication.getChapterCount();
    this.paginatedChapters = [];
    // Pre-allocate
    for (let i: number = 0; i < totalChapters; i++) {
      this.paginatedChapters.push(createPaginatedChapter(''));
    }
    // Queue all chapters for layout
    for (let i: number = 0; i < totalChapters; i++) {
      this.queueChunkLayout(i, 'high');
    }
  }

  /**
   * Relayout all chapters from a given chapter index onward
   */
  public relayoutAllChapters(fromChapter: number = 0): void {
    const publication = this.host.publication;
    if (publication === undefined) {
      return;
    }
    // 重排作废在途任务，避免旧布局覆盖新布局（ENG-005）
    this.bumpLayoutEpoch();
    this.layoutQueue = [];
    this.isProcessing = false;
    // Clear pagination from fromChapter onward
    for (let i: number = fromChapter; i < this.paginatedChapters.length; i++) {
      this.paginatedChapters[i] = createPaginatedChapter('');
    }
    // Re-queue from chapter
    for (let i: number = fromChapter; i < publication.getChapterCount(); i++) {
      this.queueChunkLayout(i, 'high');
    }
  }

  /**
   * Ripple layout outward from a given chapter (re-layout neighboring chapters)
   */
  public rippleOutward(chapterIndex: number): void {
    const publication = this.host.publication;
    if (publication === undefined) {
      return;
    }
    // 重排作废在途任务（ENG-005）
    this.bumpLayoutEpoch();
    this.layoutQueue = [];
    this.isProcessing = false;
    this.rippleAborted = false;
    const maxChapters: number = publication.getChapterCount();

    // Relayout the trigger chapter
    this.relayoutSingleChunk(chapterIndex);

    // Ripple forward: layout next N chapters
    const rippleRange: number = 5;
    for (let i: number = 1; i <= rippleRange && !this.rippleAborted; i++) {
      const idx: number = chapterIndex + i;
      if (idx >= maxChapters) {
        break;
      }
      this.relayoutSingleChunk(idx);
    }
    // Ripple backward: layout previous N chapters
    for (let i: number = 1; i <= rippleRange && !this.rippleAborted; i++) {
      const idx: number = chapterIndex - i;
      if (idx < 0) {
        break;
      }
      this.relayoutSingleChunk(idx);
    }
    this.host.rebuildPageSlots();
  }

  /**
   * Relayout a single chunk (re-parse and re-split)
   */
  public relayoutSingleChunk(chapterIndex: number): void {
    const publication = this.host.publication;
    if (publication === undefined) {
      return;
    }
    const html: string | undefined = this.getChapterHtml(chapterIndex);
    if (html === undefined || html === '') {
      return;
    }
    this.markChapterOrigin(chapterIndex, 'live');
    const domTree: DomNode = this.htmlParser.parse(html);
    const renderTree: RenderNode[] = this.htmlParser.buildRenderTree(domTree, this.compiledSheet, this.styleMapper, undefined);
    if (renderTree.length === 0) {
      return;
    }
    // Layout the render tree (computes lineBoxes/images) before re-splitting
    this.layoutEngine.setViewport(this.host.config.viewWidth, this.host.config.viewHeight);
    this.layoutEngine.layout(renderTree);
    const pageSplitter: PageSplitter = this.pageSplitter;
    pageSplitter.setConfig({
      viewWidth: this.host.config.viewWidth,
      viewHeight: this.host.config.viewHeight,
      orphanLines: 2,
      widowLines: 2,
      avoidBreakInside: true
    });
    const paginated: PaginatedChapter = pageSplitter.splitChapter(renderTree,
      publication.getChapterLink(chapterIndex)?.href ?? '');

    if (chapterIndex < this.paginatedChapters.length) {
      this.paginatedChapters[chapterIndex] = paginated;
    } else {
      this.paginatedChapters.push(paginated);
    }
  }

  // ==================== Reading Parameters ====================

  /**
   * Adjust vertical reading parameters (page height / margins)
   */
  public adjustVerticalParams(): void {
    // Trigger a re-layout when view height changes.
    this.host.relayoutCurrentPageOnly();
  }

  /**
   * 销毁管道（ENG-005）：置位销毁标记并作废在途任务。
   * 与 clearAll 不同，shutdown 后 scheduleNext/processNextInQueue 直接丢弃任务，
   * 保证引擎销毁后后台任务不再更新页面。由 OhEngineCore.destroy() 调用。
   */
  public shutdown(): void {
    this.destroyed = true;
    this.cancellationToken.cancel();
    this.clearAll();
  }

  /**
   * Clear all pipeline state (called on destroy / reset)
   */
  public clearAll(): void {
    // 清空作废在途任务（ENG-005）
    this.bumpLayoutEpoch();
    this.cancellationToken.cancel();
    this.layoutQueue = [];
    this.isProcessing = false;
    this.rippleAborted = false;
    // 统计随 session 重置（固定 hit-rate 分母 = 本次 session 的缓存访问总数）
    this.statsL3Hits = 0;
    this.statsL2Hits = 0;
    this.statsL2Miss = 0;
    this.statsLiveLayouts = 0;
    this.statsLayoutMs = 0;
    this.memoryPageCache.clear();
    this.chapterOriginMap.clear();
    this.paginatedChapters = [];
    this.chapterHtmlCache = [];
    this.chapterHtmlProvider = undefined;
    this.fontFaceCssTexts = [];
    this.fullCssText = '';
    this.readingDirection = 1;
    this.readingSpeed = 250;
    this.layoutEngine = new LayoutEngine();
    this.cssParser = new CssParser();
    this.styleMapper = new StyleMapper();
    this.compiledSheet = new CompiledStylesheet();
    this.fontLoader = new FontLoader();
    this.fontFallbackChain = new FontFallbackChain();
    this.mediaOverlayController = new DefaultMediaOverlayController();
    this.remoteResourceLoader = new RemoteResourceLoader();
    this.mediaCompiler = new MediaConditionalCompiler();
  }

  /**
   * Prepare the pipeline for image-based (fixed-layout) rendering.
   *
   * Called by ImageRouter during initialisation after stub pages have
   * been created. Pre-allocates the paginatedChapters array so that
   * each image chapter has a placeholder entry.
   *
   * @param totalPages - number of image pages
   */
  public prepareImagePipeline(totalPages: number): void {
    // Pre-allocate paginated chapters — one per image page
    while (this.paginatedChapters.length < totalPages) {
      this.paginatedChapters.push(createPaginatedChapter(''));
    }
    // Image books generally don't need CSS compilation; skip.
  }

  /**
   * Prepare the pipeline for reflowable-content rendering.
   *
   * Called by ReflowRouter during initialisation after stub pages have
   * been created. Pre-allocates the paginatedChapters array and kicks
   * off CSS compilation so the layout queue is ready for dynamic
   * pagination on every page turn.
   *
   * @param totalChapters - number of reflow chapters
   */
  public prepareReflowPipeline(totalChapters: number): void {
    // Pre-allocate paginated chapters
    while (this.paginatedChapters.length < totalChapters) {
      this.paginatedChapters.push(createPaginatedChapter(''));
    }
    // Compile CSS once — all chapters share the same stylesheet
    this.loadAndCompileCss();
  }

  /**
   * Synchronously layout a RANGE of chapters [from·to] (cache-first,
   * write-through). Phase 2 (L2 hot cache): open() only paginates the
   * hot window (current ±N + neighbor start/end) synchronously, then
   * delegates the rest to the async queue (queueChunkLayout) so the
   * first-readable page is available without whole-book pagination.
   *
   * @param fromChapter - 起始章节（inclusive）
   * @param toChapter - 结束章节（inclusive，clamp 到全书）
   */
  public layoutRangeSync(fromChapter: number, toChapter: number): void {
    const publication = this.host.publication;
    if (publication === undefined) {
      return;
    }
    const totalChapters: number = publication.getChapterCount();
    const from: number = Math.max(0, fromChapter);
    const to: number = Math.min(totalChapters - 1, toChapter);
    if (from > to || totalChapters === 0) {
      return;
    }
    const pageCtx: PageCacheContext | undefined = this.pageCacheContext;
    for (let i: number = from; i <= to; i++) {
      if (this.cancellationToken.isCancelled()) {
        break;
      }
      // 1) Cache-first: per-chapter hit skips the whole parse/layout/split chain.
      if (pageCtx !== undefined) {
        const cached: CacheChapter | null = this.loadChapterCached(i);
        if (cached !== null) {
          const cachedChapter: PaginatedChapter = cached as PaginatedChapter;
          cachedChapter.isStub = false;
          if (i < this.paginatedChapters.length) {
            this.paginatedChapters[i] = cachedChapter;
          } else {
            this.paginatedChapters.push(cachedChapter);
          }
          continue;
        }
      }
      // 2) Live layout for uncached chapter.
      const html: string | undefined = this.getChapterHtml(i);
      if (html === undefined || html === '') {
        continue;
      }
      this.markChapterOrigin(i, 'live');
      const domTree: DomNode = this.htmlParser.parse(html);
      const renderTree: RenderNode[] = this.htmlParser.buildRenderTree(domTree,
        this.compiledSheet, this.styleMapper, undefined);
      if (renderTree.length === 0) {
        const emptyChapter: PaginatedChapter = createPaginatedChapter(
          publication.getChapterLink(i)?.href ?? '');
        emptyChapter.isStub = false;
        emptyChapter.pages.push(createEmptyPage(0));
        emptyChapter.totalPages = 1;
        emptyChapter.totalLineCount = 0;
        if (i < this.paginatedChapters.length) {
          this.paginatedChapters[i] = emptyChapter;
        } else {
          this.paginatedChapters.push(emptyChapter);
        }
        continue;
      }
      this.layoutEngine.setViewport(this.host.config.viewWidth, this.host.config.viewHeight);
      this.layoutEngine.layout(renderTree);
      this.pageSplitter.setConfig({
        viewWidth: this.host.config.viewWidth,
        viewHeight: this.host.config.viewHeight,
        orphanLines: 2,
        widowLines: 2,
        avoidBreakInside: true
      });
      const paginated: PaginatedChapter = this.pageSplitter.splitChapter(renderTree,
        publication.getChapterLink(i)?.href ?? '');
      paginated.isStub = false;
      if (i < this.paginatedChapters.length) {
        this.paginatedChapters[i] = paginated;
      } else {
        this.paginatedChapters.push(paginated);
      }
      // Write-through: persist as soon as the chapter paginates.
      if (pageCtx !== undefined) {
        PageCacheManager.saveChapter(pageCtx.cacheDir, i, paginated as CacheChapter,
          pageCtx.sourcePath, pageCtx.signature, pageCtx.bookId, pageCtx.contentFingerprint);
        // Phase 3 (L3): 实时分页结果写内存缓存（热窗内重复命中零反序列化）。
        this.memoryPageCache.put(i, paginated as CacheChapter);
      }
    }
    this.host.rebuildPageSlots();
  }

  /**
   * Synchronously layout ALL chapters (cache-first, write-through).
   *
   * Unlike the async queue path (open() returns with stub pages for chapters
   * 1..N), this method guarantees that when it returns, every chapter's
   * pagination is either loaded from the page cache or computed live and
   * persisted back to cache. open() calls this so that "open" implies
   * "already fully paginated and cached" — no background stub→real swap.
   *
   * Per-chapter flow:
   *   1. Page cache hit  → reuse cached PaginatedChapter (no parse/layout)
   *   2. Page cache miss → parse HTML → buildRenderTree → layoutEngine.layout
   *                        → splitChapter → store in paginatedChapters
   *                        → PageCacheManager.saveChapter (write-through)
   *
   * @param totalChapters - number of chapters to lay out
   */
  public layoutAllChaptersSync(totalChapters: number): void {
    const publication = this.host.publication;
    if (publication === undefined) {
      return;
    }
    const pageCtx: PageCacheContext | undefined = this.pageCacheContext;
    for (let i: number = 0; i < totalChapters; i++) {
      if (this.cancellationToken.isCancelled()) {
        break;
      }
      // 1) Cache-first: per-chapter hit skips the whole parse/layout/split chain.
      if (pageCtx !== undefined) {
        const cached: CacheChapter | null = this.loadChapterCached(i);
        if (cached !== null) {
          const cachedChapter: PaginatedChapter = cached as PaginatedChapter;
          cachedChapter.isStub = false;
          if (i < this.paginatedChapters.length) {
            this.paginatedChapters[i] = cachedChapter;
          } else {
            this.paginatedChapters.push(cachedChapter);
          }
          continue;
        }
      }
      // 2) Live layout for uncached chapter.
      const html: string | undefined = this.getChapterHtml(i);
      if (html === undefined || html === '') {
        continue;
      }
      this.markChapterOrigin(i, 'live');
      const domTree: DomNode = this.htmlParser.parse(html);
      const renderTree: RenderNode[] = this.htmlParser.buildRenderTree(domTree,
        this.compiledSheet, this.styleMapper, undefined);
      if (renderTree.length === 0) {
        const emptyChapter: PaginatedChapter = createPaginatedChapter(
          publication.getChapterLink(i)?.href ?? '');
        emptyChapter.isStub = false;
        emptyChapter.pages.push(createEmptyPage(0));
        emptyChapter.totalPages = 1;
        emptyChapter.totalLineCount = 0;
        if (i < this.paginatedChapters.length) {
          this.paginatedChapters[i] = emptyChapter;
        } else {
          this.paginatedChapters.push(emptyChapter);
        }
        continue;
      }
      this.layoutEngine.setViewport(this.host.config.viewWidth, this.host.config.viewHeight);
      this.layoutEngine.layout(renderTree);
      this.pageSplitter.setConfig({
        viewWidth: this.host.config.viewWidth,
        viewHeight: this.host.config.viewHeight,
        orphanLines: 2,
        widowLines: 2,
        avoidBreakInside: true
      });
      const paginated: PaginatedChapter = this.pageSplitter.splitChapter(renderTree,
        publication.getChapterLink(i)?.href ?? '');
      paginated.isStub = false;
      if (i < this.paginatedChapters.length) {
        this.paginatedChapters[i] = paginated;
      } else {
        this.paginatedChapters.push(paginated);
      }
      // Write-through: persist as soon as the chapter paginates.
      if (pageCtx !== undefined) {
        PageCacheManager.saveChapter(pageCtx.cacheDir, i, paginated as CacheChapter,
          pageCtx.sourcePath, pageCtx.signature, pageCtx.bookId, pageCtx.contentFingerprint);
        // Phase 25: 页数索引同步
        PageCacheManager.updatePageCount(pageCtx.cacheDir, i, paginated.pages.length,
          pageCtx.signature,
          pageCtx.bookId !== undefined ? pageCtx.bookId : '',
          pageCtx.contentFingerprint !== undefined ? pageCtx.contentFingerprint : '');
        // Phase 3 (L3): 实时分页结果写内存缓存。
        this.memoryPageCache.put(i, paginated as CacheChapter);
      }
    }
    this.host.rebuildPageSlots();
  }
}
