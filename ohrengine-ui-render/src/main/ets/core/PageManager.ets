/**
 * PageManager — Page Navigation, Pagination, and Layout State
 *
 * Holds all page-slot state, navigation methods, page rebuild/reflow logic,
 * and reading-progress persistence.
 *
 * Decoupled from OhEngineCore via constructor injection of PipelineManager,
 * PageSplitter, ReadingMetrics, and a PageManagerHost callback interface.
 *
 * This is NOT the public API entry point. Use OhEngine (facade) for all external consumption.
 */

import { PaginatedChapter, Page, PageSplitter } from '../layout/PageSplitter.ets';
import type { RenderNode, LineBox, BoxModel } from 'ohrengine-common';
import type { PageSlot, EngineConfig, ReadingProgress } from 'ohrengine-common';
import type { RecordPosition, ReadingRecord, IReadingHistoryStore } from 'ohrengine-common';
import type { ReadingAnchor, ReadingState } from 'ohrengine-common';
import { extractParagraphs, computeParagraphStarts, hashParagraphText,
         clampParagraphCharOffset, READING_STATE_SCHEMA_VERSION } from 'ohrengine-common';
import { ReadingMetrics } from '../typography/ReadingMetrics.ets';
import { SelectionGestureHandler, Bookmark, SearchResult } from 'ohrengine-feature';
import { Annotation, Publication, TocItem, Link,
         TurnDirection, PageReadyState } from 'ohrengine-common';
import { PipelineManager, LayoutPriority } from './PipelineManager';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Callback interface grouping OhEngineCore state that PageManager needs.
 * Injected at construction to break the circular dependency between
 * OhEngineCore ↔ PageManager.
 */
export interface PageManagerHost {
  /** The currently open book (undefined before open()) */
  publication: Publication | undefined;
  /** Engine configuration (view size, profiles, etc.) */
  config: EngineConfig;
  /** Monotonic epoch counter bumped on every updateReadingPosition() */
  epoch: number;
  /** Whether the engine is in READY state and can handle navigation */
  isReady: boolean;
  /** Access the reading history store for position persistence */
  getReadingHistory(): IReadingHistoryStore | undefined;
  /** Stable book ID for the currently open book */
  getBookId(): string;
  /** Current layout signature ('' when unavailable) */
  getLayoutSignature(): string;
  /** Current content fingerprint (source size:mtime; '' when unavailable) */
  getContentFingerprint(): string;
  /** Persist a ReadingState (atomic file write owned by the host) */
  saveReadingState(state: ReadingState): void;
  /**
   * Phase 24 (Issue B)：统一分页模型估算参数——单页可容纳的正文 UTF-16 字符数。
   * 由「viewport + 排版参数（行距/边距） + 字体参数（字号）」派生，
   * 供未物化章节的 documentTotalPages 估算使用（不区分格式）。
   */
  getCharsPerPage(): number;
}

/** 段落邻近搜索窗口（恢复时 hash 未命中在此范围内找最近匹配） */
const PARAGRAPH_SEARCH_WINDOW: number = 40;
/** 页面起始文本片段长度（用于段落定位） */
const PAGE_FRAGMENT_CHARS: number = 12;

/**
 * Derive a stable book ID from a Publication.
 * Uses manifest.metadata.identifier if available, falls back to getTitle().
 */
function getBookId(pub: Publication): string {
  const id: string | undefined = pub.manifest.metadata.identifier;
  if (id !== undefined && id.length > 0) {
    return id;
  }
  return pub.getTitle();
}

export class PageManager {
  private readonly pipelineManager: PipelineManager;
  private readonly pageSplitter: PageSplitter;
  private readonly readingMetrics: ReadingMetrics;
  private readonly host: PageManagerHost;

  // ==================== Page State Fields ====================
  pageSlots: PageSlot[] = [];
  currentGlobalPage: number = 0;

  /**
   * pageGeneration — 页槽代次计数器（0.13/FR-011，与 epoch 语义完全分离）。
   * 独立单调递增，覆盖全部会替换/修改 pageSlots 内容或布局结果的重排入口；
   * 用于翻页 B2 提交前的快照校验（跨层校验唯一依据 = ArkTS 侧重新读取的当前值）。
   *
   * ⚠️ 递增点清单（0.13 六入口 vs 实际实现对照，代码审查检查项）：
   *   [1] rebuildPageSlots()                     → 本方法首行递增（唯一替换 pageSlots 的点）
   *   [2] reflowFromCurrentPage()                → 内部调用 this.rebuildPageSlots()，经 [1] 递增
   *   [3] relayoutAllChapters()                  → PipelineManager 侧；队列排版完成后
   *                                                 经 host.rebuildPageSlots() → PageManager.rebuildPageSlots()，经 [1] 递增
   *   [4] relayoutCurrentPageOnly()              → 内部调用 this.rebuildPageSlots()，经 [1] 递增
   *   [5] recompileCss() 触发的 reflow           → OhEngineCore.recompileCss → reflowFromCurrentPage，经 [1] 递增
   *   [6] PipelineManager.processNextInQueue()   → 异步完成时调用 host.rebuildPageSlots()
   *                                                  → OhEngineCore.rebuildPageSlots → PageManager.rebuildPageSlots，经 [1] 递增
   * 任何新增的会替换/修改 pageSlots 内容的入口必须同步经 rebuildPageSlots() 递增。
   */
  private pageGeneration: number = 0;

  /** P0-C: 用户导航代次（Latest Jump Wins；每次主动导航自增） */
  navigationSerial: number = 0;

  /** pageGeneration 只读访问器（0.13，实现 PageGenerationProvider 契约） */
  public getPageGeneration(): number {
    return this.pageGeneration;
  }
  chunkToPages: Map<number, number[]> = new Map();
  currentCharIndex: number = 0;
  totalCharCount: number = 0;
  chunkPlainTextLengths: number[] = [];
  chunkPlainTexts: string[] = [];
  lastPageTurnTime: number = 0;
  lastPageChars: number = 0;
  saveCacheTimer: number = -1;

  /**
   * Phase 24 最小状态表达（STUB/LOADING/READY/FAILED）：
   *  - STUB   → slot.state === 'stub'
   *  - LOADING→ pendingNavChunk（导航目标已入队等待 commit；rebuild 时清除）
   *  - READY  → slot.state === 'ready'
   *  - FAILED → layoutFailedChunks（章节内容不可得，布局失败）
   * 仅运行时诊断/渲染提示用，不进入 L2 缓存序列化。
   */
  private pendingNavChunk: number = -1;
  private layoutFailedChunks: Set<number> = new Set();
  /** Phase 24：异步导航的章内目标页序（goToProgress 设置；rebuild 重映射后清除） */
  private pendingNavInChunkPage: number = -1;
  /**
   * Phase 24（恢复守卫）：此时刻之前的 persistCurrentReadingState 一律跳过。
   * restoreReadingState 入口设置（+2s 自愈），防止恢复路径回写降级位置。
   */
  private persistGuardUntil: number = 0;
  /** Issue B：估算缓存（rebuild / 索引重置时失效；避免 UI 高频调用 O(n²)） */
  private cachedCharsPerPage: number = 0;
  private cachedDensityFactor: number = -1;

  /**
   * Phase 25（真实总页数）：open 期从 L2 pgcount.json 装载的每章真实页数。
   * chapterIndex → 页数；>0 即该章已按当前排版签名完整缓存。null = 未装载
   * （无缓存/签名失效/新书）。排版参数变更（签名变化）时由 OhEngineCore 置空。
   */
  private cachedChapterCounts: number[] | null = null;

  /**
   * Phase 25：注入已缓存章节的真实页数（打开时由 OhEngineCore 从 pgcount.json
   * 装载并校验签名后调用；引擎每次 open 前先置空，避免跨书/跨代串用）。
   */
  public setCachedChapterCounts(counts: number[] | null): void {
    if (counts === null) {
      this.cachedChapterCounts = null;
      return;
    }
    const copy: number[] = [];
    for (let i = 0; i < counts.length; i++) {
      copy.push(counts[i]);
    }
    this.cachedChapterCounts = copy;
  }

  /** Phase 25：当前是否有已缓存的真实页数表（诊断用） */
  public hasCachedChapterCounts(): boolean {
    return this.cachedChapterCounts !== null;
  }

  /** Phase 8 D2: 旧章索引 → 首 vchapter 全局序（TXT vchapter 映射；EPUB 空） */
  oldChapterToVchapterStart: number[] = [];
  /** Phase 8 D2: 旧章索引 → 该章 vchapter 数（TXT vchapter 映射；EPUB 空） */
  oldChapterVchapterCounts: number[] = [];

  /** Phase 1 (L1): 每章的段落文本缓存（extractParagraphs 确定性结果）；存 undefined 表示未缓存 */
  private chapterParagraphs: Array<string[] | undefined> = [];
  /** Phase 1 (L1): 每章的段落起始字符偏移缓存 */
  private chapterParagraphStarts: Array<number[] | undefined> = [];

  constructor(
    pipelineManager: PipelineManager,
    pageSplitter: PageSplitter,
    readingMetrics: ReadingMetrics,
    host: PageManagerHost
  ) {
    this.pipelineManager = pipelineManager;
    this.pageSplitter = pageSplitter;
    this.readingMetrics = readingMetrics;
    this.host = host;
  }

  // ==================== Simple Getters ====================

  /**
   * Get current page (line boxes)
   */
  public getCurrentPage(): PageSlot | undefined {
    if (this.currentGlobalPage >= 0 && this.currentGlobalPage < this.pageSlots.length) {
      return this.pageSlots[this.currentGlobalPage];
    }
    return undefined;
  }

  /**
   * Phase 24 (Issue B)：总页数语义修正。
   *
   * 旧行为：返回 pageSlots.length —— 即「已物化页数 + 每未物化章 1 页压缩 stub」，
   * 把物化缓存当作文档坐标系统使用（31 章 EPUB 打开显示 31/31，实际 318 页）。
   *
   * 新语义：返回 documentTotalPages = Σ 已物化章真实页数 + Σ 未物化章统一模型估算页数。
   * 打开时（热窗已同步分页）即可显示接近全书的总页数；后台物化推进时仅做小幅收敛，
   * 不再出现「31 → 318」的跳变。global pageSlots 仍是导航实现细节，不再外泄为总页数。
   */
  public getTotalPages(): number {
    return this.getDocumentTotalPages();
  }

  /** 已物化真实页数（诊断/对照用；用户可见的总页数请走 getTotalPages） */
  public getMaterializedPages(): number {
    return this.pageSlots.length;
  }

  /**
   * Phase 24 (Issue B)：整本书理论总页数。
   * 估算来源 = 统一分页模型（chapter 文本长度 + 排版参数 + viewport + 字体参数），
   * 不区分 EPUB/TXT/PDF；已物化章使用真实分页结果；未物化章估算乘以
   * 「已物化章实/估密度自校准因子」（补偿段落断行碎片化造成的页数膨胀），
   * 使打开瞬间即接近收敛值，后台物化推进时不再出现大幅跳变。
   */
  public getDocumentTotalPages(): number {
    const pcs: PaginatedChapter[] = this.pipelineManager.paginatedChapters;
    let total: number = 0;
    for (let ci: number = 0; ci < pcs.length; ci++) {
      const pc: PaginatedChapter | undefined = pcs[ci];
      if (pc === undefined || pc === null) {
        continue;
      }
      // Phase 25：统一走 getChapterPageCount（已物化 > L2 缓存页数 > 估算），
      // 保证「二次打开 = 真实总页数」且不引入两套口径。
      total += this.getChapterPageCount(ci);
    }
    return total;
  }

  /**
   * 未物化章的页数估算（统一分页模型；文本长度未知时按 1 页占位）。
   *
   * ESTIMATE_FRAGMENTATION_FACTOR（0.85）：段落碎片化先验——纯文本按满页
   * 切分低估真实页数（每段最后一行半空、标题独占、段距），实测 CJK 长篇
   * 约 15%；该先验只影响开书瞬间的估算精度，后台物化后由
   * estimateDensityFactor（实/估自校准）在线修正，不引入格式特判。
   */
  private static readonly ESTIMATE_FRAGMENTATION_FACTOR: number = 0.85;

  private estimateChunkPageCount(chapterIndex: number): number {
    const len: number = chapterIndex < this.chunkPlainTextLengths.length
      ? this.chunkPlainTextLengths[chapterIndex] : 0;
    if (len <= 0) {
      return 1;
    }
    const charsPerPage: number = Math.max(50,
      this.resolveCharsPerPage() * PageManager.ESTIMATE_FRAGMENTATION_FACTOR);
    return Math.max(1, Math.ceil(len / charsPerPage));
  }

  /** 估算失效（rebuild / 索引重置后重算） */
  private invalidatePageEstimates(): void {
    this.cachedCharsPerPage = 0;
    this.cachedDensityFactor = -1;
  }

  /**
   * 已物化章「真实页数 / 估算页数」比值（段落碎片化校正因子）。
   * 纯文本按 charsPerPage 满页切分低估了真实页数——每段落最后一行、
   * 标题、段距都会产生页内空隙。因子随物化推进自动收敛到 1 附近
   * （已物化章直接用真实值），clamp 到 [0.5, 2.5] 防御异常章节。
   */
  private estimateDensityFactor(): number {
    if (this.cachedDensityFactor >= 0) {
      return this.cachedDensityFactor;
    }
    const pcs: PaginatedChapter[] = this.pipelineManager.paginatedChapters;
    let real: number = 0;
    let est: number = 0;
    for (let ci: number = 0; ci < pcs.length; ci++) {
      const pc: PaginatedChapter | undefined = pcs[ci];
      if (pc === undefined || pc.isStub || pc.pages.length === 0) {
        continue;
      }
      const len: number = ci < this.chunkPlainTextLengths.length
        ? this.chunkPlainTextLengths[ci] : 0;
      if (len <= 0) {
        continue;
      }
      real += pc.pages.length;
      est += Math.max(1, Math.ceil(len / this.resolveCharsPerPage()));
    }
    const f: number = (est > 0 && real > 0) ? real / est : 1;
    this.cachedDensityFactor = Math.max(0.5, Math.min(2.5, f));
    return this.cachedDensityFactor;
  }

  /**
   * 单页可容纳字符数：
   * 1) 优先使用已物化页面的实测平均 charRange 跨度（最贴近真实分页密度，
   *    天然涵盖缩进/段距/标题等真实排版效应）；
   * 2) 回退到 host 参数模型（viewport + 排版参数 + 字体参数）；
   * 3) 最终兜底 800（历史经验值）。
   */
  private resolveCharsPerPage(): number {
    if (this.cachedCharsPerPage > 0) {
      return this.cachedCharsPerPage;
    }
    let chars: number = 0;
    let pages: number = 0;
    for (let i: number = 0; i < this.pageSlots.length; i++) {
      const s: PageSlot = this.pageSlots[i];
      if (s.state === 'ready') {
        const span: number = s.charRange[1] - s.charRange[0];
        if (span > 0) {
          chars += span;
          pages++;
        }
      }
    }
    let result: number = 800;
    if (pages >= 3) {
      const avg: number = chars / pages;
      if (avg >= 100) {
        result = avg;
      }
    }
    if (result === 800) {
      const hint: number = this.host.getCharsPerPage();
      if (hint >= 100) {
        result = hint;
      }
    }
    this.cachedCharsPerPage = result;
    return result;
  }

  /**
   * Get page at relative offset from current page WITHOUT changing current page.
   * Used by page-curl preview (peek next/prev page while dragging).
   * @param offset relative offset (e.g. 1 = next page, -1 = previous page)
   */
  public getPageByOffset(offset: number): PageSlot | undefined {
    const target: number = this.currentGlobalPage + offset;
    if (target >= 0 && target < this.pageSlots.length) {
      const slot: PageSlot = this.pageSlots[target];
      if (slot.state === 'stub') {
        // 与 goToPage 一致：stub 页触发章节预取，返回非 stub 前先用当前可用状态
        this.ensureChapterReady(slot.chunkIndex);
        // Phase 24 (Issue C)：ensure 可能已同步 relayout/rebuild——返回重建后的
        // 新鲜页槽，避免翻页预览（peek）把 stale stub 空白页带进动画。
        if (target < this.pageSlots.length) {
          return this.pageSlots[target];
        }
      }
      return slot;
    }
    return undefined;
  }

  /**
   * Get global page number (across all chapters, 1-based)
   */
  public getGlobalPageNumber(): number {
    return this.currentGlobalPage + 1;
  }

  /**
   * Phase 24 (Issue B)：文档空间页码（1-based）。
   * 与 getDocumentTotalPages 同空间，供 UI「X / Y」显示使用——
   * 此前 X 是物化页槽序、Y 是总页数，分子分母不同空间（31/31 vs 318 页）。
   */
  public getDocumentPageNumber(): number {
    return this.getCurrentDocumentPageIndex() + 1;
  }

  /**
   * Get current chapter index
   */
  public getCurrentChapterIndex(): number {
    if (this.currentGlobalPage >= 0 && this.currentGlobalPage < this.pageSlots.length) {
      return this.pageSlots[this.currentGlobalPage].chunkIndex;
    }
    return 0;
  }

  /**
   * Get current page index within chapter (0-based page number within chunk)
   */
  public getCurrentPageIndex(): number {
    if (this.currentGlobalPage >= 0 && this.currentGlobalPage < this.pageSlots.length) {
      const slot: PageSlot = this.pageSlots[this.currentGlobalPage];
      const pages: number[] | undefined = this.chunkToPages.get(slot.chunkIndex);
      if (pages !== undefined) {
        for (let i: number = 0; i < pages.length; i++) {
          if (pages[i] === slot.pageNumber) {
            return i;
          }
        }
      }
    }
    return 0;
  }

  /**
   * Get chapter page count for specific chapter index
   * Phase 24 (Issue B)：未物化章返回统一模型估算值（此前返回 0/1，
   * 导致章节页码与目录页码在冷启动时全部失真）。
   */
  public getChapterPageCount(chapterIndex: number): number {
    // 注意：不查 chunkToPages——它是「页槽空间」映射（未物化章仅 1 个压缩
    // stub 槽，长度恒为 1），用作章页数会把所有 stub 章计成 1 页（open 期
    // 总页数塌缩成「物化热窗 + 每章 1」的假值）。页数语义统一为：
    // 真实分页（已物化） > L2 页数索引（pgcount，签名匹配） > 统一模型估算。
    const pc: PaginatedChapter | undefined = this.pipelineManager.paginatedChapters[chapterIndex];
    if (pc !== undefined && !pc.isStub && pc.pages.length > 0) {
      return pc.pages.length;
    }
    // Phase 25（真实总页数）：优先已缓存章节的真实页数（open 期从 pgcount.json
    // 装载），其次统一模型估算。命中已缓存页数时总页数/页码立即精确，
    // 不再依赖「未物化章估算 + 后台物化收敛」。
    const cachedCounts: number[] | null = this.cachedChapterCounts;
    if (cachedCounts !== null && chapterIndex < cachedCounts.length &&
      cachedCounts[chapterIndex] > 0) {
      return cachedCounts[chapterIndex];
    }
    return Math.max(1,
      Math.ceil(this.estimateChunkPageCount(chapterIndex) * this.estimateDensityFactor()));
  }

  // ==================== Navigation ====================

  /**
   * Turn page
   *
   * Respects OPF page-progression-direction for RTL books:
   *   - RTL:  FORWARD (visual left turn) -> goToPreviousPage
   *           BACKWARD (visual right turn) -> goToNextPage
   *   - LTR:  normal mapping
   */
  public turnPage(direction: TurnDirection): boolean {
    if (!this.host.isReady) {
      return false;
    }
    SelectionGestureHandler.reset();

    const isRtl: boolean = this.host.publication?.pageProgressionDirection === 'rtl';
    let effectiveDirection: TurnDirection = direction;
    if (isRtl) {
      effectiveDirection = (direction === TurnDirection.FORWARD)
        ? TurnDirection.BACKWARD
        : TurnDirection.FORWARD;
    }

    if (effectiveDirection === TurnDirection.FORWARD) {
      return this.goToNextPage();
    }
    return this.goToPreviousPage();
  }

  /**
   * Peek the page that turnPage(direction) would navigate to, WITHOUT changing
   * the current page. Applies the same RTL mapping as turnPage().
   * @param direction turn direction (visual)
   */
  public peekPage(direction: TurnDirection): PageSlot | undefined {
    const isRtl: boolean = this.host.publication?.pageProgressionDirection === 'rtl';
    let effectiveDirection: TurnDirection = direction;
    if (isRtl) {
      effectiveDirection = (direction === TurnDirection.FORWARD)
        ? TurnDirection.BACKWARD
        : TurnDirection.FORWARD;
    }
    const offset: number = effectiveDirection === TurnDirection.FORWARD ? 1 : -1;
    return this.getPageByOffset(offset);
  }

  /**
   * Go to specific page
   */
  public goToPage(pageIndex: number): boolean {
    if (!this.host.isReady || this.host.publication === undefined) {
      return false;
    }
    if (pageIndex >= 0 && pageIndex < this.pageSlots.length) {
      this.currentGlobalPage = pageIndex;
      const slot: PageSlot = this.pageSlots[pageIndex];
      this.commitNavigation(slot.chunkIndex);
      return true;
    }
    return false;
  }

  /**
   * Go to specific chapter (navigate to first page of that chapter)
   */
  public goToChapter(chapterIndex: number): boolean {
    if (!this.host.isReady || this.host.publication === undefined) {
      return false;
    }
    const pages: number[] | undefined = this.chunkToPages.get(chapterIndex);
    if (pages !== undefined && pages.length > 0) {
      // pages[] 存的是 0-based 页槽索引，pages[0] 即该章第一页
      this.currentGlobalPage = pages[0];
      this.commitNavigation(chapterIndex);
      return true;
    }
    return false;
  }

  /**
   * Go to progress position (0.0 to 1.0)
   * Phase 24 (Issue B)：进度空间从「pageSlots.length（物化缓存）」改为
   * 「documentTotalPages（文档空间）」。目标页先映射到 (章, 章内页)，再落到页槽；
   * 目标章未物化时按既有 P0-C 语义异步布局（commitNavigation → P0_USER_JUMP 入队）。
   */
  public goToProgress(progress: number): boolean {
    if (!this.host.isReady || this.host.publication === undefined) {
      return false;
    }
    const pcs: PaginatedChapter[] = this.pipelineManager.paginatedChapters;
    if (pcs.length === 0) {
      return false;
    }
    const docTotal: number = this.getDocumentTotalPages();
    if (docTotal <= 0) {
      return false;
    }
    const targetDocPage: number = Math.max(0, Math.min(
      Math.floor(progress * docTotal), docTotal - 1));
    // 文档页 → (章, 章内页序)：按真实/估算页数累计
    let acc: number = 0;
    let targetChunk: number = pcs.length - 1;
    let inChunk: number = 0;
    for (let ci: number = 0; ci < pcs.length; ci++) {
      const cnt: number = this.getChapterPageCount(ci);
      if (targetDocPage < acc + cnt) {
        targetChunk = ci;
        inChunk = targetDocPage - acc;
        break;
      }
      acc += cnt;
    }
    // 章内页序 → 页槽：已物化直接落点；未物化先落其 stub 页槽（异步布局后
    // rebuildPageSlots 的身份重映射会把当前页锚定到该章真实页）。
    const pages: number[] | undefined = this.chunkToPages.get(targetChunk);
    if (pages !== undefined && pages.length > 0) {
      const idx: number = Math.min(inChunk, pages.length - 1);
      // 目标章仍是 stub（页槽数 1）且请求了章内第 inChunk 页：
      // 记录章内目标页序，异步布局 commit 后精确落点（而非章首）。
      const pc: PaginatedChapter | undefined = pcs[targetChunk];
      if (pages.length === 1 && idx === 0 && inChunk > 0 &&
        (pc === undefined || pc.isStub)) {
        this.setPendingNavInChunkPage(inChunk);
      }
      this.currentGlobalPage = pages[idx];
    } else {
      // 该章无页槽（异常态）：钳制到当前范围内
      if (this.pageSlots.length === 0) {
        return false;
      }
      this.currentGlobalPage = Math.min(this.currentGlobalPage, this.pageSlots.length - 1);
    }
    const slot: PageSlot | undefined = this.pageSlots[this.currentGlobalPage];
    if (slot !== undefined) {
      this.commitNavigation(slot.chunkIndex);
    } else {
      this.updateReadingPosition();
    }
    return true;
  }

  /**
   * Navigate to table-of-contents item (first href-match chapter)
   */
  public goToTocItem(item: TocItem): boolean {
    if (this.host.publication === undefined) {
      return false;
    }
    // href 可能带锚点（如 part0006.html#frag），去锚后与 spine 章节匹配
    const targetHref: string = (item.href ?? '').split('#')[0];
    if (targetHref.length === 0) {
      return false;
    }
    for (let i: number = 0; i < this.host.publication.getChapterCount(); i++) {
      const link: Link | undefined = this.host.publication.getChapterLink(i);
      const linkHref: string = link !== undefined ? (link.href ?? '').split('#')[0] : '';
      if (linkHref === targetHref) {
        const pages: number[] | undefined = this.chunkToPages.get(i);
        if (pages !== undefined && pages.length > 0) {
          // pages[] 存的是 0-based 页槽索引，pages[0] 即该章第一页
          this.currentGlobalPage = pages[0];
          this.commitNavigation(i);
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 同步确保「当前导航落点」是真实内容页（Phase 24 / Issue C 主修复）。
   *
   * 旧行为缺陷：仅当章未物化时才 relayout + rebuild。若后台队列已完成该章
   * 排版（paginatedChapters 已是真页）而 pageSlots 仍持有 stale stub 页槽
   * （pipeline 提交点只在「当前页=该章 stub」时重建），本方法会提前返回、
   * 不重建 → 用户翻进该章时停在空白 stub 页上，等待也不恢复。
   *
   * 新行为：
   *   1. 章未物化 → 同步 relayout（原语义不变）；
   *   2. 只要当前页槽仍是 stub（无论章是否已物化）→ 一律 rebuildPageSlots，
   *      保证导航落点为真实页；布局产物缺失（HTML 不可得）时记入
   *      layoutFailedChunks（FAILED 状态，最小状态表达）。
   *
   * @param chunkIndex 目标章节索引
   */
  private ensureChapterReady(chunkIndex: number): void {
    const pc = this.pipelineManager.paginatedChapters[chunkIndex];
    if (pc === undefined || pc.pages.length === 0 || pc.isStub) {
      this.pipelineManager.relayoutSingleChunk(chunkIndex);
      const after: PaginatedChapter | undefined =
        this.pipelineManager.paginatedChapters[chunkIndex];
      if (after === undefined || after.pages.length === 0 || after.isStub) {
        // FAILED：章节内容不可得（provider 缺失/空 HTML），标记避免静默空白
        this.layoutFailedChunks.add(chunkIndex);
        hilog.warn(0x0000, 'OhEngine',
          'LAYOUT_FAILED ch=%{public}d reason=no-content', chunkIndex);
      } else {
        this.layoutFailedChunks.delete(chunkIndex);
      }
    }
    // Issue C：stale stub 页槽必须重建（即使章早已物化）——
    // 禁止空 stub 页进入用户可见区域等待「后台碰巧刷新」。
    const slot: PageSlot | undefined = this.pageSlots[this.currentGlobalPage];
    if (slot !== undefined && slot.state === 'stub') {
      this.rebuildPageSlots();
    }
  }

  /** Phase 24 最小状态表达：该章是否处于 LOADING（已入队等待 commit） */
  public isChunkLoading(chunkIndex: number): boolean {
    return this.pendingNavChunk === chunkIndex && chunkIndex >= 0;
  }

  /** Phase 24 最小状态表达：该章是否 FAILED（内容不可得，布局失败） */
  public isChunkLayoutFailed(chunkIndex: number): boolean {
    return this.layoutFailedChunks.has(chunkIndex);
  }

  /**
   * P0-C: 立即把导航目标写入「导航态」（currentGlobalPage + 持久化计划），
   * 与目标页就绪（Render/Data State）解耦。若目标为 stub：
   *   - 章已物化（stale 页槽）→ 同步重建（无空白闪现，Phase 24 / Issue C）；
   *   - 章未物化 → 异步 P0_USER_JUMP 入队（Latest-Jump-Wins 由 unshift 保证），
   *     并标记 LOADING（pendingNavChunk，最小状态表达）。
   */
  private commitNavigation(targetChunkIndex: number): void {
    this.navigationSerial++;
    if (targetChunkIndex >= 0) {
      const slot: PageSlot | undefined = this.pageSlots[this.currentGlobalPage];
      if (slot !== undefined && slot.state === 'stub') {
        const pc: PaginatedChapter | undefined =
          this.pipelineManager.paginatedChapters[targetChunkIndex];
        if (pc !== undefined && !pc.isStub && pc.pages.length > 0) {
          // 页槽 stale 但章已物化：同步重建即可见真实内容，禁止异步空白等待
          this.rebuildPageSlots();
        } else {
          this.pendingNavChunk = targetChunkIndex;
          this.pipelineManager.queueChunkLayout(targetChunkIndex, LayoutPriority.P0_USER_JUMP);
        }
      }
    }
    this.updateReadingPosition();
  }

  /** 记录异步导航的章内目标页序（目标章未物化时，commit 后精确落点用） */
  public setPendingNavInChunkPage(inChunkPage: number): void {
    this.pendingNavInChunkPage = inChunkPage;
  }

  /**
   * Navigate to next page
   */
  private goToNextPage(): boolean {
    // 守卫放宽：无 publication（如 PDF 文本提取书）但有页槽时允许翻页；
    // EPUB 等有 publication 的书籍行为不变。
    if (!this.host.isReady || (this.host.publication === undefined && this.pageSlots.length === 0)) {
      return false;
    }
    this.pipelineManager.readingDirection = 1;
    if (this.currentGlobalPage + 1 < this.pageSlots.length) {
      this.currentGlobalPage++;
      const slot: PageSlot = this.pageSlots[this.currentGlobalPage];
      if (slot.state === 'stub') {
        // 同步布局，避免 stub 占位闪现
        this.ensureChapterReady(slot.chunkIndex);
      }
      // reading speed learning (Phase 7)
      const now: number = Date.now();
      if (this.lastPageTurnTime > 0) {
        const dt: number = now - this.lastPageTurnTime;
        if (dt > 100) {
          const instantSpeed: number = Math.max(1, this.lastPageChars / (dt / 1000));
          this.pipelineManager.readingSpeed = this.pipelineManager.readingSpeed * 0.7 + instantSpeed * 0.3;
        }
      }
      this.lastPageTurnTime = now;
      if (this.currentGlobalPage < this.pageSlots.length) {
        const s: PageSlot = this.pageSlots[this.currentGlobalPage];
        this.lastPageChars = (s.charRange[1] - s.charRange[0]) || 1;
      }
      this.updateReadingPosition();
      // preload next 3 chapters after turn（Phase 20.1：stub 相邻章也入队预分页）
      const curChunk: number = slot.chunkIndex;
      for (let n: number = 1; n <= 3; n++) {
        const preloadIdx: number = curChunk + n;
        if (preloadIdx < this.pipelineManager.paginatedChapters.length &&
            this.pipelineManager.paginatedChapters[preloadIdx] !== undefined) {
          this.pipelineManager.queueChunkLayout(preloadIdx, 'low');
        }
      }
      return true;
    }
    return false;
  }

  /**
   * Navigate to previous page
   */
  private goToPreviousPage(): boolean {
    // 守卫放宽：无 publication（如 PDF 文本提取书）但有页槽时允许翻页
    if (!this.host.isReady || (this.host.publication === undefined && this.pageSlots.length === 0)) {
      return false;
    }
    this.pipelineManager.readingDirection = -1;
    if (this.currentGlobalPage > 0) {
      this.currentGlobalPage--;
      const slot: PageSlot = this.pageSlots[this.currentGlobalPage];
      if (slot.state === 'stub') {
        // 同步布局，避免 stub 占位闪现
        this.ensureChapterReady(slot.chunkIndex);
      }
      const now: number = Date.now();
      if (this.lastPageTurnTime > 0) {
        const dt: number = now - this.lastPageTurnTime;
        if (dt > 100) {
          const instantSpeed: number = Math.max(1, this.lastPageChars / (dt / 1000));
          this.pipelineManager.readingSpeed = this.pipelineManager.readingSpeed * 0.7 + instantSpeed * 0.3;
        }
      }
      this.lastPageTurnTime = now;
      if (this.currentGlobalPage < this.pageSlots.length) {
        const s: PageSlot = this.pageSlots[this.currentGlobalPage];
        this.lastPageChars = (s.charRange[1] - s.charRange[0]) || 1;
      }
      this.updateReadingPosition();
      const curChunk: number = slot.chunkIndex;
      for (let n: number = 1; n <= 3; n++) {
        const preloadIdx: number = curChunk - n;
        if (preloadIdx >= 0 && preloadIdx < this.pipelineManager.paginatedChapters.length &&
            this.pipelineManager.paginatedChapters[preloadIdx] !== undefined) {
          this.pipelineManager.queueChunkLayout(preloadIdx, 'low');
        }
      }
      return true;
    }
    return false;
  }

  /**
   * Compute current character offset within the book from the current page
   */
  public computeCurrentCharIndex(): number {
    if (this.pageSlots.length === 0 || this.currentGlobalPage >= this.pageSlots.length) {
      return 0;
    }
    const slot: PageSlot = this.pageSlots[this.currentGlobalPage];
    if (slot.state === 'ready') {
      return slot.charRange[0];
    }
    // For stub pages, estimate from previous layouted content
    let cumChars: number = 0;
    for (let i: number = 0; i < this.currentGlobalPage && i < this.pageSlots.length; i++) {
      const ps: PageSlot = this.pageSlots[i];
      cumChars += (ps.charRange[1] - ps.charRange[0]);
    }
    return cumChars;
  }

  /**
   * 当前页在文档空间中的页序（0-based）：前面各章页数（真实/估算）之和 + 章内页序。
   * Phase 24：阅读历史 progress 的稳定分母/分子（不再随物化推进漂移）。
   */
  public getCurrentDocumentPageIndex(): number {
    const curChunk: number = this.getCurrentChapterIndex();
    let docPage: number = this.getCurrentPageIndex();
    for (let ci: number = 0; ci < curChunk; ci++) {
      docPage += this.getChapterPageCount(ci);
    }
    return docPage;
  }

  /**
   * Update reading position (call after every page navigation)
   */
  public updateReadingPosition(): void {
    this.currentCharIndex = this.computeCurrentCharIndex();
    this.host.epoch++;

    // Save reading position to history
    const readingHistory = this.host.getReadingHistory();
    if (readingHistory !== undefined && this.host.publication !== undefined) {
      const pub = this.host.publication;
      const bookId: string = getBookId(pub);
      // Phase 24 (Issue B)：进度分数改为文档空间（原分母 pageSlots.length 随
      // 后台物化漂移，同一页的 progress 会自行变化）。
      const docTotal: number = this.getDocumentTotalPages();
      const pos: number = docTotal > 1
        ? Math.max(0, Math.min(1, this.getCurrentDocumentPageIndex() / (docTotal - 1)))
        : 0;
      const recordPos: RecordPosition = {
        chapterIndex: this.getCurrentChapterIndex(),
        charOffset: this.currentCharIndex,
        progress: pos
      };
      readingHistory.recordPosition(bookId, recordPos);
    }

    // Debounced save (500ms)
    if (this.saveCacheTimer !== -1) {
      clearTimeout(this.saveCacheTimer);
    }
    this.saveCacheTimer = setTimeout(() => {
      this.saveProgress();
    }, 500);
  }

  // ==================== Bookmark / Annotation / Search Navigation ====================

  /**
   * Go to bookmark
   */
  public goToBookmark(bookmark: Bookmark): boolean {
    if (this.host.publication === undefined) {
      return false;
    }
    // Try chapter + char offset
    if (bookmark.chapterIndex >= 0 && bookmark.charOffset > 0) {
      return this.navigateToCharOffset(bookmark.chapterIndex, bookmark.charOffset);
    }
    // Fallback: try to find by chapterIndex / chapterHref
    if (bookmark.chapterIndex >= 0 && bookmark.chapterIndex < this.chunkToPages.size) {
      const pages: number[] | undefined = this.chunkToPages.get(bookmark.chapterIndex);
      if (pages !== undefined && pages.length > 0) {
        this.currentGlobalPage = pages[0];
        const slot: PageSlot = this.pageSlots[this.currentGlobalPage];
        if (slot.state === 'stub') {
          this.ensureChapterReady(slot.chunkIndex);
        }
        this.updateReadingPosition();
        return true;
      }
    }
    return false;
  }

  /**
   * Go to annotation position
   */
  public goToAnnotation(ann: Annotation): boolean {
    if (this.host.publication === undefined) {
      return false;
    }
    const cfi: string | undefined = ann.locator.cfi;
    if (cfi !== undefined && cfi.length > 0) {
      const cfiResult: boolean = this.navigateToCfi(cfi);
      if (cfiResult) {
        return true;
      }
    }
    const chapterIdx: number = ann.chapterIndex !== undefined ? ann.chapterIndex : -1;
    const charOff: number = ann.startCharOffset !== undefined ? ann.startCharOffset : 0;
    if (chapterIdx >= 0 && charOff > 0) {
      return this.navigateToCharOffset(chapterIdx, charOff);
    }
    if (charOff > 0) {
      return this.navigateToCharOffset(this.getCurrentChapterIndex(), charOff);
    }
    return false;
  }

  /**
   * Navigate to search result position
   */
  public navigateToSearchResult(result: SearchResult): boolean {
    if (this.host.publication === undefined) {
      return false;
    }
    const chapIdx: number = result.chapterIndex;
    if (chapIdx >= 0 && chapIdx < this.host.publication.getChapterCount()) {
      return this.navigateToCharOffset(chapIdx, result.charOffset);
    }
    return false;
  }

  /**
   * Navigate to character offset within a specific chapter
   */
  private navigateToCharOffset(chapterIndex: number, charOffset: number): boolean {
    if (this.host.publication === undefined) {
      return false;
    }
    // Ensure the chapter is layouted
    const chapterHtml: string | undefined = this.pipelineManager.getChapterHtml(chapterIndex);
    if (chapterHtml !== undefined) {
      this.pipelineManager.queueChunkLayout(chapterIndex, 'high');
    }
    // Compute approximate global page based on char offset
    let cumChars: number = 0;
    for (let i: number = 0; i < chapterIndex; i++) {
      if (i < this.chunkPlainTextLengths.length) {
        cumChars += this.chunkPlainTextLengths[i];
      }
    }
    const targetChar: number = cumChars + charOffset;
    let bestPage: number = 0;
    let bestDist: number = Number.MAX_VALUE;
    for (let i: number = 0; i < this.pageSlots.length; i++) {
      const ps: PageSlot = this.pageSlots[i];
      const dist: number = Math.abs(ps.charRange[1] + (ps.charRange[0] - ps.charRange[1]) / 2 - targetChar);
      if (dist < bestDist) {
        bestDist = dist;
        bestPage = i;
      }
    }
    this.currentGlobalPage = bestPage;
    this.updateReadingPosition();
    return true;
  }

  /**
   * Simple CFI navigation (approximation). Extracts chapter index at minimum.
   */
  private navigateToCfi(cfi: string): boolean {
    // CFI format: /6/4[chapter]!/4/2/1:0
    const chapterMatch: RegExpMatchArray | null = cfi.match(/\/6\/(\d+)/);
    if (chapterMatch !== null) {
      const chapterIdx: number = parseInt(chapterMatch[1], 10) - 1;
      // Estimate character offset from CFI par index
      const parMatch: RegExpMatchArray | null = cfi.match(/:\s*(\d+)/);
      if (parMatch !== null) {
        const charOffset: number = parseInt(parMatch[1], 10);
        return this.navigateToCharOffset(chapterIdx, charOffset);
      }
      return this.goToChapter(chapterIdx);
    }
    return false;
  }

  // ==================== Page Rebuild / Pagination ====================

  /**
   * Rebuild the pageSlots array from scratch by iterating all paginatedChapters
   *
   * Phase 24（page identity）：重建前记录当前页的稳定身份
   * (chunkIndex, 章内页序)，重建后按身份重映射 currentGlobalPage——
   * 全局下标随物化推进漂移，不再允许裸下标跨 rebuild 存活。
   * global index 自此只作为派生展示。
   */
  public rebuildPageSlots(): void {
    // 递增点 [1]（0.13 六入口唯一替换 pageSlots 的点；其余入口经本方法级联递增）
    this.pageGeneration++;
    // ── 页身份快照（重建前） ──
    let identityChunk: number = -1;
    let identityInChunk: number = -1;
    if (this.currentGlobalPage >= 0 && this.currentGlobalPage < this.pageSlots.length) {
      const oldSlot: PageSlot = this.pageSlots[this.currentGlobalPage];
      identityChunk = oldSlot.chunkIndex;
      let inChunk: number = 0;
      for (let i: number = 0; i < this.currentGlobalPage; i++) {
        if (this.pageSlots[i].chunkIndex === identityChunk) {
          inChunk++;
        }
      }
      identityInChunk = inChunk;
    }

    const newSlots: PageSlot[] = [];
    const newChunkToPages: Map<number, number[]> = new Map();
    let globalPage: number = 0;
    const paginatedChapters: PaginatedChapter[] = this.pipelineManager.paginatedChapters;

    for (let ci: number = 0; ci < paginatedChapters.length; ci++) {
      const pc: PaginatedChapter = paginatedChapters[ci];
      if (pc === undefined || pc === null) {
        continue;
      }
      // Get chapter href
      let chapterHref: string = '';
      if (this.host.publication !== undefined) {
        const link: Link | undefined = this.host.publication.getChapterLink(ci);
        if (link !== undefined) {
          chapterHref = link.href;
        }
      }
      const pagesInChunk: number[] = [];
      for (let pi: number = 0; pi < pc.pages.length; pi++) {
        const p: Page = pc.pages[pi];
        // Compute charRange from LineBox startCharOffset
        let startChar: number = 0;
        let endChar: number = 0;
        if (p.lines.length > 0) {
          startChar = p.lines[0].startCharOffset;
          const lastLine: LineBox = p.lines[p.lines.length - 1];
          endChar = lastLine.startCharOffset + lastLine.text.length;
        }
        // Phase 10: 页面就绪标注（stub=NOT_READY；含图真实页=LAYOUT_READY；
        // 纯文本真实页直接 RENDER_READY，无待解码资产）。
        let pageImgCount: number = 0;
        for (let li: number = 0; li < p.lines.length; li++) {
          const lsrc: string | undefined = p.lines[li].imageSrc;
          if (lsrc !== undefined && lsrc.length > 0) {
            pageImgCount++;
          }
        }
        const slot: PageSlot = {
          chunkIndex: ci,
          pageNumber: pi,
          charRange: [startChar, endChar],
          state: pc.isStub ? 'stub' : 'ready',
          lines: p.lines,
          href: chapterHref,
          epoch: this.host.epoch,
          globalIndex: globalPage,
          readyState: pc.isStub ? PageReadyState.NOT_READY
            : (pageImgCount === 0 ? PageReadyState.RENDER_READY : PageReadyState.LAYOUT_READY),
          generation: this.pageGeneration,
          imageCount: pageImgCount
        };
        newSlots.push(slot);
        pagesInChunk.push(globalPage);
        globalPage++;
      }
      newChunkToPages.set(ci, pagesInChunk);
    }

    this.pageSlots = newSlots;
    this.chunkToPages = newChunkToPages;
    // 估算缓存随页槽内容变化失效（密度因子/每页字符数重算）
    this.invalidatePageEstimates();

    // Recalculate total chars
    let tc: number = 0;
    for (let i: number = 0; i < this.chunkPlainTextLengths.length; i++) {
      tc += this.chunkPlainTextLengths[i];
    }
    this.totalCharCount = tc;

    // ── 页身份重映射（Phase 24）：优先章内同序页；章页数变化钳制到章尾；
    // 章页槽消失则锚定最近后续章起始；全书无页槽时回退首页。
    // 异步进度跳转（goToProgress）携带的章内目标页序优先于身份快照。 ──
    if (identityChunk >= 0) {
      const pages: number[] | undefined = newChunkToPages.get(identityChunk);
      if (pages !== undefined && pages.length > 0) {
        let idx: number = Math.max(0, Math.min(identityInChunk, pages.length - 1));
        if (this.pendingNavChunk === identityChunk && this.pendingNavInChunkPage >= 0) {
          idx = Math.max(0, Math.min(this.pendingNavInChunkPage, pages.length - 1));
          this.pendingNavInChunkPage = -1;
        }
        this.currentGlobalPage = pages[idx];
      } else {
        let fallback: number = -1;
        for (let ci: number = identityChunk + 1; ci < paginatedChapters.length; ci++) {
          const p2: number[] | undefined = newChunkToPages.get(ci);
          if (p2 !== undefined && p2.length > 0) {
            fallback = p2[0];
            break;
          }
        }
        this.currentGlobalPage = fallback >= 0
          ? fallback
          : Math.max(0, newSlots.length - 1);
      }
    } else if (this.currentGlobalPage >= this.pageSlots.length) {
      this.currentGlobalPage = Math.max(0, this.pageSlots.length - 1);
    }
    // 异步布局已 commit（页槽已更新）→ LOADING 状态解除
    if (this.pendingNavChunk >= 0 && !this.isCurrentSlotStub()) {
      this.pendingNavChunk = -1;
    }
  }

  /** 当前页槽是否仍为 stub（LOADING 解除判定用） */
  private isCurrentSlotStub(): boolean {
    const slot: PageSlot | undefined = this.getCurrentPage();
    return slot !== undefined && slot.state === 'stub';
  }

  /**
   * Estimate how many pages a chunk of given HTML length will produce
   */
  public estimatePagesPerChunk(htmlLength: number): number {
    const charsPerPage: number = 800;
    if (charsPerPage <= 0) {
      return 1;
    }
    // Rough estimate: ~20% of HTML is markup
    const textLength: number = Math.floor(htmlLength * 0.8);
    return Math.max(1, Math.ceil(textLength / charsPerPage));
  }

  /**
   * Append stub (placeholder) pages for a chunk that hasn't been layouted yet
   */
  private createStubLineBox(x: number, y: number, width: number, height: number,
    startCharOffset: number): LineBox {
    return {
      text: '',
      x: x,
      y: y,
      width: width,
      height: height,
      ascent: height * 0.8,
      descent: height * 0.2,
      isSoftBreak: false,
      imageSrc: undefined,
      estimatedLines: 1,
      charPositions: [],
      isLastLineOfParagraph: false,
      isCJK: false,
      effectiveOpacity: 1.0,
      startCharOffset: startCharOffset,
      charWidths: [],
      renderedY: y
    };
  }

  public appendStubPagesForChunk(chunkIndex: number): void {
    const paginatedChapters: PaginatedChapter[] = this.pipelineManager.paginatedChapters;
    const html: string | undefined = this.pipelineManager.getChapterHtml(chunkIndex);
    if (html === undefined) {
      return;
    }
    const estimatedPages: number = this.estimatePagesPerChunk(html.length);
    const pages: Page[] = [];
    // Rough char offset accumulator for the stub
    let cumCharOffset: number = 0;
    const stubLineHeight: number = ReadingMetrics.STUB_LINE_HEIGHT;
    for (let i: number = 0; i < estimatedPages; i++) {
      const stubLines: LineBox[] = [];
      const linesPerPage: number = Math.max(1, Math.floor(this.host.config.viewHeight / stubLineHeight));
      for (let li: number = 0; li < linesPerPage; li++) {
        const lineY: number = i * this.host.config.viewHeight + li * stubLineHeight;
        const lineBox: LineBox = this.createStubLineBox(
          0, lineY, this.host.config.viewWidth, stubLineHeight, cumCharOffset
        );
        stubLines.push(lineBox);
        cumCharOffset += 40; // ~40 chars per stub line
      }
      const page: Page = {
        index: i,
        lines: stubLines,
        startLineIndex: 0,
        endLineIndex: stubLines.length - 1,
        startPosition: i / Math.max(1, estimatedPages),
        endPosition: (i + 1) / Math.max(1, estimatedPages),
        hasPageBreakBefore: false,
        isEmpty: stubLines.length === 0,
        yOffset: i * this.host.config.viewHeight
      };
      pages.push(page);
    }
    let chapterHref: string = '';
    if (this.host.publication !== undefined) {
      const link: Link | undefined = this.host.publication.getChapterLink(chunkIndex);
      if (link !== undefined) {
        chapterHref = link.href;
      }
    }
    const stubChapter: PaginatedChapter = {
      href: chapterHref,
      pages: pages,
      totalPages: pages.length,
      totalLineCount: pages.reduce((acc: number, p: Page) => acc + p.lines.length, 0),
      isStub: true
    };
    // Use a setter or direct assignment — paginatedChapters is a property array
    if (chunkIndex < paginatedChapters.length) {
      paginatedChapters[chunkIndex] = stubChapter;
    } else {
      paginatedChapters.push(stubChapter);
    }
    this.rebuildPageSlots();
  }

  /**
   * Create a single-page PaginatedChapter for FXL (fixed-layout) content
   */
  public createFXLSinglePage(render: RenderNode[], href: string): PaginatedChapter {
    // Fixed-layout: render nodes placed absolutely, single page
    const lineBoxes: LineBox[] = [];
    for (let i: number = 0; i < render.length; i++) {
      const node: RenderNode = render[i];
      const box: BoxModel | undefined = node.boxModel;
      const lb: LineBox = {
        text: node.text ?? '',
        x: box !== undefined ? box.x : 0,
        y: box !== undefined ? box.y : 0,
        width: box !== undefined ? box.contentWidth : this.host.config.viewWidth,
        height: box !== undefined ? box.contentHeight : ReadingMetrics.STUB_LINE_HEIGHT,
        ascent: ReadingMetrics.STUB_FONT_SIZE * 0.8,
        descent: ReadingMetrics.STUB_FONT_SIZE * 0.2,
        isSoftBreak: false,
        imageSrc: undefined,
        estimatedLines: 1,
        charPositions: [],
        isLastLineOfParagraph: false,
        isCJK: false,
        effectiveOpacity: node.effectiveOpacity,
        startCharOffset: 0,
        charWidths: [],
        renderedY: box !== undefined ? box.y : 0
      };
      lineBoxes.push(lb);
    }
    const page: Page = {
      index: 0,
      lines: lineBoxes,
      startLineIndex: 0,
      endLineIndex: Math.max(0, lineBoxes.length - 1),
      startPosition: 0,
      endPosition: 1,
      hasPageBreakBefore: false,
      isEmpty: lineBoxes.length === 0,
      yOffset: 0
    };
    return {
      pages: [page],
      href: href,
      totalPages: 1,
      totalLineCount: lineBoxes.length,
      isStub: false
    };
  }

  // ==================== Reflow / Relayout ====================

  /**
   * Reflow from current page — re-layout the current chapter and ripple outward
   */
  public reflowFromCurrentPage(): void {
    if (this.host.publication === undefined) {
      return;
    }
    const curSlot: PageSlot | undefined = this.getCurrentPage();
    if (curSlot === undefined) {
      return;
    }
    const curChunk: number = curSlot.chunkIndex;
    // Reset pagination from current chunk onward
    this.pipelineManager.relayoutAllChapters(curChunk);
    this.rebuildPageSlots();
    // Try to restore position
    if (this.currentGlobalPage >= this.pageSlots.length) {
      this.currentGlobalPage = Math.max(0, this.pageSlots.length - 1);
    }
    this.updateReadingPosition();
  }

  /**
   * Relayout only the current page (lighter than full reflow) — re-layout current chunk
   */
  public relayoutCurrentPageOnly(): void {
    const curSlot: PageSlot | undefined = this.getCurrentPage();
    if (curSlot === undefined) {
      return;
    }
    const curChunk: number = curSlot.chunkIndex;
    this.pipelineManager.relayoutSingleChunk(curChunk);
    this.rebuildPageSlots();
    if (this.currentGlobalPage >= this.pageSlots.length) {
      this.currentGlobalPage = Math.max(0, this.pageSlots.length - 1);
    }
  }

  /**
   * 全量重排所有章节并尽量保持阅读位置。
   *
   * 用于字号/行距等全局排版参数变更：此类参数影响所有章节的行高与
   * 断行，仅重排当前章（reflowFromCurrentPage 从当前章起清分页）会在
   * 前文章节留下旧度量分页——绘制端按新度量推进行距时这些页面的
   * 内容会超出内容区。故必须从第 0 章起全量重排。
   *
   * 同步执行（layoutAllChaptersSync）：返回时全部章节已是新度量分页。
   * 不能用异步队列（queueChunkLayout）——异步期间当前页要么是空白
   * stub，要么残留旧分页；旧分页被绘制端用新字形渲染时必然出现
   * 「行重叠 / 超右边界 / 填不满」等错乱。页缓存签名已在调用方
   * 刷新并作废，因此同步路径必然实时重排而非命中旧缓存。
   *
   * 位置保持：先记录当前章 + 字符偏移，重建后按字符偏移回跳
   * （navigateToCharOffset 内部含 stub 兜底），失败则退化为页码钳制。
   */
  public reflowAllChapters(): void {
    if (this.host.publication === undefined) {
      return;
    }
    const curSlot: PageSlot | undefined = this.getCurrentPage();
    const curChunk: number = curSlot !== undefined ? curSlot.chunkIndex : 0;
    const charOffset: number = this.computeCurrentCharIndex();
    // 作废在途异步布局任务（ENG-005）：同步全量重排后会回写同一批章节，
    // 旧任务可能带旧度量/旧纪元数据，先作废避免后写覆盖新分页。
    this.pipelineManager.bumpLayoutEpoch();
    this.pipelineManager.layoutQueue = [];
    this.pipelineManager.isProcessing = false;
    this.pipelineManager.layoutAllChaptersSync(this.host.publication.getChapterCount());
    this.rebuildPageSlots();
    if (charOffset > 0 && this.navigateToCharOffset(curChunk, charOffset)) {
      return;
    }
    if (this.currentGlobalPage >= this.pageSlots.length) {
      this.currentGlobalPage = Math.max(0, this.pageSlots.length - 1);
    }
    this.updateReadingPosition();
  }

  // ==================== Text Preview ====================

  /**
   * Get a short plain-text preview from a page slot
   */
  public getTextPreview(slot: PageSlot): string {
    if (slot.state !== 'ready' || slot.lines === undefined || slot.lines.length === 0) {
      return '';
    }
    let text: string = '';
    const maxChars: number = 120;
    for (let i: number = 0; i < slot.lines.length; i++) {
      const line: LineBox = slot.lines[i];
      if (line.text !== undefined && line.text !== null) {
        text += line.text;
        if (text.length >= maxChars) {
          return text.substring(0, maxChars);
        }
      }
    }
    return text;
  }

  // ==================== Progress Methods ====================

  /**
   * Save reading progress to storage
   */
  public saveProgress(): void {
    // Phase 24（Issue A 加固）：ReadingState 是 L1 critical state，
    // 先落盘；阅读历史（preferences）写入失败不得阻断/跳过状态持久化。
    this.persistCurrentReadingState();
    const readingHistory = this.host.getReadingHistory();
    if (readingHistory !== undefined && this.host.publication !== undefined) {
      const pub = this.host.publication;
      const bookId: string = getBookId(pub);
      // Phase 24 (Issue B)：与 updateReadingPosition 一致，文档空间进度
      const docTotal: number = this.getDocumentTotalPages();
      const pos: number = docTotal > 1
        ? Math.max(0, Math.min(1, this.getCurrentDocumentPageIndex() / (docTotal - 1)))
        : 0;
      const recordPos: RecordPosition = {
        chapterIndex: this.getCurrentChapterIndex(),
        charOffset: this.currentCharIndex,
        progress: pos
      };
      try {
        readingHistory.recordPosition(bookId, recordPos);
        readingHistory.updateMeta(bookId, {
          bookTitle: pub.getTitle()
        });
      } catch (_e) {
        hilog.warn(0x0000, 'OhEngine', 'READING_HISTORY_SAVE_FAIL swallowed');
      }
    }
  }

  /**
   * Load reading progress from storage
   */
  public loadProgress(): ReadingProgress | undefined {
    const readingHistory = this.host.getReadingHistory();
    if (readingHistory !== undefined && this.host.publication !== undefined) {
      const pub = this.host.publication;
      const bookId: string = getBookId(pub);
      const record: ReadingRecord | undefined = readingHistory.getRecord(bookId);
      if (record !== undefined) {
        // Phase 24 (Issue B)：文档空间总页数
        const totalPages: number = Math.max(1, this.getDocumentTotalPages());
        return {
          pagesRead: Math.round(record.progress * totalPages),
          pagesTotal: totalPages,
          progression: record.progress,
          currentChapter: record.chapterIndex,
          currentPage: Math.round(record.progress * totalPages),
          totalChapters: pub.getChapterCount(),
          globalPage: Math.round(record.progress * totalPages)
        } as ReadingProgress;
      }
    }
    return undefined;
  }

  // ==================== Phase 1: ReadingAnchor / ReadingState (L1) ====================

  /**
   * 获取某章的段落文本列表（确定性，来自章节 HTML；首次计算后缓存）。
   * 退化为零段时返回 []（调用方按章起始处理）。
   */
  public getChapterParagraphs(chapterIndex: number): string[] {
    const cached: string[] | undefined = this.chapterParagraphs[chapterIndex];
    if (cached !== undefined) {
      return cached;
    }
    const html: string | undefined = this.pipelineManager.getChapterHtml(chapterIndex);
    const paragraphs: string[] = html !== undefined ? extractParagraphs(html) : [];
    if (paragraphs.length === 0) {
      // Phase 24（Issue A 根因修复）：provider 未命中/空章不落缓存——
      // 空数组一旦被缓存即为永久权威值，恢复流程触发的低章预填充会把
      // 全部 <当前章 的章节缓存投毒为 []，persist 链路从此静默跳过。
      // 不缓存则后续调用可重试（parse 文件就绪后即可成功）。
      hilog.warn(0x0000, 'OhEngine',
        'CHAPTER_PARAS_EMPTY ch=%{public}d htmlLoaded=%{public}s (not cached, retry allowed)',
        chapterIndex, html !== undefined ? '1' : '0');
      return paragraphs;
    }
    // Phase 24（Issue A 根因修复）：预填充用 undefined（未计算语义），禁止 []。
    // 旧实现 push([]) 会在高章请求时把全部低章索引预填充为空数组，
    // "cached !== undefined" 早退将其视为权威缓存 → 低章锚点构造永久失败。
    while (this.chapterParagraphs.length <= chapterIndex) {
      this.chapterParagraphs.push(undefined);
    }
    this.chapterParagraphs[chapterIndex] = paragraphs;
    // Phase 9.6 内存边界：TXT lazy 下该缓存随访问章节线性增长。
    // 超过上限时丢弃除当前章外的条目（确定性，可在 provider 重新计算）。
    if (this.chapterParagraphs.length > 64) {
      const keepIdx: number = chapterIndex;
      for (let i = 0; i < this.chapterParagraphs.length; i++) {
        if (i !== keepIdx) {
          this.chapterParagraphs[i] = undefined;
        }
      }
    }
    return paragraphs;
  }

  /** 获取某章的段落起始偏移数组 */
  public getChapterParagraphStarts(chapterIndex: number): number[] {
    const cached: number[] | undefined = this.chapterParagraphStarts[chapterIndex];
    if (cached !== undefined) {
      return cached;
    }
    const paragraphs: string[] = this.getChapterParagraphs(chapterIndex);
    // Phase 24（Issue A 根因修复）：段落为空（未就绪/未命中）不落缓存，
    // 与 getChapterParagraphs 保持同一「空结果可重试」语义。
    if (paragraphs.length === 0) {
      return computeParagraphStarts(paragraphs);
    }
    const starts: number[] = computeParagraphStarts(paragraphs);
    // Phase 24（Issue A 根因修复）：预填充用 undefined，禁止 []（防止低章索引
    // 被空数组预填充后经 "cached !== undefined" 早退误判为已计算）。
    while (this.chapterParagraphStarts.length <= chapterIndex) {
      this.chapterParagraphStarts.push(undefined);
    }
    this.chapterParagraphStarts[chapterIndex] = starts;
    return starts;
  }

  /**
   * 章节稳定 ID：优先 spine href（EPUB），回退 'chapter-N'（TXT 语义）。
   */
  public getChapterId(chapterIndex: number): string {
    if (this.host.publication !== undefined) {
      const link: Link | undefined = this.host.publication.getChapterLink(chapterIndex);
      if (link !== undefined && link.href !== undefined && link.href.length > 0) {
        return link.href;
      }
    }
    return 'chapter-' + chapterIndex;
  }

  /**
   * 由章节 ID 解析章节索引；找不到返回 -1。
   */
  public resolveChapterId(chapterId: string): number {
    if (this.host.publication !== undefined) {
      const count: number = this.host.publication.getChapterCount();
      for (let i: number = 0; i < count; i++) {
        const link: Link | undefined = this.host.publication.getChapterLink(i);
        if (link !== undefined && link.href === chapterId) {
          return i;
        }
      }
    }
    // vchapter_XXXXX（Phase 8 D2）——顺序即 vchapter 全局序
    if (chapterId.startsWith('vchapter_')) {
      const num: number = parseInt(chapterId.substring('vchapter_'.length), 10);
      if (!isNaN(num) && num >= 0) {
        return num;
      }
    }
    // TXT 旧格式 'chapter-N'（Phase 8 D2 迁移：映射到该旧章的首个 vchapter）
    if (chapterId.startsWith('chapter-') || chapterId.startsWith('page-')) {
      const prefix: string = chapterId.startsWith('vchapter_') ? '' :
        chapterId.startsWith('page-') ? 'page-' : 'chapter-';
      const num: number = parseInt(chapterId.substring(prefix.length), 10);
      if (!isNaN(num) && num >= 1) {
        const oldIdx: number = num - 1;
        if (oldIdx < this.oldChapterToVchapterStart.length &&
          this.oldChapterToVchapterStart.length > 0) {
          const start: number = this.oldChapterToVchapterStart[oldIdx];
          if (start >= 0) {
            return start;
          }
        }
        // 未建立映射（非 TXT vchapter 场景）：退化为旧章序直接解析
        return oldIdx;
      }
    }
    return -1;
  }

  /**
   * 从当前页构造 ReadingAnchor。
   *
   * 用当前页首行文本在段落列表里做确定性定位（段落文本即章节 HTML
   * 的 stripped 文本块，页面首行是同一来源的子串），得出 paragraphIndex
   * 与 paragraph-relative charOffset。若页面无文本（图片页/空页）则回退到
   * 用一个可解释的锚点：章起始（paragraphIndex 0 + charOffset 0）。
   */
  public buildCurrentAnchor(): ReadingAnchor | undefined {
    const slot: PageSlot | undefined = this.getCurrentPage();
    if (slot === undefined) {
      hilog.warn(0x0000, 'OhEngine',
        'ANCHOR_FAIL cur=%{public}d slots=%{public}d', this.currentGlobalPage, this.pageSlots.length);
      return undefined;
    }
    const chapterIndex: number = slot.chunkIndex;
    const paragraphs: string[] = this.getChapterParagraphs(chapterIndex);
    if (paragraphs.length === 0) {
      hilog.warn(0x0000, 'OhEngine',
        'ANCHOR_FAIL_NO_PARAS ch=%{public}d cur=%{public}d slotState=%{public}s lines=%{public}d',
        chapterIndex, this.currentGlobalPage, slot.state,
        slot.lines !== undefined ? slot.lines.length : -1);
      return undefined;
    }
    // 页面首行文本 → 段落定位
    let firstLineText: string = '';
    for (let i: number = 0; i < slot.lines.length; i++) {
      const t: string = slot.lines[i].text;
      if (t !== undefined && t.length > 0) {
        firstLineText = t;
        break;
      }
    }
    const trimmed: string = firstLineText.trim();
    if (trimmed.length > 0) {
      const frag: string = trimmed.substring(0, Math.min(trimmed.length, PAGE_FRAGMENT_CHARS));
      for (let pi: number = 0; pi < paragraphs.length; pi++) {
        const idx: number = paragraphs[pi].indexOf(frag);
        if (idx >= 0) {
          const chapterId: string = this.getChapterId(chapterIndex);
          return {
            chapterId: chapterId,
            paragraphIndex: pi,
            paragraphHash: hashParagraphText(paragraphs[pi]),
            charOffset: idx
          } as ReadingAnchor;
        }
      }
    }
    // 回退：章起始（不 crash、不静默错位——恢复端再按 hash 校验）
    const chapterId0: string = this.getChapterId(chapterIndex);
    const fbHash: string = hashParagraphText(paragraphs[0]);
    const fallbackFrag: string = trimmed.substring(0, Math.min(trimmed.length, 12));
    hilog.info(0x0000, 'OhEngine',
      'ANCHOR_FALLBACK ch=%{public}d chid=%{public}s frag=%{public}s fh=%{public}s para0Hash=%{public}s',
      chapterIndex, chapterId0, fallbackFrag,
      trimmed.length > 0 ? hashParagraphText(trimmed) : '0', fbHash);
    return {
      chapterId: chapterId0,
      paragraphIndex: 0,
      paragraphHash: fbHash,
      charOffset: 0
    } as ReadingAnchor;
  }

  /**
   * 构造当前 ReadingState（含 schemaVersion/bookId/anchor/visualPageIndex/
   * layoutSignature/lastReadTime/contentFingerprint）。
   */
  public buildCurrentReadingState(): ReadingState | undefined {
    const anchor: ReadingAnchor | undefined = this.buildCurrentAnchor();
    if (anchor === undefined) {
      return undefined;
    }
    const pub = this.host.publication;
    if (pub === undefined) {
      return undefined;
    }
    const chapterIndex: number = this.getCurrentChapterIndex();
    return {
      schemaVersion: READING_STATE_SCHEMA_VERSION,
      bookId: getBookId(pub),
      chapterId: this.getChapterId(chapterIndex),
      anchor: anchor,
      visualPageIndex: this.currentGlobalPage,
      layoutSignature: this.host.getLayoutSignature(),
      lastReadTime: Date.now(),
      contentFingerprint: this.host.getContentFingerprint()
    } as ReadingState;
  }

  /**
   * 持久化当前 ReadingState（由 saveProgress 的 debounce 调用）。
   * Phase 24（恢复守卫）：restoreReadingState 触发的 updateReadingPosition
   * 会在 500ms 后回写磁盘——若本次恢复是降级结果（章首/首页/错页），
   * 会覆盖掉原本更好的保存状态并随打开次数单调恶化（退化棘轮）。
   * 守卫窗口内的 persist 一律跳过：磁盘上保留的是用户最后一次真实阅读位置。
   */
  public persistCurrentReadingState(): void {
    if (Date.now() < this.persistGuardUntil) {
      hilog.info(0x0000, 'OhEngine', 'READING_STATE_PRESERVE skip-persist restore-guard');
      return;
    }
    const state: ReadingState | undefined = this.buildCurrentReadingState();
    if (state !== undefined) {
      this.host.saveReadingState(state);
      hilog.info(0x0000, 'OhEngine',
        'READING_STATE_SAVE chid=%{public}s anchChid=%{public}s slotCh=%{public}d para=%{public}d off=%{public}d visual=%{public}d',
        state.chapterId, state.anchor.chapterId, this.getCurrentChapterIndex(),
        state.anchor.paragraphIndex, state.anchor.charOffset, state.visualPageIndex);
    } else {
      hilog.warn(0x0000, 'OhEngine', 'READING_STATE_SAVE_SKIP reason=no-anchor');
    }
  }

  /**
   * 从 ReadingState 恢复位置（页面级定位，非 pageIndex-only）。
   *
   * 流程：schemaVersion 校验 → contentFingerprint 校验 → chapter 解析 →
   * paragraphIndex 定位 → paragraphHash 验证 → 邻域搜索 → charOffset clamp →
   * 用章节内 charOffset 做页面定位。全部失败则回退章起始，不 crash。
   *
   * @param state 持久化的阅读状态
   * @returns 是否成功定位（false 表示已回退或不可恢复）
   */
  public restoreReadingState(state: ReadingState | null): boolean {
    if (state === null) {
      return false;
    }
    if (this.host.publication === undefined) {
      return false;
    }
    // Phase 24（恢复守卫）：恢复流程内部会触发 updateReadingPosition →
    // 防抖 persist。守卫窗口 +2s 内禁止回写，保证「恢复失败或降级不覆盖
    // 原始 ReadingState」；窗口自愈，不影响用户后续正常翻页的保存。
    this.persistGuardUntil = Date.now() + 2000;
    if (state.schemaVersion !== READING_STATE_SCHEMA_VERSION) {
      hilog.info(0x0000, 'OhEngine',
        'READING_RESTORE_FAIL_REASON cat=SCHEMA saved=%{public}d current=%{public}d',
        state.schemaVersion, READING_STATE_SCHEMA_VERSION);
      return false;
    }
    // contentFingerprint 变化 → ReadingState 失效，安全回退（不开书/不跳页）
    const currentFp: string = this.host.getContentFingerprint();
    if (state.contentFingerprint.length > 0 && currentFp.length > 0 &&
      state.contentFingerprint !== currentFp) {
      hilog.info(0x0000, 'OhEngine',
        'READING_RESTORE_FAIL_REASON cat=FINGERPRINT saved=%{public}s current=%{public}s',
        state.contentFingerprint, currentFp);
      return false;
    }
    // chapter 解析
    let chapterIndex: number = this.resolveChapterId(state.anchor.chapterId);
    if (chapterIndex < 0) {
      // 兜底：visualPageIndex 仅为派生态，这里不适用；回退首章
      hilog.info(0x0000, 'OhEngine',
        'READING_RESTORE_FAIL_REASON cat=CHAPTER_RESOLVE saved=%{public}s resolved=-1',
        state.anchor.chapterId);
      chapterIndex = 0;
    }
    const paragraphs: string[] = this.getChapterParagraphs(chapterIndex);
    if (paragraphs.length === 0) {
      hilog.info(0x0000, 'OhEngine',
        'READING_RESTORE_FAIL_REASON cat=PARAGRAPHS saved=%{public}s resolved=%{public}d',
        state.anchor.chapterId, chapterIndex);
      return this.goToChapter(chapterIndex);
    }
    // paragraphIndex 定位 + hash 验证
    let targetParagraph: number = -1;
    const anchorPara: number = state.anchor.paragraphIndex;
    if (anchorPara >= 0 && anchorPara < paragraphs.length &&
      hashParagraphText(paragraphs[anchorPara]) === state.anchor.paragraphHash) {
      targetParagraph = anchorPara;
    } else {
      // 邻域搜索：±PARAGRAPH_SEARCH_WINDOW 内找最近且 hash 匹配的候选
      let bestDist: number = Number.MAX_VALUE;
      let bestIndex: number = -1;
      for (let d: number = 1; d <= PARAGRAPH_SEARCH_WINDOW; d++) {
        const hi: number = anchorPara + d;
        const lo: number = anchorPara - d;
        if (hi < paragraphs.length && hashParagraphText(paragraphs[hi]) === state.anchor.paragraphHash) {
          if (d < bestDist) {
            bestDist = d;
            bestIndex = hi;
          }
        }
        if (lo >= 0 && hashParagraphText(paragraphs[lo]) === state.anchor.paragraphHash) {
          if (d < bestDist) {
            bestDist = d;
            bestIndex = lo;
          }
        }
      }
      targetParagraph = bestIndex;
    }
    if (targetParagraph < 0) {
      // 找不到匹配段落 → 回退章起始
      hilog.info(0x0000, 'OhEngine',
        'READING_RESTORE_FAIL_REASON cat=PARAGRAPH_HASH saved=%{public}s para=%{public}d',
        state.anchor.chapterId, state.anchor.paragraphIndex);
      return this.goToChapter(chapterIndex);
    }
    // charOffset clamp 到合法范围
    const clamped: number = clampParagraphCharOffset(state.anchor.charOffset, paragraphs[targetParagraph]);
    // Phase 22: 保存的视觉页（visualPageIndex）作为恢复提示（schema 已有字段，零协议改动）
    const pageFound: boolean = this.navigateToChapterCharOffset(chapterIndex, targetParagraph, clamped,
      state.visualPageIndex);
    hilog.info(0x0000, 'OhEngine',
      'READING_RESTORE_PAGE_RESOLVE savedCh=%{public}s resolvedCh=%{public}d savedPara=%{public}d savedOffset=%{public}d visual=%{public}d result=%{public}d page=%{public}d',
      state.anchor.chapterId, chapterIndex, state.anchor.paragraphIndex, state.anchor.charOffset,
      state.visualPageIndex, pageFound ? 1 : 0, this.currentGlobalPage);
    if (!pageFound) {
      hilog.info(0x0000, 'OhEngine',
        'READING_RESTORE_FAIL_REASON cat=NAVIGATE saved=%{public}s resolved=%{public}d para=%{public}d',
        state.anchor.chapterId, chapterIndex, targetParagraph);
      return this.goToChapter(chapterIndex);
    }
    this.updateReadingPosition();
    return true;
  }

  /**
   * 在指定章节内，按「段落文本片段」定位页面（页面级定位）。
   *
   * 用段落中 charOffset 起的一段文本作为片段，在全书页的行文本里搜索——
   * 行文本与段落文本同源（章节 HTML），命中页面即该段落附近页；找不到时
   * 退回按 charRange 中点近似选择。这是近似定位（spec 允许 nearby page），
   * 不依赖 layoutSignature，缓存命中/实时排版一致。
   */
  private navigateToChapterCharOffset(chapterIndex: number, targetParagraph: number,
    clampedCharOffset: number, hintGlobalPage: number = -1): boolean {
    const pages: number[] | undefined = this.chunkToPages.get(chapterIndex);
    if (pages === undefined || pages.length === 0) {
      return false;
    }
    const paragraphs: string[] = this.getChapterParagraphs(chapterIndex);
    if (targetParagraph < 0 || targetParagraph >= paragraphs.length) {
      return false;
    }
    // Phase 24（恢复优先级倒转）：语义锚（段落 + charOffset 片段）为主恢复依据；
    // visualPageIndex 仅作片段搜索失败时的兜底提示。
    // 旧实现（Phase 22 Priority 1）把 stale 的全局视觉页提示放在片段搜索之前——
    // 该值来自上一次 session 的物化拓扑（热窗外全是 1 页 stub，全局页号已漂移），
    // 重开后钳制到错误页，且发生在 hash 校验已通过的情况下，直接破坏正确恢复。
    // 片段：优先取 charOffset 之后；段落末尾则取段落尾部片段
    const paraText: string = paragraphs[targetParagraph];
    const frag: string = this.buildSearchFragment(paraText, clampedCharOffset);
    const fragment: string = frag.trim();
    if (fragment.length > 0) {
      // 逐页累加文本并定位片段首次出现的页面
      for (let i: number = 0; i < pages.length; i++) {
        const slot: PageSlot = this.pageSlots[pages[i]];
        let pageText: string = '';
        for (let li: number = 0; li < slot.lines.length; li++) {
          const t: string = slot.lines[li].text;
          if (t !== undefined) {
            pageText += t;
          }
        }
        if (pageText.indexOf(fragment) >= 0) {
          this.currentGlobalPage = pages[i];
          return true;
        }
      }
    }
    // Phase 24（兜底）：片段未命中时才允许使用 visualPageIndex 提示——
    // 精确命中当前章页槽则采纳，否则取最近页（stale 值的误差被限制在本章内）。
    if (hintGlobalPage >= 0) {
      for (let i: number = 0; i < pages.length; i++) {
        if (pages[i] === hintGlobalPage) {
          this.currentGlobalPage = hintGlobalPage;
          return true;
        }
      }
      let bestIdx: number = -1;
      let bestD: number = Number.MAX_VALUE;
      for (let i: number = 0; i < pages.length; i++) {
        const d: number = Math.abs(pages[i] - hintGlobalPage);
        if (d < bestD) {
          bestD = d;
          bestIdx = i;
        }
      }
      if (bestIdx >= 0) {
        this.currentGlobalPage = pages[bestIdx];
        return true;
      }
    }
    // 兜底：最近 charRange 中点
    const chapterStart: number = this.getChapterGlobalCharStart(chapterIndex);
    const targetChar: number = chapterStart + this.getChapterParagraphStarts(chapterIndex)[targetParagraph] + clampedCharOffset;
    let bestPage: number = -1;
    let bestDist: number = Number.MAX_VALUE;
    for (let i: number = 0; i < pages.length; i++) {
      const slot: PageSlot = this.pageSlots[pages[i]];
      if (slot.state === 'stub') {
        continue;
      }
      if (slot.charRange === undefined || slot.charRange[1] === slot.charRange[0]) {
        continue;
      }
      const mid: number = chapterStart + (slot.charRange[0] + slot.charRange[1]) / 2;
      const dist: number = Math.abs(mid - targetChar);
      if (dist < bestDist) {
        bestDist = dist;
        bestPage = pages[i];
      }
    }
    if (bestPage < 0) {
      return false;
    }
    this.currentGlobalPage = bestPage;
    return true;
  }

  /** 构造搜索片段：charOffset 处起不超过 20 字符；段落末尾取尾部片段 */
  private buildSearchFragment(paraText: string, charOffset: number): string {
    const clamped: number = clampParagraphCharOffset(charOffset, paraText);
    const start: number = Math.min(clamped, Math.max(0, paraText.length - 20));
    return paraText.substring(start, Math.min(paraText.length, start + 20));
  }

  /** 章节在全书字符流中的起始偏移（累计 chunkPlainTextLengths） */
  private getChapterGlobalCharStart(chapterIndex: number): number {
    let acc: number = 0;
    for (let i: number = 0; i < chapterIndex && i < this.chunkPlainTextLengths.length; i++) {
      acc += this.chunkPlainTextLengths[i];
    }
    return acc;
  }

  /** 清空 L1 段落缓存（clearAll 时调用） */
  private clearParagraphCache(): void {
    this.chapterParagraphs = [];
    this.chapterParagraphStarts = [];
  }

  /**
   * Create bookmark from current position
   */
  public createBookmark(): Bookmark {
    let chapterIdx: number = this.getCurrentChapterIndex();
    const slot: PageSlot | undefined = this.getCurrentPage();
    if (slot !== undefined) {
      chapterIdx = slot.chunkIndex;
    }
    let chapterHref: string | undefined = undefined;
    if (this.host.publication !== undefined) {
      const link: Link | undefined = this.host.publication.getChapterLink(chapterIdx);
      if (link !== undefined) {
        chapterHref = link.href;
      }
    }
    const book: Bookmark = {
      id: 'bm_' + String(Date.now()) + '_' + String(chapterIdx),
      chapterIndex: chapterIdx,
      charOffset: this.currentCharIndex,
      chapterHref: chapterHref,
      createdAt: Date.now(),
      type: 'bookmark'
    };
    return book;
  }

  /**
   * Phase 24（Router 生命周期修复）：仅重置页导航状态，供 Router.render 使用。
   *
   * 旧行为：ReflowRouter/ImageRouter 调用 clearAll() —— 连带清空 open() 刚
   * 填充的 chunkPlainTextLengths / chunkPlainTexts / TXT vchapter 映射，导致：
   *   - 全书字符累计恒为 0（书签/标注/搜索全局定位失效）；
   *   - TXT 旧格式锚点 'chapter-N' 解析错章；
   *   - 恢复兜底路径 getChapterGlobalCharStart 失效。
   * Router 只有权重置「页槽导航态」，无权清理 engine 层全书索引。
   */
  public resetPageNavigationState(): void {
    this.pageSlots = [];
    this.currentGlobalPage = 0;
    this.chunkToPages = new Map();
    this.currentCharIndex = 0;
    this.lastPageTurnTime = 0;
    this.lastPageChars = 0;
    this.pendingNavChunk = -1;
    this.pendingNavInChunkPage = -1;
    this.layoutFailedChunks.clear();
    if (this.saveCacheTimer !== -1) {
      clearTimeout(this.saveCacheTimer);
      this.saveCacheTimer = -1;
    }
  }

  /**
   * Phase 24：重置 engine 层全书索引（open() 入口调用，替代对 router
   * clearAll 的隐式依赖）。换书重开时避免 push 追加到上一本的数组上。
   */
  public resetCharIndices(): void {
    this.chunkPlainTextLengths = [];
    this.chunkPlainTexts = [];
    this.oldChapterToVchapterStart = [];
    this.oldChapterVchapterCounts = [];
    this.chapterParagraphs = [];
    this.chapterParagraphStarts = [];
    this.totalCharCount = 0;
    this.currentCharIndex = 0;
    this.invalidatePageEstimates();
    // Phase 25：换书/重开时清空上一本的已缓存页数表（open 后按当前书重新装载）
    this.cachedChapterCounts = null;
  }

  /**
   * Clear all page state (called on destroy / reset)
   */
  public clearAll(): void {
    this.pageSlots = [];
    this.currentGlobalPage = 0;
    this.chunkToPages = new Map();
    this.currentCharIndex = 0;
    this.totalCharCount = 0;
    this.lastPageTurnTime = 0;
    this.lastPageChars = 0;
    this.pendingNavChunk = -1;
    this.pendingNavInChunkPage = -1;
    this.layoutFailedChunks.clear();
    this.chunkPlainTextLengths = [];
    this.chunkPlainTexts = [];
    this.oldChapterToVchapterStart = [];
    this.oldChapterVchapterCounts = [];
    if (this.saveCacheTimer !== -1) {
      clearTimeout(this.saveCacheTimer);
      this.saveCacheTimer = -1;
    }
    this.clearParagraphCache();
    // Phase 25：session 销毁清空已缓存页数表
    this.cachedChapterCounts = null;
  }

  /**
   * Create a stub (placeholder) page for a chunk
   *
   * Called by StrategyRouter implementations during initialisation.
   * Creates a PaginatedChapter with `pageCount` placeholder pages
   * and rebuilds the global page slot array.
   *
   * @param chunkIndex - chapter index
   * @param pageCount  - number of stub pages to create (typ. 1 per chapter)
   */
  public createStubPage(chunkIndex: number, pageCount: number): void {
    const stubChapter: PaginatedChapter = this.buildStubChapter(chunkIndex, pageCount);
    const paginatedChapters: PaginatedChapter[] = this.pipelineManager.paginatedChapters;
    if (chunkIndex < paginatedChapters.length) {
      paginatedChapters[chunkIndex] = stubChapter;
    } else {
      paginatedChapters.push(stubChapter);
    }
    this.rebuildPageSlots();
  }

  /**
   * P0-A: 批量创建全书 stub 章（只一次 rebuildPageSlots）。
   * 修复1：ReflowRouter 逐章 createStubPage → 每章一次全量 rebuild（O(章数²)）。
   * 修复2：stub 页从「全高 30 行」压为「1 行占位」——8703 章 × 30 行 = 261k
   * LineBox（≈100MB+ HEAP，触发 THREAD_BLOCK_6S/GC 冻结）；占位页无正文，
   * 渲染效果等效空白占位。真实页在分页/ensure 时替换 stub。
   */
  public createAllStubPages(totalChapters: number): void {
    const paginatedChapters: PaginatedChapter[] = this.pipelineManager.paginatedChapters;
    for (let ci: number = 0; ci < totalChapters; ci++) {
      const stubChapter: PaginatedChapter = this.buildCompactStubChapter(ci);
      if (ci < paginatedChapters.length) {
        paginatedChapters[ci] = stubChapter;
      } else {
        paginatedChapters.push(stubChapter);
      }
    }
    this.rebuildPageSlots();
  }

  /** 极小占位章：1 页 × 1 行空行（内存 O(1)，视觉等价空白占位） */
  private buildCompactStubChapter(chunkIndex: number): PaginatedChapter {
    let chapterHref: string = '';
    if (this.host.publication !== undefined) {
      const link: Link | undefined = this.host.publication.getChapterLink(chunkIndex);
      if (link !== undefined) {
        chapterHref = link.href;
      }
    }
    const stubLine: LineBox = this.createStubLineBox(
      0, 0, this.host.config.viewWidth, ReadingMetrics.STUB_LINE_HEIGHT, 0);
    return {
      href: chapterHref,
      pages: [{
        index: 0,
        lines: [stubLine],
        startLineIndex: 0,
        endLineIndex: 0,
        startPosition: 0,
        endPosition: 1,
        hasPageBreakBefore: false,
        isEmpty: false,
        yOffset: 0
      }],
      totalPages: 1,
      totalLineCount: 1,
      isStub: true
    };
  }

  /** 构造单章 stub PaginatedChapter（不写回 paginatedChapters，不 rebuild） */
  private buildStubChapter(chunkIndex: number, pageCount: number): PaginatedChapter {
    // Resolve chapter href
    let chapterHref: string = '';
    if (this.host.publication !== undefined) {
      const link: Link | undefined = this.host.publication.getChapterLink(chunkIndex);
      if (link !== undefined) {
        chapterHref = link.href;
      }
    }

    const stubLineHeight: number = ReadingMetrics.STUB_LINE_HEIGHT;
    const pages: Page[] = [];
    let cumCharOffset: number = 0;

    for (let i: number = 0; i < pageCount; i++) {
      const stubLines: LineBox[] = [];
      const linesPerPage: number = Math.max(1,
        Math.floor(this.host.config.viewHeight / stubLineHeight));
      for (let li: number = 0; li < linesPerPage; li++) {
        const lineY: number = i * this.host.config.viewHeight + li * stubLineHeight;
        const lineBox: LineBox = this.createStubLineBox(
          0, lineY, this.host.config.viewWidth, stubLineHeight, cumCharOffset
        );
        stubLines.push(lineBox);
        cumCharOffset += 40;
      }
      const page: Page = {
        index: i,
        lines: stubLines,
        startLineIndex: 0,
        endLineIndex: stubLines.length - 1,
        startPosition: i / Math.max(1, pageCount),
        endPosition: (i + 1) / Math.max(1, pageCount),
        hasPageBreakBefore: false,
        isEmpty: stubLines.length === 0,
        yOffset: i * this.host.config.viewHeight
      };
      pages.push(page);
    }

    return {
      href: chapterHref,
      pages: pages,
      totalPages: pages.length,
      totalLineCount: pages.reduce((acc: number, p: Page) => acc + p.lines.length, 0),
      isStub: true
    };
  }

  /**
   * 创建单页图片章（IMAGE 策略：CBZ/CBR 每图一章）。
   *
   * 产出非 stub 的 PaginatedChapter：单行 LineBox.imageSrc（行盒铺满视口），
   * 绘制层按 imageSrc 异步解码整页图（drawImageScaled contain 等比居中）。
   * isStub=false 表示章节已就绪——ensureChapterReady/重排路径不会把图片章
   * 当 stub 占位再排版（stub 页只有占位空行，无法承载图片）。
   *
   * @param chunkIndex - chapter index
   * @param imageSrc   - 图片绝对路径（CbzParser 产出 fullPath）
   */
  public createImagePage(chunkIndex: number, imageSrc: string): void {
    const paginatedChapters: PaginatedChapter[] = this.pipelineManager.paginatedChapters;
    const viewWidth: number = this.host.config.viewWidth;
    const viewHeight: number = this.host.config.viewHeight;
    const imageLine: LineBox = {
      text: '',
      x: 0,
      y: 0,
      width: viewWidth,
      height: viewHeight,
      ascent: viewHeight * 0.8,
      descent: viewHeight * 0.2,
      isSoftBreak: false,
      imageSrc: imageSrc,
      estimatedLines: 1,
      charPositions: [],
      isLastLineOfParagraph: true,
      isCJK: false,
      effectiveOpacity: 1.0,
      startCharOffset: 0,
      charWidths: [],
      renderedY: 0
    };
    const page: Page = {
      index: 0,
      lines: [imageLine],
      startLineIndex: 0,
      endLineIndex: 0,
      startPosition: 0,
      endPosition: 1,
      hasPageBreakBefore: false,
      isEmpty: false,
      yOffset: 0
    };
    const imageChapter: PaginatedChapter = {
      href: imageSrc,
      pages: [page],
      totalPages: 1,
      totalLineCount: 1,
      isStub: false
    };
    if (chunkIndex < paginatedChapters.length) {
      paginatedChapters[chunkIndex] = imageChapter;
    } else {
      paginatedChapters.push(imageChapter);
    }
    this.rebuildPageSlots();
  }
}
