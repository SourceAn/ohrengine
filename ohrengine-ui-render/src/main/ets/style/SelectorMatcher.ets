/**
 * CSS Selector Matching Engine
 *
 * Performs correct right-to-left CSS selector matching against the DOM tree.
 * Parses combined selector strings (output of CssParser's mergeSelectors())
 * into structured selector chains and evaluates them against DomNode elements.
 *
 * Usage:
 *   const matcher: SelectorMatcher = new SelectorMatcher();
 *   const matches: boolean = matcher.matches('div.warning > p.highlight', element);
 */

import { DomNodeType } from 'ohrengine-common';
import type { DomNode } from 'ohrengine-common';

// ---- Data Types (defined before class to satisfy ArkTS constraints) ----

/**
 * CSS combinator types
 */
export enum Combinator {
  DESCENDANT = ' ',
  CHILD = '>',
  ADJACENT_SIBLING = '+',
  GENERAL_SIBLING = '~'
}

/**
 * Attribute selector operator types
 */
export enum AttrOp {
  PRESENT,
  EQUALS,
  INCLUDES,
  DASH_MATCH,
  PREFIX,
  SUFFIX,
  SUBSTRING
}

/**
 * Attribute selector condition
 */
export interface AttrCondition {
  attr: string;
  op: AttrOp;
  value: string;
}

/**
 * Pseudo-class information (name + optional parameter)
 */
export interface PseudoClassInfo {
  name: string;
  param?: string;
}

/**
 * A single compound selector (tag.class#id[attr]:pseudo)
 */
export interface CompoundSelector {
  tag?: string;
  classes: string[];
  id?: string;
  attributeConditions: AttrCondition[];
  pseudoClass?: PseudoClassInfo;
}

/**
 * A link in the selector chain: a combinator plus the compound it connects
 */
export interface SelectorChainLink {
  combinator: Combinator;
  compound: CompoundSelector;
}

/**
 * A complete selector chain — left-to-right list of links
 */
export interface SelectorChain {
  links: SelectorChainLink[];
}

/**
 * Parsed an+b expression for :nth-child / :nth-of-type
 */
export interface AnPlusB {
  a: number;
  b: number;
}

/**
 * SelectorMatcher — stateless CSS selector matching engine.
 * Parses combined selector strings and performs right-to-left matching.
 */
export class SelectorMatcher {
  /**
   * Check if a CSS selector matches a DOM element.
   * @param selectorStr - Combined selector string (e.g. 'div.warning>p.highlight')
   * @param element - The target DOM element (parent chain must be intact)
   * @returns true if the selector matches the element
   */
  public matches(selectorStr: string, element: DomNode): boolean {
    const chain: SelectorChain | null = this.parseSelector(selectorStr);
    if (chain === null) {
      return false;
    }
    return this.matchRightToLeft(chain, element);
  }

  /**
   * Parse a combined selector string into a structured SelectorChain.
   */
  private parseSelector(selectorStr: string): SelectorChain | null {
    // Return null for empty or whitespace-only input
    const trimmed: string = selectorStr.trim();
    if (trimmed.length === 0) {
      return null;
    }

    const len: number = selectorStr.length;
    const links: SelectorChainLink[] = [];

    let i: number = 0;
    let parenDepth: number = 0;
    let partStart: number = 0;
    let pendingCombinator: Combinator = Combinator.DESCENDANT;

    while (i < len) {
      const ch: string = selectorStr[i];

      // Track parenthesis nesting
      if (ch === '(') {
        parenDepth++;
        i++;
        continue;
      }
      if (ch === ')') {
        if (parenDepth > 0) {
          parenDepth--;
        }
        i++;
        continue;
      }

      // Inside parentheses — skip combinator detection
      if (parenDepth > 0) {
        i++;
        continue;
      }

      // --- Combinator detection (outside parentheses) ---

      if (ch === '>') {
        const part: string = selectorStr.substring(partStart, i).trim();
        if (part.length > 0) {
          links.push({
            combinator: pendingCombinator,
            compound: this.parseCompound(part)
          });
        }
        pendingCombinator = Combinator.CHILD;
        i++;
        partStart = i;
        continue;
      }

      if (ch === '+') {
        const part: string = selectorStr.substring(partStart, i).trim();
        if (part.length > 0) {
          links.push({
            combinator: pendingCombinator,
            compound: this.parseCompound(part)
          });
        }
        pendingCombinator = Combinator.ADJACENT_SIBLING;
        i++;
        partStart = i;
        continue;
      }

      if (ch === '~') {
        const part: string = selectorStr.substring(partStart, i).trim();
        if (part.length > 0) {
          links.push({
            combinator: pendingCombinator,
            compound: this.parseCompound(part)
          });
        }
        pendingCombinator = Combinator.GENERAL_SIBLING;
        i++;
        partStart = i;
        continue;
      }

      // Whitespace combinator (space, tab, newline, etc.)
      if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\f') {
        const part: string = selectorStr.substring(partStart, i).trim();
        if (part.length > 0) {
          links.push({
            combinator: pendingCombinator,
            compound: this.parseCompound(part)
          });
          pendingCombinator = Combinator.DESCENDANT;
        }
        // Consume ALL consecutive whitespace as a single descendant combinator
        while (i < len) {
          const next: string = selectorStr[i];
          if (next === ' ' || next === '\t' || next === '\n' || next === '\r' || next === '\f') {
            i++;
          } else {
            break;
          }
        }
        partStart = i;
        continue;
      }

      // Regular character — advance
      i++;
    }

    // Handle the remaining part after the last combinator
    const lastPart: string = selectorStr.substring(partStart).trim();
    if (lastPart.length > 0) {
      links.push({
        combinator: pendingCombinator,
        compound: this.parseCompound(lastPart)
      });
    }

    if (links.length === 0) {
      return null;
    }

    return { links };
  }

  /**
   * Parse a single compound selector part into CompoundSelector.
   */
  private parseCompound(part: string): CompoundSelector {
    const result: CompoundSelector = {
      classes: [],
      attributeConditions: []
    };

    let pos: number = 0;
    const len: number = part.length;

    // --- Parse optional tag name / universal selector ---
    if (len > 0) {
      if (part[0] === '*') {
        // Universal selector — skip it, no tag set
        pos = 1;
      } else if (part[0] !== '.' && part[0] !== '#' && part[0] !== '[' && part[0] !== ':') {
        // Read tag name: letters, digits, hyphens
        const tagStart: number = pos;
        while (pos < len) {
          const ch: string = part[pos];
          if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9') || ch === '-') {
            pos++;
          } else {
            break;
          }
        }
        if (pos > tagStart) {
          result.tag = part.substring(tagStart, pos);
        }
      }
    }

    // --- Parse classes, id, attributes, pseudo-classes ---
    while (pos < len) {
      const ch: string = part[pos];

      if (ch === '.') {
        // Parse class name
        pos++; // skip '.'
        const clsStart: number = pos;
        while (pos < len) {
          const c: string = part[pos];
          if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c === '-' || c === '_') {
            pos++;
          } else {
            break;
          }
        }
        if (pos > clsStart) {
          result.classes.push(part.substring(clsStart, pos));
        }
      } else if (ch === '#') {
        // Parse ID
        pos++; // skip '#'
        const idStart: number = pos;
        while (pos < len) {
          const c: string = part[pos];
          if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c === '-' || c === '_') {
            pos++;
          } else {
            break;
          }
        }
        if (pos > idStart) {
          result.id = part.substring(idStart, pos);
        }
      } else if (ch === '[') {
        // Parse attribute condition — find matching ']'
        pos++; // skip '['
        const attrStart: number = pos;
        while (pos < len && part[pos] !== ']') {
          pos++;
        }
        const inner: string = part.substring(attrStart, pos);
        result.attributeConditions.push(this.parseAttributeCondition(inner));
        pos++; // skip ']'
      } else if (ch === ':') {
        // Parse pseudo-class
        pos++; // skip ':'
        const pseudoStart: number = pos;

        // Read pseudo-class name (letters, digits, hyphens)
        while (pos < len) {
          const c: string = part[pos];
          if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c === '-') {
            pos++;
          } else {
            break;
          }
        }

        // Check for parenthesized parameter like :nth-child(2n+1)
        if (pos < len && part[pos] === '(') {
          const parenStart: number = pseudoStart;
          let parenDepth: number = 1;
          pos++; // skip '('
          while (pos < len && parenDepth > 0) {
            if (part[pos] === '(') {
              parenDepth++;
            } else if (part[pos] === ')') {
              parenDepth--;
            }
            if (parenDepth > 0) {
              pos++;
            }
          }
          pos++; // skip ')'
          const pseudoFull: string = part.substring(parenStart, pos);
          const parsedPseudo: PseudoClassInfo | undefined = this.parsePseudoClass(pseudoFull);
          if (parsedPseudo !== undefined) {
            result.pseudoClass = parsedPseudo;
          }
        } else {
          const pseudoName: string = part.substring(pseudoStart, pos);
          if (pseudoName.length > 0) {
            const parsedPseudo: PseudoClassInfo | undefined = this.parsePseudoClass(pseudoName);
            if (parsedPseudo !== undefined) {
              result.pseudoClass = parsedPseudo;
            }
          }
        }
      } else {
        // Unknown character — skip
        pos++;
      }
    }

    return result;
  }

  /**
   * Parse a pseudo-class string into PseudoClassInfo.
   */
  private parsePseudoClass(pseudo: string): PseudoClassInfo | undefined {
    const trimmed: string = pseudo.trim();
    if (trimmed.length === 0) {
      return undefined;
    }

    const parenIndex: number = trimmed.indexOf('(');

    // Non-parameterized pseudo-classes
    if (parenIndex === -1) {
      const knownPseudos: string[] = [
        'first-child', 'last-child', 'first-of-type', 'last-of-type',
        'empty', 'hover', 'active', 'focus', 'checked', 'disabled', 'enabled'
      ];
      if (knownPseudos.indexOf(trimmed) !== -1) {
        return { name: trimmed };
      }
      return undefined;
    }

    // Parameterized pseudo-class: name(param)
    const name: string = trimmed.substring(0, parenIndex).trim();
    const inner: string = trimmed.substring(parenIndex + 1);
    if (inner.length === 0 || inner[inner.length - 1] !== ')') {
      return undefined; // malformed, missing trailing ')'
    }
    const param: string = inner.substring(0, inner.length - 1).trim();

    const knownParamPseudos: string[] = [
      'nth-child', 'nth-of-type', 'nth-last-child', 'nth-last-of-type', 'not'
    ];
    if (knownParamPseudos.indexOf(name) !== -1) {
      return { name: name, param: param };
    }
    return undefined;
  }

  /**
   * Parse an attribute selector string into AttrCondition.
   */
  private parseAttributeCondition(attrStr: string): AttrCondition {
    const trimmed: string = attrStr.trim();
    const result: AttrCondition = {
      attr: '',
      op: AttrOp.PRESENT,
      value: ''
    };

    if (trimmed.length === 0) {
      return result;
    }

    // Detect operator — check multi-character operators before single '='
    let opPos: number = -1;
    let opStr: string = '';
    const ops: string[] = ['~=', '|=', '^=', '$=', '*=', '='];
    for (const op of ops) {
      const idx: number = trimmed.indexOf(op);
      if (idx !== -1) {
        opPos = idx;
        opStr = op;
        break;
      }
    }

    if (opPos === -1) {
      // No operator found — treat entire string as attribute name (PRESENT)
      result.attr = trimmed;
      return result;
    }

    // Extract attribute name (before operator)
    result.attr = trimmed.substring(0, opPos).trim();

    // Extract and clean value (after operator)
    let rawValue: string = trimmed.substring(opPos + opStr.length).trim();
    if ((rawValue.startsWith('"') && rawValue.endsWith('"')) ||
        (rawValue.startsWith("'") && rawValue.endsWith("'"))) {
      rawValue = rawValue.substring(1, rawValue.length - 1);
    }
    result.value = rawValue;

    // Map operator string to AttrOp enum
    switch (opStr) {
      case '=':
        result.op = AttrOp.EQUALS;
        break;
      case '~=':
        result.op = AttrOp.INCLUDES;
        break;
      case '|=':
        result.op = AttrOp.DASH_MATCH;
        break;
      case '^=':
        result.op = AttrOp.PREFIX;
        break;
      case '$=':
        result.op = AttrOp.SUFFIX;
        break;
      case '*=':
        result.op = AttrOp.SUBSTRING;
        break;
    }

    return result;
  }

  /**
   * Parse an an+b expression string into AnPlusB.
   */
  private parseAnPlusB(expression: string): AnPlusB | null {
    const expr: string = expression.trim();
    const len: number = expr.length;

    if (len === 0) {
      return null;
    }

    // Handle keyword forms
    if (expr === 'odd') {
      return { a: 2, b: 1 };
    }
    if (expr === 'even') {
      return { a: 2, b: 0 };
    }

    let pos: number = 0;
    let sign: number = 1;

    // Parse optional leading sign
    if (expr[pos] === '+') {
      sign = 1;
      pos++;
    } else if (expr[pos] === '-') {
      sign = -1;
      pos++;
    }

    // Parse digits for the 'a' coefficient
    let aValue: number = 0;
    let hasDigits: boolean = false;
    while (pos < len && expr[pos] >= '0' && expr[pos] <= '9') {
      aValue = aValue * 10 + (expr.charCodeAt(pos) - 48);
      hasDigits = true;
      pos++;
    }

    // Check for 'n' or 'N' (an+b form)
    if (pos < len && (expr[pos] === 'n' || expr[pos] === 'N')) {
      pos++; // consume 'n'

      // Determine 'a': if digits were parsed use them, otherwise implicit 1
      const a: number = hasDigits ? sign * aValue : sign * 1;

      // Parse optional b part after 'n'
      let b: number = 0;

      if (pos < len) {
        // Must have a sign before b
        let bSign: number = 1;
        if (expr[pos] === '+') {
          bSign = 1;
          pos++;
        } else if (expr[pos] === '-') {
          bSign = -1;
          pos++;
        } else {
          return null; // expected '+' or '-' after 'n'
        }

        // Must have at least one digit after the sign
        if (pos >= len || expr[pos] < '0' || expr[pos] > '9') {
          return null;
        }
        let bValue: number = 0;
        while (pos < len && expr[pos] >= '0' && expr[pos] <= '9') {
          bValue = bValue * 10 + (expr.charCodeAt(pos) - 48);
          pos++;
        }
        b = bSign * bValue;
      }

      // Must have consumed all input
      if (pos !== len) {
        return null;
      }

      return { a, b };
    }

    // No 'n' found — bare integer form: {a: 0, b: <value>}
    if (!hasDigits || pos !== len) {
      return null;
    }

    return { a: 0, b: sign * aValue };
  }

  /**
   * Right-to-left matching against the DOM tree.
   */
  private matchRightToLeft(chain: SelectorChain, element: DomNode): boolean {
    if (chain.links.length === 0) {
      return false;
    }

    // Start from the rightmost link
    let linkIndex: number = chain.links.length - 1;
    let currentElement: DomNode = element;

    // Check the rightmost compound against the starting element
    if (!this.matchCompound(chain.links[linkIndex].compound, currentElement)) {
      return false;
    }

    // Walk leftwards through remaining links
    for (let i: number = linkIndex - 1; i >= 0; i--) {
      const link: SelectorChainLink = chain.links[i];
      const combinator: Combinator = link.combinator;

      switch (combinator) {
        case Combinator.DESCENDANT: {
          // Move up parent chain until one matches
          let ancestor: DomNode | undefined = currentElement.parent;
          let matched: boolean = false;
          while (ancestor !== undefined) {
            if (this.matchCompound(link.compound, ancestor)) {
              currentElement = ancestor;
              matched = true;
              break;
            }
            ancestor = ancestor.parent;
          }
          if (!matched) {
            return false;
          }
          break;
        }
        case Combinator.CHILD: {
          const parent: DomNode | undefined = currentElement.parent;
          if (parent === undefined || !this.matchCompound(link.compound, parent)) {
            return false;
          }
          currentElement = parent;
          break;
        }
        case Combinator.ADJACENT_SIBLING: {
          const prevSibling: DomNode | undefined = this.getPreviousSibling(currentElement);
          if (prevSibling === undefined || !this.matchCompound(link.compound, prevSibling)) {
            return false;
          }
          currentElement = prevSibling;
          break;
        }
        case Combinator.GENERAL_SIBLING: {
          // Scan ALL preceding element siblings; return true if ANY matches
          const parent: DomNode | undefined = currentElement.parent;
          if (parent === undefined) {
            return false;
          }
          // Find index of currentElement in parent.children
          let elemIdx: number = -1;
          for (let j: number = 0; j < parent.children.length; j++) {
            if (parent.children[j] === currentElement) {
              elemIdx = j;
              break;
            }
          }
          if (elemIdx === -1) {
            return false;
          }
          let matched: boolean = false;
          for (let j: number = elemIdx - 1; j >= 0; j--) {
            const sibling: DomNode = parent.children[j];
            if (sibling.nodeType === DomNodeType.ELEMENT) {
              if (this.matchCompound(link.compound, sibling)) {
                currentElement = sibling;
                matched = true;
                break;
              }
            }
          }
          if (!matched) {
            return false;
          }
          break;
        }
        default:
          return false;
      }
    }

    return true;
  }

  /**
   * Match a single compound selector against one element.
   */
  private matchCompound(compound: CompoundSelector, element: DomNode): boolean {
    // Tag check
    if (compound.tag !== undefined && compound.tag !== '*') {
      if (element.tagName === undefined || element.tagName.toUpperCase() !== compound.tag.toUpperCase()) {
        return false;
      }
    }

    // Class check
    if (compound.classes.length > 0) {
      const classAttr: string | undefined = element.attributes['class'];
      if (classAttr === undefined) {
        return false;
      }
      const elementClasses: string[] = this.splitWhitespace(classAttr);
      for (let i: number = 0; i < compound.classes.length; i++) {
        let found: boolean = false;
        for (let j: number = 0; j < elementClasses.length; j++) {
          if (elementClasses[j] === compound.classes[i]) {
            found = true;
            break;
          }
        }
        if (!found) {
          return false;
        }
      }
    }

    // Id check
    if (compound.id !== undefined) {
      const idAttr: string | undefined = element.attributes['id'];
      if (idAttr === undefined || idAttr !== compound.id) {
        return false;
      }
    }

    // Attribute conditions
    for (let i: number = 0; i < compound.attributeConditions.length; i++) {
      if (!this.checkAttribute(element, compound.attributeConditions[i])) {
        return false;
      }
    }

    // Pseudo-class
    if (compound.pseudoClass !== undefined) {
      if (!this.checkPseudoClass(compound.pseudoClass, element)) {
        return false;
      }
    }

    return true;
  }

  /**
   * Split a string by ASCII whitespace (' ', '\t', '\n', '\r', '\f').
   * Avoids RegExp literal which is not allowed in ArkTS.
   */
  private splitWhitespace(input: string): string[] {
    const result: string[] = [];
    let current: string = '';
    for (let i: number = 0; i < input.length; i++) {
      const ch: string = input[i];
      if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\f') {
        if (current.length > 0) {
          result.push(current);
          current = '';
        }
      } else {
        current += ch;
      }
    }
    if (current.length > 0) {
      result.push(current);
    }
    return result;
  }

  /**
   * Check an attribute condition against an element.
   */
  private checkAttribute(element: DomNode, condition: AttrCondition): boolean {
    const value: string | undefined = element.attributes[condition.attr];
    if (value === undefined) {
      return false;
    }
    switch (condition.op) {
      case AttrOp.PRESENT:
        return true;
      case AttrOp.EQUALS:
        return value === condition.value;
      case AttrOp.INCLUDES: {
        const segments: string[] = this.splitWhitespace(value);
        for (let i: number = 0; i < segments.length; i++) {
          if (segments[i] === condition.value) {
            return true;
          }
        }
        return false;
      }
      case AttrOp.DASH_MATCH:
        return value === condition.value || value.startsWith(condition.value + '-');
      case AttrOp.PREFIX:
        return value.startsWith(condition.value);
      case AttrOp.SUFFIX:
        return value.endsWith(condition.value);
      case AttrOp.SUBSTRING:
        return value.indexOf(condition.value) !== -1;
      default:
        return false;
    }
  }

  /**
   * Evaluate an an+b formula against a 1-based index.
   * Returns true if there exists a non-negative integer n such that a*n + b === index.
   */
  private evaluateAnPlusB(ab: AnPlusB, index: number): boolean {
    if (ab.a === 0) {
      return index === ab.b;
    }
    // Solve n = (index - b) / a, must be an integer >= 0
    if ((index - ab.b) % ab.a !== 0) {
      return false;
    }
    const n: number = (index - ab.b) / ab.a;
    return n >= 0;
  }

  /**
   * Evaluate a pseudo-class against an element.
   */
  private checkPseudoClass(pseudo: PseudoClassInfo, element: DomNode): boolean {
    switch (pseudo.name) {
      case 'first-child':
        return this.getElementIndex(element) === 1;
      case 'last-child': {
        const parent: DomNode | undefined = element.parent;
        if (parent === undefined) {
          return false;
        }
        for (let i: number = parent.children.length - 1; i >= 0; i--) {
          const child: DomNode = parent.children[i];
          if (child.nodeType === DomNodeType.ELEMENT) {
            return child === element;
          }
        }
        return false;
      }
      case 'first-of-type':
        return this.getTypeIndex(element) === 1;
      case 'last-of-type': {
        const parent: DomNode | undefined = element.parent;
        if (parent === undefined) {
          return false;
        }
        for (let i: number = parent.children.length - 1; i >= 0; i--) {
          const child: DomNode = parent.children[i];
          if (child.nodeType === DomNodeType.ELEMENT &&
              child.tagName !== undefined && element.tagName !== undefined &&
              child.tagName.toUpperCase() === element.tagName.toUpperCase()) {
            return child === element;
          }
        }
        return false;
      }
      case 'nth-child': {
        if (pseudo.param === undefined) {
          return false;
        }
        const ab: AnPlusB | null = this.parseAnPlusB(pseudo.param);
        if (ab === null) {
          return false;
        }
        return this.evaluateAnPlusB(ab, this.getElementIndex(element));
      }
      case 'nth-of-type': {
        if (pseudo.param === undefined) {
          return false;
        }
        const ab: AnPlusB | null = this.parseAnPlusB(pseudo.param);
        if (ab === null) {
          return false;
        }
        return this.evaluateAnPlusB(ab, this.getTypeIndex(element));
      }
      case 'nth-last-child': {
        if (pseudo.param === undefined) {
          return false;
        }
        const ab: AnPlusB | null = this.parseAnPlusB(pseudo.param);
        if (ab === null) {
          return false;
        }
        const parent: DomNode | undefined = element.parent;
        if (parent === undefined) {
          return false;
        }
        let total: number = 0;
        let elementIdx: number = 0;
        for (let i: number = 0; i < parent.children.length; i++) {
          const child: DomNode = parent.children[i];
          if (child.nodeType === DomNodeType.ELEMENT) {
            total++;
            if (child === element) {
              elementIdx = total;
            }
          }
        }
        const reverseIndex: number = total - elementIdx + 1;
        return this.evaluateAnPlusB(ab, reverseIndex);
      }
      case 'nth-last-of-type': {
        if (pseudo.param === undefined) {
          return false;
        }
        const ab: AnPlusB | null = this.parseAnPlusB(pseudo.param);
        if (ab === null) {
          return false;
        }
        const parent: DomNode | undefined = element.parent;
        if (parent === undefined) {
          return false;
        }
        let total: number = 0;
        let elementIdx: number = 0;
        for (let i: number = 0; i < parent.children.length; i++) {
          const child: DomNode = parent.children[i];
          if (child.nodeType === DomNodeType.ELEMENT &&
              child.tagName !== undefined && element.tagName !== undefined &&
              child.tagName.toUpperCase() === element.tagName.toUpperCase()) {
            total++;
            if (child === element) {
              elementIdx = total;
            }
          }
        }
        const reverseIndex: number = total - elementIdx + 1;
        return this.evaluateAnPlusB(ab, reverseIndex);
      }
      case 'empty': {
        for (let i: number = 0; i < element.children.length; i++) {
          if (element.children[i].nodeType === DomNodeType.ELEMENT) {
            return false;
          }
        }
        return true;
      }
      case 'hover':
      case 'active':
      case 'focus':
      case 'checked':
      case 'disabled':
      case 'enabled':
        return false;
      case 'not': {
        if (pseudo.param === undefined) {
          return false;
        }
        const inner: CompoundSelector = this.parseCompound(pseudo.param);
        return !this.matchCompound(inner, element);
      }
      default:
        return false;
    }
  }

  /**
   * Get 1-based index of element among parent's element-type children.
   */
  private getElementIndex(element: DomNode): number {
    const parent: DomNode | undefined = element.parent;
    if (parent === undefined) {
      return 0;
    }
    let index: number = 0;
    for (let i: number = 0; i < parent.children.length; i++) {
      const child: DomNode = parent.children[i];
      if (child.nodeType === DomNodeType.ELEMENT) {
        index++;
        if (child === element) {
          return index;
        }
      }
    }
    return 0;
  }

  /**
   * Get 1-based index of element among same-tag siblings.
   */
  private getTypeIndex(element: DomNode): number {
    const parent: DomNode | undefined = element.parent;
    if (parent === undefined) {
      return 0;
    }
    let index: number = 0;
    for (let i: number = 0; i < parent.children.length; i++) {
      const child: DomNode = parent.children[i];
      if (child.nodeType === DomNodeType.ELEMENT &&
          child.tagName !== undefined && element.tagName !== undefined &&
          child.tagName.toUpperCase() === element.tagName.toUpperCase()) {
        index++;
        if (child === element) {
          return index;
        }
      }
    }
    return 0;
  }

  /**
   * Find the nearest preceding element sibling.
   */
  private getPreviousSibling(element: DomNode): DomNode | undefined {
    const parent: DomNode | undefined = element.parent;
    if (parent === undefined) {
      return undefined;
    }
    let elementIdx: number = -1;
    for (let i: number = 0; i < parent.children.length; i++) {
      if (parent.children[i] === element) {
        elementIdx = i;
        break;
      }
    }
    if (elementIdx === -1) {
      return undefined;
    }
    for (let i: number = elementIdx - 1; i >= 0; i--) {
      if (parent.children[i].nodeType === DomNodeType.ELEMENT) {
        return parent.children[i];
      }
    }
    return undefined;
  }
}
