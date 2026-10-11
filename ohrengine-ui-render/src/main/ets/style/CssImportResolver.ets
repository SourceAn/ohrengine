/**
 * CssImportResolver — Recursive CSS @import resolution
 *
 * Responsibilities:
 * 1. Parse @import directives from CSS text
 * 2. Resolve relative URLs against the current CSS file path
 * 3. Recursively load imported CSS (deduplicated by normalized path)
 * 4. Return the flattened list of CSS texts in proper cascade order
 *
 * Usage:
 *   const resolver = new CssImportResolver();
 *   const texts = await resolver.resolve('path/to/style.css', bookBasePath);
 *   // texts: [imported1, imported2, ..., parent-stripped]
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { RemoteResourceLoader, LoadResult } from '../layout/RemoteResourceLoader.ets';

/** Internal value type for parsed @import directives */
interface CssImportDirective {
  url: string;
  media?: string;
}

export class CssImportResolver {
  private loadedUrls: Set<string> = new Set();

  /** Clear the deduplication cache (call between different books) */
  reset(): void {
    this.loadedUrls.clear();
  }

  /**
   * Recursively load CSS and all its @import dependencies.
   * Returns the flattened CSS texts in cascade order:
   *   [grandparent-imports..., parent-imports..., current-stripped]
   *
   * @param cssPath - path of the CSS file relative to the book root
   * @param bookBasePath - absolute path to the book root directory
   * @param remoteLoader - optional RemoteResourceLoader for fetching remote CSS
   * @returns non-empty CSS text strings (empty/stripped results are omitted)
   */
  async resolve(cssPath: string, bookBasePath: string, remoteLoader?: RemoteResourceLoader): Promise<string[]> {
    const normalPath: string = this.normalizePath(cssPath);
    if (this.loadedUrls.has(normalPath)) {
      return [];
    }
    this.loadedUrls.add(normalPath);

    let cssText: string;
    if (normalPath.startsWith('http://') || normalPath.startsWith('https://')) {
      // 远程 CSS：通过 RemoteResourceLoader 获取
      if (remoteLoader === undefined) {
        return [];
      }
      const result: LoadResult = await remoteLoader.fetchText(normalPath);
      if (!result.success || result.data === null) {
        return [];
      }
      cssText = result.data as string;
    } else {
      const fullFsPath: string = bookBasePath + '/' + cssPath;
      cssText = await this.readFile(fullFsPath);
    }

    const imports: CssImportDirective[] = this.extractImports(cssText);
    const result: string[] = [];

    for (const imp of imports) {
      const resolvedPath: string = this.resolvePath(imp.url, cssPath);
      const imported: string[] = await this.resolve(resolvedPath, bookBasePath, remoteLoader);
      result.push(...imported);
    }

    // Strip @import statements from the current CSS (they are already loaded above)
    const clean: string = this.stripImports(cssText);
    if (clean.trim().length > 0) {
      result.push(clean);
    }

    return result;
  }

  /**
   * Extract @import directives from CSS text.
   * Supports all standard forms:
   *   @import url("file.css");
   *   @import url('file.css');
   *   @import url(file.css);
   *   @import "file.css";
   *   @import 'file.css';
   *   @import url("file.css") screen and (min-width: 600px);
   */
  private extractImports(css: string): CssImportDirective[] {
    const imports: CssImportDirective[] = [];
    const pattern: RegExp =
      /@import\s+(?:url\s*\(\s*["']?([^"'\s)]+)["']?\s*\)|["']([^"']+)["'])\s*([^;]*?)?\s*;/g;
    let match: RegExpExecArray | null = pattern.exec(css);
    while (match !== null) {
      const url: string = (match[1] ?? match[2] ?? '').trim();
      const media: string | undefined = match[3] ? match[3].trim() : undefined;
      if (url.length > 0) {
        imports.push({ url, media: media && media.length > 0 ? media : undefined });
      }
      match = pattern.exec(css);
    }
    return imports;
  }

  /**
   * Remove @import statements from CSS text, returning only the body rules.
   */
  private stripImports(css: string): string {
    return css.replace(
      /@import\s+(?:url\s*\(\s*["']?[^"'\s)]+["']?\s*\)|["'][^"']+["'])\s*[^;]*?;/g,
      ''
    ).trim();
  }

  /**
   * Resolve a relative @import URL against the current CSS file path.
   * Supports:
   *   - Absolute paths (starting with '/'): resolve from book root
   *   - Relative paths: resolve relative to the current CSS directory
   *   - '..' and '.' path segments
   */
  private resolvePath(importUrl: string, currentCssPath: string): string {
    const normalized: string = this.normalizePath(importUrl);
    if (normalized.startsWith('/')) {
      // Absolute in EPUB: strip leading slash
      return normalized.substring(1);
    }

    // Relative: resolve against the directory of the current CSS
    const lastSlash: number = currentCssPath.lastIndexOf('/');
    const dir: string = lastSlash >= 0 ? currentCssPath.substring(0, lastSlash + 1) : '';
    const parts: string[] = normalized.split('/');
    const dirParts: string[] = dir.length > 0 ? dir.split('/') : [];

    for (const part of parts) {
      if (part === '..') {
        if (dirParts.length > 0) {
          dirParts.pop();
        }
      } else if (part !== '.') {
        dirParts.push(part);
      }
    }

    return dirParts.join('/');
  }

  /**
   * Normalize a file path: backslash → forward slash, collapse duplicates, strip trailing slash.
   */
  private normalizePath(p: string): string {
    return p.replace(/\\/g, '/').replace(/\/+/g, '/').replace(/\/$/, '');
  }

  /**
   * Read a file from the filesystem and return its UTF-8 text content.
   */
  private async readFile(path: string): Promise<string> {
    let file: fileIo.File;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    } catch (e) {
      throw new Error('CssImportResolver.readFile: open failed: ' + (e instanceof Error ? e.message : String(e)));
    }
    try {
      const stat = fileIo.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf, { offset: 0, length: stat.size });
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf));
    } catch (e) {
      throw new Error('CssImportResolver.readFile: read failed: ' + (e instanceof Error ? e.message : String(e)));
    } finally {
      try {
        fileIo.closeSync(file);
      } catch (_e) {
        // 忽略关闭失败
      }
    }
  }
}
