/**
 * ReflowRouter — Reflowable-content rendering strategy
 *
 * Implements StrategyRouter for 'reflow' strategy.
 * Handles reflowable EPUB/TXT books — creates stub page slots
 * for each chapter and prepares the layout pipeline for
 * dynamic pagination on every page turn.
 */

import { ParsedBook, StrategyRouter } from 'ohrengine-common';
import { PageManager } from '../core/PageManager.ets';
import { PipelineManager } from '../core/PipelineManager.ets';

/**
 * ReflowRouter — creates stub pages for reflowable content.
 * Injected with PageManager and PipelineManager to set up
 * the pagination pipeline.
 */
export class ReflowRouter implements StrategyRouter {
  readonly strategy: string = 'reflow';

  private readonly pageManager: PageManager;
  private readonly pipelineManager: PipelineManager;

  constructor(pageManager: PageManager, pipelineManager: PipelineManager) {
    this.pageManager = pageManager;
    this.pipelineManager = pipelineManager;
  }

  /**
   * Render a parsed book using reflow layout strategy.
   *
   * Creates stub page slots (one per chapter initially) and
   * sets up the layout pipeline for dynamic pagination.
   *
   * @param book - The ParsedBook to render
   */
  render(book: ParsedBook): void {
    const totalChapters: number = book.chapters.length;

    // Phase 24（Router 生命周期修复）：仅重置页导航态，不再调用
    // pageManager.clearAll()——那会连带清空 open() 刚填充的
    // chunkPlainTextLengths / TXT vchapter 映射（全书字符定位失效、
    // 旧锚点解析错章的根因）。Router 无权清理 engine 层核心状态。
    // P0-A: 批量创建 + 单次 rebuild（逐章 createStubPage 全量 rebuild 是 O(章数²)，
    // 200MB TXT 8703 vch 触发 THREAD_BLOCK_6S）。
    this.pageManager.resetPageNavigationState();
    this.pageManager.createAllStubPages(totalChapters);

    // Signal the pipeline to prepare for reflow pagination
    this.pipelineManager.prepareReflowPipeline(totalChapters);
  }
}
