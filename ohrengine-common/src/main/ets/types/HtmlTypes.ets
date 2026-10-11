/**
 * HtmlTypes — Shared HTML/DOM type definitions
 *
 * Extracted from HtmlParser.ets during modularization.
 * These types are used across ohrengine-common, ohrengine-parsers,
 * and ohrengine-ui-render modules.
 */

import { CssStyleSet } from '../document/CssDefinitions.ets';

/**
 * MathML expression tree node
 */
export interface MathMlExpression {
  type: 'fraction' | 'radical' | 'superscript' | 'subscript' | 'text' | 'placeholder';
  children?: MathMlExpression[];
  value?: string;
  numerator?: MathMlExpression;
  denominator?: MathMlExpression;
  radicand?: MathMlExpression;
  base?: MathMlExpression;
  script?: MathMlExpression;
}

/**
 * A 2D point used in SVG polyline/polygon point arrays.
 */
export interface SvgPoint {
  x: number;
  y: number;
}

/**
 * SVG viewBox rectangle.
 */
export interface SvgViewBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

/**
 * A single SVG shape primitive for canvas rendering.
 */
export interface SvgShape {
  type: string;
  x?: number;
  y?: number;
  w?: number;
  h?: number;
  cx?: number;
  cy?: number;
  r?: number;
  rx?: number;
  ry?: number;
  x1?: number;
  y1?: number;
  x2?: number;
  y2?: number;
  points?: SvgPoint[];
  commands?: string[];
  content?: string;
  fontSize?: number;
  fill?: string;
  stroke?: string;
  strokeWidth?: number;
}

/**
 * Parsed SVG document data.
 */
export interface SvgDocument {
  shapes: SvgShape[];
  viewBox: SvgViewBox | null;
  width: number | null;
  height: number | null;
}

/**
 * Box model — rendering node final layout dimensions.
 */
export interface BoxModel {
  marginTop: number;
  marginRight: number;
  marginBottom: number;
  marginLeft: number;
  borderTop: number;
  borderRight: number;
  borderBottom: number;
  borderLeft: number;
  paddingTop: number;
  paddingRight: number;
  paddingBottom: number;
  paddingLeft: number;
  contentWidth: number;
  contentHeight: number;
  totalWidth: number;
  totalHeight: number;
  x: number;
  y: number;
}

export function createBoxModel(): BoxModel {
  return {
    marginTop: 0, marginRight: 0, marginBottom: 0, marginLeft: 0,
    borderTop: 0, borderRight: 0, borderBottom: 0, borderLeft: 0,
    paddingTop: 0, paddingRight: 0, paddingBottom: 0, paddingLeft: 0,
    contentWidth: 0, contentHeight: 0,
    totalWidth: 0, totalHeight: 0,
    x: 0, y: 0
  };
}

/**
 * DOM node type enum.
 */
export enum DomNodeType {
  DOCUMENT = 'document',
  ELEMENT = 'element',
  TEXT = 'text',
  COMMENT = 'comment'
}

/**
 * Lightweight DOM node.
 */
export interface DomNode {
  nodeType: DomNodeType;
  tagName: string | undefined;
  text: string | undefined;
  attributes: Record<string, string>;
  children: DomNode[];
  parent: DomNode | undefined;
  styleSet: CssStyleSet | undefined;
}

export function createTextNode(text: string): DomNode {
  return {
    nodeType: DomNodeType.TEXT,
    tagName: undefined,
    text: text,
    attributes: {},
    children: [],
    parent: undefined,
    styleSet: undefined
  };
}

export function createElementNode(tagName: string): DomNode {
  return {
    nodeType: DomNodeType.ELEMENT,
    tagName: tagName,
    text: undefined,
    attributes: {},
    children: [],
    parent: undefined,
    styleSet: undefined
  };
}

export function createDocumentNode(): DomNode {
  return {
    nodeType: DomNodeType.DOCUMENT,
    tagName: undefined,
    text: undefined,
    attributes: {},
    children: [],
    parent: undefined,
    styleSet: undefined
  };
}

/**
 * RenderNode — layout engine input unit.
 */
export interface RenderNode {
  tagName: string | undefined;
  text: string | undefined;
  attributes: Record<string, string>;
  computedStyle: CssStyleSet | undefined;
  isBlock: boolean;
  isReplaced: boolean;
  children: RenderNode[];
  lineBoxes: LineBox[];
  elementNode: DomNode | undefined;
  boxModel: BoxModel | undefined;
  rubyAnnotations?: object[];
  isSuperscript?: boolean;
  isSubscript?: boolean;
  isListItem?: boolean;
  listLevel?: number;
  listMarker?: string;
  markerWidth?: number;
  markerFontSize?: number;
  markerColor?: string;
  markerImageSrc?: string;
  listReversed?: boolean;
  listItemIndex?: number;
  listTotalItems?: number;
  listStartOffset?: number;
  tableData?: Object;
  floatDirection?: 'none' | 'left' | 'right';
  effectiveOpacity: number;
  mathMlAst?: MathMlExpression;
  svgAst?: SvgDocument;
}

/**
 * LineBox — single text line layout result.
 */
export interface LineBox {
  text: string;
  x: number;
  y: number;
  width: number;
  height: number;
  ascent: number;
  descent: number;
  isSoftBreak: boolean;
  imageSrc?: string;
  estimatedLines: number;
  charPositions: number[];
  isLastLineOfParagraph: boolean;
  isCJK: boolean;
  fontFamilyList?: string[];
  rubySegments?: Object[];
  isSuperscript?: boolean;
  isSubscript?: boolean;
  listMarker?: string;
  listMarkerX?: number;
  listMarkerFontSize?: number;
  listMarkerColor?: string;
  markerImageSrc?: string;
  listLevel?: number;
  gridResult?: Object;
  isFloat?: boolean;
  marginTop?: number;
  marginRight?: number;
  marginBottom?: number;
  marginLeft?: number;
  effectiveOpacity: number;
  startCharOffset: number;
  charWidths: number[];
  renderedY: number;
  containerOverflow?: string;
  containerX?: number;
  containerY?: number;
  containerWidth?: number;
  containerHeight?: number;
  fontWeight?: number;
  fontStyle?: string;
  fontSynthesis?: string;
  fontFamily?: string;
  mathMlExpr?: MathMlExpression;
  svgDoc?: SvgDocument;
}

export function createEmptyLineBox(): LineBox {
  return {
    text: '',
    x: 0,
    y: 0,
    width: 0,
    height: 0,
    ascent: 0,
    descent: 0,
    isSoftBreak: false,
    estimatedLines: 1,
    charPositions: [],
    isLastLineOfParagraph: false,
    isCJK: false,
    effectiveOpacity: 1.0,
    startCharOffset: 0,
    charWidths: [],
    renderedY: 0
  };
}

/**
 * Ruby annotation pair — base text and its ruby (furigana) annotation.
 * Unified definition (was duplicated in HtmlParser.ets / RubyRenderer.ets).
 */
export interface RubyPair {
  baseText: string;
  rubyText: string;
}

/**
 * Table element — parsed from <table>.
 * Unified definition (was duplicated in HtmlParser.ets / TableRenderer.ets).
 */
export interface TableElement {
  rows: TableRow[];
  gridResult?: GridResult;  // 由 LayoutEngine.layout() 填充
}

/**
 * Table row.
 */
export interface TableRow {
  cells: TableCell[];
}

/**
 * Table cell.
 */
export interface TableCell {
  text: string;
  colspan: number;
  rowspan: number;
  bgColor: string | undefined;
  align: string | undefined;   // 'left' | 'center' | 'right'
  imageSrc?: string;           // <img> src inside cell
  children?: RenderNode[];     // Non-text children (lists, etc.)
}

/**
 * Grid result — layout() 的输出
 */
export interface GridResult {
  columns: number;
  rows: number;
  colWidths: number[];
  rowHeights: number[];
  cells: GridCell[];
  totalWidth: number;
  totalHeight: number;
  breakPoints?: number[];          // Row indices where page breaks should occur
}

/**
 * Grid cell — 布局后的精确位置 + 尺寸
 */
export interface GridCell {
  row: number;
  col: number;
  rowspan: number;
  colspan: number;
  x: number;
  y: number;
  width: number;
  height: number;
  text: string;
  bgColor: string | undefined;
  align: string | undefined;
  imageSrc?: string;               // Propagated from TableCell
  children?: RenderNode[];         // Propagated from TableCell
}
