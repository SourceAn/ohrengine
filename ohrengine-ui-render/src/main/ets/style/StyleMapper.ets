/**
 * 样式映射器
 * 参考：crengine lvstsheet.cpp + lvstyles.cpp
 *
 * 职责：
 * 1. 将 CSS 规则集（CssRuleSet）映射到 DOM 元素
 * 2. 实现 CSS 层叠算法（基于特异性 specificity + 来源优先级）
 * 3. 实现属性继承（继承父元素的计算后样式）
 * 4. 将 CSS 声明解析为 CssStyleSet（类型安全的样式值）
 * 5. 支持用户样式 / 默认样式覆盖
 *
 * 使用方式：
 *   const mapper: StyleMapper = new StyleMapper();
 *   const computed: CssStyleSet = mapper.computeStyle(element, parentStyle, ruleSet);
 */

import {
  CssStyleSet, CssDisplay, CssWhiteSpace, CssTextAlign, CssFontStyle,
  CssFontWeight, CssFontFamily, CssPageBreak, CssFloat, CssClear,
  CssTextDecoration, CssTextTransform, CssHyphenate, CssBorderStyle,
  CssBorderCollapse, CssDirection, CssVisibility, CssValueType,
  CssBackgroundRepeat, CssBackgroundPosition, CssLength, createCssLength,
  CssGenericValue, CssLineBreak, CssWordBreak, createDefaultCssStyleSet,
  CssVerticalAlign
} from 'ohrengine-common';
import { CssParser, StyleSource, SelectorType, createCssRuleSet } from 'ohrengine-parsers';
import type { CssRuleSet, CssRule, CssSelector, CssDeclaration, StyleSheet } from 'ohrengine-parsers';
import type { DomNode } from 'ohrengine-common';
import { CompiledStylesheet, CompiledRule } from './CssCompiler.ets';
import { SelectorMatcher } from './SelectorMatcher.ets';

/**
 * 可继承的 CSS 属性列表
 * 当子元素未显式设置时，继承父元素的计算后值
 */
const INHERITED_PROPERTIES: string[] = [
  'color', 'font-family', 'font-size', 'font-style', 'font-weight',
  'line-height', 'text-align', 'text-indent', 'text-transform',
  'visibility', 'white-space', 'word-break', 'line-break',
  'direction', 'orphans', 'widows', 'hyphens', 'font-synthesis'
];

/**
 * 来源优先级权重
 */
function sourcePriority(source: StyleSource): number {
  if (source === StyleSource.USER_AGENT) {
    return 0;
  }
  if (source === StyleSource.USER) {
    return 2;
  }
  // AUTHOR
  return 1;
}

/**
 * 计算特异性优先级：
 * [a, b, c] → 三级权重比较
 */
function compareSpecificity(a: number[], b: number[]): number {
  if (a[0] !== b[0]) {
    return a[0] - b[0];
  }
  if (a[1] !== b[1]) {
    return a[1] - b[1];
  }
  return a[2] - b[2];
}

/**
 * 样式来源条目
 */
interface StyleSourceEntry {
  rules: CssRule[];
  source: StyleSource;
}

/**
 * 已匹配的声明条目
 */
interface MatchedDeclEntry {
  decl: CssDeclaration;
  priority: number[];
  sourceOrder: number;
}

/**
 * 样式映射器
 */
export class StyleMapper {
  private userAgentStyles: CssRuleSet = { rules: [], rulesByTag: {}, rulesByClass: {}, rulesById: {} };
  private authorStyles: CssRuleSet = { rules: [], rulesByTag: {}, rulesByClass: {}, rulesById: {} };
  private userStyles: CssRuleSet = { rules: [], rulesByTag: {}, rulesByClass: {}, rulesById: {} };
  private parser: CssParser = new CssParser();
  private selectorMatcher: SelectorMatcher = new SelectorMatcher();
  private allSheetsInitialized: boolean = false;

  constructor() {
  }

  /**
   * 加载用户代理默认样式表
   */
  public loadUserAgentStyleSheet(css: string): void {
    const sheet: StyleSheet = this.parser.parseStyleSheet(css, StyleSource.USER_AGENT);
    this.userAgentStyles = this.buildRuleSet(sheet);
  }

  /**
   * 加载作者样式表（EPUB 内嵌 CSS）
   */
  public loadAuthorStyleSheet(css: string): void {
    const sheet: StyleSheet = this.parser.parseStyleSheet(css, StyleSource.AUTHOR);
    this.authorStyles = this.buildRuleSet(sheet);
  }

  /**
   * 加载用户样式表
   */
  public loadUserStyleSheet(css: string): void {
    const sheet: StyleSheet = this.parser.parseStyleSheet(css, StyleSource.USER);
    this.userStyles = this.buildRuleSet(sheet);
  }

  /**
   * 加载默认样式（初始化 UA 样式）
   */
  public loadDefaultStyles(): void {
    const defaultCss: string =
      'body { display: block; margin: 0; padding: 0; }' +
      'p { display: block; margin: 1em 0; }' +
      'h1 { display: block; font-size: 2em; font-weight: bold; margin: 0.67em 0; }' +
      'h2 { display: block; font-size: 1.5em; font-weight: bold; margin: 0.75em 0; }' +
      'h3 { display: block; font-size: 1.17em; font-weight: bold; margin: 0.83em 0; }' +
      'h4 { display: block; font-size: 1em; font-weight: bold; margin: 1.12em 0; }' +
      'h5 { display: block; font-size: 0.83em; font-weight: bold; margin: 1.5em 0; }' +
      'h6 { display: block; font-size: 0.67em; font-weight: bold; margin: 1.67em 0; }' +
      'div { display: block; }' +
      'ul, ol { display: block; margin: 1em 0; padding-left: 40px; }' +
      'li { display: list-item; }' +
      'blockquote { display: block; margin: 1em 40px; }' +
      'pre { display: block; font-family: monospace; white-space: pre; margin: 1em 0; }' +
      'table { display: table; }' +
      'tr { display: table-row; }' +
      'td, th { display: table-cell; }' +
      'a { color: blue; text-decoration: underline; }' +
      'em { font-style: italic; }' +
      'strong { font-weight: bold; }' +
      'i { font-style: italic; }' +
      'b { font-weight: bold; }' +
      'u { text-decoration: underline; }' +
      'img { display: inline; }' +
      'br { display: inline; }' +
      'span { display: inline; }' +
      'code { font-family: monospace; }' +
      'hr { display: block; margin: 0.5em 0; }' +
      'ruby { ruby-position: over; ruby-align: auto; }' +
      'rt { font-size: 0.5em; }' +
      'rp { display: none; }' +
      '* { font-synthesis: weight style; }' +
      '';
    this.loadUserAgentStyleSheet(defaultCss);
  }

  /**
   * 计算元素的最终样式
   */
  public computeStyle(
    element: DomNode,
    parentStyle: CssStyleSet | undefined,
    tagName: string
  ): CssStyleSet {
    if (!this.allSheetsInitialized) {
      this.loadDefaultStyles();
      this.allSheetsInitialized = true;
    }

    // 从父元素继承
    const result: CssStyleSet = parentStyle !== undefined ?
      this.inheritStyle(parentStyle) : createDefaultCssStyleSet();

    // 收集所有匹配的规则并排序
    const matchedDeclarations: MatchedDeclEntry[] = [];

    // 匹配各来源样式
    const allSources: StyleSourceEntry[] = [
      { rules: this.userAgentStyles.rules, source: StyleSource.USER_AGENT },
      { rules: this.authorStyles.rules, source: StyleSource.AUTHOR },
      { rules: this.userStyles.rules, source: StyleSource.USER }
    ];

    for (let s = 0; s < allSources.length; s++) {
      const sourceRules: CssRule[] = allSources[s].rules;
      const source: StyleSource = allSources[s].source;
      for (let r = 0; r < sourceRules.length; r++) {
        const rule: CssRule = sourceRules[r];
        if (rule.selectors.length > 0 &&
            this.selectorMatcher.matches(rule.selectors[0].value, element)) {
          for (let d = 0; d < rule.declarations.length; d++) {
            const decl: CssDeclaration = rule.declarations[d];
            const spec: number[] = rule.selectors.length > 0 ?
              rule.selectors[0].specificity : [0, 0, 0];
            matchedDeclarations.push({
              decl: decl,
              priority: [
                sourcePriority(source),
                decl.important ? 1 : 0,
                spec[0],
                spec[1],
                spec[2],
                rule.sourceOrder
              ],
              sourceOrder: rule.sourceOrder
            });
          }
        }
      }
    }

    // 按优先级排序
    matchedDeclarations.sort((a, b) => {
      for (let i = 0; i < Math.min(a.priority.length, b.priority.length); i++) {
        if (a.priority[i] !== b.priority[i]) {
          return a.priority[i] - b.priority[i];
        }
      }
      return 0;
    });

    // 应用声明
    for (let i = 0; i < matchedDeclarations.length; i++) {
      this.applyDeclaration(result, matchedDeclarations[i].decl);
    }

    // === 处理 ::marker 伪元素规则 ===
    // 对于 <li> 元素，额外匹配选择器中含 ::marker 的规则，提取 font-size / color
    if (tagName === 'li') {
      for (let s = 0; s < allSources.length; s++) {
        const markerSourceRules: CssRule[] = allSources[s].rules;
        for (let r = 0; r < markerSourceRules.length; r++) {
          const markerRule: CssRule = markerSourceRules[r];
          for (let selIdx = 0; selIdx < markerRule.selectors.length; selIdx++) {
            const selVal: string = markerRule.selectors[selIdx].value;
            const markerPos: number = selVal.indexOf('::marker');
            if (markerPos >= 0) {
              const baseSel: string = selVal.substring(0, markerPos);
              // 空 baseSel = 仅 ::marker（全局所有 li 的 marker）
              if (baseSel.length === 0 || this.selectorMatcher.matches(baseSel, element)) {
                for (let d = 0; d < markerRule.declarations.length; d++) {
                  const markerDecl: CssDeclaration = markerRule.declarations[d];
                  if (markerDecl.property === 'font-size') {
                    result.markerFontSize = markerDecl.value;   // 保持原始字符串，HtmlParser 中解析
                  } else if (markerDecl.property === 'color') {
                    result.markerColor = markerDecl.value;
                  }
                }
              }
            }
          }
        }
      }
    }

    return result;
  }

  /**
   * 基于 CompiledStylesheet 计算元素最终样式（更快的路径）
   *
   * 与 computeStyle 不同，此方法直接查 CompiledStylesheet 的已分桶规则，
   * 跳过全量规则遍历和匹配声明排序。
   */
  public resolveStyle(
    element: DomNode,
    parentStyle: CssStyleSet | undefined,
    compiledSheet: object | undefined
  ): CssStyleSet {
    if (!this.allSheetsInitialized) {
      this.loadDefaultStyles();
      this.allSheetsInitialized = true;
    }

    // 从父元素继承
    const result: CssStyleSet = parentStyle !== undefined ?
      this.inheritStyle(parentStyle) : createDefaultCssStyleSet();

    if (compiledSheet === undefined) {
      return result;
    }

    const cs: CompiledStylesheet = compiledSheet as CompiledStylesheet;

    const tagName: string = element.tagName ?? '';
    const classAttr: string = element.attributes['class'] ?? '';
    const idAttr: string = element.attributes['id'] ?? '';
    const classes: string[] = [];
    if (classAttr.length > 0) {
      let start: number = -1;
      for (let i: number = 0; i <= classAttr.length; i++) {
        const ch: string = i < classAttr.length ? classAttr[i] : ' ';
        if (ch !== ' ' && ch !== '\t' && ch !== '\n' && ch !== '\r') {
          if (start === -1) { start = i; }
        } else {
          if (start !== -1) {
            classes.push(classAttr.substring(start, i));
            start = -1;
          }
        }
      }
    }

    // 逐条应用匹配的已排序规则（按 priority 升序 = 低优先级先应用，高优先级覆盖）
    this.applyMatchingRules(cs.universalRules, element, tagName, classes, idAttr, result);

    // 标签匹配
    if (tagName !== '' && cs.tagRules.size > 0) {
      const tagRules: CompiledRule[] | undefined = cs.tagRules.get(tagName);
      if (tagRules !== undefined) {
        this.applyCompiledRules(tagRules, result);
      }
    }

    // 类匹配
    for (let i = 0; i < classes.length; i++) {
      const cls: string = classes[i];
      if (cls !== '' && cs.classRules.size > 0) {
        const clsRules: CompiledRule[] | undefined = cs.classRules.get(cls);
        if (clsRules !== undefined) {
          this.applyCompiledRules(clsRules, result);
        }
      }
    }

    // ID 匹配
    if (idAttr !== '' && cs.idRules.size > 0) {
      const idRules: CompiledRule[] | undefined = cs.idRules.get(idAttr);
      if (idRules !== undefined) {
        this.applyCompiledRules(idRules, result);
      }
    }

    // 复合/后代规则（全量匹配检查）
    if (cs.otherRules.length > 0) {
      this.applyMatchingRules(cs.otherRules, element, tagName, classes, idAttr, result);
    }

    return result;
  }

  /**
   * 应用一批 CompiledRule（已按 priority 排序）
   */
  private applyCompiledRules(rules: CompiledRule[], style: CssStyleSet): void {
    for (let i = 0; i < rules.length; i++) {
      const cr: CompiledRule = rules[i];
      for (let d = 0; d < cr.rule.declarations.length; d++) {
        this.applyDeclaration(style, cr.rule.declarations[d]);
      }
    }
  }

  /**
   * 应用通配/匹配规则
   */
  private applyMatchingRules(
    rules: CompiledRule[],
    element: DomNode,
    tagName: string,
    classes: string[],
    idAttr: string,
    style: CssStyleSet
  ): void {
    for (let i: number = 0; i < rules.length; i++) {
      const cr: CompiledRule = rules[i];
      // Fast-check pre-filtering: skip if rightmost tag/class/id don't match
      if (cr.rightmostTag.length > 0 && cr.rightmostTag !== tagName) {
        continue;
      }
      if (cr.rightmostClass.length > 0) {
        let hasClass: boolean = false;
        for (let c: number = 0; c < classes.length; c++) {
          if (classes[c] === cr.rightmostClass) {
            hasClass = true;
            break;
          }
        }
        if (!hasClass) { continue; }
      }
      if (cr.rightmostId.length > 0 && cr.rightmostId !== idAttr) {
        continue;
      }
      // Full selector matching via SelectorMatcher
      if (cr.rule.selectors.length > 0 &&
          this.selectorMatcher.matches(cr.rule.selectors[0].value, element)) {
        for (let d: number = 0; d < cr.rule.declarations.length; d++) {
          this.applyDeclaration(style, cr.rule.declarations[d]);
        }
      }
    }
  }

  /**
   * 简化的规则匹配检查
   */
  private ruleMatchesElement(
    rule: CssRule,
    element: DomNode,
    tagName: string,
    classes: string[],
    idAttr: string
  ): boolean {
    for (let s = 0; s < rule.selectors.length; s++) {
      if (this.matchesSimpleSelector(element, tagName, rule.selectors[s])) {
        return true;
      }
    }
    return false;
  }

  /**
   * 从父样式继承可继承属性
   */
  private inheritStyle(parent: CssStyleSet): CssStyleSet {
    const result: CssStyleSet = createDefaultCssStyleSet();
    result.color = parent.color;
    result.fontFamily = parent.fontFamily;
    result.fontSize = parent.fontSize;
    result.fontStyle = parent.fontStyle;
    result.fontWeight = parent.fontWeight;
    result.lineHeight = parent.lineHeight;
    result.textAlign = parent.textAlign;
    result.textIndent = parent.textIndent;
    result.textTransform = parent.textTransform;
    result.visibility = parent.visibility;
    result.whiteSpace = parent.whiteSpace;
    result.wordBreak = parent.wordBreak;
    result.lineBreak = parent.lineBreak;
    result.direction = parent.direction;
    result.orphans = parent.orphans;
    result.widows = parent.widows;
    result.hyphenate = parent.hyphenate;
    result.fontSynthesis = parent.fontSynthesis;
    return result;
  }

  /**
   * 检查元素是否匹配任意选择器
   */
  private matchesAnySelector(
    element: DomNode,
    tagName: string,
    selectors: CssSelector[]
  ): boolean {
    for (let i = 0; i < selectors.length; i++) {
      if (this.matchesSimpleSelector(element, tagName, selectors[i])) {
        return true;
      }
    }
    return false;
  }

  /**
   * 检查元素是否匹配单个简易选择器
   */
  private matchesSimpleSelector(
    element: DomNode,
    tagName: string,
    selector: CssSelector
  ): boolean {
    if (selector.type === SelectorType.UNIVERSAL) {
      return true;
    }
    if (selector.type === SelectorType.TAG) {
      return tagName === selector.value;
    }
    if (selector.type === SelectorType.CLASS) {
      const classAttr: string = element.attributes['class'] ?? '';
      const classes: string[] = classAttr.split(/\s+/);
      for (let i = 0; i < classes.length; i++) {
        if (classes[i] === selector.value) {
          return true;
        }
      }
      return false;
    }
    if (selector.type === SelectorType.ID) {
      return (element.attributes['id'] ?? '') === selector.value;
    }
    // 复杂选择器需要父链遍历，当前简化处理
    if (selector.type === SelectorType.GROUP) {
      return true; // 已在复合选择器时处理
    }
    return true;
  }

  /**
   * 将声明应用到样式集
   */
  private applyDeclaration(style: CssStyleSet, decl: CssDeclaration): void {
    const prop: string = decl.property;
    const val: string = decl.value;

    if (prop === 'display') {
      style.display = this.parseDisplay(val);
    } else if (prop === 'white-space' || prop === 'whitespace') {
      style.whiteSpace = this.parseWhiteSpace(val);
    } else if (prop === 'text-align' || prop === 'textalign') {
      style.textAlign = this.parseTextAlign(val);
    } else if (prop === 'font-style' || prop === 'fontstyle') {
      style.fontStyle = this.parseFontStyle(val);
    } else if (prop === 'font-weight' || prop === 'fontweight') {
      style.fontWeight = this.parseFontWeight(val);
    } else if (prop === 'font-family' || prop === 'fontfamily') {
      style.fontFamily = this.parseFontFamily(val);
    } else if (prop === 'font-size' || prop === 'fontsize') {
      style.fontSize = this.parseLength(val);
    } else if (prop === 'line-height' || prop === 'lineheight') {
      style.lineHeight = this.parseLength(val);
    } else if (prop === 'color') {
      style.color = val;
    } else if (prop === 'background-color' || prop === 'backgroundcolor') {
      style.backgroundColor = val;
    } else if (prop === 'margin-top' || prop === 'margintop') {
      style.marginTop = this.parseLength(val);
    } else if (prop === 'margin-right' || prop === 'marginright') {
      style.marginRight = this.parseLength(val);
    } else if (prop === 'margin-bottom' || prop === 'marginbottom') {
      style.marginBottom = this.parseLength(val);
    } else if (prop === 'margin-left' || prop === 'marginleft') {
      style.marginLeft = this.parseLength(val);
    } else if (prop === 'padding-top' || prop === 'paddingtop') {
      style.paddingTop = this.parseLength(val);
    } else if (prop === 'padding-right' || prop === 'paddingright') {
      style.paddingRight = this.parseLength(val);
    } else if (prop === 'padding-bottom' || prop === 'paddingbottom') {
      style.paddingBottom = this.parseLength(val);
    } else if (prop === 'padding-left' || prop === 'paddingleft') {
      style.paddingLeft = this.parseLength(val);
    } else if (prop === 'visibility') {
      style.visibility = this.parseVisibility(val);
    } else if (prop === 'text-decoration' || prop === 'textdecoration') {
      style.textDecoration = this.parseTextDecoration(val);
    } else if (prop === 'text-transform' || prop === 'texttransform') {
      style.textTransform = this.parseTextTransform(val);
    } else if (prop === 'float') {
      style.float = this.parseFloat(val);
    } else if (prop === 'clear') {
      style.clear = this.parseClear(val);
    } else if (prop === 'direction') {
      style.direction = this.parseDirection(val);
    } else if (prop === 'text-indent' || prop === 'textindent') {
      style.textIndent = this.parseLength(val);
    } else if (prop === 'width') {
      style.width = this.parseLength(val);
    } else if (prop === 'height') {
      style.height = this.parseLength(val);
    } else if (prop === 'min-width' || prop === 'minwidth') {
      style.minWidth = this.parseLength(val);
    } else if (prop === 'max-width' || prop === 'maxwidth') {
      style.maxWidth = this.parseLength(val);
    } else if (prop === 'min-height' || prop === 'minheight') {
      style.minHeight = this.parseLength(val);
    } else if (prop === 'max-height' || prop === 'maxheight') {
      style.maxHeight = this.parseLength(val);
    } else if (prop === 'page-break-before' || prop === 'pagebreakbefore') {
      style.pageBreakBefore = this.parsePageBreak(val);
    } else if (prop === 'page-break-after' || prop === 'pagebreakafter') {
      style.pageBreakAfter = this.parsePageBreak(val);
    } else if (prop === 'page-break-inside' || prop === 'pagebreakinside') {
      style.pageBreakInside = this.parsePageBreak(val);
    } else if (prop === 'word-break' || prop === 'wordbreak') {
      style.wordBreak = this.parseWordBreak(val);
    } else if (prop === 'opacity') {
      const parsed: number = parseFloat(val);
      style.opacity = Number.isNaN(parsed) ? 1.0 : Math.max(0, Math.min(1, parsed));
    } else if (prop === 'text-overflow' || prop === 'textoverflow') {
      style.textOverflow = val === 'ellipsis' ? 'ellipsis' : 'clip';
    } else if (prop === 'overflow') {
      style.overflow = val === 'hidden' ? 'hidden' : 'visible';
    } else if (prop === 'list-style-image' || prop === 'liststyleimage') {
      // 提取 url("...") / url('...') / url(...)
      const urlPattern: RegExp = new RegExp("url\\([\"']?([^\"')]+)[\"']?\\)");
      const urlMatch: RegExpMatchArray | null = val.match(urlPattern);
      style.listStyleImage = urlMatch !== null ? urlMatch[1] : undefined;
      return;
    } else if (prop === 'list-style-type' || prop === 'liststyletype') {
      style.listStyleType = val;
      return;
    } else if (prop === 'counter-reset' || prop === 'counterreset') {
      style.counterReset = val;
      return;
    } else if (prop === 'counter-increment' || prop === 'counterincrement') {
      style.counterIncrement = val;
      return;
    } else if (prop === 'ruby-position' || prop === 'rubyposition') {
      style.rubyPosition = val;
    } else if (prop === 'ruby-align' || prop === 'rubyalign') {
      style.rubyAlign = val;
    } else if (prop === 'font-synthesis' || prop === 'fontsynthesis') {
      style.fontSynthesis = val;
    }
  }

  /**
   * 将 CssRuleSet 按 Tag/Class/Id 索引化
   */
  private buildRuleSet(sheet: StyleSheet): CssRuleSet {
    const set: CssRuleSet = createCssRuleSet();
    for (let i = 0; i < sheet.rules.length; i++) {
      const rule: CssRule = sheet.rules[i];
      set.rules.push(rule);
      for (let j = 0; j < rule.selectors.length; j++) {
        const sel: CssSelector = rule.selectors[j];
        if (sel.type === SelectorType.TAG && sel.value !== '') {
          this.addToIndex(set.rulesByTag, sel.value.toLowerCase(), rule);
        }
        if (sel.type === SelectorType.CLASS && sel.value !== '') {
          this.addToIndex(set.rulesByClass, sel.value, rule);
        }
        if (sel.type === SelectorType.ID && sel.value !== '') {
          this.addToIndex(set.rulesById, sel.value, rule);
        }
      }
    }
    return set;
  }

  private addToIndex(index: Record<string, CssRule[]>, key: string, rule: CssRule): void {
    if (index[key] === undefined) {
      index[key] = [];
    }
    index[key].push(rule);
  }

  // ============ CSS 值解析工具 ============

  private parseDisplay(val: string): CssDisplay {
    const v: string = val.toLowerCase().trim();
    if (v === 'block') return CssDisplay.BLOCK;
    if (v === 'inline') return CssDisplay.INLINE;
    if (v === 'inline-block') return CssDisplay.INLINE_BLOCK;
    if (v === 'none') return CssDisplay.NONE;
    if (v === 'table') return CssDisplay.TABLE;
    if (v === 'table-row') return CssDisplay.TABLE_ROW;
    if (v === 'table-cell') return CssDisplay.TABLE_CELL;
    if (v === 'list-item') return CssDisplay.LIST_ITEM_BLOCK;
    if (v === 'flex') return CssDisplay.FLEX;
    if (v === 'inline-flex') return CssDisplay.INLINE_FLEX;
    if (v === 'inherit') return CssDisplay.INHERIT;
    return CssDisplay.INLINE;
  }

  private parseWhiteSpace(val: string): CssWhiteSpace {
    const v: string = val.toLowerCase().trim();
    if (v === 'normal') return CssWhiteSpace.NORMAL;
    if (v === 'nowrap') return CssWhiteSpace.NOWRAP;
    if (v === 'pre') return CssWhiteSpace.PRE;
    if (v === 'pre-wrap') return CssWhiteSpace.PRE_WRAP;
    if (v === 'pre-line') return CssWhiteSpace.PRE_LINE;
    if (v === 'break-spaces') return CssWhiteSpace.BREAK_SPACES;
    return CssWhiteSpace.NORMAL;
  }

  private parseTextAlign(val: string): CssTextAlign {
    const v: string = val.toLowerCase().trim();
    if (v === 'left') return CssTextAlign.LEFT;
    if (v === 'right') return CssTextAlign.RIGHT;
    if (v === 'center') return CssTextAlign.CENTER;
    if (v === 'justify') return CssTextAlign.JUSTIFY;
    if (v === 'start') return CssTextAlign.START;
    if (v === 'end') return CssTextAlign.END;
    return CssTextAlign.INHERIT;
  }

  private parseFontStyle(val: string): CssFontStyle {
    const v: string = val.toLowerCase().trim();
    if (v === 'normal') return CssFontStyle.NORMAL;
    if (v === 'italic') return CssFontStyle.ITALIC;
    if (v === 'oblique') return CssFontStyle.OBLIQUE;
    return CssFontStyle.INHERIT;
  }

  private parseFontWeight(val: string): CssFontWeight {
    const v: string = val.toLowerCase().trim();
    if (v === 'normal' || v === '400') return CssFontWeight.NORMAL;
    if (v === 'bold' || v === '700') return CssFontWeight.BOLD;
    if (v === 'bolder') return CssFontWeight.BOLDER;
    if (v === 'lighter') return CssFontWeight.LIGHTER;
    if (v === '100') return CssFontWeight.W_100;
    if (v === '200') return CssFontWeight.W_200;
    if (v === '300') return CssFontWeight.W_300;
    if (v === '500') return CssFontWeight.W_400;
    if (v === '600') return CssFontWeight.W_600;
    if (v === '800') return CssFontWeight.W_800;
    if (v === '900') return CssFontWeight.W_900;
    return CssFontWeight.INHERIT;
  }

  private parseFontFamily(val: string): CssFontFamily {
    const v: string = val.toLowerCase().trim();
    if (v.indexOf('serif') >= 0) return CssFontFamily.SERIF;
    if (v.indexOf('sans') >= 0) return CssFontFamily.SANS_SERIF;
    if (v.indexOf('mono') >= 0) return CssFontFamily.MONOSPACE;
    if (v.indexOf('cursive') >= 0) return CssFontFamily.CURSIVE;
    if (v.indexOf('fantasy') >= 0) return CssFontFamily.FANTASY;
    return CssFontFamily.SERIF;
  }

  private parseLength(val: string): CssLength {
    const v: string = val.trim().toLowerCase();
    if (v === 'inherit') return createCssLength(CssValueType.INHERITED, 0);
    if (v === 'auto' || v === 'none') return createCssLength(CssValueType.UNSPECIFIED, CssGenericValue.AUTO);
    if (v === 'normal' || v === '0') return createCssLength(CssValueType.PX, 0);

    const numMatch: RegExpMatchArray | null = v.match(/^(-?[\d.]+)(%|px|pt|em|rem|vw|vh|vmin|vmax|in|cm|mm|pc)?$/);
    if (numMatch !== undefined && numMatch !== null) {
      const number: number = parseFloat(numMatch[1]);
      const unit: string = numMatch[2] ?? 'px';
      const fixedValue: number = Math.round(number * 256); // 定点数
      if (unit === '%') return createCssLength(CssValueType.PERCENT, fixedValue);
      if (unit === 'px') return createCssLength(CssValueType.PX, fixedValue);
      if (unit === 'pt') return createCssLength(CssValueType.PT, fixedValue);
      if (unit === 'em') return createCssLength(CssValueType.EM, fixedValue);
      if (unit === 'rem') return createCssLength(CssValueType.REM, fixedValue);
      if (unit === 'vw') return createCssLength(CssValueType.VW, fixedValue);
      if (unit === 'vh') return createCssLength(CssValueType.VH, fixedValue);
      if (unit === 'in') return createCssLength(CssValueType.IN, fixedValue);
      if (unit === 'cm') return createCssLength(CssValueType.CM, fixedValue);
      if (unit === 'mm') return createCssLength(CssValueType.MM, fixedValue);
      if (unit === 'pc') return createCssLength(CssValueType.PC, fixedValue);
      return createCssLength(CssValueType.PX, fixedValue);
    }
    return createCssLength(CssValueType.UNSPECIFIED, 0);
  }

  private parseVisibility(val: string): CssVisibility {
    const v: string = val.toLowerCase().trim();
    if (v === 'visible') return CssVisibility.VISIBLE;
    if (v === 'hidden') return CssVisibility.HIDDEN;
    if (v === 'collapse') return CssVisibility.COLLAPSE;
    return CssVisibility.INHERIT;
  }

  private parseTextDecoration(val: string): CssTextDecoration {
    const v: string = val.toLowerCase().trim();
    if (v === 'none') return CssTextDecoration.NONE;
    if (v === 'underline') return CssTextDecoration.UNDERLINE;
    if (v === 'overline') return CssTextDecoration.OVERLINE;
    if (v === 'line-through') return CssTextDecoration.LINE_THROUGH;
    return CssTextDecoration.INHERIT;
  }

  private parseTextTransform(val: string): CssTextTransform {
    const v: string = val.toLowerCase().trim();
    if (v === 'none') return CssTextTransform.NONE;
    if (v === 'uppercase') return CssTextTransform.UPPERCASE;
    if (v === 'lowercase') return CssTextTransform.LOWERCASE;
    if (v === 'capitalize') return CssTextTransform.CAPITALIZE;
    return CssTextTransform.INHERIT;
  }

  private parseFloat(val: string): CssFloat {
    const v: string = val.toLowerCase().trim();
    if (v === 'left') return CssFloat.LEFT;
    if (v === 'right') return CssFloat.RIGHT;
    if (v === 'none') return CssFloat.NONE;
    return CssFloat.INHERIT;
  }

  private parseClear(val: string): CssClear {
    const v: string = val.toLowerCase().trim();
    if (v === 'left') return CssClear.LEFT;
    if (v === 'right') return CssClear.RIGHT;
    if (v === 'both') return CssClear.BOTH;
    if (v === 'none') return CssClear.NONE;
    return CssClear.INHERIT;
  }

  private parseDirection(val: string): CssDirection {
    const v: string = val.toLowerCase().trim();
    if (v === 'ltr') return CssDirection.LTR;
    if (v === 'rtl') return CssDirection.RTL;
    return CssDirection.INHERIT;
  }

  private parsePageBreak(val: string): CssPageBreak {
    const v: string = val.toLowerCase().trim();
    if (v === 'auto') return CssPageBreak.AUTO;
    if (v === 'always') return CssPageBreak.ALWAYS;
    if (v === 'avoid') return CssPageBreak.AVOID;
    if (v === 'left') return CssPageBreak.LEFT;
    if (v === 'right') return CssPageBreak.RIGHT;
    return CssPageBreak.INHERIT;
  }

  private parseWordBreak(val: string): CssWordBreak {
    const v: string = val.toLowerCase().trim();
    if (v === 'normal') return CssWordBreak.NORMAL;
    if (v === 'break-word') return CssWordBreak.BREAK_WORD;
    if (v === 'break-all') return CssWordBreak.BREAK_ALL;
    if (v === 'keep-all') return CssWordBreak.KEEP_ALL;
    return CssWordBreak.NORMAL;
  }
}
