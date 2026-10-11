/**
 * 分页器
 * 参考：crengine LVDocView 分页逻辑 + Readium Page.progression
 *
 * 职责：
 * 1. 接收 LayoutEngine 布局后的 RenderNode[]（含行盒）
 * 2. 按视口高度将内容切割为页面
 * 3. 计算每个资源（章节）内的当前位置 / 进度
 * 4. 处理分页边界（标题避首尾、widow/orphan）
 * 5. 输出：Page[] 供渲染层消费
 */

import { createEmptyLineBox } from 'ohrengine-common';
import type { RenderNode, LineBox } from 'ohrengine-common';
import { GridResult, TableElement } from 'ohrengine-common';
import { CssPageBreak, CssVisibility } from 'ohrengine-common';
import { Locator, createLocator } from 'ohrengine-common';

/**
 * 单个页面的数据
 */
export interface Page {
  index: number;
  lines: LineBox[];
  startLineIndex: number;
  endLineIndex: number;
  startPosition: number; // 0~1 在章节内的进度
  endPosition: number;
  hasPageBreakBefore: boolean;
  isEmpty: boolean;
  yOffset: number;
  /** Phase 2 PageRange: 页起始 logical char（章内全局 UTF-16 offset） */
  startChar?: number;
  /** Phase 2 PageRange: 页结束 logical char（章内全局 UTF-16 offset） */
  endChar?: number;
}

export function createEmptyPage(index: number): Page {
  return {
    index: index,
    lines: [],
    startLineIndex: 0,
    endLineIndex: 0,
    startPosition: 0,
    endPosition: 0,
    hasPageBreakBefore: false,
    isEmpty: true,
    yOffset: 0
  };
}

/**
 * 分页结果 — 整个资源（章节）的页面集合
 */
export interface PaginatedChapter {
  href: string;
  pages: Page[];
  totalPages: number;
  totalLineCount: number;
  /**
   * true — placeholder chapter created before layout (stub pages);
   * false — chapter produced by real layout (PageSplitter.splitChapter,
   * FXL single page, or an empty chapter processed by the layout queue).
   */
  isStub: boolean;
}

export function createPaginatedChapter(href: string): PaginatedChapter {
  return {
    href: href,
    pages: [],
    totalPages: 0,
    totalLineCount: 0,
    isStub: true
  };
}

/**
 * 分页配置
 */
export interface PaginationConfig {
  viewWidth: number;
  viewHeight: number;
  orphanLines: number;
  widowLines: number;
  avoidBreakInside: boolean;
}

export function createDefaultPaginationConfig(width: number, height: number): PaginationConfig {
  return {
    viewWidth: width,
    viewHeight: height,
    orphanLines: 2,
    widowLines: 2,
    avoidBreakInside: true
  };
}

/**
 * 分页器
 *
 * 使用方式：
 *   const splitter: PageSplitter = new PageSplitter();
 *   splitter.setConfig({ viewWidth: 720, viewHeight: 1080 });
 *   const chapter: PaginatedChapter = splitter.splitChapter(renderNodes, 'chapter1.xhtml');
 */
export class PageSplitter {
  private config: PaginationConfig = createDefaultPaginationConfig(720, 1000);

  constructor() {
  }

  /**
   * 设置分页配置
   */
  public setConfig(config: PaginationConfig): void {
    this.config = config;
  }

  /**
   * 对一个章节的渲染节点进行分页
   */
  public splitChapter(nodes: RenderNode[], href: string): PaginatedChapter {
    const result: PaginatedChapter = createPaginatedChapter(href);
    result.isStub = false;
    const allLines: LineBox[] = this.collectLines(nodes);
    result.totalLineCount = allLines.length;

    if (allLines.length === 0) {
      const emptyPage: Page = createEmptyPage(0);
      result.pages.push(emptyPage);
      result.totalPages = 1;
      return result;
    }

    const viewH: number = this.config.viewHeight;

    let currentPageStart: number = 0;
    let pageIndex: number = 0;
    // Phase 2 PageRange: 章内全局 logical char 游标（跨页面累计）
    let runningChar: number = 0;

    while (currentPageStart < allLines.length) {
      let pageEnd: number = currentPageStart;
      let pageContentHeight: number = 0;
      while (pageEnd < allLines.length) {
        const line: LineBox = allLines[pageEnd];
        if (line.imageSrc !== undefined && line.imageSrc.length > 0) {
          if (pageEnd > currentPageStart) { break; }
          pageEnd++;
          break;
        }
        const lineH: number = Math.max(1, line.height);
        if (pageContentHeight + lineH > viewH && pageContentHeight > 0) {
          break;
        }
        if (pageContentHeight + lineH > viewH && pageContentHeight === 0) {
          pageContentHeight += lineH;
          pageEnd++;
          break;
        }
        pageContentHeight += lineH;
        pageEnd++;
      }

      // 强制至少一行
      if (pageEnd === currentPageStart) {
        pageEnd = currentPageStart + 1;
        if (pageEnd > allLines.length) {
          pageEnd = allLines.length;
        }
      }

      // 孤儿行检查：如果下一页剩下行数 < orphanLines，合并到当前页
      const remainingLines: number = allLines.length - pageEnd;
      if (remainingLines > 0 && remainingLines < this.config.orphanLines &&
          pageEnd > currentPageStart) {
        while (pageEnd < allLines.length) {
          const orphanLineH: number = Math.max(1, allLines[pageEnd].height);
          pageContentHeight += orphanLineH;
          pageEnd++;
        }
      }

      // 寡妇行检查：如果当前页只有最后 < widowLines 行，且不是第一页，则合并到上一页
      // （需要回溯修改前一页 pageEnd，当前只作占位）
      // if (pageIndex > 0 && (pageEnd - currentPageStart) < this.config.widowLines) {
      //   TODO: 回溯到前一页合并
      // }

      const page: Page = createEmptyPage(pageIndex);
      for (let i = currentPageStart; i < pageEnd && i < allLines.length; i++) {
        page.lines.push(allLines[i]);
      }
      page.startLineIndex = currentPageStart;
      page.endLineIndex = pageEnd - 1;
      page.startPosition = currentPageStart / allLines.length;
      page.endPosition = (pageEnd - 1) / allLines.length;
      page.isEmpty = false;
      page.yOffset = 0;
      // Phase 2 PageRange: 页起止 logical char（章内全局，跨页累计）。
      let pageStartChar: number = runningChar;
      let pageEndChar: number = runningChar;
      for (let li = 0; li < page.lines.length; li++) {
        pageEndChar += (page.lines[li].text !== undefined ? page.lines[li].text.length : 0);
      }
      runningChar = pageEndChar;
      page.startChar = pageStartChar;
      page.endChar = pageEndChar;

      result.pages.push(page);
      currentPageStart = pageEnd;
      pageIndex++;
    }

    result.totalPages = result.pages.length;
    return result;
  }

  /**
   * 根据 Locator 查找所在页面索引
   */
  public findPageByLocator(chapter: PaginatedChapter, locator: Locator): number {
    if (locator.progression === undefined) {
      return 0;
    }
    for (let i = 0; i < chapter.pages.length; i++) {
      const page: Page = chapter.pages[i];
      if (locator.progression >= page.startPosition &&
          locator.progression <= page.endPosition) {
        return i;
      }
    }
    return 0;
  }

  /**
   * 从章节页码生成 Locator
   */
  public pageToLocator(href: string, chapter: PaginatedChapter, pageIndex: number): Locator {
    const clampedIndex: number = Math.max(0, Math.min(pageIndex, chapter.pages.length - 1));
    const page: Page = chapter.pages[clampedIndex];
    const progression: number = (page.startPosition + page.endPosition) / 2;
    return createLocator(href, progression);
  }

  /**
   * 从渲染节点中收集所有行盒
   */
  private collectLines(nodes: RenderNode[]): LineBox[] {
    const allLines: LineBox[] = [];
    for (let i = 0; i < nodes.length; i++) {
      this.collectLinesFromNode(nodes[i], allLines);
    }
    return allLines;
  }

  /**
   * 递归从节点收集行盒
   */
  private collectLinesFromNode(node: RenderNode, lines: LineBox[]): void {
    // 表格节点：注入合成行盒（不走 lineBoxes）
    if (node.tableData !== undefined) {
      const td: TableElement = node.tableData as TableElement;
      if (td.gridResult === undefined) { return; }
      const gridResult: GridResult = td.gridResult;
      const tableLine: LineBox = createEmptyLineBox();
      tableLine.gridResult = gridResult;
      tableLine.height = gridResult.totalHeight;
      lines.push(tableLine);
      return; // 表格内部子节点已包含在 gridResult 中，不递归
    }

    // 加入当前节点的行盒
    for (let i = 0; i < node.lineBoxes.length; i++) {
      lines.push(node.lineBoxes[i]);
    }

    // 递归子节点
    for (let i = 0; i < node.children.length; i++) {
      this.collectLinesFromNode(node.children[i], lines);
    }
  }
}
