/**
 * EPUB 解析器
 * 参考：Readium 解析器架构（Parser/PublicationServer）
 *
 * 职责：
 * 1. 解析 EPUB 容器（解压后 container.xml, OPF, NCX）
 * 2. 构建 Publication 模型（Manifest + Metadata）
 * 3. 提取 TOC、spine、resource 索引
 *
 * 注意：此版本面向已解压的 EPUB 文件，
 * 基于 @ohrs：CoreFileKit / @kit.CoreFileKit 做本地文件 I/O
 */

import { Publication, TocItem, BookParser, BookFormat, ParsedBook,
  RenderStrategy, ChapterData } from 'ohrengine-common';
import { Book } from 'ohrengine-common';
import { Manifest } from 'ohrengine-common';
import { Metadata, Contributor, createContributor } from 'ohrengine-common';
import { Link, createLink, createLinkWithTitle } from 'ohrengine-common';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { NcxParser } from './NcxParser.ets';
import { CoverFinder, CoverResult } from '../model/CoverFinder.ets';
import { CoverHtmlParser } from '../model/CoverHtmlParser.ets';
import { OpfMeta } from 'ohrengine-common';

// EPUB 关键文件的 MIME 类型
export const MIME_TYPE_XHTML: string = 'application/xhtml+xml';
export const MIME_TYPE_CSS: string = 'text/css';
export const MIME_TYPE_IMAGE_JPEG: string = 'image/jpeg';
export const MIME_TYPE_IMAGE_PNG: string = 'image/png';
export const MIME_TYPE_IMAGE_GIF: string = 'image/gif';
export const MIME_TYPE_IMAGE_SVG: string = 'image/svg+xml';
export const MIME_TYPE_NCX: string = 'application/x-dtbncx+xml';
export const MIME_TYPE_DTBOOK: string = 'application/x-dtbook+xml';
export const MIME_TYPE_SMIL: string = 'application/smil+xml';
export const MIME_TYPE_PACKAGE_OPF: string = 'application/oebpkg+xml';
export const MIME_TYPE_DTBOOK_ZIP: string = 'application/x-dtbook+xml';
export const MIME_TYPE_EPUB: string = 'application/epub+zip';

/**
 * 根据文件扩展名猜测 MIME 类型
 */
export function guessMimeType(filePath: string): string {
  const name: string = filePath.toLowerCase();
  if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return MIME_TYPE_IMAGE_JPEG;
  if (name.endsWith('.png')) return MIME_TYPE_IMAGE_PNG;
  if (name.endsWith('.gif')) return MIME_TYPE_IMAGE_GIF;
  if (name.endsWith('.svg')) return MIME_TYPE_IMAGE_SVG;
  if (name.endsWith('.xhtml') || name.endsWith('.html') || name.endsWith('.htm')) return MIME_TYPE_XHTML;
  if (name.endsWith('.css')) return MIME_TYPE_CSS;
  return 'application/octet-stream';
}

/**
 * EPUB 容器根文件信息
 */
export interface ContainerEntry {
  fullPath: string;
  mediaType: string;
}

/**
 * OPF 包信息（解析后的结果）
 */
export interface OpfData {
  version: string;
  uniqueId: string | undefined;
  metadata: Metadata;
  spine: Link[];
  manifest: Link[];
  tocLink: Link | undefined;
  guide: Link[] | undefined;
  /** OPF spine page-progression-direction, default 'ltr' */
  pageProgressionDirection: string;
  /** 布局模式: 'reflowable' | 'pre-paginated' */
  layout: string;
}

/**
 * NCX 解析结果
 */
export interface NcxData {
  title: string | undefined;
  navPoints: Link[];
  depth: number;
}

/**
 * EPUB 解析进度回调
 */
export interface ParseProgressCallback {
  onProgress(percent: number, message: string): void;
}

/**
 * OPF manifest 条目（内部解析用）
 */
interface OpfManifestItem {
  id: string;
  href: string;
  mediaType: string;
}

/**
 * OPF spine 条目（内部解析用）
 */
interface OpfSpineItem {
  idref: string;
}

/**
 * EPUB 解析器
 *
 * 使用方式：
 *   const parser: EpubParser = new EpubParser();
 *   const pub: Publication = await parser.parseFromDir('/path/to/unzipped/epub');
 *
 * BookParser 接口实现：
 *   const book: ParsedBook = await parser.parse('/path/to/unzipped/epub');
 */
export class EpubParser implements BookParser {
  /** BookParser 接口：本解析器处理的格式 */
  readonly format: BookFormat = BookFormat.EPUB;

  private basePath: string = '';
  private opfDir: string = ''; // OPF 所在目录（相对于 basePath），如 "OEBPS"
  private progressCallback: ParseProgressCallback | undefined = undefined;

  constructor() {
  }

  /**
   * 设置进度回调
   */
  public setProgressCallback(callback: ParseProgressCallback): void {
    this.progressCallback = callback;
  }

  /**
   * BookParser.parse — 统一解析接口
   *
   * 对 EPUB 格式，filePath 为解压后的 EPUB 目录路径。
   * 内部委托给 parseFromDir 获取 Publication，再读取各章节内容和 CSS。
   */
  public async parse(filePath: string): Promise<ParsedBook> {
    const publication: Publication = await this.parseFromDir(filePath);
    const chapters: ChapterData[] = [];
    const cssTexts: string[] = [];

    // Step 1: 构建 chapters — 读取 spine 中各章节文件内容
    for (let i = 0; i < publication.manifest.readingOrder.length; i++) {
      const link: Link = publication.manifest.readingOrder[i];
      const fullPath: string = filePath + '/' + link.href;
      let content: string = '';
      try {
        content = this.readTextFileSync(fullPath);
      } catch (_e) {
        content = '<html><body><p>Error loading: ' + link.href + '</p></body></html>';
      }
      const title: string = link.title ?? 'Chapter ' + (i + 1);
      chapters.push({
        title: title,
        content: content,
        href: link.href,
      });
    }

    // Step 2: 收集 CSS 文本 — 遍历 manifest 中的 CSS 资源
    for (let j = 0; j < publication.manifest.resources.length; j++) {
      const resource: Link = publication.manifest.resources[j];
      if (resource.mediaType === 'text/css') {
        const cssPath: string = filePath + '/' + resource.href;
        try {
          const cssContent: string = this.readTextFileSync(cssPath);
          cssTexts.push(cssContent);
        } catch (_e) {
        }
      }
    }

    return new ParsedBook(
      BookFormat.EPUB,
      RenderStrategy.REFLOW,
      publication,
      chapters,
      cssTexts,
    );
  }

  /**
   * getBook — Book 接口工厂方法（格式无关入口）
   *
   * 直接解析 EPUB 并返回 Book 接口实例（Publication implements Book），
   * 不经过 ParsedBook 包装，供引擎核心按 Book 抽象层消费。
   *
   * @param filePath - 解压后的 EPUB 目录路径
   * @returns Book 接口实例
   */
  public async getBook(filePath: string): Promise<Book> {
    return await this.parseFromDir(filePath);
  }

  /**
   * 从解压后的目录解析 EPUB
   * 1. 读取 META-INF/container.xml 找到 OPF
   * 2. 解析 OPF 获取 metadata / spine / manifest
   * 3. 解析 NCX / 导航获取 TOC
   */
  public async parseFromDir(baseDir: string): Promise<Publication> {
    this.basePath = baseDir;
    this.reportProgress(0, '开始解析 EPUB 容器');

    // Step 1: 解析 container.xml 获取 OPF 路径
    const opfPath: string = await this.resolveOpfPath();
    if (opfPath === '') {
      throw new Error('未找到 OPF 文件');
    }
    this.reportProgress(15, '已定位 OPF 文件：' + opfPath);

    // Step 2: 解析 OPF
    const opfData: OpfData = await this.parseOpf(opfPath);
    this.reportProgress(50, 'OPF 解析完成');

    // Step 3: 构建 Publication
    const publication: Publication = new Publication(opfData.metadata.title);
    publication.manifest = this.buildManifest(opfData);
    publication.pageProgressionDirection = opfData.pageProgressionDirection;
    publication.layout = opfData.layout;

    // Step 4: 解析导航数据（NCX / 目录）
    if (opfData.tocLink !== undefined) {
      await this.parseNavigation(publication.manifest, opfData.tocLink);
    }
    // 回退：从 spine 生成扁平目录
    if (publication.manifest.tableOfContents.length === 0) {
      this.generateFlatToc(publication.manifest);
    }

    // Step 5: 设置 OPF guide 导航
    if (opfData.guide !== undefined) {
      publication.guide = { references: opfData.guide };
    }

    this.reportProgress(100, 'EPUB 解析完成');

    // 构建 Publication.toc — 优先使用 NCX/导航文档解析的真实章节名，
    // 仅当 NCX 缺失/为空时才回退到 spine 扁平目录（第N节）。
    if (publication.manifest.tableOfContents.length > 0) {
      publication.toc = [];
      for (let ti = 0; ti < publication.manifest.tableOfContents.length; ti++) {
        const tocLink: Link = publication.manifest.tableOfContents[ti];
        publication.toc.push({
          title: tocLink.title ?? '第' + (ti + 1) + '节',
          href: tocLink.href
        });
      }
    } else {
      publication.toc = [];
      for (let i = 0; i < publication.manifest.readingOrder.length; i++) {
        const link: Link = publication.manifest.readingOrder[i];
        const title: string = link.title || '第' + (i + 1) + '节';
        publication.toc.push({ title: title, href: link.href });
      }
    }

    // Step 6: 提取封面（四级定位）
    const coverFinder: CoverFinder = new CoverFinder();
    const coverResult: CoverResult | null = coverFinder.findCover(publication);
    if (coverResult) {
      if (coverResult.needsHtmlParsing) {
        try {
          const coverHtmlPath: string = baseDir + '/' + coverResult.path;
          const coverFile: fileIo.File = fileIo.openSync(coverHtmlPath, fileIo.OpenMode.READ_ONLY);
          const coverStat: fileIo.Stat = fileIo.statSync(coverHtmlPath);
          const coverBuf: ArrayBuffer = new ArrayBuffer(coverStat.size);
          fileIo.readSync(coverFile.fd, coverBuf);
          fileIo.closeSync(coverFile);
          const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
          const coverHtml: string = decoder.decodeToString(new Uint8Array(coverBuf));
          const imagePath: string | null = new CoverHtmlParser().extractCoverImage(coverHtml, coverResult.path);
          if (imagePath) {
            publication.cover = { path: imagePath, mimeType: guessMimeType(imagePath), source: 'heuristic' };
          }
        } catch (_e) {
        }
      } else {
        publication.cover = { path: coverResult.path, mimeType: coverResult.mimeType, source: coverResult.source };
      }
    }

    return publication;
  }

  /**
   * 从 OPF 构建 Manifest
   */
  private buildManifest(opfData: OpfData): Manifest {
    const manifest: Manifest = {
      metadata: opfData.metadata,
      links: [],
      readingOrder: opfData.spine,
      resources: opfData.manifest,
      tableOfContents: [],
      subcollections: undefined,
      landmarks: undefined,
      pageList: undefined,
      list: undefined
    };
    return manifest;
  }

  /**
   * 解析 container.xml 获取 OPF 路径
   */
  private async resolveOpfPath(): Promise<string> {
    const containerPath: string = this.basePath + '/META-INF/container.xml';
    let content: string;
    try {
      content = this.readTextFileSync(containerPath);
    } catch (_e) {
      return '';
    }
    return this.extractOpfPathFromContainer(content);
  }

  /**
   * 从 container.xml 内容中提取 OPF 路径
   */
  private extractOpfPathFromContainer(xmlContent: string): string {
    // 查找 rootfile 元素中的 full-path 属性
    const regex: RegExp = /<rootfile[^>]*full-path\s*=\s*"([^"]+)"/;
    const match: RegExpMatchArray | null = xmlContent.match(regex);
    if (match !== null && match[1] !== undefined) {
      return match[1];
    }
    return '';
  }

  /**
   * 解析 OPF 包文件
   */
  private async parseOpf(opfPath: string): Promise<OpfData> {
    // 提取 OPF 目录用于解析相对路径
    const lastSep: number = opfPath.lastIndexOf('/');
    this.opfDir = lastSep >= 0 ? opfPath.substring(0, lastSep) : '';
    const fullPath: string = this.basePath + '/' + opfPath;
    let content: string;
    try {
      content = this.readTextFileSync(fullPath);
    } catch (_e) {
      return {
        version: '3.0',
        uniqueId: undefined,
        metadata: this.createFallbackMetadata(''),
        spine: [],
        manifest: [],
        tocLink: undefined,
        guide: undefined,
        pageProgressionDirection: 'ltr',
        layout: 'reflowable'
      };
    }

    const metadata: Metadata = this.parseOpfMetadata(content);
    const manifestItems: OpfManifestItem[] = this.parseOpfManifest(content);
    const spineItems: OpfSpineItem[] = this.parseOpfSpine(content);

    // 构建 Link 列表，href 解析为相对 basePath 的路径
    const manifestLinks: Link[] = [];
    const manifestMap: Record<string, Link> = {};
    for (let i = 0; i < manifestItems.length; i++) {
      const item: OpfManifestItem = manifestItems[i];
      const resolvedHref: string = this.opfDir !== '' ? this.opfDir + '/' + item.href : item.href;
      const link: Link = createLink(resolvedHref, item.mediaType);
      link.rels = ['manifest'];
      link.id = item.id;
      manifestLinks.push(link);
      manifestMap[item.id] = link;
    }

    // 构建 spine / readingOrder
    const spineLinks: Link[] = [];
    for (let i = 0; i < spineItems.length; i++) {
      const ref: OpfSpineItem = spineItems[i];
      const link: Link | undefined = manifestMap[ref.idref];
      if (link !== undefined) {
        spineLinks.push(link);
      } else {
        // spine 引用了 manifest 中不存在的 item，创建一个占位
        spineLinks.push(createLink(ref.idref + '.xhtml', MIME_TYPE_XHTML));
      }
    }

    // 查找 TOC 链接
    let tocLink: Link | undefined = undefined;
    const tocId: string = this.extractSpineTocId(content);
    if (tocId !== '') {
      tocLink = manifestMap[tocId];
    }
    // EPUB 3：spine 无 toc 属性时，从 manifest 找 properties="nav" 的导航文档
    if (tocLink === undefined) {
      const navId: string = this.extractManifestNavId(content);
      if (navId !== '' && manifestMap[navId] !== undefined) {
        tocLink = manifestMap[navId];
      }
    }

    // 解析 guide 导航
    const guideRefs: Link[] = this.parseOpfGuide(content);
    // 填充该 guide 引用中关联的 href（manifest 中的相对路径）
    for (let i = 0; i < guideRefs.length; i++) {
      const ref: Link = guideRefs[i];
      const resolvedHref: string = this.opfDir !== '' ? this.opfDir + '/' + ref.href : ref.href;
      guideRefs[i] = createLink(resolvedHref, MIME_TYPE_XHTML);
      guideRefs[i].type = ref.type;
      guideRefs[i].title = ref.title;
    }

    // 解析原始 <meta> 元素存入 metadata
    metadata.meta = this.parseOpfMetaElements(content);

    // 解析全局翻页方向
    const pageProgressionDirection: string = this.extractSpinePageProgressionDirection(content);

    // 解析 FXL 固定布局模式（rendition:layout）
    const layout: string = this.extractOpfLayout(metadata.meta);

    return {
      version: '3.0',
      uniqueId: undefined,
      metadata: metadata,
      spine: spineLinks,
      manifest: manifestLinks,
      tocLink: tocLink,
      guide: guideRefs.length > 0 ? guideRefs : undefined,
      pageProgressionDirection: pageProgressionDirection,
      layout: layout
    };
  }

  /**
   * OPF 清单条目
   */
  private parseOpfMetadata(xmlContent: string): Metadata {
    // 提取 <metadata> 区域
    const metaRegex: RegExp = /<metadata[^>]*>([\s\S]*?)<\/metadata>/i;
    const metaMatch: RegExpMatchArray | null = xmlContent.match(metaRegex);
    const metaSection: string = (metaMatch !== null && metaMatch[1] !== undefined) ? metaMatch[1] : '';

    const title: string = this.extractXmlTagContent(metaSection, 'dc:title');
    const creatorName: string = this.extractXmlTagContent(metaSection, 'dc:creator');
    const lang: string = this.extractXmlTagContent(metaSection, 'dc:language');

    const result: Metadata = this.createFallbackMetadata(title);
    if (creatorName !== '') {
      result.authors.push(createContributor(creatorName));
    }
    if (lang !== '') {
      result.language = [lang];
      result.languages = [lang];
    }
    // 提取 identifier
    const idRegex: RegExp = /<dc:identifier[^>]*>([^<]*)<\/dc:identifier>/i;
    const idMatch: RegExpMatchArray | null = metaSection.match(idRegex);
    if (idMatch !== null && idMatch[1] !== undefined) {
      result.identifier = idMatch[1].trim();
    }
    // 提取 publisher
    const pubRegex: RegExp = /<dc:publisher[^>]*>([^<]*)<\/dc:publisher>/i;
    const pubMatch: RegExpMatchArray | null = metaSection.match(pubRegex);
    if (pubMatch !== null && pubMatch[1] !== undefined) {
      result.publisher = createContributor(pubMatch[1].trim());
    }
    // 提取 description
    const descRegex: RegExp = /<dc:description[^>]*>([^<]*)<\/dc:description>/i;
    const descMatch: RegExpMatchArray | null = metaSection.match(descRegex);
    if (descMatch !== null && descMatch[1] !== undefined) {
      result.description = descMatch[1].trim();
    }

    return result;
  }

  /**
   * 提取 XML 标签内容
   */
  private extractXmlTagContent(xml: string, tagName: string): string {
    const regex: RegExp = new RegExp('<' + tagName + '[^>]*>([^<]*)<\\/' + tagName + '>', 'i');
    const match: RegExpMatchArray | null = xml.match(regex);
    if (match !== null && match[1] !== undefined) {
      return match[1].trim();
    }
    return '';
  }

  /**
   * 解析 OPF manifest 条目
   */
  private parseOpfManifest(xmlContent: string): OpfManifestItem[] {
    const result: OpfManifestItem[] = [];
    // 提取 <manifest> 区域
    const manifestRegex: RegExp = /<manifest[^>]*>([\s\S]*?)<\/manifest>/i;
    const manifestMatch = xmlContent.match(manifestRegex);
    const section: string = (manifestMatch !== null && manifestMatch[1] !== undefined) ? manifestMatch[1] : '';

    // 按 <item 分割避免使用 RegExpExecArray
    const parts: string[] = section.split('<item');
    for (let i = 1; i < parts.length; i++) {
      const tagPart: string = parts[i];
      const closeTagIndex: number = tagPart.indexOf('>');
      if (closeTagIndex < 0) {
        continue;
      }
      const attrs: string = tagPart.substring(0, closeTagIndex);
      const id: string = this.extractAttrValue(attrs, 'id');
      const href: string = this.extractAttrValue(attrs, 'href');
      const mediaType: string = this.extractAttrValue(attrs, 'media-type');
      if (id !== '' && href !== '') {
        const item: OpfManifestItem = {
          id: id,
          href: href,
          mediaType: mediaType !== '' ? mediaType : 'application/octet-stream'
        };
        result.push(item);
      }
    }
    return result;
  }

  /**
   * 解析 OPF spine
   */
  private parseOpfSpine(xmlContent: string): OpfSpineItem[] {
    const result: OpfSpineItem[] = [];
    const spineRegex: RegExp = /<spine[^>]*>([\s\S]*?)<\/spine>/i;
    const spineMatch = xmlContent.match(spineRegex);
    const section: string = (spineMatch !== null && spineMatch[1] !== undefined) ? spineMatch[1] : '';

    // 按 <itemref 分割避免使用 RegExpExecArray
    const parts: string[] = section.split('<itemref');
    for (let i = 1; i < parts.length; i++) {
      const tagPart: string = parts[i];
      const closeTagIndex: number = tagPart.indexOf('>');
      if (closeTagIndex < 0) {
        continue;
      }
      const attrs: string = tagPart.substring(0, closeTagIndex);
      const idref: string = this.extractAttrValue(attrs, 'idref');
      if (idref !== '') {
        const item: OpfSpineItem = { idref: idref };
        result.push(item);
      }
    }
    return result;
  }

  /**
   * 提取 spine 的 toc 属性值
   */
  private extractSpineTocId(xmlContent: string): string {
    const regex: RegExp = /<spine[^>]*\s+toc\s*=\s*"([^"]+)"/i;
    const match: RegExpMatchArray | null = xmlContent.match(regex);
    if (match !== null && match[1] !== undefined) {
      return match[1];
    }
    return '';
  }

  /**
   * 提取 manifest 中 properties="nav" 的 item id（EPUB 3 导航文档）
   * 例如 <item id="nav" href="nav.xhtml" properties="nav"/>
   */
  private extractManifestNavId(xmlContent: string): string {
    const regex: RegExp = /<item\s+[^>]*\sid\s*=\s*"([^"]+)"[^>]*\sproperties\s*=\s*"([^"]*)"/gi;
    let m: RegExpExecArray | null;
    while ((m = regex.exec(xmlContent)) !== null) {
      const props: string = (m[2] ?? '').toLowerCase();
      if (props.split(/\s+/).indexOf('nav') >= 0) {
        return m[1];
      }
    }
    // properties 可能在 id 之前
    const regex2: RegExp = /<item\s+[^>]*\sproperties\s*=\s*"([^"]*)"[^>]*\sid\s*=\s*"([^"]+)"/gi;
    let m2: RegExpExecArray | null;
    while ((m2 = regex2.exec(xmlContent)) !== null) {
      const props: string = (m2[1] ?? '').toLowerCase();
      if (props.split(/\s+/).indexOf('nav') >= 0) {
        return m2[2];
      }
    }
    return '';
  }

  /**
   * 提取 spine 的 page-progression-direction 属性值
   * 默认返回 'ltr'
   */
  private extractSpinePageProgressionDirection(xmlContent: string): string {
    const regex: RegExp = /<spine[^>]*\spage-progression-direction\s*=\s*"([^"]+)"/i;
    const match: RegExpMatchArray | null = xmlContent.match(regex);
    if (match !== null && match[1] !== undefined) {
      const val: string = match[1].toLowerCase();
      if (val === 'rtl' || val === 'ltr') {
        return val;
      }
    }
    return 'ltr';
  }

  /**
   * 从 OPF <meta> 元素中提取 rendition:layout
   * 支持 EPUB 3: <meta property="rendition:layout">pre-paginated</meta>
   * 也兼容 <meta name="rendition:layout" content="pre-paginated"/>
   */
  private extractOpfLayout(metaElements: OpfMeta[]): string {
    for (let i = 0; i < metaElements.length; i++) {
      const m: OpfMeta = metaElements[i];
      if (m.property === 'rendition:layout' && m.content !== undefined) {
        const val: string = m.content.toLowerCase().trim();
        if (val === 'pre-paginated') {
          return 'pre-paginated';
        }
      }
      // 兼容 name/content 形式
      if (m.name === 'rendition:layout' && m.content !== undefined) {
        const val: string = m.content.toLowerCase().trim();
        if (val === 'pre-paginated') {
          return 'pre-paginated';
        }
      }
    }
    return 'reflowable';
  }

  /**
   * 从属性字符串中提取属性值
   */
  private extractAttrValue(attrStr: string, attrName: string): string {
    const regex: RegExp = new RegExp('\\b' + attrName + '\\s*=\\s*"([^"]*)"', 'i');
    const match: RegExpMatchArray | null = attrStr.match(regex);
    if (match !== null && match[1] !== undefined) {
      return match[1];
    }
    return '';
  }

  /**
   * 解析 OPF <guide> 中的 <reference> 元素
   */
  private parseOpfGuide(xmlContent: string): Link[] {
    const result: Link[] = [];
    const guideRegex: RegExp = /<guide[^>]*>([\s\S]*?)<\/guide>/i;
    const guideMatch = xmlContent.match(guideRegex);
    if (guideMatch === null || guideMatch[1] === undefined) {
      return result;
    }
    const section: string = guideMatch[1];
    const parts: string[] = section.split('<reference');
    for (let i = 1; i < parts.length; i++) {
      const tagPart: string = parts[i];
      const closeTagIndex: number = tagPart.indexOf('>');
      if (closeTagIndex < 0) {
        continue;
      }
      const attrs: string = tagPart.substring(0, closeTagIndex);
      const type: string = this.extractAttrValue(attrs, 'type');
      const title: string = this.extractAttrValue(attrs, 'title');
      const href: string = this.extractAttrValue(attrs, 'href');
      if (type !== '' && href !== '') {
        const link: Link = createLink(href, MIME_TYPE_XHTML);
        link.type = type;
        if (title !== '') {
          link.title = title;
        }
        result.push(link);
      }
    }
    return result;
  }

  /**
   * 解析 OPF <metadata> 中的原始 <meta> 元素
   */
  private parseOpfMetaElements(xmlContent: string): OpfMeta[] {
    const result: OpfMeta[] = [];
    const metaRegex: RegExp = /<metadata[^>]*>([\s\S]*?)<\/metadata>/i;
    const metaMatch = xmlContent.match(metaRegex);
    if (metaMatch === null || metaMatch[1] === undefined) {
      return result;
    }
    const section: string = metaMatch[1];
    const parts: string[] = section.split('<meta');
    for (let i = 1; i < parts.length; i++) {
      const tagPart: string = parts[i];
      const closeTagIndex: number = tagPart.indexOf('>');
      if (closeTagIndex < 0) {
        continue;
      }
      const attrs: string = tagPart.substring(0, closeTagIndex);
      // 跳过结束标签 </meta>
      if (attrs.startsWith('/') || attrs.startsWith(' ')) {
        continue;
      }
      const name: string = this.extractAttrValue(attrs, 'name');
      let content: string = this.extractAttrValue(attrs, 'content');
      const property: string = this.extractAttrValue(attrs, 'property');
      const id: string = this.extractAttrValue(attrs, 'id');
      // EPUB 3 <meta property="..."> 使用标签体文本而非 content 属性
      if (content === '' && property !== '') {
        const bodyEnd: number = tagPart.indexOf('</');
        if (bodyEnd > closeTagIndex) {
          content = tagPart.substring(closeTagIndex + 1, bodyEnd).trim();
        }
      }
      if (name !== '' || property !== '') {
        const meta: OpfMeta = {
          name: name !== '' ? name : undefined,
          content: content !== '' ? content : undefined,
          property: property !== '' ? property : undefined,
          id: id !== '' ? id : undefined
        };
        result.push(meta);
      }
    }
    return result;
  }

  /**
   * 同步读取文本文件内容
   */
  private readTextFileSync(filePath: string): string {
    let file: fileIo.File;
    try {
      file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
    } catch (e) {
      throw new Error('EpubParser.readTextFileSync: open failed: ' + (e instanceof Error ? e.message : String(e)));
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      const bufSize: number = stat.size;
      const buf: ArrayBuffer = new ArrayBuffer(bufSize);
      const readLen: number = fileIo.readSync(file.fd, buf, { offset: 0, length: bufSize });
      const uint8Array: Uint8Array = new Uint8Array(buf.slice(0, readLen));
      const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return textDecoder.decodeToString(uint8Array);
    } catch (e) {
      throw new Error('EpubParser.readTextFileSync: read failed: ' + (e instanceof Error ? e.message : String(e)));
    } finally {
      try {
        fileIo.closeSync(file);
      } catch (_e) {
        // 忽略关闭失败
      }
    }
  }

  /**
   * 解析 NCX 导航文件
   */
  private async parseNcx(ncxPath: string): Promise<NcxData> {
    try {
      const filePath: string = this.basePath + '/' + ncxPath;
      const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const ncxXml: string = decoder.decodeToString(new Uint8Array(buf));

      const parser: NcxParser = new NcxParser();
      const toc: TocItem[] = parser.parse(ncxXml);

      // NCX <content src> 是相对于 NCX 文件路径的，加上 opfDir
      const ncxDir: string = this.opfDir !== '' ? this.opfDir + '/' : '';
      const navPoints: Link[] = [];
      const flatten = (items: TocItem[], _parentPath?: string): void => {
        for (let idx = 0; idx < items.length; idx++) {
          const item: TocItem = items[idx];
          const resolvedHref: string = ncxDir + item.href;
          navPoints.push(createLinkWithTitle(resolvedHref, 'application/xhtml+xml', item.title));
          if (item.children) flatten(item.children);
        }
      };
      flatten(toc);

      return { title: undefined, navPoints, depth: 0 };
    } catch (e) {
      return { title: undefined, navPoints: [], depth: 0 };
    }
  }

  /**
   * 解析导航数据到 Manifest.tableOfContents
   */
  private async parseNavigation(manifest: Manifest, tocLink: Link): Promise<void> {
    // NCX (EPUB 2) 或导航文档 (EPUB 3)
    if (tocLink.mediaType === MIME_TYPE_NCX) {
      const ncxData: NcxData = await this.parseNcx(tocLink.href);
      manifest.tableOfContents = ncxData.navPoints;
    } else {
      // EPUB 3 导航文档（nav.xhtml，mediaType 为 xhtml）— 解析 <nav epub:type="toc">
      const navPoints: Link[] = await this.parseNavDocument(tocLink.href);
      if (navPoints.length > 0) {
        manifest.tableOfContents = navPoints;
      }
    }
  }

  /**
   * 解析 EPUB 3 导航文档（<nav epub:type="toc">）中的目录项。
   *
   * 导航项 href 可能带锚点（如 part0006.html#frag），保留锚点供章节内定位；
   * 递归收集 <ol><li><a> 结构，支持嵌套子目录。
   *
   * @param navPath - nav.xhtml 相对于容器根目录的路径
   * @returns 扁平化的 Link 列表（title + href）
   */
  private async parseNavDocument(navPath: string): Promise<Link[]> {
    const navPoints: Link[] = [];
    try {
      const fullPath: string = this.basePath + '/' + navPath;
      const file: fileIo.File = fileIo.openSync(fullPath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(fullPath);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const navXml: string = decoder.decodeToString(new Uint8Array(buf));

      // 提取 <nav> 内第一个 <ol> 及其 <li><a href> 结构
      const collectLinks = (html: string): void => {
        // 只解析 <nav epub:type="toc"> 部分（跳过 landmarks 等隐藏 nav）
        let tocSection: string = html;
        const tocNavStart: number = html.indexOf('epub:type="toc"');
        if (tocNavStart >= 0) {
          const navStart: number = html.lastIndexOf('<nav', tocNavStart);
          const navEnd: number = html.indexOf('</nav>', tocNavStart);
          if (navStart >= 0 && navEnd > navStart) {
            tocSection = html.substring(navStart, navEnd + 6);
          }
        }
        // 用正则提取 <a href="...">title</a>（nav 文档是 XHTML，结构规整）
        const linkRe: RegExp = /<a\s+[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi;
        let m: RegExpExecArray | null;
        while ((m = linkRe.exec(tocSection)) !== null) {
          const href: string = m[1].trim();
          let title: string = m[2].replace(/<[^>]*>/g, '').trim();
          if (href.length === 0 || title.length === 0) {
            continue;
          }
          // href 相对 nav 文件所在目录；nav 在根目录时 opfDir 拼接即正确
          const resolved: string = this.opfDir !== '' ? this.opfDir + '/' + href : href;
          navPoints.push(createLinkWithTitle(resolved, 'application/xhtml+xml', title));
        }
      };
      collectLinks(navXml);
    } catch (e) {
    }
    return navPoints;
  }

  /**
   * 从 spine 生成扁平目录（回退方案）
   */
  private generateFlatToc(manifest: Manifest): void {
    for (let i = 0; i < manifest.readingOrder.length; i++) {
      const spineItem: Link = manifest.readingOrder[i];
      const title: string = spineItem.title ?? '第 ' + (i + 1) + ' 章';
      const tocItem: Link = createLinkWithTitle(spineItem.href, spineItem.mediaType, title);
      manifest.tableOfContents.push(tocItem);
    }
  }

  /**
   * 回退元数据
   */
  private createFallbackMetadata(title: string): Metadata {
    // fallback implementation for TypeScript compatibility
    const result: Metadata = {
      identifier: undefined,
      title: title,
      subtitle: undefined,
      sortAs: undefined,
      authors: [],
      translators: [],
      editors: [],
      artists: [],
      illustrators: [],
      letterers: [],
      pencilers: [],
      colorists: [],
      narrators: [],
      contributors: [],
      publisher: undefined,
      imprint: undefined,
      language: [],
      languages: [],
      modified: undefined,
      published: undefined,
      publicationDate: undefined,
      description: undefined,
      subjects: [],
      subjectsAlt: [],
      collections: [],
      readingProgression: 'auto',
      pageCount: undefined,
      duration: undefined,
      numberOfPages: undefined,
      source: undefined,
      rights: undefined,
      rendition: undefined,
      meta: []
    };
    return result;
  }

  /**
   * 报告解析进度
   */
  private reportProgress(percent: number, message: string): void {
    if (this.progressCallback !== undefined) {
      this.progressCallback.onProgress(percent, message);
    }
  }
}
