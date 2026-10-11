/**
 * CSS 编译器
 *
 * 职责：
 * 1. 将 CssRuleSet（CssParser 的输出）编译为按选择器类型索引的结构
 * 2. 规则排序：sourcePriority → !important → specificity → sourceOrder
 * 3. 多样式表合并（UA 表 + 作者表 + 用户表）
 * 4. 提供 CompiledStylesheet，供 HtmlParser 在 convertNode 时做样式匹配
 */

import { StyleSource, SelectorType } from 'ohrengine-parsers';
import type { CssRule, CssSelector, CssRuleSet } from 'ohrengine-parsers';

/**
 * 来源优先级权重（数值越低优先级越高）
 * USER_AGENT → AUTHOR → USER
 */
function sourcePriority(source: StyleSource): number {
  if (source === StyleSource.USER_AGENT) {
    return 0;
  }
  if (source === StyleSource.USER) {
    return 2;
  }
  return 1; // AUTHOR
}

/**
 * 比较特异性数组 [a, b, c]
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
 * 已排序的规则条目（含优先级排序键）
 */
export interface CompiledRule {
  rule: CssRule;
  source: StyleSource;
  priority: number[];          // [sourcePriority, important, specA, specB, specC, sourceOrder]
  rightmostTag: string;
  rightmostClass: string;
  rightmostId: string;
}

/**
 * 编译后的样式表 — 按选择器类型分桶存储，每桶内已排序
 */
export class CompiledStylesheet {
  /**
   * 标签名 → 匹配此标签的已排序规则
   */
  public tagRules: Map<string, CompiledRule[]> = new Map();

  /**
   * 类名 → 匹配此类的已排序规则
   */
  public classRules: Map<string, CompiledRule[]> = new Map();

  /**
   * ID → 匹配此 ID 的已排序规则
   */
  public idRules: Map<string, CompiledRule[]> = new Map();

  /**
   * 通配选择器（*）规则 — 匹配所有元素
   */
  public universalRules: CompiledRule[] = [];

  /**
   * 仅通过简单选择器无法匹配的复合/后代规则
   * （在 convertNode 中需要基于 DomNode 树结构判断）
   */
  public otherRules: CompiledRule[] = [];

  /**
   * 合并另一个 CompiledStylesheet 的规则
   */
  public merge(other: CompiledStylesheet): void {
    this.mergeMap(this.tagRules, other.tagRules);
    this.mergeMap(this.classRules, other.classRules);
    this.mergeMap(this.idRules, other.idRules);
    this.mergeArray(this.universalRules, other.universalRules);
    this.mergeArray(this.otherRules, other.otherRules);
  }

  private mergeMap(
    target: Map<string, CompiledRule[]>,
    source: Map<string, CompiledRule[]>
  ): void {
    source.forEach((rules, key) => {
      const existing: CompiledRule[] | undefined = target.get(key);
      if (existing !== undefined) {
        // 归并排序：两个已排序数组合并 → 依然有序
        const merged: CompiledRule[] = [];
        let i = 0;
        let j = 0;
        while (i < existing.length && j < rules.length) {
          if (comparePriority(existing[i].priority, rules[j].priority) <= 0) {
            merged.push(existing[i]);
            i++;
          } else {
            merged.push(rules[j]);
            j++;
          }
        }
        while (i < existing.length) {
          merged.push(existing[i]);
          i++;
        }
        while (j < rules.length) {
          merged.push(rules[j]);
          j++;
        }
        target.set(key, merged);
      } else {
        target.set(key, rules);
      }
    });
  }

  private mergeArray(target: CompiledRule[], source: CompiledRule[]): void {
    const merged: CompiledRule[] = [];
    let i = 0;
    let j = 0;
    while (i < target.length && j < source.length) {
      if (comparePriority(target[i].priority, source[j].priority) <= 0) {
        merged.push(target[i]);
        i++;
      } else {
        merged.push(source[j]);
        j++;
      }
    }
    while (i < target.length) {
      merged.push(target[i]);
      i++;
    }
    while (j < source.length) {
      merged.push(source[j]);
      j++;
    }
    // 替换原有数组
    target.length = 0;
    for (let k = 0; k < merged.length; k++) {
      target.push(merged[k]);
    }
  }
}

/**
 * 创建已编译规则条目
 */
function createCompiledRule(rule: CssRule, source: StyleSource): CompiledRule {
  const spec: number[] = rule.selectors.length > 0
    ? rule.selectors[0].specificity : [0, 0, 0];
  return {
    rule: rule,
    source: source,
    priority: [
      sourcePriority(source),
      rule.important ? 1 : 0,
      spec[0],
      spec[1],
      spec[2],
      rule.sourceOrder
    ],
    rightmostTag: '',
    rightmostClass: '',
    rightmostId: ''
  };
}

/**
 * 比较两条规则的优先级（数值小的优先）
 * 用于归并排序
 */
function comparePriority(a: number[], b: number[]): number {
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      return a[i] - b[i];
    }
  }
  return 0;
}

/**
 * Rightmost selector info for fast-check pre-filtering.
 */
export interface RightmostSelectorInfo {
  tag: string;
  cls: string;
  id: string;
}

/**
 * Extract rightmost simple selector info from a combined selector string.
 * Scans right-to-left for tag name, class, and ID at the end of the selector.
 * This enables fast-check pre-filtering before full selector matching.
 */
export function extractRightmostInfo(selectorStr: string): RightmostSelectorInfo {
  const result: RightmostSelectorInfo = { tag: '', cls: '', id: '' };
  const len: number = selectorStr.length;

  // Scan right-to-left, stop at combinator (space, >, +, ~) outside parens
  let parenDepth: number = 0;
  let pos: number = len - 1;

  // Skip trailing whitespace
  while (pos >= 0 && selectorStr[pos] === ' ') {
    pos--;
  }

  // Find the start of the rightmost simple selector
  let end: number = pos + 1;
  while (pos >= 0) {
    const ch: string = selectorStr[pos];
    if (ch === ')') {
      parenDepth++;
    } else if (ch === '(') {
      parenDepth--;
    } else if (parenDepth === 0 && (ch === '>' || ch === '+' || ch === '~' || ch === ' ')) {
      // Found combinator — stop
      break;
    }
    pos--;
  }

  const rightmostStr: string = selectorStr.substring(pos + 1, end).trim();
  if (rightmostStr.length === 0) {
    return result;
  }

  // Scan rightmostStr for tag, class, id
  let i: number = 0;
  while (i < rightmostStr.length) {
    const c: string = rightmostStr[i];
    if (c === '.') {
      // Read class name
      i++;
      const start: number = i;
      while (i < rightmostStr.length) {
        const ch: string = rightmostStr[i];
        const isIdent: boolean = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch === '-' || ch === '_';
        if (!isIdent) { break; }
        i++;
      }
      if (i > start && result.cls.length === 0) {
        result.cls = rightmostStr.substring(start, i);
      }
    } else if (c === '#') {
      // Read ID
      i++;
      const start: number = i;
      while (i < rightmostStr.length) {
        const ch: string = rightmostStr[i];
        const isIdent: boolean = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch === '-' || ch === '_';
        if (!isIdent) { break; }
        i++;
      }
      if (i > start && result.id.length === 0) {
        result.id = rightmostStr.substring(start, i);
      }
    } else if (c === '[' || c === ':') {
      break; // Skip attribute/pseudo selectors for fast-check
    } else if (c === '*') {
      i++;
      // universal — no tag
    } else {
      // Tag name (letters, digits, hyphens)
      const start: number = i;
      while (i < rightmostStr.length) {
        const ch: string = rightmostStr[i];
        const isIdent: boolean = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch === '-' || ch === '_';
        if (!isIdent) { break; }
        i++;
      }
      if (i > start && result.tag.length === 0) {
        result.tag = rightmostStr.substring(start, i);
      }
    }
  }

  return result;
}

/**
 * 编译 CssRuleSet 为 CompiledStylesheet
 *
 * 将规则按选择器类型分桶，每桶内按
 * [sourcePriority, !important, specificity, sourceOrder] 排序。
 */
export function compileRuleSet(ruleSet: CssRuleSet, source: StyleSource): CompiledStylesheet {
  const sheet: CompiledStylesheet = new CompiledStylesheet();

  for (let i = 0; i < ruleSet.rules.length; i++) {
    const rule: CssRule = ruleSet.rules[i];
    const compiled: CompiledRule = createCompiledRule(rule, source);

    // Extract rightmost info for fast-check pre-filtering
    if (rule.selectors.length > 0 && rule.selectors[0].type === SelectorType.GROUP) {
      const info = extractRightmostInfo(rule.selectors[0].value);
      compiled.rightmostTag = info.tag;
      compiled.rightmostClass = info.cls;
      compiled.rightmostId = info.id;
    }

    // 为每个选择器分桶
    let hasBucket: boolean = false;
    for (let j = 0; j < rule.selectors.length; j++) {
      const sel: CssSelector = rule.selectors[j];
      if (sel.type === SelectorType.TAG && sel.value !== '') {
        addToMap(sheet.tagRules, sel.value.toLowerCase(), compiled);
        hasBucket = true;
      } else if (sel.type === SelectorType.CLASS && sel.value !== '') {
        addToMap(sheet.classRules, sel.value, compiled);
        hasBucket = true;
      } else if (sel.type === SelectorType.ID && sel.value !== '') {
        addToMap(sheet.idRules, sel.value, compiled);
        hasBucket = true;
      } else if (sel.type === SelectorType.UNIVERSAL) {
        sheet.universalRules.push(compiled);
        hasBucket = true;
      }
    }

    if (!hasBucket) {
      sheet.otherRules.push(compiled);
    }
  }

  // 桶内排序（如果 push 顺序与 sourceOrder 一致，可免排序。
  // 但 compileRuleSet 接收多个来源的规则，必须统一排序）
  sortBucket(sheet.tagRules);
  sortBucket(sheet.classRules);
  sortBucket(sheet.idRules);
  sheet.universalRules.sort((a, b) => comparePriority(a.priority, b.priority));
  sheet.otherRules.sort((a, b) => comparePriority(a.priority, b.priority));

  return sheet;
}

function addToMap(map: Map<string, CompiledRule[]>, key: string, rule: CompiledRule): void {
  let arr: CompiledRule[] | undefined = map.get(key);
  if (arr === undefined) {
    arr = [];
    map.set(key, arr);
  }
  arr.push(rule);
}

function sortBucket(map: Map<string, CompiledRule[]>): void {
  map.forEach((rules, _key) => {
    rules.sort((a, b) => comparePriority(a.priority, b.priority));
  });
}
