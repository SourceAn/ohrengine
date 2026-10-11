/**
 * EngineTypes — Core engine type definitions
 *
 * Extracted from OhEngineCore.ets during modularization.
 * All types shared across modules live here.
 */

import { LineBox } from './HtmlTypes.ets';
import { Annotation } from '../document/Publication.ets';

/**
 * Phase 10: 页面就绪状态（最小状态机）。
 * 说明：本层状态由引擎在 pageSlots 重建时标注；「资产解码级」的 RENDER_READY
 * 由渲染侧（PageRenderer）在每次绘制/解码完成时按行级逐页核实，动画入口读取。
 * NOT_READY → DATA_READY → LAYOUT_READY → RENDER_READY；
 * FAILED/INVALIDATED 为异常与失效兜底（当前仅诊断可见，不驱动行为）。
 */
export enum PageReadyState {
  NOT_READY = 0,
  DATA_READY = 1,
  LAYOUT_READY = 2,
  RENDER_READY = 3,
  FAILED = 4,
  INVALIDATED = 5,
}

/**
 * PageSlot — global page space slot
 */
export interface PageSlot {
  pageNumber: number;
  chunkIndex: number;
  href: string;
  state: 'stub' | 'ready';
  epoch: number;
  lines: LineBox[];
  charRange: [number, number];
  /** Phase 10: 全局页索引（pageSlots 数组下标；诊断/生命周期保护用） */
  globalIndex?: number;
  /** Phase 10: 就绪状态标注（stub=NOT_READY；真实页=LAYOUT_READY 起；渲染侧可核实 RENDER_READY） */
  readyState?: PageReadyState;
  /** Phase 10: 构建该 slot 时的 pageGeneration（重排代次，用于动画中代际变更检测） */
  generation?: number;
  /** Phase 10: 本页含图行数（资产就绪判定用） */
  imageCount?: number;
}

/**
 * Reading progress persistence format
 */
export interface ReadingProgress {
  pagesRead: number;
  pagesTotal: number;
  progression: number;
  currentChapter: number;
  currentPage: number;
  totalChapters: number;
  globalPage: number;
}

/** Page cache data */
export interface PageCacheData {
  epoch: number;
  slots: PageSlot[];
  chunks: number;
  totalChars: number;
}

/**
 * Turn direction for page navigation
 */
export enum TurnDirection {
  FORWARD = 'forward',
  BACKWARD = 'backward'
}

/** Unified margin configuration */
export interface Margins {
  left: number;
  right: number;
  top: number;
  bottom: number;
}

/** Theme color configuration */
export interface ThemeConfig {
  backgroundColor: string;
  textColor: string;
}

export interface EngineConfig {
  viewWidth: number;
  viewHeight: number;
  density: number;
}

/**
 * Parameter change cost classification
 */
export enum ParamCategory {
  VERTICAL_ONLY = 'vertical_only',
  PARAGRAPH_LOCAL = 'paragraph_local',
  FULL_REMEASURE = 'full_remeasure'
}

/**
 * Unified layout parameter set
 */
export interface LayoutProfile {
  lineSpacing: number;
  letterSpacing: number;
  wordSpacing: number;
  textIndent: number;
  margins: Margins;
  paragraphSpacing: number;
  textAlign: 'left' | 'right' | 'center' | 'justify';
  theme: ThemeConfig;
  fontFamily?: string;
  rubyFontFamily?: string;
  rubyColor?: string;
  rubyFontSizeRatio?: number;
}

export function createDefaultEngineConfig(): EngineConfig {
  return {
    viewWidth: 720,
    viewHeight: 1080,
    density: 3.0
  };
}

/**
 * Engine state machine
 */
export enum EngineState {
  INITIALIZED = 'initialized',
  LOADING = 'loading',
  READY = 'ready',
  ERROR = 'error',
  DESTROYED = 'destroyed'
}

/**
 * Annotation group by chapter
 */
export class ChapterAnnotationGroup {
  chapterIndex: number;
  title: string;
  annotations: Annotation[];

  constructor(chapterIndex: number, title: string, annotations: Annotation[]) {
    this.chapterIndex = chapterIndex;
    this.title = title;
    this.annotations = annotations;
  }
}

/**
 * Annotation statistics
 */
export interface AnnotationStats {
  total: number;
  chapterStats: Map<number, number>;
  typeStats: Map<string, number>;
}

/**
 * CurlModel — 翻页卷曲几何模型选择（历史类型，旧 GL 翻页使用；现已归档）。
 * 保留供历史兼容；新翻页引擎（ohrengine-pageflip）不再消费该枚举。
 * CYLINDER=0、CONE=1 / HYBRID=2。
 */
export enum CurlModel {
  CYLINDER = 0,
  CONE = 1,
  HYBRID = 2
}

/**
 * PageGenerationProvider — pageGeneration 只读访问器契约（0.13/FR-011）。
 * 由 PageManager 实现；与 PageSlot.epoch 语义完全分离，覆盖 6 个重排入口。
 * 用于翻页 B2 提交前的跨层快照校验（唯一校验依据为 ArkTS 侧重新读取值）。
 */
export interface PageGenerationProvider {
  /** 返回当前页槽代次（进程内单调递增；重排即递增） */
  getPageGeneration(): number;
}
