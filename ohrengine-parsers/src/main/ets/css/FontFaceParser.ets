/**
 * FontFaceParser — @font-face CSS rule parser
 *
 * Extracts @font-face declarations from raw CSS text using regex.
 * Designed as a standalone parser (not extending CssParser) to avoid
 * risk to the existing 600+ line CSS parsing pipeline.
 *
 * Parsed properties:
 *   - font-family (required)
 *   - src         (required, may list multiple urls)
 *   - font-weight (optional)
 *   - font-style  (optional)
 *   - unicode-range (optional)
 */

import type { FontSource, FontFaceRule } from 'ohrengine-common';

/**
 * Parses CSS text to extract @font-face rules.
 *
 * Usage:
 *   const parser: FontFaceParser = new FontFaceParser();
 *   const rules: FontFaceRule[] = parser.parse(cssText);
 */
export class FontFaceParser {
  /**
   * Parse @font-face rules from CSS text.
   * Returns an array of FontFaceRule objects.
   * Returns empty array if no @font-face rules are found.
   */
  public parse(cssText: string): FontFaceRule[] {
    if (cssText.length === 0) {
      return [];
    }

    const rules: FontFaceRule[] = [];
    const blocks: string[] = this.extractFontFaceBlocks(cssText);

    for (let i = 0; i < blocks.length; i++) {
      const block: string = blocks[i];
      const rule: FontFaceRule | undefined = this.parseBlock(block);
      if (rule !== undefined) {
        rules.push(rule);
      }
    }

    return rules;
  }

  /**
   * Extract raw @font-face { ... } blocks from CSS text.
   * Uses brace-depth counting to correctly handle nested braces.
   */
  private extractFontFaceBlocks(cssText: string): string[] {
    const blocks: string[] = [];
    const atRulePattern: RegExp = new RegExp('@font-face\\s*\\{', 'gi');
    let match: RegExpExecArray | null;

    while ((match = atRulePattern.exec(cssText)) !== null) {
      const startIdx: number = match.index;
      const braceStart: number = match.index + match[0].length - 1;
      let braceDepth: number = 1;
      let pos: number = braceStart + 1;

      while (pos < cssText.length && braceDepth > 0) {
        if (cssText[pos] === '{') {
          braceDepth++;
        } else if (cssText[pos] === '}') {
          braceDepth--;
        }
        pos++;
      }

      if (braceDepth === 0) {
        // Extract the full block including @font-face keyword
        const block: string = cssText.substring(startIdx, pos);
        blocks.push(block);
      }
    }

    return blocks;
  }

  /**
   * Parse a single @font-face block into a FontFaceRule.
   */
  private parseBlock(block: string): FontFaceRule | undefined {
    // Extract font-family (required)
    const familyName: string | undefined = this.extractProperty(block, 'font-family');
    if (familyName === undefined || familyName.length === 0) {
      return undefined;
    }

    // Extract src (required)
    const src: FontSource[] = this.extractSrc(block);
    if (src.length === 0) {
      return undefined;
    }

    // Extract optional properties
    const fontWeight: string | undefined = this.extractProperty(block, 'font-weight');
    const fontStyle: string | undefined = this.extractProperty(block, 'font-style');
    const unicodeRange: string | undefined = this.extractProperty(block, 'unicode-range');

    const rule: FontFaceRule = {
      familyName: familyName,
      src: src,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      unicodeRange: unicodeRange
    };

    return rule;
  }

  /**
   * Extract a single CSS property value from a block.
   * Handles quoted values (single or double quotes) and unquoted values.
   */
  private extractProperty(block: string, propertyName: string): string | undefined {
    // Match property: value; — handles quoted and unquoted values
    const pattern: RegExp = new RegExp(
      propertyName + '\\s*:\\s*[\'"]?([^\'";}]+)[\'"]?\\s*(?:;|})',
      'i'
    );
    const match: RegExpExecArray | null = pattern.exec(block);
    if (match === null) {
      return undefined;
    }
    const value: string = match[1].trim();
    if (value.length === 0) {
      return undefined;
    }
    return value;
  }

  /**
   * Extract src URLs from the src descriptor.
   * Handles url('...'), url("..."), url(...) with optional format().
   */
  private extractSrc(block: string): FontSource[] {
    const sources: FontSource[] = [];

    // Extract the src property value first
    const srcPattern: RegExp = new RegExp('src\\s*:\\s*([^;]+)\\s*;', 'i');
    const srcMatch: RegExpExecArray | null = srcPattern.exec(block);
    if (srcMatch === null) {
      return sources;
    }

    const srcValue: string = srcMatch[1].trim();

    // Parse individual url() entries
    const urlPattern: RegExp = new RegExp(
      'url\\([\'"]?([^\'")\\s]+)[\'"]?\\)\\s*(?:format\\([\'"]?([^\'")]+)[\'"]?\\))?',
      'gi'
    );
    let urlMatch: RegExpExecArray | null;

    while ((urlMatch = urlPattern.exec(srcValue)) !== null) {
      let url: string = urlMatch[1].trim();
      // URL-decode the path
      try {
        url = decodeURIComponent(url);
      } catch (_e) {}

      const source: FontSource = {
        url: url
      };

      if (urlMatch[2] !== undefined) {
        source.format = urlMatch[2].trim();
      }

      sources.push(source);
    }

    return sources;
  }
}
