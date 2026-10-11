/**
 * HTML 解析器
 * 参考：crengine lvxmlparser/lvstreambuf 的 DOM 构建
 *
 * 职责：
 * 1. 将 XHTML/HTML 文本解析为 DOM 树
 * 2. 提供遍历、查询 DOM 的能力
 * 3. 结合 CSS 选择器计算元素样式
 * 4. 输出排版引擎可消费的渲染节点树
 *
 * 排版输入格式（中间表示）：
 *   渲染节点包含 tag, text, attributes, computedStyle, children
 *
 * NOTE: This file is the moved version of entry/src/main/ets/parser/HtmlParser.ets.
 * Duplicate type definitions (DomNode, RenderNode, etc.) have been removed
 * in favor of imports from ohrengine-common.
 */

import { CssStyleSet, createDefaultCssStyleSet, CssFloat,
  DomNode, DomNodeType, RenderNode,
  MathMlExpression, SvgPoint, SvgViewBox, SvgShape, SvgDocument,
  createTextNode, createElementNode, createDocumentNode,
  RubyPair, TableElement, TableRow, TableCell } from 'ohrengine-common';

// ──────────────────────────────────────────────
// Local type stubs (originally from layout/ modules)
// These are minimal interfaces used by the moved parser logic.
// ──────────────────────────────────────────────

/**
 * StyleMapper interface — only the signature used by the parser.
 * The actual implementation lives in ohrengine-ui-render.
 */
/**
 * StyleMapper — opaque interface, never inspected by the parser,
 * only passed through to the actual implementation in ohrengine-ui-render.
 */
export interface StyleMapper {
  resolveStyle(
    element: DomNode,
    parentStyle: CssStyleSet | undefined,
    compiledSheet: object | undefined
  ): CssStyleSet;
}

/**
 * CompiledStylesheet — opaque type, never inspected by the parser,
 * only passed through to StyleMapper.resolveStyle().
 */
export type CompiledStylesheet = object;

/**
 * List marker type enum.
 */
export enum ListStyleType {
  DISC = 'disc',
  CIRCLE = 'circle',
  SQUARE = 'square',
  DECIMAL = 'decimal',
  LOWER_ALPHA = 'lower-alpha',
  UPPER_ALPHA = 'upper-alpha',
  LOWER_ROMAN = 'lower-roman',
  UPPER_ROMAN = 'upper-roman',
  NONE = 'none'
}

/**
 * Convert integer to Roman numeral string (1–3999).
 */
export function toRoman(num: number): string {
  const values: number[] = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
  const numerals: string[] = ['M', 'CM', 'D', 'CD', 'C', 'XC', 'L', 'XL', 'X', 'IX', 'V', 'IV', 'I'];
  let result: string = '';
  let n: number = num;
  for (let i = 0; i < values.length; i++) {
    while (n >= values[i]) {
      result += numerals[i];
      n -= values[i];
    }
  }
  return result;
}

/**
 * Generate marker text based on index, type, and nesting level.
 *
 * @param index 0-based item index
 * @param type marker type (ListStyleType)
 * @param level nesting level (0-based, affects disc→circle→square cycling)
 * @param listStyleImage optional image URL (if set, marker text is empty)
 * @returns marker string (e.g. "•", "1.", "a.", "iii.")
 */
export function generateMarker(
  index: number,
  type: ListStyleType,
  level: number,
  listStyleImage?: string
): string {
  if (listStyleImage !== undefined && listStyleImage.length > 0) {
    return '';
  }
  switch (type) {
    case ListStyleType.DISC:
      return '\u2022';
    case ListStyleType.CIRCLE:
      return '\u25E6';
    case ListStyleType.SQUARE:
      return '\u25AA';
    case ListStyleType.DECIMAL:
      return (index + 1) + '.';
    case ListStyleType.LOWER_ALPHA: {
      if (index >= 0 && index < 26) {
        return String.fromCharCode(97 + index) + '.';
      }
      return (index + 1) + '.';
    }
    case ListStyleType.UPPER_ALPHA: {
      if (index >= 0 && index < 26) {
        return String.fromCharCode(65 + index) + '.';
      }
      return (index + 1) + '.';
    }
    case ListStyleType.LOWER_ROMAN:
      return toRoman(index + 1).toLowerCase() + '.';
    case ListStyleType.UPPER_ROMAN:
      return toRoman(index + 1) + '.';
    case ListStyleType.NONE:
      return '';
    default:
      return '\u2022';
  }
}

/**
 * Return the default unordered list marker type for a given nesting level.
 * Cycles: disc → circle → square → disc → ...
 */
export function getLevelDefaultMarkerType(level: number): ListStyleType {
  const types: ListStyleType[] = [ListStyleType.DISC, ListStyleType.CIRCLE, ListStyleType.SQUARE];
  return types[level % 3];
}

/**
 * Estimate marker text width in vp units.
 * Used for layout before precise Canvas measureText().
 */
export function estimateMarkerWidth(marker: string, fontSize: number): number {
  if (marker.length === 0) {
    return 0;
  }
  const firstChar: number = marker.charCodeAt(0);
  if (firstChar === 0x2022 || firstChar === 0x25E6 || firstChar === 0x25AA) {
    return fontSize * 0.8;
  }
  return (marker.length - 1) * fontSize * 0.6 + fontSize * 0.4;
}

/**
 * Recursively extract text content from a DomNode tree (used for <ruby> child extraction).
 */
function extractTextContent(node: DomNode): string {
  if (node.nodeType === DomNodeType.TEXT) {
    return node.text ?? '';
  }
  let result: string = '';
  const children: DomNode[] = node.children;
  for (let i = 0; i < children.length; i++) {
    result += extractTextContent(children[i]);
  }
  return result;
}

/**
 * Create a RenderNode from a tag name and optional style.
 */
export function createRenderNode(
  tagName: string | undefined,
  style: CssStyleSet | undefined
): RenderNode {
  const result: RenderNode = {
    tagName: tagName,
    text: undefined,
    attributes: {},
    computedStyle: style ?? createDefaultCssStyleSet(),
    isBlock: false,
    isReplaced: false,
    children: [],
    lineBoxes: [],
    elementNode: undefined,
    boxModel: undefined,
    isSuperscript: undefined,
    isSubscript: undefined,
    isListItem: undefined,
    listLevel: undefined,
    listMarker: undefined,
    markerWidth: undefined,
    markerFontSize: undefined,
    markerColor: undefined,
    markerImageSrc: undefined,
    listReversed: undefined,
    effectiveOpacity: 1.0,
    mathMlAst: undefined,
    svgAst: undefined
  };
  return result;
}

/**
 * HTML 解析器
 *
 * 使用方式：
 *   const parser: HtmlParser = new HtmlParser();
 *   const doc: DomNode = parser.parse(htmlText);
 *   const renderNodes: RenderNode[] = parser.buildRenderTree(doc);
 */
export class HtmlParser {
  private pos: number = 0;
  private input: string = '';

  constructor() {
  }

  /**
   * Parse HTML string into a DOM tree.
   */
  public parse(html: string): DomNode {
    this.input = html;
    this.pos = 0;
    const doc: DomNode = createDocumentNode();
    this.parseChildren(doc);
    return doc;
  }

  /**
   * Build RenderNode tree from DOM tree (with style computation).
   *
   * @param doc DOM root node
   * @param compiledSheet optional compiled stylesheet
   * @param styleMapper optional style mapper (paired with compiledSheet)
   * @param parentStyle parent element's CssStyleSet (for style inheritance)
   */
  public buildRenderTree(
    doc: DomNode,
    compiledSheet?: object,
    styleMapper?: object,
    parentStyle?: CssStyleSet
  ): RenderNode[] {
    const result: RenderNode[] = [];
    for (let i = 0; i < doc.children.length; i++) {
      const child: DomNode = doc.children[i];
      const rn: RenderNode | undefined = this.convertNode(child, compiledSheet, styleMapper, parentStyle);
      if (rn !== undefined) {
        result.push(rn);
      }
    }
    return result;
  }

  /**
   * Recursively convert a DomNode to a RenderNode.
   */
  private convertNode(
    node: DomNode,
    compiledSheet?: object,
    styleMapper?: object,
    parentStyle?: CssStyleSet
  ): RenderNode | undefined {
    if (node.tagName === 'style' || node.tagName === 'script') {
      return undefined;
    }
    if (node.tagName === 'head' || node.tagName === 'title') {
      return undefined;
    }
    if (node.nodeType === DomNodeType.TEXT) {
      const text: string = (node.text ?? '').trim();
      if (text === '') {
        return undefined;
      }
      // Text nodes use parent style
      const textStyle: CssStyleSet = parentStyle !== undefined ? parentStyle : createDefaultCssStyleSet();
      const rn: RenderNode = createRenderNode('#text', textStyle);
      rn.text = text;
      return rn;
    }

    // Compute current node style
    let nodeStyle: CssStyleSet | undefined = node.styleSet;
    if (nodeStyle === undefined && styleMapper !== undefined) {
      const sm: StyleMapper = styleMapper as StyleMapper;
      nodeStyle = sm.resolveStyle(node, parentStyle, compiledSheet);
    }
    if (nodeStyle === undefined) {
      nodeStyle = createDefaultCssStyleSet();
    }
    node.styleSet = nodeStyle;

    const rn: RenderNode = createRenderNode(node.tagName, nodeStyle);
    rn.attributes = node.attributes;
    rn.elementNode = node;

    // Fill floatDirection from computedStyle
    if (nodeStyle.float === CssFloat.LEFT) {
      rn.floatDirection = 'left';
    } else if (nodeStyle.float === CssFloat.RIGHT) {
      rn.floatDirection = 'right';
    } else {
      rn.floatDirection = 'none';
    }

    // Mark block-level elements
    const blockTags: string[] = [
      'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
      'ul', 'ol', 'li', 'blockquote', 'pre', 'table', 'tr', 'td', 'th',
      'section', 'article', 'nav', 'header', 'footer', 'aside', 'figure',
      'figcaption', 'dl', 'dt', 'dd', 'hr'
    ];
    if (node.tagName !== undefined && blockTags.indexOf(node.tagName) >= 0) {
      rn.isBlock = true;
    }

    // Mark replaced elements
    const replacedTags: string[] = ['img', 'video', 'audio', 'iframe', 'object'];
    if (node.tagName !== undefined && replacedTags.indexOf(node.tagName) >= 0) {
      rn.isReplaced = true;
    }

    // img: save src to attributes, no text output
    if (node.tagName === 'img') {
      rn.attributes['imageSrc'] = node.attributes['src'] || '';
      rn.text = undefined;
    }

    // SVG inline image tag (xlink:href)
    if (node.tagName === 'image') {
      const href: string = node.attributes['xlink:href'] || node.attributes['href'] || '';
      rn.attributes['imageSrc'] = href;
      rn.text = undefined;
      rn.isReplaced = true;
    }

    // <ruby> annotation element: extract base/rt pairs, skip recursive children
    if (node.tagName === 'ruby') {
      const pairs: RubyPair[] = [];
      let totalBaseText: string = '';
      let currentBase: string = '';
      for (let i = 0; i < node.children.length; i++) {
        const child: DomNode = node.children[i];
        if (child.nodeType === DomNodeType.TEXT) {
          const text: string = (child.text ?? '').trim();
          if (text.length > 0) {
            currentBase += text;
          }
        } else if (child.tagName === 'rt') {
          const rtText: string = extractTextContent(child).trim();
          if (currentBase.length > 0 && rtText.length > 0) {
            pairs.push({ baseText: currentBase, rubyText: rtText });
            totalBaseText += currentBase;
            currentBase = '';
          } else if (currentBase.length > 0) {
            totalBaseText += currentBase;
            currentBase = '';
          }
        } else if (child.tagName === 'rb' || child.tagName === 'rp') {
          const innerText: string = extractTextContent(child).trim();
          if (innerText.length > 0) {
            currentBase += innerText;
          }
        } else {
          const innerText: string = extractTextContent(child).trim();
          if (innerText.length > 0) {
            currentBase += innerText;
          }
        }
      }
      // Flush remaining base text (no ruby pair)
      if (currentBase.length > 0) {
        totalBaseText += currentBase;
      }
      rn.text = totalBaseText.length > 0 ? totalBaseText : undefined;
      if (pairs.length > 0) {
        rn.rubyAnnotations = pairs;
      }
      return rn;
    }

    // <sup> / <sub> superscript/subscript: extract text, set flag, skip recursion
    if (node.tagName === 'sup') {
      const innerText: string = extractTextContent(node).trim();
      if (innerText.length > 0) {
        rn.text = innerText;
      }
      rn.isSuperscript = true;
      return rn;
    }
    if (node.tagName === 'sub') {
      const innerText: string = extractTextContent(node).trim();
      if (innerText.length > 0) {
        rn.text = innerText;
      }
      rn.isSubscript = true;
      return rn;
    }

    // <li> list item: compute level, marker, index, then continue recursion
    if (node.tagName === 'li') {
      // Compute nesting level (parent ul/ol chain depth)
      let listLevel: number = 0;
      let parentCursor: DomNode | undefined = node.parent;
      while (parentCursor !== undefined) {
        if (parentCursor.tagName === 'ul' || parentCursor.tagName === 'ol') {
          listLevel++;
        }
        parentCursor = parentCursor.parent;
      }
      const effectiveLevel: number = Math.max(0, listLevel - 1); // 0-based

      // Determine list type
      let listStyleType: ListStyleType;
      const parentNode: DomNode | undefined = node.parent;
      if (parentNode !== undefined && parentNode.tagName === 'ol') {
        const typeAttr: string = parentNode.attributes['type'] || '';
        switch (typeAttr) {
          case 'a':
            listStyleType = ListStyleType.LOWER_ALPHA;
            break;
          case 'A':
            listStyleType = ListStyleType.UPPER_ALPHA;
            break;
          case 'i':
            listStyleType = ListStyleType.LOWER_ROMAN;
            break;
          case 'I':
            listStyleType = ListStyleType.UPPER_ROMAN;
            break;
          default:
            listStyleType = ListStyleType.DECIMAL;
            break;
        }
      } else {
        listStyleType = getLevelDefaultMarkerType(effectiveLevel);
      }

      // Compute index (which <li> this is in parent)
      let liIndex: number = 0;
      let totalLi: number = 0;
      if (parentNode !== undefined) {
        for (let ci = 0; ci < parentNode.children.length; ci++) {
          if (parentNode.children[ci].tagName === 'li') {
            if (parentNode.children[ci] === node) {
              liIndex = totalLi;
            }
            totalLi++;
          }
        }
      }

      // Handle <ol start="...">
      let startOffset: number = 0;
      let isReversed: boolean = false;
      if (parentNode !== undefined && parentNode.tagName === 'ol') {
        const startAttr: string = parentNode.attributes['start'] || '';
        if (startAttr.length > 0) {
          const parsed: number = parseInt(startAttr, 10);
          if (!Number.isNaN(parsed) && parsed > 0) {
            startOffset = parsed - 1;
          }
        }
        const reversedAttr: string = parentNode.attributes['reversed'] || '';
        isReversed = reversedAttr.length > 0;
      }

      const effectiveIndex: number = liIndex + startOffset;

      rn.listItemIndex = liIndex;
      rn.listTotalItems = totalLi;
      rn.listStartOffset = startOffset;

      // Generate marker text + estimate width
      const markerText: string = generateMarker(effectiveIndex, listStyleType, effectiveLevel);
      rn.isListItem = true;
      rn.listLevel = effectiveLevel;
      rn.listMarker = markerText;
      rn.markerWidth = estimateMarkerWidth(markerText, 16);
      rn.listReversed = isReversed;
      const compStyle: CssStyleSet | undefined = rn.computedStyle;
      if (compStyle !== undefined && compStyle.listStyleImage !== undefined && compStyle.listStyleImage.length > 0) {
        rn.markerImageSrc = compStyle.listStyleImage;
      }
      if (compStyle !== undefined) {
        if (compStyle.markerColor !== undefined) {
          rn.markerColor = compStyle.markerColor;
        }
        if (compStyle.markerFontSize !== undefined) {
          const resolved: number = resolveCssFontSize(compStyle.markerFontSize, 16);
          if (!Number.isNaN(resolved) && resolved > 0) {
            rn.markerFontSize = resolved;
          }
        }
      }
    }

    // <table>: build TableElement structure
    if (node.tagName === 'table') {
      const tableElement: TableElement = { rows: [] };
      for (let ti = 0; ti < node.children.length; ti++) {
        const child: DomNode = node.children[ti];
        if (child.tagName === 'tr') {
          const tableRow: TableRow = { cells: [] };
          for (let ci = 0; ci < child.children.length; ci++) {
            const cell: DomNode = child.children[ci];
            if (cell.tagName === 'td' || cell.tagName === 'th') {
              const cellText: string = extractTextContent(cell).trim();
              const colspanStr: string = cell.attributes['colspan'] || '';
              const rowspanStr: string = cell.attributes['rowspan'] || '';
              let colspan: number = 1;
              let rowspan: number = 1;
              if (colspanStr.length > 0) {
                const p: number = parseInt(colspanStr, 10);
                if (!Number.isNaN(p) && p > 0) {
                  colspan = p;
                }
              }
              if (rowspanStr.length > 0) {
                const p: number = parseInt(rowspanStr, 10);
                if (!Number.isNaN(p) && p > 0) {
                  rowspan = p;
                }
              }
              const bgColor: string | undefined = cell.attributes['bgcolor'] || undefined;
              const align: string | undefined = cell.attributes['align'] || undefined;

              // Detect <img> inside cell
              let cellImageSrc: string | undefined = undefined;
              for (let imgIdx: number = 0; imgIdx < cell.children.length; imgIdx++) {
                const cellChild: DomNode = cell.children[imgIdx];
                if (cellChild.tagName === 'img') {
                  cellImageSrc = cellChild.attributes['src'] || undefined;
                  break;
                }
              }

              // Detect non-text children (<ul>, <ol>, etc.) and convert to RenderNodes
              const cellChildren: RenderNode[] = [];
              for (let childIdx: number = 0; childIdx < cell.children.length; childIdx++) {
                const cellChild: DomNode = cell.children[childIdx];
                if (cellChild.tagName === 'ul' || cellChild.tagName === 'ol') {
                  const childRn: RenderNode | undefined = this.convertNode(
                    cellChild, compiledSheet, styleMapper, nodeStyle);
                  if (childRn !== undefined) {
                    cellChildren.push(childRn);
                  }
                }
              }

              tableRow.cells.push({
                text: cellText,
                colspan: colspan,
                rowspan: rowspan,
                bgColor: bgColor,
                align: align,
                imageSrc: cellImageSrc,
                children: cellChildren.length > 0 ? cellChildren : undefined
              });
            }
          }
          if (tableRow.cells.length > 0) {
            tableElement.rows.push(tableRow);
          }
        }
      }
      rn.tableData = tableElement;
    }

    // <math> MathML formula: extract text as placeholder, full parse by MathMLRenderer
    if (node.tagName === 'math') {
      const mathText: string = extractTextContent(node).trim();
      rn.mathMlAst = {
        type: 'placeholder',
        value: mathText.length > 0 ? mathText : '[Math]'
      };
      rn.text = undefined;
      rn.isReplaced = true;
      return rn;
    }

    // <svg> inline SVG: extract viewBox/width/height attributes, shape parse by SvgRenderer
    if (node.tagName === 'svg') {
      const viewBoxStr: string = node.attributes['viewBox'] || '';
      const widthStr: string = node.attributes['width'] || '';
      const heightStr: string = node.attributes['height'] || '';
      let viewBox: SvgViewBox | null = null;
      if (viewBoxStr.length > 0) {
        const parts: string[] = viewBoxStr.split(/\s+/);
        if (parts.length === 4) {
          viewBox = {
            x: parseFloat(parts[0]),
            y: parseFloat(parts[1]),
            w: parseFloat(parts[2]),
            h: parseFloat(parts[3])
          };
        }
      }
      rn.svgAst = {
        shapes: [],
        viewBox: viewBox,
        width: widthStr.length > 0 ? parseFloat(widthStr) : null,
        height: heightStr.length > 0 ? parseFloat(heightStr) : null
      };
      rn.text = undefined;
      rn.isReplaced = true;
      // EPUB 封面常见结构：<svg><image xlink:href="cover.jpg"/></svg>。
      // 若 SVG 内嵌 <image> 子元素，提取其 href 作为整页图片（封面）渲染，
      // 而非空 SVG——否则封面页渲染为空白。
      for (let ci = 0; ci < node.children.length; ci++) {
        const child: DomNode = node.children[ci];
        if (child.tagName === 'image') {
          const href: string = child.attributes['xlink:href'] || child.attributes['href'] || '';
          if (href.length > 0) {
            rn.attributes['imageSrc'] = href;
          }
          break;
        }
      }
      return rn;
    }

    // Recursively process children (pass current nodeStyle as parentStyle)
    const childParentStyle: CssStyleSet | undefined = nodeStyle;
    for (let i = 0; i < node.children.length; i++) {
      const childRn: RenderNode | undefined = this.convertNode(
        node.children[i], compiledSheet, styleMapper, childParentStyle);
      if (childRn !== undefined) {
        rn.children.push(childRn);
      }
    }

    return rn;
  }

  /**
   * Parse child nodes.
   */
  private parseChildren(parent: DomNode): void {
    while (this.pos < this.input.length) {
      this.skipWhitespace();
      if (this.pos >= this.input.length) {
        break;
      }

      if (this.peek() === '<') {
        const nextChar: string = this.peekAt(1);
        if (nextChar === '/') {
          break;
        }
        if (nextChar === '!') {
          this.skipComment();
          continue;
        }
        if (nextChar === '?') {
          this.skipProcessingInstruction();
          continue;
        }
        const elem: DomNode | undefined = this.parseElement();
        if (elem !== undefined) {
          parent.children.push(elem);
        }
      } else {
        const text: string = this.parseText();
        if (text !== '') {
          parent.children.push(createTextNode(text));
        }
      }
    }
  }

  /**
   * Parse a single element.
   */
  private parseElement(): DomNode | undefined {
    if (this.peek() !== '<') {
      return undefined;
    }
    this.advance(); // skip '<'

    const tagName: string = this.parseTagName();
    if (tagName === '') {
      return undefined;
    }

    const elem: DomNode = createElementNode(tagName);

    // Parse attributes
    this.parseAttributes(elem);

    // Self-closing tag
    if (this.peek() === '/') {
      this.advance(); // '/'
      if (this.peek() === '>') {
        this.advance(); // '>'
      }
      return elem;
    }

    if (this.peek() === '>') {
      this.advance();
    }

    // Void elements
    const voidElements: string[] = ['br', 'hr', 'img', 'input', 'meta', 'link',
      'area', 'base', 'col', 'embed', 'source', 'track', 'wbr'];
    if (voidElements.indexOf(tagName) >= 0) {
      return elem;
    }

    // Parse children
    this.parseChildren(elem);

    // Skip end tag
    this.skipEndTag(tagName);

    return elem;
  }

  /**
   * Parse attribute list.
   */
  private parseAttributes(elem: DomNode): void {
    this.skipWhitespace();
    while (this.pos < this.input.length && this.peek() !== '>' && this.peek() !== '/') {
      const attrName: string = this.parseAttrName();
      if (attrName === '') {
        break;
      }
      let attrValue: string = '';
      if (this.peek() === '=') {
        this.advance(); // '='
        attrValue = this.parseAttrValue();
      }
      elem.attributes[attrName] = attrValue;
      this.skipWhitespace();
    }
  }

  /**
   * Parse tag name.
   */
  private parseTagName(): string {
    let name: string = '';
    while (this.pos < this.input.length) {
      const ch: string = this.peek();
      if (/[a-zA-Z0-9_:]/.test(ch)) {
        name += ch;
        this.advance();
      } else {
        break;
      }
    }
    return name;
  }

  /**
   * Parse attribute name.
   */
  private parseAttrName(): string {
    let name: string = '';
    while (this.pos < this.input.length) {
      const ch: string = this.peek();
      if (/[a-zA-Z0-9_:.-]/.test(ch)) {
        name += ch;
        this.advance();
      } else {
        break;
      }
    }
    return name;
  }

  /**
   * Parse attribute value.
   */
  private parseAttrValue(): string {
    if (this.pos >= this.input.length) {
      return '';
    }
    const quote: string = this.peek();
    if (quote === '"' || quote === '\'') {
      this.advance(); // skip opening quote
      let value: string = '';
      while (this.pos < this.input.length && this.peek() !== quote) {
        value += this.peek();
        this.advance();
      }
      if (this.pos < this.input.length) {
        this.advance(); // skip closing quote
      }
      return value;
    }
    // Unquoted attribute value
    let value: string = '';
    while (this.pos < this.input.length && !(/[\s>]/.test(this.peek()))) {
      value += this.peek();
      this.advance();
    }
    return value;
  }

  /**
   * Parse text content.
   */
  private parseText(): string {
    let text: string = '';
    while (this.pos < this.input.length && this.peek() !== '<') {
      text += this.peek();
      this.advance();
    }
    // Basic HTML entity decoding
    text = text.replace(/&amp;/g, '&');
    text = text.replace(/&lt;/g, '<');
    text = text.replace(/&gt;/g, '>');
    text = text.replace(/&quot;/g, '"');
    text = text.replace(/&#39;/g, '\'');
    text = text.replace(/&nbsp;/g, ' ');
    return text;
  }

  /**
   * Skip end tag.
   */
  private skipEndTag(tagName: string): void {
    this.skipWhitespace();
    if (this.pos + 2 + tagName.length >= this.input.length) {
      return;
    }
    if (this.peek() === '<' && this.peekAt(1) === '/') {
      this.advance(); // '<'
      this.advance(); // '/'
      const endTagName: string = this.parseTagName();
      if (endTagName.toLowerCase() === tagName.toLowerCase()) {
        this.skipWhitespace();
        if (this.peek() === '>') {
          this.advance();
        }
      }
    }
  }

  /**
   * Skip comment or DOCTYPE.
   */
  private skipComment(): void {
    if (this.input.substring(this.pos, this.pos + 4) === '<!--') {
      const endIdx: number = this.input.indexOf('-->', this.pos + 4);
      if (endIdx >= 0) {
        this.pos = endIdx + 3;
        return;
      }
    }
    // DOCTYPE
    if (this.input.substring(this.pos, this.pos + 9) === '<!DOCTYPE') {
      const endIdx: number = this.input.indexOf('>', this.pos);
      if (endIdx >= 0) {
        this.pos = endIdx + 1;
        return;
      }
    }
    this.advance();
  }

  /**
   * Skip processing instruction <? ... ?>
   */
  private skipProcessingInstruction(): void {
    const endIdx: number = this.input.indexOf('?>', this.pos);
    if (endIdx >= 0) {
      this.pos = endIdx + 2;
    } else {
      this.advance();
    }
  }

  /**
   * Skip whitespace characters.
   */
  private skipWhitespace(): void {
    while (this.pos < this.input.length && /[\s\n\r\t]/.test(this.peek())) {
      this.advance();
    }
  }

  /**
   * Peek current character.
   */
  private peek(): string {
    if (this.pos < this.input.length) {
      return this.input[this.pos];
    }
    return '';
  }

  /**
   * Peek at offset character.
   */
  private peekAt(offset: number): string {
    const idx: number = this.pos + offset;
    if (idx >= 0 && idx < this.input.length) {
      return this.input[idx];
    }
    return '';
  }

  /**
   * Advance one character.
   */
  private advance(): void {
    this.pos++;
  }
}

/**
 * Parse CSS font-size value and return numeric value in vp units.
 * Supports "px" (direct numeric), "em" (relative to parentFontSize), unitless (px).
 *
 * @param cssVal CSS font-size string (e.g. "14px", "1.2em", "16")
 * @param parentFontSize parent element font size (vp)
 * @returns parsed font size (vp), NaN on parse failure
 */
function resolveCssFontSize(cssVal: string, parentFontSize: number): number {
  const trimmed: string = cssVal.trim();
  // em unit
  if (trimmed.endsWith('em')) {
    const num: number = parseFloat(trimmed.substring(0, trimmed.length - 2));
    return num * parentFontSize;
  }
  // px or bare number
  if (trimmed.endsWith('px')) {
    return parseFloat(trimmed.substring(0, trimmed.length - 2));
  }
  // bare number (default px)
  return parseFloat(trimmed);
}


