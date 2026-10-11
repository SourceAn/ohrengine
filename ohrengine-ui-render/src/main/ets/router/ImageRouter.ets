/**
 * ImageRouter — Image-book rendering strategy
 *
 * Implements StrategyRouter for 'image' strategy.
 * Handles CBZ/CBR comic books — creates one image page per chapter
 * and sets up the pipeline for static page rendering.
 */

import { ParsedBook, StrategyRouter } from 'ohrengine-common';
import { PageManager } from '../core/PageManager.ets';
import { PipelineManager } from '../core/PipelineManager.ets';

/**
 * ImageRouter — creates per-chapter image pages for image-based content (CBZ/CBR).
 * Each chapter in the parsed book represents one image page.
 */
export class ImageRouter implements StrategyRouter {
  readonly strategy: string = 'image';

  private readonly pageManager: PageManager;
  private readonly pipelineManager: PipelineManager;

  constructor(pageManager: PageManager, pipelineManager: PipelineManager) {
    this.pageManager = pageManager;
    this.pipelineManager = pipelineManager;
  }

  /**
   * Render a parsed book using image-based layout strategy.
   *
   * Each chapter maps to exactly one image page. No reflow
   * pagination is needed — pages are pre-computed.
   *
   * @param book - The ParsedBook to render
   */
  render(book: ParsedBook): void {
    const totalPages: number = book.chapters.length;

    // Phase 24（Router 生命周期修复）：仅重置页导航态，不再调用
    // pageManager.clearAll()（Router 无权清理 engine 层核心状态）。
    this.pageManager.resetPageNavigationState();

    // Signal the pipeline to prepare for image-based rendering
    this.pipelineManager.prepareImagePipeline(totalPages);

    // 每图一章 → 单行图片页（非 stub）：绘制层按 line.imageSrc 异步解码整页图。
    // 不能沿用 createStubPage——stub 页只有占位空行（STUB_LINE_HEIGHT 空行盒），
    // 没有 imageSrc，渲染结果会是整页空白。
    for (let i: number = 0; i < totalPages; i++) {
      this.pageManager.createImagePage(i, book.chapters[i].href);
    }
  }
}
