/**
 * CSS 解析器
 * 参考：crengine cssparser.cpp + lvstsheet.cpp
 *
 * 职责：
 * 1. 解析 CSS 字符串为结构化规则集合
 * 2. 支持：element, .class, #id, 复合选择器, 伪类
 * 3. 支持：层叠 / 继承 / important
 * 4. 输出：CssRuleSet，供 StyleMapper 消费
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

/**
 * 选择器类型
 */
export enum SelectorType {
  TAG = 'tag',
  CLASS = 'class',
  ID = 'id',
  UNIVERSAL = 'universal',
  DESCENDANT = 'descendant',
  CHILD = 'child',
  ADJACENT = 'adjacent',
  SIBLING = 'sibling',
  PSEUDO_CLASS = 'pseudo-class',
  ATTRIBUTE = 'attribute',
  GROUP = 'group'
}

/**
 * CSS 选择器
 */
export interface CssSelector {
  type: SelectorType;
  value: string;
  specificity: number[];
  pseudoClass: string | undefined;
  attributeSelector: string | undefined;
}

/**
 * CSS 规则（选择器 + 声明块）
 */
export interface CssRule {
  selectors: CssSelector[];
  declarations: CssDeclaration[];
  important: boolean;
  sourceOrder: number;
}

/**
 * CSS 声明（属性名 + 值）
 */
export interface CssDeclaration {
  property: string;
  value: string;
  important: boolean;
}

/**
 * CSS 规则集 — 供样式映射使用
 */
export interface CssRuleSet {
  rules: CssRule[];
  rulesByTag: Record<string, CssRule[]>;
  rulesByClass: Record<string, CssRule[]>;
  rulesById: Record<string, CssRule[]>;
}

export function createCssRuleSet(): CssRuleSet {
  return {
    rules: [],
    rulesByTag: {},
    rulesByClass: {},
    rulesById: {}
  };
}

/**
 * 媒体查询条件
 */
export interface MediaQuery {
  type: string;
  feature: string | undefined;
  value: string | undefined;
}

/**
 * 样式表来源
 */
export enum StyleSource {
  AUTHOR = 'author',
  USER = 'user',
  USER_AGENT = 'user-agent'
}

/**
 * 样式表
 */
export interface StyleSheet {
  source: StyleSource;
  rules: CssRule[];
  mediaQueries: MediaQuery[];
  disabled: boolean;
}

export function createStyleSheet(source: StyleSource): StyleSheet {
  return {
    source: source,
    rules: [],
    mediaQueries: [],
    disabled: false
  };
}

/**
 * CSS 解析器
 *
 * 解析 CSS 字符串为 StyleSheet 对象：
 *   const parser: CssParser = new CssParser();
 *   const sheet: StyleSheet = parser.parseStyleSheet(cssText, StyleSource.AUTHOR);
 */
export class CssParser {
  private pos: number = 0;
  private input: string = '';
  private ruleCounter: number = 0;

  constructor() {
  }

  /**
   * 解析完整样式表
   */
  public parseStyleSheet(css: string, source: StyleSource): StyleSheet {
    this.input = css;
    this.pos = 0;
    this.ruleCounter = 0;
    const sheet: StyleSheet = createStyleSheet(source);
    this.parseSheetRules(sheet);
    return sheet;
  }

  /**
   * 解析规则块
   */
  private parseSheetRules(sheet: StyleSheet): void {
    this.skipWhitespaceAndComments();
    while (this.pos < this.input.length) {
      if (this.peek() === '@') {
        this.skipAtRule();
        this.skipWhitespaceAndComments();
        continue;
      }
      const rule: CssRule | undefined = this.parseRule();
      if (rule !== undefined) {
        sheet.rules.push(rule);
      } else {
        break;
      }
      this.skipWhitespaceAndComments();
    }
  }

  /**
   * 解析单一规则
   */
  private parseRule(): CssRule | undefined {
    const selectors: CssSelector[] = this.parseSelectorList();
    if (selectors.length === 0) {
      return undefined;
    }
    this.skipWhitespaceAndComments();
    if (this.peek() !== '{') {
      return undefined;
    }
    this.advance();
    const declarations: CssDeclaration[] = this.parseDeclarationBlock();
    this.skipWhitespaceAndComments();
    if (this.peek() === '}') {
      this.advance();
    }
    if (declarations.length === 0) {
      return undefined;
    }
    const rule: CssRule = {
      selectors: selectors,
      declarations: declarations,
      important: this.hasImportant(declarations),
      sourceOrder: this.ruleCounter++
    };
    return rule;
  }

  /**
   * 解析选择器列表（逗号分隔）
   */
  private parseSelectorList(): CssSelector[] {
    const list: CssSelector[] = [];
    const first: CssSelector[] = this.parseCompoundSelector();
    if (first.length === 0) {
      return list;
    }
    list.push(this.mergeSelectors(first));
    this.skipWhitespaceAndComments();
    while (this.peek() === ',') {
      this.advance();
      this.skipWhitespaceAndComments();
      const next: CssSelector[] = this.parseCompoundSelector();
      if (next.length > 0) {
        list.push(this.mergeSelectors(next));
      }
      this.skipWhitespaceAndComments();
    }
    return list;
  }

  /**
   * 解析复合选择器（例如 div.class#id）
   */
  private parseCompoundSelector(): CssSelector[] {
    const parts: CssSelector[] = [];
    while (this.pos < this.input.length) {
      this.skipWhitespaceAndComments();
      const ch: string = this.peek();
      if (ch === '{' || ch === ',' || ch === '}' || ch === '') {
        break;
      }
      if (ch === '.') {
        this.advance();
        const className: string = this.parseIdent();
        if (className !== '') {
          parts.push({
            type: SelectorType.CLASS,
            value: className,
            specificity: [0, 1, 0],
            pseudoClass: undefined,
            attributeSelector: undefined
          });
        }
      } else if (ch === '#') {
        this.advance();
        const idName: string = this.parseIdent();
        if (idName !== '') {
          parts.push({
            type: SelectorType.ID,
            value: idName,
            specificity: [1, 0, 0],
            pseudoClass: undefined,
            attributeSelector: undefined
          });
        }
      } else if (ch === '[') {
        const attrSel: CssSelector | undefined = this.parseAttributeSelector();
        if (attrSel !== undefined) {
          parts.push(attrSel);
        }
      } else if (ch === ':') {
        const pseudo: CssSelector | undefined = this.parsePseudoClass();
        if (pseudo !== undefined) {
          parts.push(pseudo);
        }
      } else if (ch === '*' && this.peekAt(1) !== undefined && !(/[a-zA-Z]/.test(this.peekAt(1)))) {
        this.advance();
        parts.push({
          type: SelectorType.UNIVERSAL,
          value: '*',
          specificity: [0, 0, 0],
          pseudoClass: undefined,
          attributeSelector: undefined
        });
      } else if (/[a-zA-Z_]/.test(ch)) {
        const tagName: string = this.parseIdent();
        if (tagName !== '') {
          parts.push({
            type: SelectorType.TAG,
            value: tagName,
            specificity: [0, 0, 1],
            pseudoClass: undefined,
            attributeSelector: undefined
          });
        }
      } else if (ch === '>') {
        this.advance();
        parts.push({
          type: SelectorType.CHILD,
          value: '>',
          specificity: [0, 0, 0],
          pseudoClass: undefined,
          attributeSelector: undefined
        });
      } else if (ch === '+') {
        this.advance();
        parts.push({
          type: SelectorType.ADJACENT,
          value: '+',
          specificity: [0, 0, 0],
          pseudoClass: undefined,
          attributeSelector: undefined
        });
      } else if (ch === '~') {
        this.advance();
        parts.push({
          type: SelectorType.SIBLING,
          value: '~',
          specificity: [0, 0, 0],
          pseudoClass: undefined,
          attributeSelector: undefined
        });
      } else if (ch === ' ') {
        this.advance();
        while (this.pos < this.input.length && (this.peek() === ' ' || this.peek() === '\n')) {
          this.advance();
        }
        if (this.peek() !== '>' && this.peek() !== '+' && this.peek() !== '~' &&
            this.peek() !== ',' && this.peek() !== '{') {
          parts.push({
            type: SelectorType.DESCENDANT,
            value: ' ',
            specificity: [0, 0, 0],
            pseudoClass: undefined,
            attributeSelector: undefined
          });
        }
      } else {
        break;
      }
    }
    return parts;
  }

  /**
   * 合并复合选择器各部分
   */
  private mergeSelectors(parts: CssSelector[]): CssSelector {
    if (parts.length === 0) {
      return {
        type: SelectorType.UNIVERSAL,
        value: '*',
        specificity: [0, 0, 0],
        pseudoClass: undefined,
        attributeSelector: undefined
      };
    }
    let combinedValue: string = '';
    const combinedSpec: number[] = [0, 0, 0];
    for (let i = 0; i < parts.length; i++) {
      const p: CssSelector = parts[i];
      combinedValue += p.value;
      combinedSpec[0] += p.specificity[0];
      combinedSpec[1] += p.specificity[1];
      combinedSpec[2] += p.specificity[2];
    }
    return {
      type: SelectorType.GROUP,
      value: combinedValue,
      specificity: combinedSpec,
      pseudoClass: parts.length > 0 ? parts[parts.length - 1].pseudoClass : undefined,
      attributeSelector: undefined
    };
  }

  /**
   * 解析声明块
   */
  private parseDeclarationBlock(): CssDeclaration[] {
    const decls: CssDeclaration[] = [];
    this.skipWhitespaceAndComments();
    while (this.pos < this.input.length && this.peek() !== '}') {
      const decl: CssDeclaration | undefined = this.parseDeclaration();
      if (decl !== undefined) {
        decls.push(decl);
      }
      this.skipWhitespaceAndComments();
      if (this.peek() === ';') {
        this.advance();
      }
      this.skipWhitespaceAndComments();
    }
    return decls;
  }

  /**
   * 解析单个声明
   */
  private parseDeclaration(): CssDeclaration | undefined {
    const prop: string = this.parseIdent();
    if (prop === '') {
      return undefined;
    }
    this.skipWhitespaceAndComments();
    if (this.peek() !== ':') {
      return undefined;
    }
    this.advance();
    this.skipWhitespaceAndComments();
    const value: string = this.parseDeclValue();
    if (value === '') {
      return undefined;
    }
    const isImportant: boolean = this.checkImportant();
    return {
      property: prop.toLowerCase(),
      value: value,
      important: isImportant
    };
  }

  /**
   * 解析标识符（属性名、值等）
   */
  private parseIdent(): string {
    let ident: string = '';
    while (this.pos < this.input.length) {
      const ch: string = this.peek();
      if (/[a-zA-Z0-9_-]/.test(ch) || ch === '-' || ch === '*' || ch === '.') {
        ident += ch;
        this.advance();
      } else {
        break;
      }
    }
    return ident;
  }

  /**
   * 解析声明值
   */
  private parseDeclValue(): string {
    let value: string = '';
    let inParens: number = 0;
    while (this.pos < this.input.length) {
      const ch: string = this.peek();
      if (ch === ';' && inParens === 0) {
        break;
      }
      if (ch === '}' && inParens === 0) {
        break;
      }
      if (ch === '(') {
        inParens++;
      }
      if (ch === ')') {
        inParens--;
      }
      value += ch;
      this.advance();
    }
    return value.trim();
  }

  /**
   * 检查 !important
   */
  private checkImportant(): boolean {
    this.skipWhitespaceAndComments();
    if (this.input.substring(this.pos, this.pos + 10) === '!important') {
      this.pos += 10;
      return true;
    }
    return false;
  }

  /**
   * 检查是否有 important 声明
   */
  private hasImportant(declarations: CssDeclaration[]): boolean {
    for (let i = 0; i < declarations.length; i++) {
      if (declarations[i].important) {
        return true;
      }
    }
    return false;
  }

  /**
   * 解析属性选择器 [attr=value]
   */
  private parseAttributeSelector(): CssSelector | undefined {
    if (this.peek() !== '[') {
      return undefined;
    }
    this.advance();
    this.skipWhitespaceAndComments();
    const attrName: string = this.parseIdent();
    if (attrName === '') {
      return undefined;
    }
    let attrValue: string = '';
    let op: string = '';
    this.skipWhitespaceAndComments();
    if (this.peek() === '=' || this.peek() === '~' || this.peek() === '|' ||
        this.peek() === '^' || this.peek() === '$' || this.peek() === '*') {
      op += this.peek();
      this.advance();
      if (this.peek() === '=') {
        op += this.peek();
        this.advance();
      }
      this.skipWhitespaceAndComments();
      if (this.peek() === '"' || this.peek() === '\'') {
        const quote: string = this.peek();
        this.advance();
        while (this.pos < this.input.length && this.peek() !== quote) {
          attrValue += this.peek();
          this.advance();
        }
        if (this.peek() === quote) {
          this.advance();
        }
      } else {
        while (this.pos < this.input.length && !(/[\s\]>~+]/.test(this.peek()))) {
          attrValue += this.peek();
          this.advance();
        }
      }
    }
    this.skipWhitespaceAndComments();
    if (this.peek() === ']') {
      this.advance();
    }
    const fullSelector: string = '[' + attrName + op + attrValue + ']';
    return {
      type: SelectorType.ATTRIBUTE,
      value: fullSelector,
      specificity: [0, 1, 0],
      pseudoClass: undefined,
      attributeSelector: attrName
    };
  }

  /**
   * 解析伪类 :pseudo
   */
  private parsePseudoClass(): CssSelector | undefined {
    if (this.peek() !== ':') {
      return undefined;
    }
    this.advance();
    let pseudoName: string = '';
    if (this.peek() === ':') {
      this.advance();
      pseudoName = '::';
    }
    pseudoName += this.parseIdent();
    if (pseudoName === '' || pseudoName === ':') {
      return undefined;
    }
    return {
      type: SelectorType.PSEUDO_CLASS,
      value: pseudoName,
      specificity: [0, 1, 0],
      pseudoClass: pseudoName,
      attributeSelector: undefined
    };
  }

  /**
   * 跳过 @ 规则
   */
  private skipAtRule(): void {
    while (this.pos < this.input.length && this.peek() !== '{' && this.peek() !== ';') {
      this.advance();
    }
    if (this.peek() === '{') {
      let depth: number = 1;
      this.advance();
      while (this.pos < this.input.length && depth > 0) {
        if (this.peek() === '{') {
          depth++;
        } else if (this.peek() === '}') {
          depth--;
        }
        this.advance();
      }
    } else if (this.peek() === ';') {
      this.advance();
    }
  }

  /**
   * 跳过空白和注释
   */
  private skipWhitespaceAndComments(): void {
    let skipped: boolean = true;
    while (skipped) {
      skipped = false;
      while (this.pos < this.input.length && /[\s\n\r\t]/.test(this.peek())) {
        this.advance();
        skipped = true;
      }
      if (this.input.substring(this.pos, this.pos + 2) === '/*') {
        const endIdx: number = this.input.indexOf('*/', this.pos + 2);
        if (endIdx >= 0) {
          this.pos = endIdx + 2;
          skipped = true;
        } else {
          this.pos = this.input.length;
          skipped = true;
        }
      }
    }
  }

  private peek(): string {
    if (this.pos < this.input.length) {
      return this.input[this.pos];
    }
    return '';
  }

  private peekAt(offset: number): string {
    const idx: number = this.pos + offset;
    if (idx >= 0 && idx < this.input.length) {
      return this.input[idx];
    }
    return '';
  }

  private advance(): void {
    this.pos++;
  }
}
