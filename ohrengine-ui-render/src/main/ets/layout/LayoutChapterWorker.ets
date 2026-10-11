/**
 * LayoutChapterWorker — 章节纯布局 TaskPool 实验（Phase 15）
 *
 * 边界：Worker 只做「输入快照 → 纯计算 → LayoutResult」，绝不触碰
 * PageManager / PageSlot / UI / Session。结果回到主线程由 PipelineManager 验证后提交。
 *
 * 覆盖真实主线程 Live 布局的等价语义：
 *   HtmlParser.parse → buildRenderTree(compiled) → LayoutEngine.layout → PageSplitter.splitChapter
 * 输入（ChapterSnapshot）为 JSON 字符串（html + cssText + 排版参数 + 视口）。
 * 输出（LayoutResult）为 PageCacheManager.serializePaginatedChapter 序列化字符串。
 */
import { HtmlParser, CssParser, StyleSource } from 'ohrengine-parsers';
import { StyleMapper } from '../style/StyleMapper.ets';
import { compileRuleSet, CompiledStylesheet } from '../style/CssCompiler.ets';
import { createCssRuleSet } from 'ohrengine-parsers';
import type { CssRuleSet, StyleSheet } from 'ohrengine-parsers';
import { LayoutEngine } from './LayoutEngine.ets';
import { PageSplitter } from './PageSplitter.ets';
import type { PaginatedChapter } from './PageSplitter.ets';
import type { DomNode, RenderNode } from 'ohrengine-common';
import { PageCacheManager, createEmptyLineBox } from 'ohrengine-common';
import type { CacheChapter, LineBox } from 'ohrengine-common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { justify } from '../typography/JustifyEngine.ets';
import { TextBreaker } from '../typography/TextBreaker.ets';

/** 主线程 ↔ Worker 的输入快照（仅包含真正需要的排版/视口参数） */
export interface ChapterLayoutSnapshot {
  html: string;
  cssText: string;
  baseFontSize: number;
  lineSpacing: number;
  letterSpacing: number;
  wordSpacing: number;
  textAlign: string;
  fontFamily: string;
  viewWidth: number;
  viewHeight: number;
  href: string;
  /** 屏幕密度（vp/px 换算；justify 复刻需要） */
  density: number;
  /** Phase 16.1 一次性字段级体积实验开关（单个后台章开启，诊断用） */
  measureOnce: boolean;
}

/** Phase 16.2 分档重建结果（仅本文件诊断类型） */
export interface RebuildCase {
  ms: number;
  chars: number;
  matched: number;
  total: number;
}

/**
 * Phase 15 实验：TaskPool 中完成单章 parse+layout+split。
 * 严格使用 import 变量（@Concurrent 约束）；不引用 UI/引擎实例。
 */
@Concurrent
export async function layoutChapterConcurrent(inputJson: string): Promise<string | null> {
  try {
    const wT0: number = Date.now();
    const input: ChapterLayoutSnapshot = JSON.parse(inputJson) as ChapterLayoutSnapshot;
    // 1) 复刻 PipelineManager.loadAndCompileCss 的编译路径（纯计算）
    const cssParser: CssParser = new CssParser();
    const styleMapper: StyleMapper = new StyleMapper();
    const styleSheet: StyleSheet = cssParser.parseStyleSheet(input.cssText, StyleSource.USER_AGENT);
    styleMapper.loadUserAgentStyleSheet(input.cssText);
    const ruleSet: CssRuleSet = createCssRuleSet();
    for (let i: number = 0; i < styleSheet.rules.length; i++) {
      ruleSet.rules.push(styleSheet.rules[i]);
    }
    const compiled: CompiledStylesheet = compileRuleSet(ruleSet, StyleSource.USER_AGENT);

    // 2) 纯 DOM → RenderTree
    const tParse: number = Date.now();
    const htmlParser: HtmlParser = new HtmlParser();
    const domTree: DomNode = htmlParser.parse(input.html);
    const tTree: number = Date.now();
    const renderTree: RenderNode[] = htmlParser.buildRenderTree(domTree, compiled, styleMapper, undefined);
    const tTreeEnd: number = Date.now();
    if (renderTree.length === 0) {
      return null;
    }

    // 3) 布局
    const layoutEngine: LayoutEngine = new LayoutEngine();
    layoutEngine.setViewport(input.viewWidth, input.viewHeight);
    layoutEngine.setBaseFontSize(input.baseFontSize);
    layoutEngine.setLineSpacing(input.lineSpacing);
    layoutEngine.setLetterSpacing(input.letterSpacing);
    layoutEngine.setWordSpacing(input.wordSpacing);
    layoutEngine.setTextAlign(input.textAlign as 'left' | 'right' | 'center' | 'justify');
    if (input.fontFamily.length > 0) {
      layoutEngine.setFontFamily(input.fontFamily);
    }
    const tLayout: number = Date.now();
    layoutEngine.layout(renderTree);
    const tSplit: number = Date.now();

    // 4) 分页
    const pageSplitter: PageSplitter = new PageSplitter();
    pageSplitter.setConfig({
      viewWidth: input.viewWidth,
      viewHeight: input.viewHeight,
      orphanLines: 2,
      widowLines: 2,
      avoidBreakInside: true
    });
    const paginated = pageSplitter.splitChapter(renderTree, input.href);
    const tSerialize: number = Date.now();

    // Phase 16.3 惰性传输序列化：结构与 L2 相同，行盒剔除 charPositions/charWidths
    //（兼容 deserializePaginatedChapter：缺字段 numArrOr → []）。
    const buildLazyJson = (pc: PaginatedChapter): string => {
      const pagesRaw: Object[] = [];
      for (let pgi = 0; pgi < pc.pages.length; pgi++) {
        const pg = pc.pages[pgi];
        const linesOut: Object[] = [];
        for (let li = 0; li < pg.lines.length; li++) {
          const lb = pg.lines[li];
          const sl: Record<string, Object> = {};
          sl['text'] = lb.text; sl['x'] = lb.x; sl['y'] = lb.y;
          sl['width'] = lb.width; sl['height'] = lb.height;
          sl['ascent'] = lb.ascent; sl['descent'] = lb.descent;
          sl['isSoftBreak'] = lb.isSoftBreak; sl['estimatedLines'] = lb.estimatedLines;
          sl['isLastLineOfParagraph'] = lb.isLastLineOfParagraph; sl['isCJK'] = lb.isCJK;
          sl['effectiveOpacity'] = lb.effectiveOpacity; sl['startCharOffset'] = lb.startCharOffset;
          sl['renderedY'] = lb.renderedY;
          if (lb.imageSrc !== undefined) { sl['imageSrc'] = lb.imageSrc; }
          if (lb.fontFamilyList !== undefined) { sl['fontFamilyList'] = lb.fontFamilyList; }
          if (lb.rubySegments !== undefined) { sl['rubySegmentsJson'] = JSON.stringify(lb.rubySegments); }
          if (lb.isSuperscript !== undefined) { sl['isSuperscript'] = lb.isSuperscript; }
          if (lb.isSubscript !== undefined) { sl['isSubscript'] = lb.isSubscript; }
          if (lb.listMarker !== undefined) { sl['listMarker'] = lb.listMarker; }
          if (lb.listMarkerX !== undefined) { sl['listMarkerX'] = lb.listMarkerX; }
          if (lb.listMarkerFontSize !== undefined) { sl['listMarkerFontSize'] = lb.listMarkerFontSize; }
          if (lb.listMarkerColor !== undefined) { sl['listMarkerColor'] = lb.listMarkerColor; }
          if (lb.markerImageSrc !== undefined) { sl['markerImageSrc'] = lb.markerImageSrc; }
          if (lb.listLevel !== undefined) { sl['listLevel'] = lb.listLevel; }
          if (lb.gridResult !== undefined) { sl['gridResultJson'] = JSON.stringify(lb.gridResult); }
          if (lb.isFloat !== undefined) { sl['isFloat'] = lb.isFloat; }
          if (lb.marginTop !== undefined) { sl['marginTop'] = lb.marginTop; }
          if (lb.marginRight !== undefined) { sl['marginRight'] = lb.marginRight; }
          if (lb.marginBottom !== undefined) { sl['marginBottom'] = lb.marginBottom; }
          if (lb.marginLeft !== undefined) { sl['marginLeft'] = lb.marginLeft; }
          if (lb.containerOverflow !== undefined) { sl['containerOverflow'] = lb.containerOverflow; }
          if (lb.containerX !== undefined) { sl['containerX'] = lb.containerX; }
          if (lb.containerY !== undefined) { sl['containerY'] = lb.containerY; }
          if (lb.containerWidth !== undefined) { sl['containerWidth'] = lb.containerWidth; }
          if (lb.containerHeight !== undefined) { sl['containerHeight'] = lb.containerHeight; }
          if (lb.fontWeight !== undefined) { sl['fontWeight'] = lb.fontWeight; }
          if (lb.fontStyle !== undefined) { sl['fontStyle'] = lb.fontStyle; }
          if (lb.fontSynthesis !== undefined) { sl['fontSynthesis'] = lb.fontSynthesis; }
          if (lb.fontFamily !== undefined) { sl['fontFamily'] = lb.fontFamily; }
          if (lb.mathMlExpr !== undefined) { sl['mathMlExprJson'] = JSON.stringify(lb.mathMlExpr); }
          if (lb.svgDoc !== undefined) { sl['svgDocJson'] = JSON.stringify(lb.svgDoc); }
          linesOut.push(sl);
        }
        const sp: Record<string, Object> = {};
        sp['index'] = pg.index; sp['lines'] = linesOut;
        sp['startLineIndex'] = pg.startLineIndex; sp['endLineIndex'] = pg.endLineIndex;
        sp['startPosition'] = pg.startPosition; sp['endPosition'] = pg.endPosition;
        sp['hasPageBreakBefore'] = pg.hasPageBreakBefore; sp['isEmpty'] = pg.isEmpty;
        sp['yOffset'] = pg.yOffset;
        if (pg.startChar !== undefined) { sp['startChar'] = pg.startChar; }
        if (pg.endChar !== undefined) { sp['endChar'] = pg.endChar; }
        pagesRaw.push(sp);
      }
      const root: Record<string, Object> = {};
      root['href'] = pc.href; root['pages'] = pagesRaw;
      root['totalPages'] = pc.totalPages; root['totalLineCount'] = pc.totalLineCount;
      root['isStub'] = pc.isStub;
      return JSON.stringify(root);
    };
    const outJson: string = buildLazyJson(paginated);
    const wT1: number = Date.now();
    hilog.info(0x0000, 'OhEngine',
      'LAYOUT_WORKER_COMPUTE derive=%{public}d parse=%{public}dms tree=%{public}dms layout=%{public}dms split=%{public}dms serialize=%{public}dms total=%{public}dms nodes=%{public}d out=%{public}d',
      tParse - wT0, tTree - tParse, tTreeEnd - tTree, tSplit - tLayout, tSerialize - tSplit,
      wT1 - tSerialize, wT1 - wT0, renderTree.length, outJson.length);
    // Phase 16.2/16.3：按行逐字几何「按需重建」对照实验（仅 measureOnce 章）。
    // 基线 = worker 内序列化前 paginated（完整数组）——与恢复算法逐一致比较。
    if (input.measureOnce && outJson !== null) {
      try {
        const fullWidth: number = input.viewWidth * 0.99;
        let done: boolean = false;
        const collectLines = (pc: PaginatedChapter): LineBox[] => {
          const out: LineBox[] = [];
          for (let pgi = 0; pgi < pc.pages.length; pgi++) {
            const pLines = pc.pages[pgi].lines;
            for (let li = 0; li < pLines.length; li++) {
              out.push(pLines[li]);
            }
          }
          return out;
        };
        const rebuildOne = (pl: LineBox, mode: string): boolean => {
          const prodPos: number[] | undefined = pl.charPositions;
          const prodW: number[] | undefined = pl.charWidths;
          if (mode === 'justify' && pl.isLastLineOfParagraph) {
            return (prodPos === undefined || prodPos.length === 0) &&
              (prodW === undefined || prodW.length === 0);
          }
          const copy: LineBox = createEmptyLineBox();
          copy.text = pl.text;
          copy.x = pl.x;
          copy.y = pl.y;
          copy.width = pl.width;
          copy.height = pl.height;
          copy.ascent = pl.ascent;
          copy.isCJK = pl.isCJK;
          copy.isLastLineOfParagraph = pl.isLastLineOfParagraph;
          if (mode === 'justify') {
            justify(copy, Math.max(1, fullWidth - copy.x), input.density);
          } else {
            const n: number = copy.text.length;
            copy.charPositions = new Array<number>(n);
            copy.charWidths = new Array<number>(n);
            let cursor: number = copy.x;
            const fillFont: number = copy.ascent > 0 ? copy.ascent : input.baseFontSize;
            for (let ci = 0; ci < n; ci++) {
              const ch: string = copy.text[ci];
              copy.charPositions[ci] = cursor;
              const cw: number = TextBreaker.charSlotWidth(ch, fillFont) +
                input.letterSpacing +
                ((ch === ' ' || ch === '\u00A0') ? input.wordSpacing : 0);
              copy.charWidths[ci] = cw;
              cursor += cw;
            }
          }
          if (prodPos === undefined || prodW === undefined) {
            return (copy.charPositions === undefined || copy.charPositions.length === 0) &&
              (copy.charWidths === undefined || copy.charWidths.length === 0);
          }
          if (prodPos.length !== copy.charPositions.length || prodW.length !== copy.charWidths.length) {
            if (!done) {
              done = true;
              hilog.info(0x0000, 'OhEngine',
                'GEOM_DEBUG mode=%{public}s lenMismatch prod=%{public}d copy=%{public}d text=%{public}s x=%{public}d',
                mode, prodPos.length, copy.charPositions.length, pl.text, pl.x);
            }
            return false;
          }
          for (let ci = 0; ci < prodPos.length; ci++) {
            if (Math.abs(prodPos[ci] - copy.charPositions[ci]) > 0.001) {
              if (!done) {
                done = true;
                hilog.info(0x0000, 'OhEngine',
                  'GEOM_DEBUG mode=%{public}s ci=%{public}d pos prod=%{public}.1f copy=%{public}.1f w prod=%{public}.1f copy=%{public}.1f x=%{public}.1f text=%{public}s',
                  mode, ci, prodPos[ci], copy.charPositions[ci],
                  prodW[ci], copy.charWidths[ci], pl.x, pl.text.substring(0, 10));
              }
              return false;
            }
            if (Math.abs(prodW[ci] - copy.charWidths[ci]) > 0.001) {
              if (!done) {
                done = true;
                hilog.info(0x0000, 'OhEngine',
                  'GEOM_DEBUG mode=%{public}s ci=%{public}d wProd=%{public}d wCopy=%{public}d posProd=%{public}d posCopy=%{public}d x=%{public}d len=%{public}d c=%{public}s',
                  mode, ci, Math.round(prodW[ci]), Math.round(copy.charWidths[ci]),
                  Math.round(prodPos[ci]), Math.round(copy.charPositions[ci]),
                  Math.round(pl.x), pl.text.length, pl.text.charAt(0));
              }
              return false;
            }
          }
          return true;
        };
        const runMode = (mode: string, allLines: LineBox[]): void => {
          const runCase = (count: number): RebuildCase => {
            const n: number = Math.min(count, allLines.length);
            const t0: number = Date.now();
            let matched: number = 0;
            let chars: number = 0;
            for (let i = 0; i < n; i++) {
              if (rebuildOne(allLines[i], mode)) {
                matched++;
              }
              chars += allLines[i].text.length;
            }
            const r: RebuildCase = { ms: Date.now() - t0, chars: chars, matched: matched, total: n };
            return r;
          };
          const c1: RebuildCase = runCase(1);
          const c10: RebuildCase = runCase(10);
          const c50: RebuildCase = runCase(50);
          const cFull: RebuildCase = runCase(allLines.length);
          hilog.info(0x0000, 'OhEngine',
            'GEOM_EXP mode=%{public}s lines=%{public}d c1=%{public}dms(%{public}d/%{public}d) c10=%{public}dms(%{public}d/%{public}d) c50=%{public}dms(%{public}d/%{public}d) full=%{public}dms(%{public}d/%{public}d) chars=%{public}d',
            mode, allLines.length,
            c1.ms, c1.matched, c1.total,
            c10.ms, c10.matched, c10.total,
            c50.ms, c50.matched, c50.total,
            cFull.ms, cFull.matched, cFull.total,
            cFull.chars);
        };
        // justify：直接使用本次布局产物（golden=序列化前数组）
        runMode('justify', collectLines(paginated));
        // left / right / center：同 html 重新排版（每次独立 parse+layout，避免渲染树残留）
        const modes: string[] = ['left', 'right', 'center'];
        for (let mi = 0; mi < modes.length; mi++) {
          const m: string = modes[mi];
          const hp: HtmlParser = new HtmlParser();
          const dv: DomNode = hp.parse(input.html);
          const tr: RenderNode[] = hp.buildRenderTree(dv, compiled, styleMapper, undefined);
          const le: LayoutEngine = new LayoutEngine();
          le.setViewport(input.viewWidth, input.viewHeight);
          le.setBaseFontSize(input.baseFontSize);
          le.setLineSpacing(input.lineSpacing);
          le.setLetterSpacing(input.letterSpacing);
          le.setWordSpacing(input.wordSpacing);
          le.setTextAlign(m as 'left' | 'right' | 'center' | 'justify');
          if (input.fontFamily.length > 0) {
            le.setFontFamily(input.fontFamily);
          }
          le.layout(tr);
          const sp: PageSplitter = new PageSplitter();
          sp.setConfig({
            viewWidth: input.viewWidth, viewHeight: input.viewHeight,
            orphanLines: 2, widowLines: 2, avoidBreakInside: true
          });
          const pc2: PaginatedChapter = sp.splitChapter(tr, input.href);
          runMode(m, collectLines(pc2));
        }
      } catch (_e) {
        hilog.info(0x0000, 'OhEngine', 'GEOM_EXP N/A');
      }
    }
    return outJson;
  } catch (_e) {
    return null;
  }
}