/**
 * FontLoader — Font registration manager for EPUB embedded fonts
 *
 * Reads font files from the EPUB container and registers them
 * with the HarmonyOS font system via font.registerFont().
 *
 * Features:
 *   - Map-based dedup (Map<string, Promise<boolean>>)
 *   - Two-step path resolution: cssBasePath first, bookBasePath fallback
 *   - Silent error handling: never throws, logs on failure
 *   - Tracks successfully registered families for downstream consumers
 *
 * 重构说明（模块化改造）：
 *   原依赖 RemoteResourceLoader（ohrengine-ui-render 模块）替换为
 *   ResourceFetcher 接口，解除 common → ui-render 的交叉依赖。
 */

import { fileIo } from '@kit.CoreFileKit';
import { FontFaceRule, LoadResult, ResourceFetcher, FontRegistrar } from '../types/FontTypes.ets';

/** @font-face 注册记录 */
interface RegisteredFontRecord {
  family: string;
  weight: number;
  unicodeRange: string;
}

/**
 * Manages loading and registration of fonts from @font-face rules.
 */
export class FontLoader {
  /**
   * Dedup cache: familyName → Promise<boolean>.
   * First request caches a Promise; subsequent requests for the same
   * familyName return the cached Promise.
   */
  private pendingLoads: Map<string, Promise<boolean>> = new Map();

  /**
   * Successfully registered font family names.
   * Populated after each successful font.registerFont() call.
   */
  private registeredFamilies: string[] = [];

  /** 查询缓存：family_weight → 实际字重 */
  private weightCache: Map<string, number> = new Map();

  /** 注册的字体记录（family + weight + unicodeRange 三元组） */
  private registeredFonts: RegisteredFontRecord[] = [];

  /**
   * 字体注册器（ENG-002）：由 UI 层注入，内部调用 UIContext.getFont().registerFont()。
   * 未注入时不注册（回退系统字体链），但保留缓存/字重/unicode-range 行为。
   */
  private registrar: FontRegistrar | null = null;

  /**
   * 注入字体注册器。必须在 UI 线程调用，UIContext 需与当前窗口/页面生命周期一致。
   */
  public setFontRegistrar(registrar: FontRegistrar | null): void {
    this.registrar = registrar;
  }

  /**
   * Load and register fonts from parsed @font-face rules.
   *
   * @param rules - Parsed @font-face rules
   * @param cssBasePath - Base directory of the CSS file (for resolving relative src URLs)
   * @param bookBasePath - Root directory of the EPUB container
   * @param remoteLoader - Optional ResourceFetcher for downloading remote fonts
   * @returns Promise<boolean> — true if at least one font was registered
   */
  public loadFontFaces(
    rules: FontFaceRule[],
    cssBasePath: string,
    bookBasePath: string,
    remoteLoader?: ResourceFetcher
  ): Promise<boolean> {
    if (rules.length === 0) {
      return Promise.resolve(false);
    }

    const loadPromises: Promise<boolean>[] = [];

    for (let i = 0; i < rules.length; i++) {
      const rule: FontFaceRule = rules[i];
      const familyName: string = rule.familyName;
      const unicodeRange: string | undefined = rule.unicodeRange;

      // Dedup key: familyName + unicode-range (同族名不同 unicode-range 需各自加载)
      const dedupKey: string = familyName + '|' + (unicodeRange ?? '');
      const existingPromise: Promise<boolean> | undefined = this.pendingLoads.get(dedupKey);
      if (existingPromise !== undefined) {
        loadPromises.push(existingPromise);
        continue;
      }

      const loadPromise: Promise<boolean> = this.loadSingleFont(rule, cssBasePath, bookBasePath, remoteLoader);
      this.pendingLoads.set(dedupKey, loadPromise);
      loadPromises.push(loadPromise);
    }

    // Wait for all font loads and return true if at least one succeeded
    return Promise.all(loadPromises).then((results: boolean[]): boolean => {
      for (let i = 0; i < results.length; i++) {
        if (results[i]) {
          return true;
        }
      }
      return false;
    });
  }

  /**
   * Get the list of successfully registered font family names.
   */
  public getRegisteredFamilies(): string[] {
    return this.registeredFamilies;
  }

  /**
   * Attempt to load and register a single @font-face rule.
   * Iterates through src URLs until one succeeds or all fail.
   */
  private async loadSingleFont(
    rule: FontFaceRule,
    cssBasePath: string,
    bookBasePath: string,
    remoteLoader?: ResourceFetcher
  ): Promise<boolean> {
    const familyName: string = rule.familyName;

    for (let i = 0; i < rule.src.length; i++) {
      const srcUrl: string = rule.src[i].url;

      let fontPath: string | undefined;

      if (srcUrl.startsWith('http://') || srcUrl.startsWith('https://')) {
        // 远程字体：通过 ResourceFetcher 下载
        if (remoteLoader === undefined) {
          continue;
        }
        fontPath = await this.downloadRemoteFont(srcUrl, remoteLoader);
      } else {
        fontPath = this.resolveFontPath(srcUrl, cssBasePath, bookBasePath);
      }

      if (fontPath === undefined) {
        continue;
      }

      // Verify the font file exists and is non-empty
      let fileSize: number = 0;
      try {
        const stat: fileIo.Stat = fileIo.statSync(fontPath);
        fileSize = stat.size;
      } catch (_e) {
        // statSync failed — file might not exist
        continue;
      }

      if (fileSize === 0) {
        continue;
      }

      // Register font via UI thread registrar (ENG-002):
      //   UIContext.getFont().registerFont() 替代废弃的 font.registerFont()
      try {
        if (this.registrar === null) {
          continue;
        }
        this.registrar.registerFont(familyName, fontPath);

        this.registeredFamilies.push(familyName);
        // 记录注册记录（family + weight + unicodeRange 三元组）
        const numWeight: number = rule.fontWeight ? parseInt(rule.fontWeight) || 400 : 400;
        this.registeredFonts.push({
          family: familyName,
          weight: numWeight,
          unicodeRange: rule.unicodeRange ?? 'U+0-10FFFF',
        });
        return true;
      } catch (_e) {
        // Continue to next source URL
      }
    }

    return false;
  }

  /**
   * 下载远程字体到临时文件并返回路径
   */
  private async downloadRemoteFont(url: string, remoteLoader: ResourceFetcher): Promise<string | undefined> {
    try {
      const result: LoadResult = await remoteLoader.fetchBinary(url);
      if (!result.success || result.data === null) {
        return undefined;
      }

      const fontData: ArrayBuffer = result.data as ArrayBuffer;
      if (fontData.byteLength === 0) {
        return undefined;
      }

      // 写入临时文件
      const tmpDir: string = '/tmp/ohengine/fonts/';
      // 确保目录存在
      try {
        fileIo.mkdirSync(tmpDir, true);
      } catch (_e) {
      }

      // 用 URL 的 hash 生成唯一文件名
      const hash: string = FontLoader.simpleHash(url);
      const ext: string = FontLoader.guessFontExt(url);
      const tmpPath: string = tmpDir + hash + ext;

      // 检查是否已下载过
      try {
        const existing: fileIo.Stat = fileIo.statSync(tmpPath);
        if (existing.size > 0) {
          return tmpPath;
        }
      } catch (_e) {
      }

      const file = fileIo.openSync(tmpPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, fontData);
      fileIo.closeSync(file);

      return tmpPath;
    } catch (_e) {
      return undefined;
    }
  }

  /**
   * 简单字符串哈希（用于生成临时文件名）
   */
  private static simpleHash(str: string): string {
    let hash: number = 0;
    for (let i = 0; i < str.length; i++) {
      const char: number = str.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash; // Convert to 32bit integer
    }
    return Math.abs(hash).toString(16);
  }

  /**
   * 根据 URL 猜测字体文件扩展名
   */
  private static guessFontExt(url: string): string {
    const lower: string = url.toLowerCase();
    if (lower.includes('.woff2')) {
      return '.woff2';
    }
    if (lower.includes('.woff')) {
      return '.woff';
    }
    if (lower.includes('.ttf')) {
      return '.ttf';
    }
    if (lower.includes('.otf')) {
      return '.otf';
    }
    if (lower.includes('.eot')) {
      return '.eot';
    }
    // 默认用 .ttf
    return '.ttf';
  }

  /**
   * 解析请求字重 → 实际可用字重（CSS 规范 §15.6 映射规则）
   * 400 以下：取 ≤ 请求值且最接近的可用字重
   * 500 以上：取 ≥ 请求值且最接近的可用字重
   * 距离相等时取较大值
   * 结果缓存，避免重复计算
   *
   * @param familyName 字体族名
   * @param requested 请求字重
   * @param char 目标字符（用于 unicode-range 筛选）
   */
  public resolveWeight(familyName: string, requested: number, char?: string): number {
    const cacheKey: string = familyName + '_' + requested + (char ?? '');
    const cached: number | undefined = this.weightCache.get(cacheKey);
    if (cached !== undefined) {
      return cached;
    }

    // 收集该族名下所有可用字重（去重）
    let available: number[] = [];
    for (const reg of this.registeredFonts) {
      if (reg.family === familyName && available.indexOf(reg.weight) < 0) {
        available.push(reg.weight);
      }
    }
    if (available.length === 0) {
      available = [400];
    }

    // unicode-range 筛选：只保留覆盖此字符的字重
    if (char !== undefined) {
      const code: number = char.codePointAt(0) ?? 0;
      const matchedWeights: Set<number> = new Set();
      for (const reg of this.registeredFonts) {
        if (reg.family === familyName && FontLoader.codePointInRange(code, reg.unicodeRange)) {
          matchedWeights.add(reg.weight);
        }
      }
      if (matchedWeights.size > 0) {
        const matchedArr: number[] = [];
        matchedWeights.forEach((w: number) => {
          matchedArr.push(w);
        });
        matchedArr.sort((a: number, b: number): number => a - b);
        available = matchedArr;
      }
    }

    if (available.indexOf(requested) >= 0) {
      this.weightCache.set(cacheKey, requested);
      return requested;
    }
    // CSS 规范映射规则
    if (requested <= 400) {
      // 取 ≤ requested 的最大值
      let best: number = -1;
      for (let i: number = 0; i < available.length; i++) {
        if (available[i] <= requested && available[i] > best) {
          best = available[i];
        }
      }
      if (best >= 0) {
        this.weightCache.set(cacheKey, best);
        return best;
      }
      // 没有更小的 → 取最小的可用字重
      const minWeight: number = Math.min(...available);
      this.weightCache.set(cacheKey, minWeight);
      return minWeight;
    }
    // requested >= 500: 取 ≥ requested 的最小值
    let best: number = 1000;
    for (let i: number = 0; i < available.length; i++) {
      if (available[i] >= requested && available[i] < best) {
        best = available[i];
      }
    }
    if (best < 1000) {
      this.weightCache.set(cacheKey, best);
      return best;
    }
    // 没有更大的 → 取最大的可用字重
    const maxWeight: number = Math.max(...available);
    this.weightCache.set(cacheKey, maxWeight);
    return maxWeight;
  }

  /**
   * 判断是否需要伪粗体：解析后的字重 ≠ 请求字重时触发
   *
   * @param familyName 字体族名
   * @param requestedWeight 请求字重
   * @param char 目标字符（用于 unicode-range 筛选）
   */
  public needsFauxBold(familyName: string, requestedWeight: number, char?: string): boolean {
    const resolved: number = this.resolveWeight(familyName, requestedWeight, char);
    return resolved !== requestedWeight;
  }

  /**
   * 判断指定字体族是否包含目标 weight / style 的字型。
   * 基于 resolveWeight 判断可用字重是否精确匹配请求字重。
   *
   * @param char 目标字符（用于 unicode-range 筛选）
   */
  public hasGlyph(familyName: string, weight: number, style: string, char?: string): boolean {
    if (weight <= 400 && style === 'normal') {
      return true;
    }
    const resolved: number = this.resolveWeight(familyName, weight, char);
    return resolved === weight;
  }

  /**
   * 根据字符的 Unicode 范围选择最匹配的已注册字体。
   * 优先匹配 unicode-range，再回退到同族名的通用字体。
   *
   * @param char - 目标字符（单个）
   * @param familyName - CSS font-family 中指定的族名
   * @returns 匹配的族名，或 undefined（无匹配）
   */
  public getFontForChar(char: string, familyName: string): string | undefined {
    const code: number = char.codePointAt(0) ?? 0;
    let hasFamily: boolean = false;
    for (const reg of this.registeredFonts) {
      if (reg.family.toLowerCase() !== familyName.toLowerCase()) {
        continue;
      }
      hasFamily = true;
      if (FontLoader.codePointInRange(code, reg.unicodeRange)) {
        return familyName;
      }
    }
    // 有族名注册但没有 range 匹配 → 仍然回退（兼容旧行为）
    if (hasFamily) {
      return familyName;
    }
    return undefined;
  }

  /** 判断 codePoint 是否在 CSS unicode-range 表达式范围内（如 U+4E00-9FFF） */
  private static codePointInRange(code: number, range: string): boolean {
    const parts: string[] = range.replace(/U\+/gi, '').split('-');
    const start: number = parseInt(parts[0], 16);
    const end: number = parts.length > 1 ? parseInt(parts[1], 16) : start;
    return code >= start && code <= end;
  }

  /**
   * Resolve a font source URL to an absolute file path.
   * Priority: cssBasePath first, then bookBasePath as fallback.
   *
   * @returns Resolved absolute path, or undefined if the file doesn't exist at either path
   */
  private resolveFontPath(
    srcUrl: string,
    cssBasePath: string,
    bookBasePath: string
  ): string | undefined {
    // Try cssBasePath first
    const cssBasedPath: string = cssBasePath + '/' + srcUrl;
    try {
      const stat: fileIo.Stat = fileIo.statSync(cssBasedPath);
      if (stat.size > 0) {
        return cssBasedPath;
      }
    } catch (_e) {
    }

    // Fall back to bookBasePath
    const bookBasedPath: string = bookBasePath + '/' + srcUrl;
    try {
      const stat: fileIo.Stat = fileIo.statSync(bookBasedPath);
      if (stat.size > 0) {
        return bookBasedPath;
      }
    } catch (_e) {
    }

    return undefined;
  }
}
