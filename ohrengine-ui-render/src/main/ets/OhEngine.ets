/**
 * OhEngine — Public Facade for the Reading Engine
 *
 * Wraps OhEngineCore and provides a simplified API for external consumers
 * (UI layer, view models, etc.). Also imports FeatureManager from
 * ohrengine-common and registers core features on initialization.
 *
 * Usage:
 *   const engine = new OhEngine(pageManager, pipelineManager);
 *   await engine.open('/path/to/book.epub');
 *   engine.goToPage(5);
 */

import { OhEngineCore, OpenOptions, OpenTypographyOptions } from './OhEngineCore.ets';
import { TocItem, Annotation,
         EngineState, EngineConfig, LayoutProfile, Margins, PageSlot, TurnDirection,
         ChapterAnnotationGroup, ParameterBus } from 'ohrengine-common';
import type { LineBox } from 'ohrengine-common';
import type { Book, Publication } from 'ohrengine-common';
import { FeatureManager, AnnotationStorage, WordEntry, VocabularyItem } from 'ohrengine-feature';
import { Theme, FontTheme } from 'ohrengine-common';
import { PageManager } from './core/PageManager.ets';
import { PipelineManager } from './core/PipelineManager.ets';
import { ReflowRouter } from './router/ReflowRouter.ets';
import { ImageRouter } from './router/ImageRouter.ets';
import { MediaContext } from './style/MediaQueryEvaluator.ets';
import { StrategyRegistry } from 'ohrengine-common';
import type { FontRegistrar } from 'ohrengine-common';

export { OhEngineCore } from './OhEngineCore.ets';
export { PageManager } from './core/PageManager.ets';
export { PipelineManager } from './core/PipelineManager.ets';

export { Publication, TocItem, EngineState, EngineConfig, LayoutProfile,
         Margins, PageSlot, TurnDirection, ReadingProgress, ChapterAnnotationGroup } from 'ohrengine-common';
export type { Book } from 'ohrengine-common';

/**
 * OhEngine — the public API facade for the reading engine.
 * All public methods delegate to OhEngineCore.
 */
export class OhEngine {
  private readonly core: OhEngineCore;
  private readonly featureManager: FeatureManager = new FeatureManager();

  constructor(
    pageManager?: PageManager,
    pipelineManager?: PipelineManager
  ) {
    this.core = new OhEngineCore(pageManager, pipelineManager);
    // Auto-register default routers (needs constructed pageManager/pipelineManager)
    StrategyRegistry.register(new ReflowRouter(this.core.pageManager, this.core.pipelineManager));
    StrategyRegistry.register(new ImageRouter(this.core.pageManager, this.core.pipelineManager));
    FeatureManager.registerBuiltinFeatures();
  }

  // ==================== Lifecycle ====================

  getCore(): OhEngineCore {
    return this.core;
  }

  async open(bookBasePath: string, opts?: OpenOptions): Promise<Book | undefined> {
    return this.core.open(bookBasePath, opts);
  }

  destroy(): void {
    this.core.destroy();
  }

  getState(): EngineState {
    return this.core.getState();
  }

  // ==================== Configuration ====================

  configure(cfg: Partial<EngineConfig>): void {
    this.core.configure(cfg);
  }

  getLayoutProfile(): LayoutProfile {
    return this.core.getLayoutProfile();
  }

  setLayoutProfile(profile: Partial<LayoutProfile>): void {
    this.core.setLayoutProfile(profile);
  }

  getMargins(): Margins {
    return this.core.getMargins();
  }

  getPublication(): Publication | undefined {
    return this.core.getPublication();
  }

  getAnnotations(): Annotation[] {
    return this.core.getAnnotations();
  }

  syncAnnotations(annotations: Annotation[]): void {
    this.core.syncAnnotations(annotations);
  }

  // ==================== Navigation ====================

  getCurrentPage(): PageSlot | undefined {
    return this.core.getCurrentPage();
  }

  /**
   * 页槽代次只读访问（0.13/FR-011）：供翻页 B2 提交前快照校验。
   */
  getPageGeneration(): number {
    return this.core.getPageGeneration();
  }

  /**
   * 按全局页索引获取页面（用于图片预取等场景）
   */
  getPageByGlobalIndex(globalIndex: number): PageSlot | undefined {
    return this.core.getPageByGlobalIndex(globalIndex);
  }

  /**
   * 按相对偏移获取页面（不改变当前页，用于翻页预览）
   */
  getPageByOffset(offset: number): PageSlot | undefined {
    return this.core.getPageByOffset(offset);
  }

  /**
   * 预览 turnPage(direction) 将到达的页面（不改变当前页，带 RTL 映射）
   */
  peekPage(direction: TurnDirection): PageSlot | undefined {
    return this.core.peekPage(direction);
  }

  /**
   * Phase 10 诊断：单页就绪快照（供翻页动画入口日志 / 测试断言）。
   */
  describePage(slot: PageSlot): string {
    return this.core.describePage(slot);
  }

  /**
   * Phase 10 诊断：N-1/N/N+1 三页就绪快照（Benchmark B）。
   */
  describeNeighborWindow(): string {
    return this.core.describeNeighborWindow();
  }

  /**
   * Phase 10: 动画窗口 pin（L3 不逐出动画中章节）。
   */
  pinChapters(chunkIndexes: number[]): void {
    this.core.pinChapters(chunkIndexes);
  }

  /**
   * Phase 10: 动画窗口解除 pin。
   */
  unpinChapters(chunkIndexes: number[]): void {
    this.core.unpinChapters(chunkIndexes);
  }

  /**
   * Phase 11: open 前排版参数（must 在 open() 前调用；不触发 reflow/invalidate）。
   */
  prepareOpenTypography(opts: OpenTypographyOptions): void {
    this.core.prepareOpenTypography(opts);
  }

  /**
   * Phase 11: 首帧后启动后台增量 reflow（非热窗 stub 章 → P4_BACKGROUND）。
   */
  scheduleBackgroundReflow(): number {
    return this.core.scheduleBackgroundReflow();
  }

  /**
   * Phase 12: 置位/复位「用户动画进行中」（后台 reflow 据此推迟，避免污染动画帧）。
   */
  setUserAnimating(active: boolean): void {
    this.core.setUserAnimating(active);
  }

  /**
   * Phase 16.3: 按行恢复逐字几何（选择/批注惰性入口；per-line cache 写回行对象）。
   */
  ensureLineGeometry(line: LineBox): void {
    this.core.ensureLineGeometry(line);
  }

  /**
   * Phase 16.3: 当前页逐行恢复（选择交互入口）。
   */
  ensureCurrentPageGeometry(): void {
    this.core.ensureCurrentPageGeometry();
  }

  turnPage(direction: TurnDirection): boolean {
    return this.core.turnPage(direction);
  }

  goToPage(pageIndex: number): boolean {
    return this.core.goToPage(pageIndex);
  }

  goToChapter(chapterIndex: number): boolean {
    return this.core.goToChapter(chapterIndex);
  }

  goToProgress(progress: number): boolean {
    return this.core.goToProgress(progress);
  }

  getTotalPages(): number {
    return this.core.getTotalPages();
  }

  /** Phase 24 (Issue B)：已物化页数（诊断对照用） */
  getMaterializedPages(): number {
    return this.core.getMaterializedPages();
  }

  /** Phase 24 最小状态表达：该章是否 LOADING */
  isChunkLoading(chunkIndex: number): boolean {
    return this.core.isChunkLoading(chunkIndex);
  }

  /** Phase 24 最小状态表达：该章是否 FAILED */
  isChunkLayoutFailed(chunkIndex: number): boolean {
    return this.core.isChunkLayoutFailed(chunkIndex);
  }

  getCurrentChapterIndex(): number {
    return this.core.getCurrentChapterIndex();
  }

  getCurrentPageIndex(): number {
    return this.core.getCurrentPageIndex();
  }

  getGlobalPageNumber(): number {
    return this.core.getGlobalPageNumber();
  }

  /** Phase 24 (Issue B)：文档空间页码（1-based，与 getTotalPages 同空间） */
  getDocumentPageNumber(): number {
    return this.core.getDocumentPageNumber();
  }

  getChapterPageCount(chapterIndex: number): number {
    return this.core.getChapterPageCount(chapterIndex);
  }

  goToTocItem(item: TocItem): boolean {
    return this.core.goToTocItem(item);
  }

  getTableOfContents(): TocItem[] {
    return this.core.getTableOfContents();
  }

  getChapterCount(): number {
    return this.core.getChapterCount();
  }

  goToAnnotation(ann: Annotation): boolean {
    return this.core.goToAnnotation(ann);
  }

  // ==================== Layout & Styling ====================

  onFontSizeChanged(): void {
    this.core.onFontSizeChanged();
  }

  recompileCss(): void {
    this.core.recompileCss();
  }

  /** 仅重编译主题 CSS 颜色（不重新排版/分页），供主题切换即时重绘用 */
  applyThemeCss(): void {
    this.core.applyThemeCss();
  }

  // ==================== Annotations ====================

  getAnnotationGroups(): ChapterAnnotationGroup[] {
    return this.core.getAnnotationGroups();
  }

  // ==================== Sub-component Access ====================

  getFontLoader() {
    return this.core.getFontLoader();
  }

  /**
   * 注入字体注册器（ENG-002）：UI 线程调用，内部用 UIContext.getFont().registerFont()
   * 替代废弃的 font.registerFont()。
   */
  setFontRegistrar(registrar: FontRegistrar | null): void {
    this.core.setFontRegistrar(registrar);
  }

  getRemoteResourceLoader() {
    return this.core.getRemoteResourceLoader();
  }

  getMediaOverlayController() {
    return this.core.getMediaOverlayController();
  }

  getFontFallbackChain() {
    return this.core.getFontFallbackChain();
  }

  getFontSizeController() {
    return this.core.fontSizeController;
  }

  getThemeManager() {
    return this.core.themeManager;
  }

  getFontThemeManager() {
    return this.core.fontThemeManager;
  }

  getParamBus(): ParameterBus {
    return this.core.paramBus;
  }

  get paramBus(): ParameterBus {
    return this.core.paramBus;
  }

  get mediaContext(): MediaContext {
    return this.core.mediaContext;
  }

  getPageManager(): PageManager {
    return this.core.pageManager;
  }

  getPipelineManager(): PipelineManager {
    return this.core.pipelineManager;
  }

  getAnnotationStorage(): AnnotationStorage {
    return this.core.annotationStorage;
  }

  getLineSpacing(): number {
    return this.core.getLineSpacing();
  }

  // ==================== Feature Access ====================

  initDictionaryConfigManager(filesDir: string): void {
    this.featureManager.initDictionaryConfigManager(filesDir);
  }

  addCustomDictionary(name: string, endpoint: string): void {
    this.featureManager.addCustomDictionary(name, endpoint);
  }

  getFeatureManager(): FeatureManager {
    return this.featureManager;
  }

  // ==================== Word Lookup ====================

  /** Look up a word via the dictionary scheduler */
  lookupWord(word: string): Promise<WordEntry | null> {
    return this.featureManager.lookupWord(word);
  }

  /** Batch look up every word in a sentence */
  lookupBatch(text: string): Promise<Map<string, WordEntry | null>> {
    return this.featureManager.lookupBatch(text);
  }

  // ==================== TTS ====================

  speakWord(word: string): Promise<void> {
    return this.featureManager.speakWord(word);
  }

  stopSpeaking(): void {
    this.featureManager.stopSpeaking();
  }

  // ==================== Vocabulary ====================

  /** Get all saved vocabulary items */
  getVocabulary(): VocabularyItem[] {
    return this.featureManager.getVocabulary();
  }

  /** Save a word entry to the vocabulary book */
  saveWordToVocabulary(entry: WordEntry): Promise<void> {
    return this.featureManager.saveWordToVocabulary(entry);
  }

  /** Check if a word is saved in the vocabulary book */
  isWordSaved(word: string): boolean {
    return this.featureManager.isWordSaved(word);
  }

  /** Remove a word from the vocabulary book */
  removeWordFromVocabulary(word: string): Promise<void> {
    return this.featureManager.removeWordFromVocabulary(word);
  }

  /** Export vocabulary as a CSV string */
  exportVocabularyAsCsv(): Promise<string> {
    return this.featureManager.exportVocabularyAsCsv();
  }
}
