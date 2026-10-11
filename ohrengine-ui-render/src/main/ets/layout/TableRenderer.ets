/**
 * 表格渲染器
 * 参考 CSS 2.2 表格模型 + FixedTableLayout 算法
 *
 * 职责：
 * 1. FixedTableLayout：等宽列 + colspan/rowspan 解析
 * 2. BorderCollapse：边框合并模型（CSS border-collapse: collapse）
 * 3. TableRowHeightCalculator：行高计算（内容自适应）
 * 4. TableCanvasRenderer：画布绘制（网格线 + 单元格内容 + 背景色，支持内嵌图片/列表）
 * 5. PageBreak：大表格跨页自动分页
 *
 * 入口：
 *   TableRenderer.layout(table, tableWidth) → GridResult
 *   TableRenderer.render(ctx, result, startX, startY) → void
 */

import type { RenderNode, TableElement, TableRow, TableCell,
              GridResult, GridCell } from 'ohrengine-common';

// ──────────────────────────────────────────────
// 公共接口
// ──────────────────────────────────────────────

/**
 * 表格分页信息 — 用于跨页自动换页
 */
export interface TablePageBreakInfo {
  totalHeight: number;       // 表格完整高度
  canSplit: boolean;         // 是否允许跨页
  preferredSplitPoints: number[];  // 建议分页位置（行号）
}

// ──────────────────────────────────────────────
// 边框合并模型
// ──────────────────────────────────────────────

/**
 * 边框水平段
 */
export interface BorderHSegment {
  row: number;
  colStart: number;
  colEnd: number;
  y: number;
  width: number;       // 实际像素宽度
  style: number;       // 0=none, 1=solid
}

/**
 * 边框垂直段
 */
export interface BorderVSegment {
  col: number;
  rowStart: number;
  rowEnd: number;
  x: number;
  width: number;
  style: number;
}

/**
 * 合并边框布局
 */
export interface CollapsedBorders {
  horizontals: BorderHSegment[];
  verticals: BorderVSegment[];
}

// ──────────────────────────────────────────────
// 内部常量
// ──────────────────────────────────────────────

const BORDER_WIDTH: number = 1;        // 边框宽 1vp
const CELL_PADDING_H: number = 6;      // 单元格水平内边距 6vp
const CELL_PADDING_V: number = 3;      // 单元格垂直内边距 3vp
const FONT_SIZE: number = 14;          // 单元格字号 14vp
const DEFAULT_MIN_ROW_HEIGHT: number = 24; // 最小行高

// ──────────────────────────────────────────────
// 主类
// ──────────────────────────────────────────────

export class TableRenderer {

  /**
   * 书籍资源根目录 — 用于解析 <img src> 为绝对路径
   */
  public bookBasePath: string = '';

  /**
   * 固定布局算法：等宽列 → 解析 colspan/rowspan → 计算行高 → 生成网格（可选分页检测）
   *
   * @param table      表格元素
   * @param tableWidth 表格可用宽度
   * @param pageHeight 可选：分页高度（大表格跨页检测用，不传则不检测）
   */
  public layout(table: TableElement, tableWidth: number, pageHeight?: number): GridResult {
    if (table.rows.length === 0) {
      return this.emptyResult(tableWidth);
    }

    // Step 1: 确定列数 = 各行的 colspan 之和的最大值
    const columnCount: number = this.resolveColumnCount(table);

    // Step 2: FixedTableLayout — 等宽列（扣除边框）
    const borderCount: number = columnCount + 1;
    const usableWidth: number = Math.max(0, tableWidth - borderCount * BORDER_WIDTH);
    const colWidths: number[] = this.fixedColumnLayout(columnCount, usableWidth);

    // Step 3: 解析 colspan/rowspan → 建立网格占用矩阵
    const spanState: SpanState = this.resolveSpans(table, columnCount);

    // Step 4: 计算行高
    const rowHeights: number[] = this.calculateRowHeights(table, spanState, colWidths);

    // Step 4a: 跨页分页检测（当 pageHeight 参数传入时）
    let breakPoints: number[] | undefined = undefined;
    if (pageHeight !== undefined && pageHeight > 0) {
      breakPoints = this.checkPageBreak(pageHeight, rowHeights);
    }

    // Step 5: 构建 GridResult（包括坐标计算）
    const cells: GridCell[] = this.buildGrid(table, spanState, colWidths, rowHeights);

    const totalWidth: number = tableWidth;
    let totalHeight: number = 0;
    for (let ri = 0; ri < rowHeights.length; ri++) {
      totalHeight += rowHeights[ri];
    }
    totalHeight += (rowHeights.length + 1) * BORDER_WIDTH; // 行间 + 底边框

    return {
      columns: columnCount,
      rows: rowHeights.length,
      colWidths: colWidths,
      rowHeights: rowHeights,
      cells: cells,
      totalWidth: totalWidth,
      totalHeight: totalHeight,
      breakPoints: breakPoints
    };
  }

  /**
   * 在画布上绘制表格
   *
   * @param ctx    Canvas 上下文
   * @param result layout() 返回的网格结果
   * @param startX 绘制起点 X
   * @param startY 绘制起点 Y
   */
  public render(ctx: CanvasRenderingContext2D, result: GridResult,
                startX: number, startY: number,
                fontUnit: string = 'vp', densityScale: number = 1): void {
    // Step 1: 填充单元格背景
    for (let ci = 0; ci < result.cells.length; ci++) {
      const cell: GridCell = result.cells[ci];
      if (cell.bgColor !== undefined && cell.bgColor !== '') {
        ctx.fillStyle = cell.bgColor;
        ctx.fillRect(startX + cell.x, startY + cell.y, cell.width, cell.height);
      }
    }

    // Step 2: 绘制边框（collapse 模型，外边框粗 1.5x）
    ctx.strokeStyle = '#000000';
    ctx.lineWidth = BORDER_WIDTH;

    // 垂直线
    const borderCount: number = result.columns + 1;
    for (let bi = 0; bi < borderCount; bi++) {
      const x: number = startX + bi * (result.colWidths[bi - 1] ?? 0) + bi * BORDER_WIDTH;
      // 使用 colWidths 累加计算更可靠
    }

    // 用网格坐标统一绘制
    this.drawGridBorders(ctx, result, startX, startY);

    // Step 3: 绘制单元格内容（文本 + 图片 + 嵌套列表）
    for (let ci = 0; ci < result.cells.length; ci++) {
      const cell: GridCell = result.cells[ci];
      this.renderCellContent(ctx, cell, startX, startY, fontUnit, densityScale);
    }
  }

  // ──────────────────────────────────────────
  // 内部方法
  // ──────────────────────────────────────────

  private emptyResult(tableWidth: number): GridResult {
    return {
      columns: 0,
      rows: 0,
      colWidths: [],
      rowHeights: [],
      cells: [],
      totalWidth: tableWidth,
      totalHeight: 0,
      breakPoints: undefined
    };
  }

  /**
   * 确定表格的列数 = 各行的 colspan 之和的最大值
   */
  private resolveColumnCount(table: TableElement): number {
    let maxCols: number = 0;
    for (let ri = 0; ri < table.rows.length; ri++) {
      const row: TableRow = table.rows[ri];
      let colSpanTotal: number = 0;
      for (let ci = 0; ci < row.cells.length; ci++) {
        const cell: TableCell = row.cells[ci];
        colSpanTotal += Math.max(1, cell.colspan);
      }
      if (colSpanTotal > maxCols) {
        maxCols = colSpanTotal;
      }
    }
    return Math.max(1, maxCols);
  }

  /**
   * FixedTableLayout：所有列等宽
   */
  private fixedColumnLayout(columnCount: number, usableWidth: number): number[] {
    const widths: number[] = [];
    const colW: number = usableWidth / columnCount;
    for (let i = 0; i < columnCount; i++) {
      widths.push(colW);
    }
    return widths;
  }

  /**
   * 网格占用状态：记录每个格子被 rowspan 占用的列
   */
  private resolveSpans(table: TableElement, columnCount: number): SpanState {
    const maxRows: number = table.rows.length;
    // occupied[row][col] = remaining rows of span
    const occ: number[][] = [];
    for (let ri = 0; ri < maxRows; ri++) {
      const row: number[] = [];
      for (let ci = 0; ci < columnCount; ci++) {
        row.push(0);
      }
      occ.push(row);
    }

    // 填充占用矩阵
    for (let ri = 0; ri < maxRows; ri++) {
      let col: number = 0;
      for (let ci = 0; ci < table.rows[ri].cells.length; ci++) {
        const cell: TableCell = table.rows[ri].cells[ci];
        // 跳过已被 rowspan 占用的列
        while (col < columnCount && occ[ri][col] > 0) {
          col++;
        }
        if (col >= columnCount) {
          break;
        }
        const spanCols: number = Math.max(1, cell.colspan);
        const spanRows: number = Math.max(1, cell.rowspan);
        const endCol: number = Math.min(col + spanCols, columnCount);
        const endRow: number = Math.min(ri + spanRows, maxRows);
        // 标记占用
        for (let rr = ri; rr < endRow; rr++) {
          for (let cc = col; cc < endCol; cc++) {
            occ[rr][cc] = 1;
          }
        }
        col = endCol;
      }
    }

    return {
      occupied: occ,
      columnCount: columnCount
    };
  }

  /**
   * 计算行高：每行取最大内容高度（简化为等高）
   */
  private calculateRowHeights(table: TableElement, state: SpanState,
                               colWidths: number[]): number[] {
    const maxRows: number = table.rows.length;
    const heights: number[] = [];
    for (let ri = 0; ri < maxRows; ri++) {
      let maxCellHeight: number = DEFAULT_MIN_ROW_HEIGHT;
      const row: TableRow = table.rows[ri];
      for (let ci = 0; ci < row.cells.length; ci++) {
        const cell: TableCell = row.cells[ci];
        // 估算文本行数
        const spanCols: number = Math.max(1, cell.colspan);
        let cellWidth: number = 0;
        for (let c = 0; c < spanCols && c < colWidths.length; c++) {
          cellWidth += colWidths[c];
        }
        cellWidth = Math.max(1, cellWidth - CELL_PADDING_H * 2);
        const estimatedLines: number = Math.max(1,
          Math.ceil(cell.text.length / Math.max(1, cellWidth / (FONT_SIZE * 0.6))));
        const contentH: number = estimatedLines * FONT_SIZE * 1.4;
        if (contentH > maxCellHeight) {
          maxCellHeight = contentH;
        }
      }
      heights.push(maxCellHeight);
    }
    return heights;
  }

  /**
   * 构建 GridCell 列表，计算每个单元格的坐标和尺寸
   */
  private buildGrid(table: TableElement, state: SpanState,
                    colWidths: number[], rowHeights: number[]): GridCell[] {
    const cells: GridCell[] = [];
    const maxRows: number = table.rows.length;
    const columnCount: number = state.columnCount;

    // 计算每列的 X 偏移
    const colX: number[] = [];
    let accX: number = BORDER_WIDTH; // 左外边框
    for (let ci = 0; ci < columnCount; ci++) {
      colX.push(accX);
      accX += colWidths[ci] + BORDER_WIDTH;
    }

    // 计算每行的 Y 偏移
    const rowY: number[] = [];
    let accY: number = BORDER_WIDTH; // 上外边框
    for (let ri = 0; ri < maxRows; ri++) {
      rowY.push(accY);
      accY += rowHeights[ri] + BORDER_WIDTH;
    }

    // 遍历单元格
    for (let ri = 0; ri < maxRows; ri++) {
      let col: number = 0;
      for (let ci = 0; ci < table.rows[ri].cells.length; ci++) {
        const cell: TableCell = table.rows[ri].cells[ci];
        // 跳过被 rowspan 占用的列
        while (col < columnCount && state.occupied[ri][col] > 0) {
          col++;
        }
        if (col >= columnCount) {
          break;
        }
        const spanCols: number = Math.max(1, cell.colspan);
        const spanRows: number = Math.max(1, cell.rowspan);
        const endCol: number = Math.min(col + spanCols, columnCount);
        const endRow: number = Math.min(ri + spanRows, maxRows);

        // 计算合并后的宽高
        let w: number = 0;
        for (let cc = col; cc < endCol; cc++) {
          w += colWidths[cc];
        }
        w += (endCol - col - 1) * BORDER_WIDTH; // 内部边框

        let h: number = 0;
        for (let rr = ri; rr < endRow; rr++) {
          h += rowHeights[rr];
        }
        h += (endRow - ri - 1) * BORDER_WIDTH; // 内部边框

        const gridCell: GridCell = {
          row: ri,
          col: col,
          rowspan: spanRows,
          colspan: spanCols,
          x: colX[col],
          y: rowY[ri],
          width: w,
          height: h,
          text: cell.text,
          bgColor: cell.bgColor,
          align: cell.align,
          imageSrc: cell.imageSrc,
          children: cell.children
        };
        cells.push(gridCell);

        col = endCol;
      }
    }

    return cells;
  }

  /**
   * 跨页分页检测
   *
   * 从 rowHeights 计算出建议的分页位置（行下标），规则：
   * - 如果总高度 ≤ pageHeight，返回空数组（不分页）
   * - 否则，在累积高度超过 pageHeight 且超过 30% 阈值处切分
   *
   * @param pageHeight 页面可用高度
   * @param rowHeights 各行高度数组
   * @returns 分页行下标数组（按升序排列）
   */
  public checkPageBreak(pageHeight: number, rowHeights: number[]): number[] {
    if (rowHeights.length === 0 || pageHeight <= 0) {
      return [];
    }
    let totalHeight: number = 0;
    for (let i = 0; i < rowHeights.length; i++) {
      totalHeight += rowHeights[i];
    }
    totalHeight += (rowHeights.length + 1) * BORDER_WIDTH; // 包括边框高度
    if (totalHeight <= pageHeight) {
      return [];
    }

    const breakPoints: number[] = [];
    let accumulated: number = BORDER_WIDTH; // 上边框
    for (let r = 0; r < rowHeights.length; r++) {
      const rowH: number = rowHeights[r];
      const nextAcc: number = accumulated + rowH + BORDER_WIDTH;
      if (nextAcc > pageHeight && accumulated > pageHeight * 0.3) {
        // 在此行之前切分（已经累积超过 30% 才切，避免太小的头段）
        breakPoints.push(r);
        accumulated = BORDER_WIDTH; // 新页重置，从边框开始
        // 将当前行计入新页
        accumulated += rowH + BORDER_WIDTH;
      } else {
        accumulated = nextAcc;
      }
    }
    return breakPoints;
  }

  /**
   * 渲染单个单元格内容 — 支持文本 / 图片 / 嵌套列表组合
   *
   * @param ctx    Canvas 上下文
   * @param cell   GridCell 单元格数据
   * @param startX 表格绘制起点 X
   * @param startY 表格绘制起点 Y
   */
  private renderCellContent(ctx: CanvasRenderingContext2D, cell: GridCell,
                            startX: number, startY: number,
                            fontUnit: string = 'vp', densityScale: number = 1): void {
    const cellX: number = startX + cell.x;
    const cellY: number = startY + cell.y;
    const cellW: number = cell.width;
    const cellH: number = cell.height;

    // 有自定义子节点（嵌套列表等）→ 用 renderInnerList
    if (cell.children !== undefined && cell.children.length > 0) {
      this.renderInnerList(ctx, cell.children, cellX, cellY, cellW, cellH, fontUnit, densityScale);
      return;
    }

    // 有图片 → 绘制图片（文本 fallback）
    if (cell.imageSrc !== undefined && cell.imageSrc.length > 0) {
      this.renderCellImage(ctx, cell, cellX, cellY, fontUnit, densityScale);
      return;
    }

    // 纯文本 → 居中绘制
    ctx.fillStyle = '#000000';
    ctx.font = (FONT_SIZE * densityScale) + fontUnit + ' HarmonyOS Sans, sans-serif';
    ctx.textBaseline = 'middle';
    let textX: number = cellX + CELL_PADDING_H;
    if (cell.align === 'right') {
      const textW: number = ctx.measureText(cell.text).width;
      textX = cellX + cellW - CELL_PADDING_H - textW;
    } else if (cell.align === 'center') {
      const textW: number = ctx.measureText(cell.text).width;
      textX = cellX + (cellW - textW) / 2;
    }
    const textY: number = cellY + cellH / 2;
    ctx.fillText(cell.text, textX, textY);
  }

  /**
   * 渲染嵌套列表（<ul> / <ol> 子节点）到单元格中
   */
  private renderInnerList(ctx: CanvasRenderingContext2D, nodes: RenderNode[],
                          cellX: number, cellY: number, cellW: number, cellH: number,
                          fontUnit: string = 'vp', densityScale: number = 1): void {
    // 使用简化渲染：每行显示一个子节点的文本内容
    ctx.fillStyle = '#000000';
    ctx.font = (FONT_SIZE * densityScale) + fontUnit + ' HarmonyOS Sans, sans-serif';
    ctx.textBaseline = 'top';
    const lineH: number = FONT_SIZE * 1.4;
    let yOff: number = CELL_PADDING_V;
    for (let i = 0; i < nodes.length; i++) {
      const text: string = this.extractListText(nodes[i]);
      if (text.length > 0) {
        if (yOff + lineH > cellH) {
          break; // 超出单元格高度截断
        }
        ctx.fillText(text, cellX + CELL_PADDING_H, cellY + yOff);
        yOff += lineH;
      }
    }
  }

  /**
   * 提取 RenderNode 的纯文本表示（递归遍历文本节点）
   */
  private extractListText(node: RenderNode): string {
    if (node.text !== undefined && node.text.length > 0) {
      return node.text;
    }
    if (node.children !== undefined) {
      let result: string = '';
      for (let i = 0; i < node.children.length; i++) {
        result += this.extractListText(node.children[i]);
      }
      return result;
    }
    return '';
  }

  /**
   * 渲染单元格内嵌图片
   *
   * TODO: 实际图片加载（需要异步 image.createImageSource），此版本占位渲染
   */
  private renderCellImage(ctx: CanvasRenderingContext2D, cell: GridCell,
                          cellX: number, cellY: number,
                          fontUnit: string = 'vp', densityScale: number = 1): void {
    // 绘制图片路径文本作为占位
    ctx.fillStyle = '#888888';
    ctx.font = ((FONT_SIZE - 2) * densityScale) + fontUnit + ' HarmonyOS Sans, sans-serif';
    ctx.textBaseline = 'middle';
    const imgLabel: string = '[img] ' + cell.imageSrc!;
    ctx.fillText(imgLabel, cellX + CELL_PADDING_H, cellY + cell.height / 2);
  }

  /**
   * 将相对路径解析为绝对路径（基于 bookBasePath）
   */
  private resolvePath(relativePath: string): string {
    if (relativePath.startsWith('/')) {
      return relativePath;
    }
    if (relativePath.startsWith('file://')) {
      return relativePath;
    }
    if (this.bookBasePath.length > 0) {
      return this.bookBasePath + '/' + relativePath;
    }
    return relativePath;
  }

  /**
   * 绘制表格网格边框（collapse 风格）
   */
  private drawGridBorders(ctx: CanvasRenderingContext2D, result: GridResult,
                          startX: number, startY: number): void {
    // 外边框加粗
    ctx.lineWidth = BORDER_WIDTH;

    // 水平线
    for (let ri = 0; ri <= result.rows; ri++) {
      const y: number = startY + ri * BORDER_WIDTH;
      let yAcc: number = startY;
      for (let rr = 0; rr < ri; rr++) {
        yAcc += result.rowHeights[rr] + BORDER_WIDTH;
      }
      const yPos: number = yAcc;
      ctx.beginPath();
      ctx.moveTo(startX, yPos);
      ctx.lineTo(startX + result.totalWidth, yPos);
      ctx.stroke();
    }

    // 垂直线
    for (let ci = 0; ci <= result.columns; ci++) {
      let xAcc: number = startX;
      for (let cc = 0; cc < ci; cc++) {
        xAcc += result.colWidths[cc] + BORDER_WIDTH;
      }
      const xPos: number = xAcc;
      ctx.beginPath();
      ctx.moveTo(xPos, startY);
      ctx.lineTo(xPos, startY + result.totalHeight);
      ctx.stroke();
    }
  }
}

// ──────────────────────────────────────────────
// 内部辅助类型
// ──────────────────────────────────────────────

/**
 * Span 状态：记录网格占用矩阵
 */
interface SpanState {
  occupied: number[][];
  columnCount: number;
}
