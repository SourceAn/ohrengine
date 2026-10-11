/**
 * 排版引擎
 * 参考：crengine lvstsheet.cpp + LVDocView
 *
 * 职责：
 * 1. 接收渲染节点树（RenderNode[]）作为输入
 * 2. 根据样式计算每个元素的盒模型（margin, border, padding, content）
 * 3. 执行 CSS 行布局：换行、行高、对齐、基线
 * 4. 输出经过布局计算的 RenderNode（含行盒列表）
 * 5. 供 PageSplitter 消费进行分页
 *
 * 排版流程：
 *   LayoutEngine.layout(renderNodes, viewWidth, viewHeight)
 *     -> 每个 RenderNode 计算盒模型
 *     -> 文本布局（换行、对齐）
 *     -> 生成 LineBox[]
 */

import { createEmptyLineBox, createBoxModel } from 'ohrengine-common';
import type { RenderNode, LineBox, DomNode, BoxModel, MathMlExpression, SvgDocument } from 'ohrengine-common';
import {
  CssStyleSet, CssDisplay, CssWhiteSpace, CssTextAlign, CssFontStyle,
  CssFontWeight, CssFontFamily, CssValueType, CssLength, createCssLength,
  CssGenericValue, CssFloat, CssClear, CssVisibility, CssBorderStyle
} from 'ohrengine-common';
import { LineRubySegment } from './RubyRenderer.ets';
import { MathMLRenderer, MathMlMeasure, MathMlRenderOptions } from './MathMLRenderer.ets';
import { SvgRenderer, SvgViewportResult } from './SvgRenderer.ets';
import { TableRenderer } from './TableRenderer.ets';
import { GridResult, TableElement, RubyPair } from 'ohrengine-common';
import { FloatLayoutEngine, FloatBox } from './FloatLayoutEngine.ets';
import { FlexLayoutEngine, FlexItem } from './FlexLayoutEngine.ets';
import { TextBreaker } from '../typography/TextBreaker.ets';
import { ReadingMetrics } from '../typography/ReadingMetrics.ets';
import { FauxBoldItalicRenderer } from './FauxBoldItalicRenderer.ets';
import { generateMarker, estimateMarkerWidth, ListStyleType, getLevelDefaultMarkerType } from './ListRenderer.ets';
import { CssCounterManager } from '../style/CssCounterManager.ets';

/**
 * 容器溢出裁剪信息（用于 overflow:hidden Canvas 裁剪）
 */
export interface OverflowClipInfo {
  overflow: string;   // 'visible' | 'hidden'
  x: number;
  y: number;
  width: number;
  height: number;
}

/**
 * 排版节点上下文 — 替代 layoutNode 的 7 个位置参数
 */
export interface LayoutContext {
  x: number;
  y: number;
  availableWidth: number;
  parentFontSize: number;
  effectiveOpacity: number;
  parentHasSpecifiedHeight: boolean;
  parentOverflowInfo: OverflowClipInfo | undefined;
}

/**
 * 排版引擎
 *
 * 使用方式：
 *   const engine: LayoutEngine = new LayoutEngine();
 *   engine.setViewport(720, 1280);
 *   const laidOut: RenderNode[] = engine.layout(renderNodes);
 */
export class LayoutEngine {
  private viewWidth: number = 720;
  private viewHeight: number = 1000;
  private baseFontSize: number = 16; // px — fallback when CSS doesn't specify
  private breaker: TextBreaker = new TextBreaker();
  private tableRenderer: TableRenderer = new TableRenderer();
  private floatEngine: FloatLayoutEngine = new FloatLayoutEngine();
  private cssCounterManager: CssCounterManager = new CssCounterManager();
  private flexEngine: FlexLayoutEngine = new FlexLayoutEngine();

  constructor() {
    this.breaker.onDpFallback = (_nTokens: number, _lineCount: number): void => {
    };
  }

  /**
   * 设置视口尺寸
   */
  public setViewport(width: number, height: number): void {
    this.viewWidth = width;
    this.viewHeight = height;
  }

  /**
   * 设置基础字号（px）— 仅当 CSS 未指定字号时生效
   */
  public setBaseFontSize(px: number): void {
    this.baseFontSize = px;
  }

  /**
   * 设置屏幕密度（TextBreaker 测量需要）
   */
  public setDensity(density: number): void {
    this.breaker.setDensity(density);
  }

  public setTextAlign(align: 'left' | 'right' | 'center' | 'justify'): void {
    this.breaker.setTextAlign(align);
  }

  public setLineSpacing(spacing: number): void {
    this.breaker.setLineSpacing(spacing);
  }

  public setLetterSpacing(spacing: number): void {
    this.breaker.setLetterSpacing(spacing);
  }

  public setWordSpacing(spacing: number): void {
    this.breaker.setWordSpacing(spacing);
  }

  /**
   * 设置首行缩进（vp）。0 表示无缩进；正值按 vp 缩进。
   * 注意：TextBreaker 内部默认 2em 联动（setFontSize 时 textIndent=fp*2），
   * 显式调用本方法会覆盖该默认（textIndentExplicit=true）。
   */
  public setTextIndent(vp: number): void {
    this.breaker.setTextIndent(vp);
  }

  /**
   * 设置默认字体（TextBreaker 测量用）— 经 setLayoutProfile 链路注入
   */
  public setFontFamily(family: string): void {
    this.breaker.setFontFamily(family);
  }

  /**
   * 只测一段文本，返回 LineBox 列表（字号实时调整.md rippleRelayoutPage）
   */
  public measureParagraph(text: string): LineBox[] {
    const effectiveFontSize: number = this.baseFontSize;
    this.breaker.setFontSize(effectiveFontSize);
    this.breaker.setMaxWidth(this.viewWidth);
    const result = this.breaker.breakText(text);
    const lines: LineBox[] = [];
    for (const lb of result.lines) {
      lb.y = lines.length * (effectiveFontSize * ReadingMetrics.LINE_HEIGHT_RATIO + this.breaker.getLineSpacing());
      lines.push(lb);
    }
    return lines;
  }

  /**
   * 对渲染节点列表执行排版
   */
  public layout(nodes: RenderNode[]): RenderNode[] {
    this.floatEngine.reset();
    this.cssCounterManager.resetAll();
    for (let i = 0; i < nodes.length; i++) {
      // 顶层节点：父字体大小 = baseFontSize，无父容器 overflow 裁剪，无父容器指定高度
      const rootCtx: LayoutContext = {
        x: 0, y: 0,
        availableWidth: this.viewWidth,
        parentFontSize: this.baseFontSize,
        effectiveOpacity: 1.0,
        parentHasSpecifiedHeight: false,
        parentOverflowInfo: undefined
      };
      this.layoutNode(nodes[i], rootCtx);
    }
    return nodes;
  }

  /**
   * 排版单个节点（递归）
   */
  private layoutNode(
    node: RenderNode, ctx: LayoutContext
  ): void {
    if (node.computedStyle!.visibility === CssVisibility.HIDDEN ||
        node.computedStyle!.visibility === CssVisibility.COLLAPSE) {
      return;
    }

    // Opacity cascade: effective = parent * self
    const nodeOpacity: number = node.computedStyle!.opacity;
    const cascadedOpacity: number = ctx.effectiveOpacity * nodeOpacity;
    node.effectiveOpacity = cascadedOpacity;

    const box: BoxModel = this.computeBoxModel(node, ctx.availableWidth);
    box.x = ctx.x;
    box.y = ctx.y;
    node.boxModel = box;

    // ---- CSS float / clear handling ----
    const cssFloat: CssFloat = node.computedStyle!.float;
    const cssClear: CssClear = node.computedStyle!.clear;

    // Clear handling: position this node below preceding floats on specified side(s)
    if (cssClear !== CssClear.NONE) {
      let clearSide: 'left' | 'right' | 'both';
      if (cssClear === CssClear.LEFT) {
        clearSide = 'left';
      } else if (cssClear === CssClear.RIGHT) {
        clearSide = 'right';
      } else {
        clearSide = 'both';
      }
      const clearY: number = this.floatEngine.clearFloats(clearSide, ctx.availableWidth);
      if (clearY > box.y) {
        box.y = clearY;
      }
    }

    // Float handling: route to float engine, create synthetic LineBox
    if (cssFloat !== CssFloat.NONE) {
      // ── Resolve explicit CSS width for the float ──
      const explicitWidth: number = this.resolveLength(node.computedStyle!.width, box.contentWidth);
      if (explicitWidth > 0) {
        box.contentWidth = explicitWidth;
      }

      // ── Resolve explicit CSS height for the float ──
      // Command 1: 百分比高度在父容器 height:auto 时无效
      const explicitHeight: number = this.resolveHeightValue(node.computedStyle!.height, ctx.availableWidth, ctx.parentHasSpecifiedHeight);
      if (explicitHeight > 0) {
        box.contentHeight = explicitHeight;
      }

      // ── For float nodes with text, estimate height via text breaking ──
      if (box.contentHeight <= 0 && node.text !== undefined && node.text.length > 0) {
        const fontSize: number = this.computeNodeFontSize(node, ctx.parentFontSize);
        const lineHeight: number = this.resolveLineHeight(node.computedStyle!.lineHeight, fontSize);
        this.breaker.setFontSize(fontSize);
        this.breaker.setFontFamily(this.getPrimaryFontFamily(node));
        this.breaker.setMaxWidth(box.contentWidth);
        this.breaker.setLineHeight(lineHeight);
        const result = this.breaker.breakText(node.text);
        box.contentHeight = result.lines.length * lineHeight;
      }

      // ── Default fallback height ──
      if (box.contentHeight <= 0) {
        const fallbackFontSize: number = this.computeNodeFontSize(node, ctx.parentFontSize);
        box.contentHeight = Math.max(fallbackFontSize * ReadingMetrics.LINE_HEIGHT_RATIO, 20);
      }

      // ── Command 1: Margin/padding/border box model ──
      const floatMarginL: number = box.marginLeft;
      const floatMarginR: number = box.marginRight;
      const floatMarginT: number = box.marginTop;
      const floatMarginB: number = box.marginBottom;
      const floatPadL: number = box.paddingLeft;
      const floatPadR: number = box.paddingRight;
      const floatPadT: number = box.paddingTop;
      const floatPadB: number = box.paddingBottom;
      const floatBorderW: number = box.borderLeft + box.borderRight;
      const floatBorderH: number = box.borderTop + box.borderBottom;

      // float 实际占用宽度/高度 = margin + border + padding + content
      const floatTotalWidth: number = floatMarginL + floatMarginR + floatBorderW
        + floatPadL + floatPadR + box.contentWidth;
      const floatTotalHeight: number = floatMarginT + floatMarginB + floatBorderH
        + floatPadT + floatPadB + box.contentHeight;

      const side: 'left' | 'right' = cssFloat === CssFloat.LEFT ? 'left' : 'right';
      const floatBox: FloatBox = {
        x: 0, y: 0,
        width: floatTotalWidth,
        height: floatTotalHeight,
        side: side,
        marginTop: floatMarginT,
        marginRight: floatMarginR,
        marginBottom: floatMarginB,
        marginLeft: floatMarginL
      };
      const positionedBox: FloatBox = this.floatEngine.positionFloat(floatBox, ctx.availableWidth);

      // ── Command 3: Recursive block-level children inside float ──
      // Block-level children sit inside the float content area (after margin/border/padding)
      const hasBlockChildren: boolean = node.children.length > 0;
      if (hasBlockChildren) {
        const contentX: number = positionedBox.x + floatMarginL + box.borderLeft + floatPadL;
        const contentY: number = positionedBox.y + floatMarginT + box.borderTop + floatPadT;
        const floatContentWidth: number = box.contentWidth;
        let innerChildY: number = contentY;
        for (let fi: number = 0; fi < node.children.length; fi++) {
          const child: RenderNode = node.children[fi];
          // Command 1: 子节点的 parentHasSpecifiedHeight = 当前节点是否指定了 height
          const childHasSpecHeight: boolean = node.computedStyle!.height.type !== CssValueType.UNSPECIFIED;
          // Command 2: 子节点继承最近的 overflow:hidden 祖先信息
          const childOverflow: OverflowClipInfo | undefined = this.computeChildOverflowInfo(node, box, ctx.parentOverflowInfo);
          const childCtx: LayoutContext = {
            x: contentX, y: innerChildY,
            availableWidth: floatContentWidth,
            parentFontSize: ctx.parentFontSize,
            effectiveOpacity: cascadedOpacity,
            parentHasSpecifiedHeight: childHasSpecHeight,
            parentOverflowInfo: childOverflow
          };
          this.layoutNode(child, childCtx);
          if (child.boxModel !== undefined) {
            innerChildY = child.boxModel.y + child.boxModel.totalHeight;
          }
        }
        // Compute content height from inner children (like normal container)
        if (innerChildY > contentY) {
          box.contentHeight = innerChildY - contentY;
        }
      }

      // ── Create synthetic LineBox for rendering ──
      const floatLine: LineBox = createEmptyLineBox();
      floatLine.isFloat = true;
      floatLine.x = positionedBox.x;
      floatLine.y = positionedBox.y;
      floatLine.width = positionedBox.width;
      floatLine.height = positionedBox.height;
      floatLine.marginTop = floatMarginT;
      floatLine.marginRight = floatMarginR;
      floatLine.marginBottom = floatMarginB;
      floatLine.marginLeft = floatMarginL;
      if (node.text !== undefined) {
        floatLine.text = node.text;
      }
      // Command 2: 从父容器传播 overflow:hidden 裁剪信息
      if (ctx.parentOverflowInfo !== undefined && ctx.parentOverflowInfo.overflow === 'hidden') {
        floatLine.containerOverflow = 'hidden';
        floatLine.containerX = ctx.parentOverflowInfo.x;
        floatLine.containerY = ctx.parentOverflowInfo.y;
        floatLine.containerWidth = ctx.parentOverflowInfo.width;
        floatLine.containerHeight = ctx.parentOverflowInfo.height;
      }
      node.lineBoxes = [floatLine];

      // ── Update box model for parent container computations ──
      box.y = positionedBox.y; // Reflect actual float Y (margin box top)
      // Re-apply min/max-height constraints before setting totalHeight
      if (node.computedStyle!.minHeight.type !== CssValueType.UNSPECIFIED) {
        const minH: number = this.resolveLength(node.computedStyle!.minHeight, ctx.availableWidth);
        if (minH > 0 && box.contentHeight < minH) {
          box.contentHeight = minH;
        }
      }
      if (node.computedStyle!.maxHeight.type !== CssValueType.UNSPECIFIED) {
        const maxH: number = this.resolveLength(node.computedStyle!.maxHeight, ctx.availableWidth);
        if (maxH > 0 && box.contentHeight > maxH) {
          box.contentHeight = maxH;
        }
      }
      // totalHeight = float's full footprint including margins (for parent clearfix)
      // Recompute with potentially-updated contentHeight from inner children layout
      const finalFloatHeight: number = floatMarginT + floatMarginB + floatBorderH
        + floatPadT + floatPadB + box.contentHeight;
      box.totalHeight = finalFloatHeight;

      return; // Skip text layout for float node (text handled above or via inner children)
    }
    // ---- end CSS float / clear handling ----

    if (node.isReplaced) {
      // 替换元素（img 等）简化处理
      this.layoutReplaced(node, box, ctx.parentHasSpecifiedHeight, ctx.parentOverflowInfo);
      return;
    }

    // 列表项缩进调整（在文本布局之前缩小 contentWidth）
    if (node.isListItem) {
      const indent: number = 32 * (node.listLevel ?? 0);
      const mw: number = node.markerWidth ?? 20;
      const gap: number = 4;
      const reservedLeft: number = indent + mw + gap;
      box.contentWidth = Math.max(0, box.contentWidth - reservedLeft);
    }

    // 表格：通过 TableRenderer 固定布局，不走 TextBreaker
    if (node.tableData !== undefined) {
      const td: TableElement = node.tableData as TableElement;
      const gridResult: GridResult = this.tableRenderer.layout(td, box.contentWidth);
      td.gridResult = gridResult;
      box.contentHeight = gridResult.totalHeight;
      // Re-apply min/max-height after table height
      if (node.computedStyle!.minHeight.type !== CssValueType.UNSPECIFIED) {
        const minH: number = this.resolveLength(node.computedStyle!.minHeight, ctx.availableWidth);
        if (minH > 0 && box.contentHeight < minH) {
          box.contentHeight = minH;
        }
      }
      if (node.computedStyle!.maxHeight.type !== CssValueType.UNSPECIFIED) {
        const maxH: number = this.resolveLength(node.computedStyle!.maxHeight, ctx.availableWidth);
        if (maxH > 0 && box.contentHeight > maxH) {
          box.contentHeight = maxH;
        }
      }
      box.totalHeight = box.contentHeight + box.paddingTop + box.paddingBottom + box.borderTop + box.borderBottom;
      return;
    }

    // 文本布局：换行 → 生成行盒（考虑当前活动浮动元素对宽度的压缩）
    if (node.text !== undefined && node.text !== '') {
      const textStartY: number = box.y + box.paddingTop + box.borderTop;
      const floatRestrictedWidth: number = this.floatEngine.getAvailableLineWidth(
        textStartY, box.contentWidth);
      if (floatRestrictedWidth < box.contentWidth) {
        box.contentWidth = floatRestrictedWidth;
      }
      this.layoutTextBox(node, box, ctx.parentFontSize, cascadedOpacity, ctx.parentOverflowInfo);
    }

    // 列表项：重新计算索引 + 重新生成标记（CSS counters 优先，DOM 计数 fallback）
    if (node.isListItem) {
      const level: number = node.listLevel ?? 0;
      // 确定列表样式类型（从 node → string → ListStyleType，或按层级 fallback）
      const rawType: string | undefined = node.computedStyle!?.listStyleType;
      let lst: ListStyleType = getLevelDefaultMarkerType(level);
      const validTypes: string[] = ['disc', 'circle', 'square', 'decimal', 'lower-alpha', 'upper-alpha', 'lower-roman', 'upper-roman', 'none'];
      if (rawType !== undefined && validTypes.indexOf(rawType) >= 0) {
        if (rawType === 'disc') { lst = ListStyleType.DISC; }
        else if (rawType === 'circle') { lst = ListStyleType.CIRCLE; }
        else if (rawType === 'square') { lst = ListStyleType.SQUARE; }
        else if (rawType === 'decimal') { lst = ListStyleType.DECIMAL; }
        else if (rawType === 'lower-alpha') { lst = ListStyleType.LOWER_ALPHA; }
        else if (rawType === 'upper-alpha') { lst = ListStyleType.UPPER_ALPHA; }
        else if (rawType === 'lower-roman') { lst = ListStyleType.LOWER_ROMAN; }
        else if (rawType === 'upper-roman') { lst = ListStyleType.UPPER_ROMAN; }
        else if (rawType === 'none') { lst = ListStyleType.NONE; }
      }

      // 列表项计数器：优先使用 CSS counters
      let listIndex: number = 0;
      const style: CssStyleSet | undefined = node.computedStyle!;
      if (style !== undefined && (style.counterIncrement !== undefined || style.counterReset !== undefined)) {
        // CSS counter 模式
        if (style.counterReset !== undefined) {
          const resetParts: string[] = style.counterReset.split(/\s+/);
          for (let ri = 0; ri < resetParts.length - 1; ri += 2) {
            this.cssCounterManager.reset(resetParts[ri], parseInt(resetParts[ri + 1]) || 0, level);
          }
        }
        if (style.counterIncrement !== undefined && style.counterIncrement.length > 0) {
          const incParts: string[] = style.counterIncrement.split(/\s+/);
          const counterName: string = incParts[0];
          const delta: number = incParts.length > 1 ? parseInt(incParts[1]) || 1 : 1;
          this.cssCounterManager.increment(counterName, delta, level);
          listIndex = this.cssCounterManager.getValue(counterName, level);
        }
      } else {
        // 传统 DOM 计数模式（现有逻辑）
        listIndex = (node.listItemIndex ?? 0) + (node.listStartOffset ?? 0);
        if (node.listReversed && node.listTotalItems !== undefined) {
          listIndex = node.listTotalItems - (node.listItemIndex ?? 0) - 1 + (node.listStartOffset ?? 0);
        }
      }
      // 用 listIndex 重新生成标记
      const newMarker: string = generateMarker(listIndex, lst, level, node.markerImageSrc);
      node.listMarker = newMarker;
      node.markerWidth = estimateMarkerWidth(newMarker, 16);
    }

    // 列表项：标记信息传播到 LineBox + 偏移行 X 为标记留空
    if (node.isListItem) {
      const indent: number = 32 * (node.listLevel ?? 0);
      const mw: number = node.markerWidth ?? 20;
      const gap: number = 4;
      const reservedLeft: number = indent + mw + gap;
      const markerX: number = box.x + box.paddingLeft + box.borderLeft + indent;
      for (let li = 0; li < node.lineBoxes.length; li++) {
        const lb: LineBox = node.lineBoxes[li];
        lb.x += reservedLeft;
        lb.listMarker = node.listMarker;
        lb.listMarkerX = markerX;
        lb.listMarkerFontSize = node.markerFontSize;
        lb.listMarkerColor = node.markerColor;
        lb.markerImageSrc = node.markerImageSrc;
        lb.listLevel = node.listLevel;
      }
    }

    // 递归子节点（传递当前节点的解析字号作为子节点的 parentFontSize）
    const resolvedParentFont: number = this.computeNodeFontSize(node, ctx.parentFontSize);
    let childY: number = box.y + box.paddingTop + box.borderTop;
    for (let i = 0; i < node.children.length; i++) {
      const child: RenderNode = node.children[i];
      // Reduce available width for children if floats overlap at the current Y position
      const floatRestrictedWidth: number = this.floatEngine.getAvailableLineWidth(
        childY, box.contentWidth);
      const childAvailableWidth: number = Math.min(box.contentWidth, floatRestrictedWidth);
      // Command 1: 子节点的 parentHasSpecifiedHeight = 当前节点是否指定了 height
      const childHasSpecHeight: boolean = node.computedStyle!.height.type !== CssValueType.UNSPECIFIED;
      // Command 2: 子节点继承最近的 overflow:hidden 祖先信息
      const childOverflow: OverflowClipInfo | undefined = this.computeChildOverflowInfo(node, box, ctx.parentOverflowInfo);
      const childCtx: LayoutContext = {
        x: ctx.x + box.paddingLeft + box.borderLeft, y: childY,
        availableWidth: childAvailableWidth,
        parentFontSize: resolvedParentFont,
        effectiveOpacity: cascadedOpacity,
        parentHasSpecifiedHeight: childHasSpecHeight,
        parentOverflowInfo: childOverflow
      };
      this.layoutNode(child, childCtx);
      if (child.boxModel !== undefined) {
        childY = child.boxModel.y + child.boxModel.totalHeight;
      }
    }
    // ── Command 2：display: flex 容器 → 对 flex items 应用 min/max 约束 ──
    if (node.computedStyle!.display === CssDisplay.FLEX ||
        node.computedStyle!.display === CssDisplay.INLINE_FLEX) {
      const flexItems: FlexItem[] = [];
      for (let i = 0; i < node.children.length; i++) {
        const child: RenderNode = node.children[i];
        if (child.boxModel !== undefined) {
          flexItems.push({
            minWidth: this.resolveLength(child.computedStyle!.minWidth, child.boxModel.contentWidth),
            maxWidth: this.resolveLength(child.computedStyle!.maxWidth, child.boxModel.contentWidth),
            minHeight: this.resolveLength(child.computedStyle!.minHeight, this.viewHeight),
            maxHeight: this.resolveLength(child.computedStyle!.maxHeight, this.viewHeight),
            flexSize: child.boxModel.contentWidth,
            crossSize: child.boxModel.contentHeight,
          });
        }
      }
      if (flexItems.length > 0) {
        this.flexEngine.applyMinMaxToFlexItems(flexItems, this.viewHeight);
        // 将约束后的尺寸写回到 child.boxModel
        for (let i = 0; i < flexItems.length; i++) {
          const child: RenderNode = node.children[i];
          if (child.boxModel !== undefined) {
            child.boxModel.contentWidth = flexItems[i].flexSize;
            child.boxModel.contentHeight = flexItems[i].crossSize;
            child.boxModel.totalWidth = child.boxModel.contentWidth +
              child.boxModel.paddingLeft + child.boxModel.paddingRight +
              child.boxModel.borderLeft + child.boxModel.borderRight;
            child.boxModel.totalHeight = child.boxModel.contentHeight +
              child.boxModel.paddingTop + child.boxModel.paddingBottom +
              child.boxModel.borderTop + child.boxModel.borderBottom;
          }
        }
      }
    }

    // 子节点布局完成后，根据子节点位置更新父节点的内容高度
    // clearfix: 所有 float 子项的 boxModel.y + boxModel.totalHeight
    // 包含 margin, border, padding, content，自然构成 clearfix。
    if (node.children.length > 0) {
      let maxBottom: number = childY;
      for (let i = 0; i < node.children.length; i++) {
        const child: RenderNode = node.children[i];
        if (child.boxModel !== undefined) {
          const childBottom: number = child.boxModel.y + child.boxModel.totalHeight;
          if (childBottom > maxBottom) {
            maxBottom = childBottom;
          }
        }
      }
      box.contentHeight = maxBottom - (box.y + box.paddingTop + box.borderTop);
      if (box.contentHeight < 0) box.contentHeight = 0;
      // Command 3: min/max-height 撑开父容器（使用 viewHeight 作为上下文）
      if (node.computedStyle!.minHeight.type !== CssValueType.UNSPECIFIED) {
        const minH: number = this.resolveLength(node.computedStyle!.minHeight, this.viewHeight);
        if (minH > 0 && box.contentHeight < minH) {
          box.contentHeight = minH;
        }
      }
      if (node.computedStyle!.maxHeight.type !== CssValueType.UNSPECIFIED) {
        const maxH: number = this.resolveLength(node.computedStyle!.maxHeight, this.viewHeight);
        if (maxH > 0 && box.contentHeight > maxH) {
          box.contentHeight = maxH;
        }
      }
      box.totalHeight = box.contentHeight + box.paddingTop + box.paddingBottom + box.borderTop + box.borderBottom;
    }

    // 最终 min/max-height 约束（覆盖 text-only / replaced 无子节点的情况）
    // Command 3: 使用 viewHeight 作为上下文，确保 totalHeight 基于撑高后的 contentHeight 重算
    if (node.computedStyle!.minHeight.type !== CssValueType.UNSPECIFIED) {
      const minH: number = this.resolveLength(node.computedStyle!.minHeight, this.viewHeight);
      if (minH > 0 && box.contentHeight < minH) {
        box.contentHeight = minH;
      }
    }
    if (node.computedStyle!.maxHeight.type !== CssValueType.UNSPECIFIED) {
      const maxH: number = this.resolveLength(node.computedStyle!.maxHeight, this.viewHeight);
      if (maxH > 0 && box.contentHeight > maxH) {
        box.contentHeight = maxH;
      }
    }
    // 确保 totalHeight 基于约束后的 contentHeight 重新计算
    box.totalHeight = box.contentHeight + box.paddingTop + box.paddingBottom +
      box.borderTop + box.borderBottom;
  }

  /**
   * 计算盒模型
   */
  private computeBoxModel(node: RenderNode, availableWidth: number): BoxModel {
    const style: CssStyleSet = node.computedStyle!;
    const box: BoxModel = createBoxModel();

    // 边距解析
    box.marginTop = this.resolveLength(style.marginTop, availableWidth);
    box.marginRight = this.resolveLength(style.marginRight, availableWidth);
    box.marginBottom = this.resolveLength(style.marginBottom, availableWidth);
    box.marginLeft = this.resolveLength(style.marginLeft, availableWidth);

    // 边框
    box.borderTop = this.resolveBorderWidth(style.borderTopStyle, style.borderTopWidth, availableWidth);
    box.borderRight = this.resolveBorderWidth(style.borderRightStyle, style.borderRightWidth, availableWidth);
    box.borderBottom = this.resolveBorderWidth(style.borderBottomStyle, style.borderBottomWidth, availableWidth);
    box.borderLeft = this.resolveBorderWidth(style.borderLeftStyle, style.borderLeftWidth, availableWidth);

    // 内边距
    box.paddingTop = this.resolveLength(style.paddingTop, availableWidth);
    box.paddingRight = this.resolveLength(style.paddingRight, availableWidth);
    box.paddingBottom = this.resolveLength(style.paddingBottom, availableWidth);
    box.paddingLeft = this.resolveLength(style.paddingLeft, availableWidth);

    // 内容区宽度
    const hPadding: number = box.paddingLeft + box.paddingRight;
    const hBorder: number = box.borderLeft + box.borderRight;
    const hMargin: number = box.marginLeft + box.marginRight;
    box.contentWidth = availableWidth - hPadding - hBorder - hMargin;
    if (box.contentWidth < 0) {
      box.contentWidth = 0;
    }

    // 应用 min/max-width 约束
    const unresolvedMinW: CssLength = style.minWidth;
    const unresolvedMaxW: CssLength = style.maxWidth;
    if (unresolvedMinW.type !== CssValueType.UNSPECIFIED) {
      const minW: number = this.resolveLength(style.minWidth, availableWidth);
      if (minW > 0 && box.contentWidth < minW) {
        box.contentWidth = minW;
      }
    }
    if (unresolvedMaxW.type !== CssValueType.UNSPECIFIED) {
      const maxW: number = this.resolveLength(style.maxWidth, availableWidth);
      if (maxW > 0 && box.contentWidth > maxW) {
        box.contentWidth = maxW;
      }
    }

    // 应用 min/max-height 约束（初始值，text/children 布局后会再次约束）
    const unresolvedMinH: CssLength = style.minHeight;
    const unresolvedMaxH: CssLength = style.maxHeight;
    if (unresolvedMinH.type !== CssValueType.UNSPECIFIED) {
      const minH: number = this.resolveLength(style.minHeight, availableWidth);
      if (minH > 0 && box.contentHeight < minH) {
        box.contentHeight = minH;
      }
    }
    if (unresolvedMaxH.type !== CssValueType.UNSPECIFIED) {
      const maxH: number = this.resolveLength(style.maxHeight, availableWidth);
      if (maxH > 0 && box.contentHeight > maxH) {
        box.contentHeight = maxH;
      }
    }

    // ── margin: auto 分配（在 min/max 约束后） ──
    const marginLeftAuto: boolean =
      style.marginLeft.type === CssValueType.UNSPECIFIED && style.marginLeft.value === CssGenericValue.AUTO;
    const marginRightAuto: boolean =
      style.marginRight.type === CssValueType.UNSPECIFIED && style.marginRight.value === CssGenericValue.AUTO;
    if (marginLeftAuto || marginRightAuto) {
      const usedWidth: number = hPadding + hBorder + box.contentWidth;
      const remaining: number = availableWidth - usedWidth;
      if (marginLeftAuto && marginRightAuto) {
        // 两边 auto → 居中
        box.marginLeft = remaining / 2;
        box.marginRight = remaining / 2;
      } else if (marginLeftAuto) {
        box.marginLeft = remaining - box.marginRight;
      } else if (marginRightAuto) {
        box.marginRight = remaining - box.marginLeft;
      }
      // 重新计算 contentWidth（margin auto 可能导致可用宽度变化）
      box.contentWidth = Math.max(0, availableWidth - box.marginLeft - box.marginRight - hPadding - hBorder);
    }

    // 总尺寸
    box.totalWidth = availableWidth;
    box.totalHeight = box.contentHeight + box.paddingTop + box.paddingBottom +
                       box.borderTop + box.borderBottom;

    return box;
  }

  /**
   * 文本行布局
   */
  private layoutTextBox(node: RenderNode, box: BoxModel, parentFontSize: number,
    cascadedOpacity: number = 1.0, parentOverflowInfo: OverflowClipInfo | undefined = undefined): void {
    const text: string = node.text ?? '';
    if (text.length === 0) { return; }
    const style: CssStyleSet = node.computedStyle!;
    // CSS-first font-size: 从 CSS 解析；若无效则回退 baseFontSize；最后乘以用户缩放
    const cssFontSize: number = this.resolveCssFontSize(style.fontSize, parentFontSize);
    let fontSize: number = cssFontSize > 0 ? cssFontSize : this.baseFontSize;
    fontSize = Math.max(1, fontSize);

    // sup/sub 上下标：65% 字号
    if (node.isSuperscript || node.isSubscript) {
      fontSize = Math.max(4, fontSize * 0.65);
    }

    const lineHeight: number = this.resolveLineHeight(style.lineHeight, fontSize);

    // 设置 CSS 属性（white-space / overflow / text-overflow 供 TextBreaker 使用）
    this.breaker.setWhiteSpace(style.whiteSpace === CssWhiteSpace.NOWRAP ? 'nowrap' : 'normal');
    this.breaker.setOverflow(style.overflow);
    this.breaker.setTextOverflow(style.textOverflow);

    // 使用 Knuth-Plass 最优换行（测量与渲染使用同一 fontFamily，保证断行一致）
    this.breaker.setFontSize(fontSize);
    this.breaker.setFontFamily(this.getPrimaryFontFamily(node));
    this.breaker.setMaxWidth(box.contentWidth);
    this.breaker.setLineHeight(lineHeight);
    const result = this.breaker.breakText(text);

    // 首行缩进由 TextBreaker 的 textIndent（2em）实现。
    // 注意：不得在 text 前拼接全角空格——那会让 text 与 charPositions 错位
    // （charPositions 是按原始文本计算的），导致绘制时每个字符右移错位、
    // 行尾字符重叠/溢出。

    // 设置 LineBox 坐标 + 传播 sup/sub 标记 + opacity
    // 首行缩进：TextBreaker 已在 breakText 中设 lb.x = textIndent（仅首行），
    // 此处保留该缩进，仅叠加容器偏移，不得覆盖。
    const startY: number = box.y + box.paddingTop + box.borderTop;
    for (let i = 0; i < result.lines.length; i++) {
      result.lines[i].x = box.x + box.paddingLeft + box.borderLeft + result.lines[i].x;
      result.lines[i].y = startY + i * lineHeight;
      result.lines[i].effectiveOpacity = cascadedOpacity;
      if (node.isSuperscript) {
        result.lines[i].isSuperscript = true;
      }
      if (node.isSubscript) {
        result.lines[i].isSubscript = true;
      }
      // Command 1 (font-synthesis): 从 computedStyle 传播字体属性以支持伪粗体/斜体
      result.lines[i].fontWeight = FauxBoldItalicRenderer.cssWeightToNumber(style.fontWeight);
      result.lines[i].fontStyle = FauxBoldItalicRenderer.cssStyleToString(style.fontStyle);
      result.lines[i].fontSynthesis = style.fontSynthesis ?? 'weight style';
      result.lines[i].fontFamily = this.getPrimaryFontFamily(node);
      // Command 2: 从父容器传播 overflow:hidden 裁剪信息
      if (parentOverflowInfo !== undefined && parentOverflowInfo.overflow === 'hidden') {
        result.lines[i].containerOverflow = 'hidden';
        result.lines[i].containerX = parentOverflowInfo.x;
        result.lines[i].containerY = parentOverflowInfo.y;
        result.lines[i].containerWidth = parentOverflowInfo.width;
        result.lines[i].containerHeight = parentOverflowInfo.height;
      }
    }

    // 累计字符偏移量（用于 text selection hit-testing）
    let globalCharOffset: number = 0;
    for (let i = 0; i < result.lines.length; i++) {
      result.lines[i].startCharOffset = globalCharOffset;
      globalCharOffset += Math.max(0, result.lines[i].text.length);
    }

    // 将 RenderNode 上的 rubyAnnotations 传播到各 LineBox
    if (node.rubyAnnotations !== undefined && node.rubyAnnotations.length > 0) {
      for (let li = 0; li < result.lines.length; li++) {
        const lb: LineBox = result.lines[li];
        const segs: LineRubySegment[] = [];
        for (let ri = 0; ri < node.rubyAnnotations.length; ri++) {
          const pair: RubyPair = node.rubyAnnotations[ri] as RubyPair;
          const idx: number = lb.text.indexOf(pair.baseText);
          if (idx >= 0) {
            segs.push({
              rubyText: pair.rubyText,
              baseStartIndex: idx,
              baseEndIndex: idx + pair.baseText.length
            });
          }
        }
        if (segs.length > 0) {
          lb.rubySegments = segs;
        }
      }
    }

    node.lineBoxes = result.lines;

    // 每行 estimatedLines = 1（TextBreaker 已精确换行）
    const totalLineCount: number = result.lines.length;
    if (totalLineCount > 0) {
      box.contentHeight = totalLineCount * lineHeight;
      box.totalHeight = box.contentHeight + box.paddingTop + box.paddingBottom
        + box.borderTop + box.borderBottom;
    }

  }

  /**
   * 替换元素布局（简化）
   */
  private layoutReplaced(node: RenderNode, box: BoxModel,
    parentHasSpecifiedHeight: boolean = false,
    parentOverflowInfo: OverflowClipInfo | undefined = undefined): void {
    // 替换元素（如 img）当前简化为占位
    box.contentWidth = this.resolveLength(node.computedStyle!.width, box.contentWidth);
    // Command 1: 百分比高度在父容器 height:auto 时无效
    box.contentHeight = this.resolveHeightValue(node.computedStyle!.height, this.viewHeight, parentHasSpecifiedHeight);
    if (box.contentWidth <= 0) {
      box.contentWidth = 100;
    }
    if (box.contentHeight <= 0) {
      box.contentHeight = 100;
    }

    // 图片节点 → 独占一页
    if (node.tagName === 'img' || node.tagName === 'image') {
      const lb: LineBox = createEmptyLineBox();
      lb.text = '';
      lb.imageSrc = node.attributes['imageSrc'] || '';
      lb.x = box.x + box.paddingLeft + box.borderLeft;
      lb.y = box.y + box.paddingTop + box.borderTop;
      lb.width = box.contentWidth;
      lb.height = this.viewHeight; // 独占一页
      lb.ascent = 0;
      lb.descent = 0;
      // Command 2: 从父容器传播 overflow:hidden 裁剪信息
      if (parentOverflowInfo !== undefined && parentOverflowInfo.overflow === 'hidden') {
        lb.containerOverflow = 'hidden';
        lb.containerX = parentOverflowInfo.x;
        lb.containerY = parentOverflowInfo.y;
        lb.containerWidth = parentOverflowInfo.width;
        lb.containerHeight = parentOverflowInfo.height;
      }
      node.lineBoxes = [lb];
      box.contentHeight = this.viewHeight;
      box.totalHeight = box.contentHeight + box.paddingTop + box.paddingBottom + box.borderTop + box.borderBottom;
    }

    // <math> MathML 公式 — 使用 MathMLRenderer 测量尺寸，创建带 mathMlExpr 的 LineBox
    if (node.tagName === 'math' && node.mathMlAst !== undefined) {
      const expr: MathMlExpression = node.mathMlAst;
      const fontSizeVal: number = this.resolveLength(node.computedStyle!.fontSize, box.contentWidth);
      const opts: MathMlRenderOptions = {
        fontSize: fontSizeVal > 0 ? fontSizeVal : this.baseFontSize,
        fontFamily: 'HarmonyOS Sans',
        color: '#000000',
        lineWidth: Math.max(1, fontSizeVal / 24),
        fractionLineExtra: fontSizeVal * 0.15,
        radicalExtra: fontSizeVal * 0.05,
        scriptScale: 0.65,
        scriptOffset: 0.4
      };
      const measure: MathMlMeasure = MathMLRenderer.measure(expr, opts);
      const contentW: number = Math.max(measure.width, 1);
      const contentH: number = Math.max(measure.height, fontSizeVal);
      box.contentWidth = contentW;
      box.contentHeight = contentH;

      const lb: LineBox = createEmptyLineBox();
      lb.text = '';
      lb.x = box.x + box.paddingLeft + box.borderLeft;
      lb.y = box.y + box.paddingTop + box.borderTop;
      lb.width = contentW;
      lb.height = contentH;
      lb.ascent = measure.baseline;
      lb.descent = contentH - measure.baseline;
      lb.mathMlExpr = expr;
      if (parentOverflowInfo !== undefined && parentOverflowInfo.overflow === 'hidden') {
        lb.containerOverflow = 'hidden';
        lb.containerX = parentOverflowInfo.x;
        lb.containerY = parentOverflowInfo.y;
        lb.containerWidth = parentOverflowInfo.width;
        lb.containerHeight = parentOverflowInfo.height;
      }
      node.lineBoxes = [lb];
      box.totalHeight = contentH + box.paddingTop + box.paddingBottom + box.borderTop + box.borderBottom;
    }

    // <svg> 内联 SVG — 使用 SvgRenderer 解析 viewport，创建带 svgDoc 的 LineBox
    if (node.tagName === 'svg' && node.svgAst !== undefined) {
      // 封面场景：<svg><image xlink:href="cover.jpg"/></svg> — SVG 容器携带了
      // imageSrc（HtmlParser 提取），此时按整页图片渲染而非空 SVG。
      const svgImageSrc: string = node.attributes['imageSrc'] ?? '';
      if (svgImageSrc.length > 0) {
        const lb: LineBox = createEmptyLineBox();
        lb.text = '';
        lb.imageSrc = svgImageSrc;
        lb.x = box.x + box.paddingLeft + box.borderLeft;
        lb.y = box.y + box.paddingTop + box.borderTop;
        lb.width = box.contentWidth > 0 ? box.contentWidth : 100;
        lb.height = this.viewHeight; // 封面独占一页
        lb.ascent = 0;
        lb.descent = 0;
        if (parentOverflowInfo !== undefined && parentOverflowInfo.overflow === 'hidden') {
          lb.containerOverflow = 'hidden';
          lb.containerX = parentOverflowInfo.x;
          lb.containerY = parentOverflowInfo.y;
          lb.containerWidth = parentOverflowInfo.width;
          lb.containerHeight = parentOverflowInfo.height;
        }
        node.lineBoxes = [lb];
        box.contentHeight = this.viewHeight;
        box.totalHeight = box.contentHeight + box.paddingTop + box.paddingBottom + box.borderTop + box.borderBottom;
        return;
      }
      const svgDoc: SvgDocument = node.svgAst;
      const resolvedW: number = this.resolveLength(node.computedStyle!.width, box.contentWidth);
      const resolvedH: number = this.resolveHeightValue(node.computedStyle!.height, this.viewHeight,
        parentHasSpecifiedHeight);
      const svgW: number = svgDoc.width !== null ? svgDoc.width : (resolvedW > 0 ? resolvedW : 200);
      const svgH: number = svgDoc.height !== null ? svgDoc.height : (resolvedH > 0 ? resolvedH : 200);
      box.contentWidth = svgW;
      box.contentHeight = svgH;

      const lb: LineBox = createEmptyLineBox();
      lb.text = '';
      lb.x = box.x + box.paddingLeft + box.borderLeft;
      lb.y = box.y + box.paddingTop + box.borderTop;
      lb.width = svgW;
      lb.height = svgH;
      lb.ascent = svgH;
      lb.descent = 0;
      lb.svgDoc = svgDoc;
      if (parentOverflowInfo !== undefined && parentOverflowInfo.overflow === 'hidden') {
        lb.containerOverflow = 'hidden';
        lb.containerX = parentOverflowInfo.x;
        lb.containerY = parentOverflowInfo.y;
        lb.containerWidth = parentOverflowInfo.width;
        lb.containerHeight = parentOverflowInfo.height;
      }
      node.lineBoxes = [lb];
      box.totalHeight = svgH + box.paddingTop + box.paddingBottom + box.borderTop + box.borderBottom;
    }
  }

  /**
   * Check if all children of a container are CSS floats (clearfix detection).
   * Used for Command 2: all-float container clearfix height auto.
   * Skips <br> elements as they don't affect layout.
   */
  private allChildrenAreFloat(children: RenderNode[]): boolean {
    if (children.length === 0) {
      return false;
    }
    for (let i = 0; i < children.length; i++) {
      const child: RenderNode = children[i];
      if (child.tagName === 'br') {
        continue;
      }
      if (child.computedStyle!.float === CssFloat.NONE) {
        return false;
      }
    }
    return true;
  }

  /**
   * Command 1: 解析高度值，百分比高度在父容器 height:auto 时返回 0
   */
  private resolveHeightValue(length: CssLength, contextSize: number, parentHasSpecifiedHeight: boolean): number {
    if (length.type === CssValueType.PERCENT && !parentHasSpecifiedHeight) {
      return 0; // 父容器高度 auto → 百分比高度无效
    }
    return this.resolveLength(length, contextSize);
  }

  /**
   * Command 2: 计算子节点应继承的 overflow 裁剪信息
   * - 如果当前节点有 overflow:hidden → 使用当前节点的内容区
   * - 否则 → 传递父容器的 overflow 信息
   */
  private computeChildOverflowInfo(node: RenderNode, box: BoxModel,
    parentOverflowInfo: OverflowClipInfo | undefined): OverflowClipInfo | undefined {
    const myOverflow: string = node.computedStyle!.overflow;
    if (myOverflow === 'hidden') {
      return {
        overflow: 'hidden',
        x: box.x + box.paddingLeft + box.borderLeft,
        y: box.y + box.paddingTop + box.borderTop,
        width: box.contentWidth,
        height: box.contentHeight,
      };
    }
    return parentOverflowInfo;
  }

  /**
   * 解析 CSS 长度值为像素
   */
  private resolveLength(length: CssLength, contextSize: number): number {
    if (length.type === CssValueType.INHERITED || length.type === CssValueType.UNSPECIFIED) {
      return 0;
    }
    if (length.type === CssValueType.SCREEN_PX) {
      return length.value;
    }
    if (length.type === CssValueType.PX) {
      return length.value / 256;
    }
    if (length.type === CssValueType.PT) {
      return length.value / 256 * 1.333; // 1pt ≈ 1.333px
    }
    if (length.type === CssValueType.EM) {
      return length.value / 256 * this.baseFontSize;
    }
    if (length.type === CssValueType.PERCENT) {
      return contextSize * length.value / (256 * 100);
    }
    if (length.type === CssValueType.VW) {
      return this.viewWidth * length.value / (256 * 100);
    }
    if (length.type === CssValueType.VH) {
      return this.viewHeight * length.value / (256 * 100);
    }
    if (length.type === CssValueType.MM) {
      return length.value / 256 * 3.78; // 1mm ≈ 3.78px
    }
    if (length.type === CssValueType.CM) {
      return length.value / 256 * 37.8; // 1cm ≈ 37.8px
    }
    if (length.type === CssValueType.IN) {
      return length.value / 256 * 96; // 1in = 96px
    }
    if (length.type === CssValueType.PC) {
      return length.value / 256 * 16; // 1pc = 16px
    }
    return 0;
  }

  /**
   * 解析 CSS 字号值，返回像素字号
   *
   * @param cssLength CSS font-size 值
   * @param parentFontSize 父元素已解析的像素字号（用于 EM）
   * @returns 像素字号（>0），若未指定则返回 -1
   */
  private resolveCssFontSize(cssLength: CssLength, parentFontSize: number): number {
    if (cssLength.type === CssValueType.UNSPECIFIED) {
      return -1; // 未指定，由调用方回退至 baseFontSize
    }
    if (cssLength.type === CssValueType.EM) {
      // 1em = 父元素字号
      const emValue: number = cssLength.value / 256;
      return parentFontSize * emValue;
    }
    // 其他绝对/相对单位直接解析
    return this.resolveLength(cssLength, this.viewWidth);
  }

  /**
   * 计算节点的实际字号（含 CSS 解析 + 用户缩放）
   */
  private computeNodeFontSize(node: RenderNode, parentFontSize: number): number {
    const style: CssStyleSet = node.computedStyle!;
    const cssFontSize: number = this.resolveCssFontSize(style.fontSize, parentFontSize);
    const base: number = cssFontSize > 0 ? cssFontSize : this.baseFontSize;
    return Math.max(1, base);
  }

  /**
   * 获取当前节点的 primary font-family (字符串形式)
   */
  private getPrimaryFontFamily(node: RenderNode): string {
    const style: CssStyleSet = node.computedStyle!;
    const familyEnum: CssFontFamily = style.fontFamily;
    return this.cssFontFamilyToString(familyEnum);
  }

  /**
   * 将 CssFontFamily 枚举映射为字体家族名称字符串
   */
  private cssFontFamilyToString(family: CssFontFamily): string {
    if (family === CssFontFamily.SERIF) {
      return 'serif';
    }
    if (family === CssFontFamily.SANS_SERIF) {
      return 'sans-serif';
    }
    if (family === CssFontFamily.MONOSPACE) {
      return 'monospace';
    }
    if (family === CssFontFamily.CURSIVE) {
      return 'cursive';
    }
    if (family === CssFontFamily.FANTASY) {
      return 'fantasy';
    }
    return 'sans-serif';
  }

  /**
   * 解析行高
   */
  private resolveLineHeight(length: CssLength, fontSize: number): number {
    if (length.type === CssValueType.UNSPECIFIED && length.value === CssGenericValue.NORMAL) {
      return fontSize * ReadingMetrics.LINE_HEIGHT_RATIO;
    }
    const resolved: number = this.resolveLength(length, this.viewWidth);
    if (resolved > 0) {
      return resolved;
    }
    return fontSize * ReadingMetrics.LINE_HEIGHT_RATIO;
  }

  /**
   * 解析边框宽度
   */
  private resolveBorderWidth(style: number, length: CssLength, contextSize: number): number {
    if (style === CssBorderStyle.NONE) {
      return 0;
    }
    return this.resolveLength(length, contextSize);
  }

  /**
   * 估算文本宽度（px）
   * 简化：全角字符算 2 单位，半角算 1 单位，乘以字号
   */
  private estimateTextWidth(text: string, fontSize: number): number {
    let charCount: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      // 全角/宽字符: CJK 汉字、CJK 扩展、CJK 部首、CJK 兼容
      if ((code >= 0x2E80 && code <= 0x9FFF) ||
          (code >= 0xF900 && code <= 0xFAFF) ||
          (code >= 0xFE30 && code <= 0xFE6F) ||
          (code >= 0xFF01 && code <= 0xFF60) ||
          (code >= 0xFFE0 && code <= 0xFFE6)) {
        charCount += 2;
      } else if ((code >= 0x0020 && code <= 0x007E) ||
                 (code >= 0xFF61 && code <= 0xFFDC) ||
                 (code >= 0xFFE8 && code <= 0xFFEE)) {
        // 半角字符: ASCII 字母/数字/符号、半角假名、半角符号
        charCount += 1;
      } else {
        // 未识别的，按半角处理
        charCount += 1;
      }
    }
    return charCount * fontSize * ReadingMetrics.CHAR_WIDTH_COEFFICIENT;
  }
}
