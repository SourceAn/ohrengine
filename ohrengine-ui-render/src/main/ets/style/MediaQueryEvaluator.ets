/**
 * MediaQueryEvaluator — CSS @media query parsing and evaluation
 *
 * Evaluates @media rules against a runtime MediaContext (viewport size,
 * orientation, color scheme, device type). Designed for use during CSS
 * loading: @media blocks that don't match are stripped before the CSS
 * reaches the parser, keeping the pipeline simple.
 *
 * Usage:
 *   const context: MediaContext = { viewWidth: 720, viewHeight: 1080, ... };
 *   const compiler = new MediaConditionalCompiler();
 *   const filtered = compiler.compileWithMedia(cssText, context);
 */

/** Runtime context for evaluating media queries */
export interface MediaContext {
  viewWidth: number;
  viewHeight: number;
  orientation: 'portrait' | 'landscape';
  colorScheme: 'light' | 'dark';
  type: 'screen' | 'print' | 'all';
  /** User contrast preference for prefers-contrast @media feature */
  prefersContrast: 'no-preference' | 'more' | 'less';
  /** User motion sensitivity for prefers-reduced-motion @media feature */
  prefersReducedMotion: 'no-preference' | 'reduce';
  /** Display color gamut for color-gamut @media feature */
  colorGamut: 'srgb' | 'p3' | 'rec2020';
}

/** A single media feature, e.g. (min-width: 600px) → name="min-width", value="600px" */
export interface MediaFeature {
  name: string;
  value?: string;
}

/** A single media query (one item in the comma-separated list) */
export interface MediaQuery {
  not: boolean;
  only: boolean;
  type: string;
  features: MediaFeature[];
}

/** A parsed @media rule */
export interface MediaRule {
  queryText: string;
  queries: MediaQuery[];
  content: string;
}

/**
 * Evaluates media queries against a given MediaContext.
 */
export class MediaQueryEvaluator {
  private context: MediaContext;

  constructor(context: MediaContext) {
    this.context = context;
  }

  /**
   * Extract all @media rules from CSS text.
   * Returns the parsed rules with their query AST and inner content.
   */
  extractMediaRules(cssText: string): MediaRule[] {
    const rules: MediaRule[] = [];
    const regex: RegExp = /@media\s+([^{]+)\{/g;
    let match: RegExpExecArray | null = regex.exec(cssText);
    while (match !== null) {
      const queryText: string = match[1].trim();
      const braceStart: number = match.index + match[0].length - 1; // position of '{'

      // Walk forward to find the matching closing brace (handles nested braces)
      let depth: number = 1;
      let pos: number = braceStart + 1;
      while (depth > 0 && pos < cssText.length) {
        const ch: string = cssText[pos];
        if (ch === '{') {
          depth++;
        } else if (ch === '}') {
          depth--;
        }
        pos++;
      }

      if (depth === 0) {
        const content: string = cssText.substring(braceStart + 1, pos - 1).trim();
        const queries: MediaQuery[] = this.parseMediaQuery(queryText);
        rules.push({ queryText, queries, content });
      }

      match = regex.exec(cssText);
    }
    return rules;
  }

  /**
   * Parse a media query list string (e.g. "screen and (min-width: 600px), print")
   * into an array of MediaQuery structures.
   */
  parseMediaQuery(text: string): MediaQuery[] {
    const parts: string[] = text.split(',');
    const result: MediaQuery[] = [];
    for (const part of parts) {
      result.push(this.parseSingleQuery(part.trim()));
    }
    return result;
  }

  /**
   * Evaluate whether ANY media query in the list matches the current context
   * (comma = OR logic).
   */
  matches(queries: MediaQuery[]): boolean {
    if (queries.length === 0) {
      return true;
    }
    for (const q of queries) {
      if (this.matchesSingle(q)) {
        return true;
      }
    }
    return false;
  }

  // ---- internal helpers ----

  private parseSingleQuery(text: string): MediaQuery {
    let not: boolean = false;
    let only: boolean = false;
    let type: string = 'all';
    const features: MediaFeature[] = [];

    const tokens: string[] = text.split(/\s+/);
    let i: number = 0;

    if (tokens[i] === 'not') {
      not = true;
      i++;
    } else if (tokens[i] === 'only') {
      only = true;
      i++;
    }

    // Media type (optional; defaults to 'all')
    if (i < tokens.length) {
      const lower: string = tokens[i].toLowerCase();
      if (lower === 'all' || lower === 'screen' || lower === 'print' || lower === 'speech') {
        type = lower;
        i++;
      }
    }

    // Remaining tokens: and (feature) and (feature) ...
    while (i < tokens.length) {
      const token: string = tokens[i];
      if (token === 'and') {
        i++;
        continue;
      }
      if (token.startsWith('(') && token.endsWith(')') && token.length > 2) {
        const inner: string = token.substring(1, token.length - 1);
        features.push(this.parseFeature(inner));
      }
      i++;
    }

    return { not, only, type, features };
  }

  private parseFeature(text: string): MediaFeature {
    const colonIdx: number = text.indexOf(':');
    if (colonIdx >= 0) {
      const name: string = text.substring(0, colonIdx).trim();
      const value: string = text.substring(colonIdx + 1).trim();
      return { name, value };
    }
    return { name: text.trim(), value: undefined };
  }

  private matchesSingle(query: MediaQuery): boolean {
    // Check media type
    let matched: boolean;
    if (query.type === 'all' || query.type === 'screen') {
      matched = true;
    } else if (query.type === 'print') {
      matched = this.context.type === 'print';
    } else {
      matched = false;
    }

    // Check all features (AND logic)
    if (matched) {
      for (const feature of query.features) {
        if (!this.matchesFeature(feature)) {
          matched = false;
          break;
        }
      }
    }

    return query.not ? !matched : matched;
  }

  private matchesFeature(feature: MediaFeature): boolean {
    const name: string = feature.name;
    const value: string | undefined = feature.value;

    if (name === 'width') {
      return value !== undefined && this.context.viewWidth === this.parseLength(value);
    }
    if (name === 'min-width') {
      return value !== undefined && this.context.viewWidth >= this.parseLength(value);
    }
    if (name === 'max-width') {
      return value !== undefined && this.context.viewWidth <= this.parseLength(value);
    }

    if (name === 'height') {
      return value !== undefined && this.context.viewHeight === this.parseLength(value);
    }
    if (name === 'min-height') {
      return value !== undefined && this.context.viewHeight >= this.parseLength(value);
    }
    if (name === 'max-height') {
      return value !== undefined && this.context.viewHeight <= this.parseLength(value);
    }

    if (name === 'orientation') {
      return this.context.orientation === value;
    }

    if (name === 'color-scheme' || name === 'prefers-color-scheme') {
      return this.context.colorScheme === value;
    }

    if (name === 'color') {
      // (color) with no value means "device supports color"
      if (value === undefined) {
        return true;
      }
      return parseInt(value) > 0;
    }

    if (name === 'prefers-contrast') {
      return this.context.prefersContrast === value;
    }

    if (name === 'prefers-reduced-motion') {
      return this.context.prefersReducedMotion === value;
    }

    if (name === 'color-gamut') {
      // color-gamut uses a "min" semantic: if the display gamut matches or exceeds the query
      const gamutRank: Record<string, number> = { 'srgb': 1, 'p3': 2, 'rec2020': 3 };
      const ctxRank: number = gamutRank[this.context.colorGamut] ?? 1;
      const queryRank: number = value !== undefined ? (gamutRank[value] ?? 1) : 1;
      return ctxRank >= queryRank;
    }

    // For features we don't recognise, assume they match (progressive enhancement)
    return true;
  }

  /**
   * Strip CSS length units (px, em, rem, vw, vh, cm, mm, etc.) and return the
   * numeric value. Uses parseInt so "600px" → 600, "20em" → 20, "600" → 600.
   */
  private parseLength(value: string): number {
    return parseInt(value, 10);
  }
}

/**
 * Strips non-matching @media blocks from CSS text at compile time.
 *
 * Given raw CSS and a runtime context, produces a filtered CSS string that
 * contains only:
 *   - All non-@media CSS rules (unchanged)
 *   - The *inner content* of matching @media rules (without the @media wrapper)
 *
 * Non-matching @media blocks are removed entirely.
 */
export class MediaConditionalCompiler {
  compileWithMedia(cssText: string, context: MediaContext): string {
    const evaluator: MediaQueryEvaluator = new MediaQueryEvaluator(context);
    const resultParts: string[] = [];
    let lastIndex: number = 0;

    const mediaRegex: RegExp = /@media\s+([^{]+)\{/g;
    let match: RegExpExecArray | null = mediaRegex.exec(cssText);
    while (match !== null) {
      // 1. Copy text before this @media block
      resultParts.push(cssText.substring(lastIndex, match.index));

      const queryText: string = match[1].trim();
      const braceStart: number = match.index + match[0].length - 1; // position of '{'

      // 2. Find the matching closing brace (handles nested braces)
      let depth: number = 1;
      let pos: number = braceStart + 1;
      while (depth > 0 && pos < cssText.length) {
        const ch: string = cssText[pos];
        if (ch === '{') {
          depth++;
        } else if (ch === '}') {
          depth--;
        }
        pos++;
      }

      const blockEnd: number = depth === 0 ? pos : cssText.length;

      if (depth === 0) {
        const content: string = cssText.substring(braceStart + 1, blockEnd - 1);
        const trimmedContent: string = content.trim();

        // 3. Evaluate the media query
        const queries: MediaQuery[] = evaluator.parseMediaQuery(queryText);
        if (evaluator.matches(queries)) {
          // Matching: emit the inner content (without the @media wrapper)
          resultParts.push(trimmedContent);
        }
        // Non-matching: emit nothing (drop the entire block)
      }

      lastIndex = blockEnd;
      match = mediaRegex.exec(cssText);
    }

    // 4. Copy remaining text after the last @media block
    resultParts.push(cssText.substring(lastIndex));

    return resultParts.join('').trim();
  }
}
