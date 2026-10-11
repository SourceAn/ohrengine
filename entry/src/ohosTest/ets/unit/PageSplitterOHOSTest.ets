/**
 * PageSplitterOhosTest — OhosTest (hypium) unit tests for PageSplitter
 *
 * Covers: empty render nodes, single page fitting,
 *         multi-page split, orphan line control,
 *         empty page fallback
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  PageSplitter, Page, PaginatedChapter, PaginationConfig,
  createDefaultPaginationConfig
} from 'ohrengine-ui-render';
import {
  RenderNode, LineBox, createEmptyLineBox
} from 'ohrengine-common';
import { createDefaultCssStyleSet } from 'ohrengine-common';

function makeNode(lines: LineBox[]): RenderNode {
  return {
    tagName: 'p',
    text: undefined,
    attributes: {},
    computedStyle: createDefaultCssStyleSet(),
    isBlock: true,
    isReplaced: false,
    children: [],
    lineBoxes: lines,
    elementNode: undefined,
    boxModel: undefined,
    effectiveOpacity: 1.0
  };
}

function makeLine(text: string, height: number): LineBox {
  const line: LineBox = createEmptyLineBox();
  line.text = text;
  line.height = height;
  line.width = 720;
  line.y = 0;
  return line;
}

export default function pageSplitterTest() {
  describe('PageSplitterTest', () => {
    it('empty_nodes_returns_empty_chapter', 0, () => {
      const splitter: PageSplitter = new PageSplitter();
      splitter.setConfig(createDefaultPaginationConfig(720, 1000));
      const chapter: PaginatedChapter = splitter.splitChapter([], 'test.xhtml');
      expect(chapter.totalPages).assertEqual(1);
      expect(chapter.pages[0].isEmpty).assertTrue();
    });

    it('single_page_when_content_fits', 0, () => {
      const splitter: PageSplitter = new PageSplitter();
      splitter.setConfig(createDefaultPaginationConfig(720, 500));
      const lines: LineBox[] = [];
      for (let i = 0; i < 5; i++) {
        lines.push(makeLine(`Line ${i}`, 24));
      }
      const chapter: PaginatedChapter = splitter.splitChapter([makeNode(lines)], 'test.xhtml');
      expect(chapter.totalPages).assertEqual(1);
    });

    it('multi_page_split', 0, () => {
      const splitter: PageSplitter = new PageSplitter();
      splitter.setConfig(createDefaultPaginationConfig(720, 100));
      const lines: LineBox[] = [];
      for (let i = 0; i < 50; i++) {
        lines.push(makeLine(`Line ${i}`, 24));
      }
      const chapter: PaginatedChapter = splitter.splitChapter([makeNode(lines)], 'test.xhtml');
      expect(chapter.totalPages).assertLarger(1);
    });

    it('orphan_lines_prevent_single_line_page', 0, () => {
      const splitter: PageSplitter = new PageSplitter();
      // orphanLines=3 → any page with ≤3 leftover lines merges into previous
      splitter.setConfig({ viewWidth: 720, viewHeight: 200, orphanLines: 3, widowLines: 2, avoidBreakInside: true });
      // 24 lines × 24vp = 576vp, page height 200vp → ~8 lines/page, last orphan band
      const lines: LineBox[] = [];
      for (let i = 0; i < 24; i++) {
        lines.push(makeLine(`Line ${i}`, 24));
      }
      const chapter: PaginatedChapter = splitter.splitChapter([makeNode(lines)], 'test.xhtml');
      // orphan=3 ensures no page has <3 lines at the end
      for (let p = 0; p < chapter.pages.length; p++) {
        const pageLines: number = chapter.pages[p].lines.length;
        if (p === chapter.pages.length - 1 && chapter.pages[p].isEmpty) {
          continue; // skip empty last page
        }
        if (pageLines > 0 && pageLines <= 3) {
          // This page should only exist if it's the only page
          expect(chapter.pages.length).assertEqual(1);
        }
      }
    });

    it('page_structure_correct', 0, () => {
      const splitter: PageSplitter = new PageSplitter();
      splitter.setConfig(createDefaultPaginationConfig(720, 100));
      const lines: LineBox[] = [];
      for (let i = 0; i < 10; i++) {
        lines.push(makeLine(`L${i}`, 24));
      }
      const chapter: PaginatedChapter = splitter.splitChapter([makeNode(lines)], 'test.xhtml');
      expect(chapter.totalPages).assertLarger(0);
      expect(chapter.href).assertEqual('test.xhtml');
      for (let p = 0; p < chapter.pages.length; p++) {
        expect(chapter.pages[p].index).assertEqual(p);
      }
    });

    it('page_break_image_gets_own_page', 0, () => {
      const splitter: PageSplitter = new PageSplitter();
      splitter.setConfig(createDefaultPaginationConfig(720, 500));
      // 图片行（imageSrc 非空）应独占一页（PageSplitter 对 imageSrc 行强制整页）
      const imgLine: LineBox = makeLine('', 400);
      imgLine.imageSrc = 'cover.jpg';
      const textLine: LineBox = makeLine('After image', 24);
      const chapter: PaginatedChapter = splitter.splitChapter([makeNode([imgLine, textLine])], 'img.xhtml');
      expect(chapter.totalPages).assertEqual(2);
    });

    it('single_line_always_placed_even_if_taller_than_page', 0, () => {
      const splitter: PageSplitter = new PageSplitter();
      splitter.setConfig(createDefaultPaginationConfig(720, 50));
      // 行高超过页面高度 → 强制放一页，不产生空页
      const bigLine: LineBox = makeLine('Tall line', 200);
      const chapter: PaginatedChapter = splitter.splitChapter([makeNode([bigLine])], 'tall.xhtml');
      expect(chapter.totalPages).assertEqual(1);
      expect(chapter.pages[0].lines.length).assertEqual(1);
    });

    it('orphan_lines_merge_into_previous_page', 0, () => {
      const splitter: PageSplitter = new PageSplitter();
      // 页面高度容纳 4 行/页，orphanLines=3 → 剩余 ≤3 行并入上一页
      splitter.setConfig({ viewWidth: 720, viewHeight: 96, orphanLines: 3, widowLines: 2, avoidBreakInside: true });
      const lines: LineBox[] = [];
      for (let i = 0; i < 11; i++) {
        lines.push(makeLine(`L${i}`, 24));
      }
      const chapter: PaginatedChapter = splitter.splitChapter([makeNode(lines)], 'orphan.xhtml');
      // 11 行 / 4 行每页 = 2 页 + 3 行孤儿并入第 2 页 → 2 页（每页 4 行，末页 3 行并入后为 7 行?）
      // 实际：孤儿检测把剩余 3 行并入 → 避免仅 3 行孤页
      expect(chapter.totalPages).assertEqual(2);
    });

    it('multi_node_chapter_accumulates_all_lines', 0, () => {
      const splitter: PageSplitter = new PageSplitter();
      splitter.setConfig(createDefaultPaginationConfig(720, 1000));
      const n1: RenderNode = makeNode([makeLine('A', 24), makeLine('B', 24)]);
      const n2: RenderNode = makeNode([makeLine('C', 24), makeLine('D', 24)]);
      const chapter: PaginatedChapter = splitter.splitChapter([n1, n2], 'multi.xhtml');
      expect(chapter.totalLineCount).assertEqual(4);
    });
  });
}
