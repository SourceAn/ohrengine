/**
 * CbzParser — Comic Book ZIP (CBZ) parser
 *
 * Parses `.cbz` / `.cbr` comic book files by:
 * 1. Decompressing the ZIP archive to a temporary directory
 * 2. Listing image files sorted in natural order
 * 3. Creating one chapter per image page
 *
 * RenderStrategy is set to IMAGE — the ImageRouter/ImageRenderer
 * handles actual page rendering.
 */

import { BookParser, BookFormat, ParsedBook, RenderStrategy,
  ChapterData, Book, Publication, TocItem, createLinkWithTitle, SecureArchive } from 'ohrengine-common';
import { fileIo } from '@kit.CoreFileKit';

/** Supported image file extensions (lowercase, without dot) */
const IMAGE_EXTENSIONS: string[] = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'];

export class CbzParser implements BookParser {
  public readonly format: BookFormat = BookFormat.CBZ;

  /**
   * Parse a CBZ comic book file.
   *
   * 两种输入形态（打开链路不同，见 OhEngineCore.open）：
   *   - filePath 为 .cbz 归档文件：解压到 `<filePath>.extracted` 后扫描。
   *   - filePath 为已解压目录（Index.ets 对 .cbz 走 SecureArchive 解压后
   *     以 extractDir 为 bookBasePath 打开）：直接扫描，避免重复解压。
   *
   * @param filePath - Absolute sandbox path to the .cbz file or extracted dir
   * @returns ParsedBook with one chapter per image page
   */
  public async parse(filePath: string): Promise<ParsedBook> {
    // 目录输入：已是解压产物，跳过解压直接扫描图片
    if (this.directoryExists(filePath)) {
      return this.buildBookFromImages(filePath);
    }

    const extractDir: string = filePath + '.extracted';

    // Clean up any previous extraction
    this.removeExtractDir(extractDir);

    // Create fresh extraction directory
    try {
      fileIo.mkdirSync(extractDir, true);
    } catch (e) {
      throw new Error('Failed to create CBZ extract directory.');
    }

    // Decompress the CBZ archive via secure extractor (SEC-002):
    // validates path traversal, symlinks, entry/size limits, and cleans up on failure.
    try {
      await SecureArchive.decompressArchive(filePath, extractDir);
    } catch (e) {
      this.removeExtractDir(extractDir);
      throw new Error('Failed to decompress CBZ file.');
    }

    return this.buildBookFromImages(extractDir);
  }

  /** 从图片目录构建 ParsedBook（每图一章；目录输入与解压后共用） */
  private buildBookFromImages(extractDir: string): ParsedBook {
    // Gather image files from the extraction directory
    const imageFiles: string[] = this.listImageFiles(extractDir);

    // Build chapters — one per image page
    const chapters: ChapterData[] = [];
    const imagePaths: string[] = [];
    for (let i = 0; i < imageFiles.length; i++) {
      const fullPath: string = extractDir + '/' + imageFiles[i];
      const chapter: ChapterData = {
        title: 'Page ' + (i + 1),
        content: '',
        href: fullPath,
        imagePaths: [fullPath]
      };
      chapters.push(chapter);
      imagePaths.push(fullPath);
    }

    return new ParsedBook(
      BookFormat.CBZ,
      RenderStrategy.IMAGE,
      null,
      chapters,
      [],
      imagePaths
    );
  }

  /**
   * getBook — Book 接口工厂方法（格式无关入口）
   *
   * 解析 CBZ 并返回 Book 接口实例。
   * CBZ 无原生元数据，故构造最小 Publication：
   * 标题取文件名，每页图片映射为 readingOrder 与 toc。
   *
   * @param filePath - Absolute sandbox path to the .cbz file
   * @returns Book 接口实例
   */
  public async getBook(filePath: string): Promise<Book> {
    const parsed: ParsedBook = await this.parse(filePath);
    const publication: Publication = new Publication(this.titleFromPath(filePath));
    for (let i = 0; i < parsed.chapters.length; i++) {
      const chapter: ChapterData = parsed.chapters[i];
      publication.manifest.readingOrder.push(
        createLinkWithTitle(chapter.href, this.mediaTypeFor(chapter.href), chapter.title));
      const item: TocItem = { title: chapter.title, href: chapter.href };
      publication.toc.push(item);
    }
    return publication;
  }

  /**
   * 从文件路径提取书名（去掉目录与扩展名）。
   */
  private titleFromPath(filePath: string): string {
    const lastSlash: number = filePath.lastIndexOf('/');
    const fileName: string = lastSlash >= 0 ? filePath.substring(lastSlash + 1) : filePath;
    const dot: number = fileName.lastIndexOf('.');
    if (dot > 0) {
      return fileName.substring(0, dot);
    }
    return fileName;
  }

  /**
   * 根据图片 href 推断 mediaType。
   */
  private mediaTypeFor(href: string): string {
    const lower: string = href.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.bmp')) {
      return 'image/bmp';
    }
    return 'image/jpeg';
  }

  /**
   * Safely remove a previously extracted directory.
   */
  private removeExtractDir(dirPath: string): void {
    try {
      const hasDir: boolean = this.directoryExists(dirPath);
      if (hasDir) {
        this.removeDirectoryRecursive(dirPath);
      }
    } catch (_e) {}
  }

  /**
   * Check if a directory exists.
   */
  private directoryExists(dirPath: string): boolean {
    try {
      const stat: fileIo.Stat = fileIo.statSync(dirPath);
      return stat.isDirectory();
    } catch (_e) {
      return false;
    }
  }

  /**
   * Recursively remove a directory and all its contents.
   *
   * fileIo.rmdirSync only removes empty directories, so we must
   * first delete all files inside.
   */
  private removeDirectoryRecursive(dirPath: string): void {
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(dirPath);
    } catch (_e) {
      return;
    }
    for (let i = 0; i < entries.length; i++) {
      const entryPath: string = dirPath + '/' + entries[i];
      try {
        const stat: fileIo.Stat = fileIo.statSync(entryPath);
        if (stat.isDirectory()) {
          this.removeDirectoryRecursive(entryPath);
        } else {
          fileIo.unlinkSync(entryPath);
        }
      } catch (_e) {}
    }
    try {
      fileIo.rmdirSync(dirPath);
    } catch (_e) {}
  }

  /**
   * List all image files in a directory, sorted in natural order.
   *
   * Natural sorting ensures that "img2.jpg" comes before "img10.jpg".
   * Only files with recognised image extensions are returned.
   *
   * @param dirPath - Directory to scan
   * @returns Array of filenames (not full paths) sorted naturally
   */
  private listImageFiles(dirPath: string): string[] {
    const result: string[] = [];
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(dirPath);
    } catch (_e) {
      return result;
    }

    for (let i = 0; i < entries.length; i++) {
      const name: string = entries[i];
      const lowerName: string = name.toLowerCase();
      if (this.hasImageExtension(lowerName)) {
        const fullPath: string = dirPath + '/' + name;
        try {
          const stat: fileIo.Stat = fileIo.statSync(fullPath);
          if (!stat.isDirectory()) {
            result.push(name);
          }
        } catch (_e) {
          // Skip entries we cannot stat
        }
      }
    }

    // Phase 24：方法引用直接传入 sort 会丢失 this（回调内 this.tokenize 抛
    // "Cannot read property 'tokenize' of undefined"，真机 CBZ 打开崩溃），
    // 改为箭头函数绑定调用方实例。
    result.sort((a: string, b: string): number => this.naturalCompare(a, b));
    return result;
  }

  /**
   * Check if a lowercase filename has a recognised image extension.
   */
  private hasImageExtension(lowerName: string): boolean {
    for (let i = 0; i < IMAGE_EXTENSIONS.length; i++) {
      const ext: string = IMAGE_EXTENSIONS[i];
      if (lowerName.endsWith('.' + ext)) {
        return true;
      }
    }
    return false;
  }

  /**
   * Natural string comparison for filename sorting.
   *
   * Compares strings by splitting into numeric and non-numeric segments,
   * so that "img2" < "img10" (instead of lexicographic "img10" < "img2").
   *
   * @param a - First filename
   * @param b - Second filename
   * @returns Negative if a < b, positive if a > b, 0 if equal
   */
  private naturalCompare(a: string, b: string): number {
    const pattern: RegExp = new RegExp('(\\d+)|(\\D+)', 'g');
    const segmentsA: string[] = this.tokenize(a, pattern);
    const segmentsB: string[] = this.tokenize(b, pattern);
    const minLen: number = segmentsA.length < segmentsB.length ? segmentsA.length : segmentsB.length;

    for (let i = 0; i < minLen; i++) {
      const segA: string = segmentsA[i];
      const segB: string = segmentsB[i];
      const numA: number = parseInt(segA, 10);
      const numB: number = parseInt(segB, 10);
      const isNumA: boolean = !isNaN(numA) && segA === String(numA);
      const isNumB: boolean = !isNaN(numB) && segB === String(numB);

      if (isNumA && isNumB) {
        if (numA !== numB) {
          return numA - numB;
        }
      } else {
        if (segA !== segB) {
          if (segA < segB) {
            return -1;
          }
          return 1;
        }
      }
    }

    return segmentsA.length - segmentsB.length;
  }

  /**
   * Tokenize a string into segments of consecutive digits and non-digits.
   */
  private tokenize(str: string, pattern: RegExp): string[] {
    const tokens: string[] = [];
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(str)) !== null) {
      tokens.push(match[0]);
    }
    return tokens;
  }
}
