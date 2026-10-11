/**
 * PdfRouter — PDF rendering strategy router (reflow)
 *
 * PdfParser 将 PDF 提取为可重排文本（REFLOW 策略），因此 PDF 走标准
 * ReflowRouter 布局分页。本类保留 StrategyRouter 契约占位（strategy='reflow'，
 * render 为 no-op），供注册表按策略解析时兼容；实际渲染由 ui-render 的
 * ReflowRouter 完成。
 */

import { StrategyRouter, ParsedBook } from 'ohrengine-common';

/**
 * PDF 路由占位 — 实际 reflow 渲染由 ReflowRouter（ui-render）完成。
 */
export class PdfRouter implements StrategyRouter {
  readonly strategy: string = 'reflow';

  /**
   * 空实现：PdfParser 产出 REFLOW 策略，由 ParserRegistry 之外的
   * StrategyRegistry 分发给 ReflowRouter。
   */
  render(_book: ParsedBook): void {
    // no-op：reflow 由 ReflowRouter 处理
  }
}
