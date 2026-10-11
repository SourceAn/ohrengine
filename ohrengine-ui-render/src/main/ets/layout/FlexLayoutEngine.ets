/**
 * FlexLayoutEngine —  Flexbox 布局工具
 *
 * 为 display: flex 容器中的 flex item 应用 min/max 尺寸约束。
 * 在分配 flex 弹性空间后调用 clamp，确保每个 flex item 的最终尺寸
 * 受 CSS min-width / max-width / min-height / max-height 约束。
 */
import { CssLength, CssValueType } from 'ohrengine-common';

/**
 * Flex 弹性项——由 LayoutEngine 从 RenderNode 构建后传入
 */
export interface FlexItem {
  /** 原始 resolved min-width (px) */
  minWidth: number;
  /** 原始 resolved max-width (px) */
  maxWidth: number;
  /** 原始 resolved min-height (px) */
  minHeight: number;
  /** 原始 resolved max-height (px) */
  maxHeight: number;
  /** flex 主轴尺寸（写入后回传至 child.boxModel.contentWidth） */
  flexSize: number;
  /** flex 交叉轴尺寸（写入后回传至 child.boxModel.contentHeight） */
  crossSize: number;
}

export class FlexLayoutEngine {
  /**
   * 对 flex items 应用 min/max 约束。
   * 在分配 flex 弹性空间后调用此方法。
   *
   * @param items  flex 子项列表
   * @param crossSize  交叉轴总尺寸（px）
   */
  applyMinMaxToFlexItems(items: FlexItem[], crossSize: number): void {
    for (const item of items) {
      // min-width / max-width 约束主轴尺寸
      if (item.minWidth > 0 && item.flexSize < item.minWidth) {
        item.flexSize = item.minWidth;
      }
      if (item.maxWidth > 0 && item.flexSize > item.maxWidth) {
        item.flexSize = item.maxWidth;
      }
      // min-height / max-height 约束交叉轴尺寸
      if (item.minHeight > 0 && item.crossSize < item.minHeight) {
        item.crossSize = item.minHeight;
      }
      if (item.maxHeight > 0 && item.crossSize > item.maxHeight) {
        item.crossSize = item.maxHeight;
      }
    }
  }
}
