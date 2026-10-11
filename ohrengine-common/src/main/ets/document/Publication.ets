/**
 * 出版物模型 — 引擎核心数据容器
 * 参考：Readium Publication.kt（简化版）
 *
 * Publication 是阅读引擎操作的顶层数据对象：
 * - 持有 Manifest 元数据与资源索引
 * - 提供解析后的容器（服务定位符、书签、高亮等）
 * - 用于在解析、排版、渲染各阶段传递出版物状态
 */

import { Manifest, createManifest } from './Manifest.ets';
import { Link, createLink } from './Link.ets';
import { Metadata } from './Metadata.ets';
import { CssStyleSet, createDefaultCssStyleSet } from './CssDefinitions.ets';
import type { Book, BookMetadata } from './Book.ets';

/**
 * 目录项
 */
export interface TocItem {
  title: string;
  href: string;
  children?: TocItem[]; // 嵌套目录
}

/**
 * 服务定位符 — 精确位置标识
 */
export interface Locator {
  href: string;
  mediaType: string | undefined;
  progression: number | undefined; // 0.0 ~ 1.0
  pageIndex: number | undefined;
  cfi: string | undefined;
  chapterIndex: number | undefined;
  paragraphIndex: number | undefined;
  wordIndex: number | undefined;
}

export function createEmptyLocator(): Locator {
  return {
    href: '',
    mediaType: undefined,
    progression: undefined,
    pageIndex: undefined,
    cfi: undefined,
    chapterIndex: undefined,
    paragraphIndex: undefined,
    wordIndex: undefined
  };
}

export function createLocator(href: string, progression: number): Locator {
  return {
    href: href,
    mediaType: undefined,
    progression: progression,
    pageIndex: undefined,
    cfi: undefined,
    chapterIndex: undefined,
    paragraphIndex: undefined,
    wordIndex: undefined
  };
}

/**
 * 阅读会话的进度状态
 */
export interface ReadingState {
  currentLocator: Locator | undefined;
  progression: number; // 整体阅读进度 0.0 ~ 1.0
  totalPages: number;
  currentPage: number;
  totalChapters: number;
  currentChapter: number;
  pagesRead: number;    // 已读页数（全书累计）
  pagesTotal: number;   // 全书总页数
}

export function createReadingState(): ReadingState {
  return {
    currentLocator: undefined,
    progression: 0,
    totalPages: 1,
    currentPage: 0,
    totalChapters: 1,
    currentChapter: 0,
    pagesRead: 0,
    pagesTotal: 1,
  };
}

/**
 * 标注类型
 */
export enum AnnotationType {
  BOOKMARK = 'bookmark',
  HIGHLIGHT = 'highlight',
  UNDERLINE = 'underline',
  NOTE = 'note'
}

/**
 * 标注 / 书签 / 高亮
 */
export interface Annotation {
  id: string;
  type: AnnotationType;
  locator: Locator;
  text: string | undefined;
  note: string | undefined;
  color: string | undefined;
  created: string;
  modified: string | undefined;
  // SQLite flattened fields (used by AnnotationStorage)
  chapterIndex: number | undefined;
  startCharOffset: number | undefined;
  endCharOffset: number | undefined;
  synchronizationVersion: number | undefined;
  noteText: string | undefined;
  noteTimestamp: number | undefined;
  createdAt: number | undefined;
  updatedAt: number | undefined;
  isVisible: number | undefined;
}

export function createAnnotation(
  id: string,
  type: AnnotationType,
  locator: Locator
): Annotation {
  const now: string = new Date().toISOString();
  const nowMs: number = new Date().getTime();
  return {
    id: id,
    type: type,
    locator: locator,
    text: undefined,
    note: undefined,
    color: undefined,
    created: now,
    modified: undefined,
    chapterIndex: locator.chapterIndex,
    startCharOffset: locator.paragraphIndex,
    endCharOffset: locator.wordIndex,
    synchronizationVersion: 0,
    noteText: undefined,
    noteTimestamp: nowMs,
    createdAt: nowMs,
    updatedAt: nowMs,
    isVisible: 1
  };
}

/**
 * 导出样式配置
 */
export interface StyleConfig {
  fontSize: number;  // pt
  fontFamily: string;
  lineHeight: number; // 乘数
  marginHorizontal: number; // px
  marginVertical: number; // px
  textAlign: string;
  backgroundColor: string;
  textColor: string;
  nightMode: boolean;
}

export function createDefaultStyleConfig(): StyleConfig {
  return {
    fontSize: 12,
    fontFamily: 'serif',
    lineHeight: 1.6,
    marginHorizontal: 16,
    marginVertical: 12,
    textAlign: 'justify',
    backgroundColor: '#FFFFFF',
    textColor: '#000000',
    nightMode: false
  };
}

/**
 * 封面信息
 */
export interface CoverInfo {
  path: string;
  mimeType: string;
  source: string;
}

/**
 * OPF guide container（references 用 Link，因为 Link 已有 type/href/title）
 */
export interface Guide {
  references: Link[];
}

/**
 * OPF spine container
 */
export interface Spine {
  items: Link[];
  /** 全局翻页方向 — OPF spine 的 page-progression-direction 属性 */
  pageProgressionDirection: string; // 'ltr' | 'rtl' | 'default'
}

/**
 * 出版物容器
 *
 * implements Book — 格式无关的图书抽象接口
 */
export class Publication implements Book {
  public manifest: Manifest;
  public styleConfig: StyleConfig;
  public readingState: ReadingState;
  public annotations: Annotation[];
  public isEncrypted: boolean;
  public encryptionProfile: string | undefined;
  public toc: TocItem[] = [];
  /** 封面信息 */
  public cover: CoverInfo | undefined = undefined;
  /** OPF guide 导航 */
  public guide: Guide | undefined = undefined;
  /** 全局翻页方向 — 取自 OPF spine page-progression-direction */
  public pageProgressionDirection: string = 'ltr';
  /** 布局模式 — 'reflowable' | 'pre-paginated'（FXL 固定布局） */
  public layout: string = 'reflowable';

  constructor(title: string) {
    this.manifest = createManifest(title);
    this.styleConfig = createDefaultStyleConfig();
    this.readingState = createReadingState();
    this.annotations = [];
    this.isEncrypted = false;
    this.encryptionProfile = undefined;
  }

  /**
   * 获取标题
   */
  public getTitle(): string {
    return this.manifest.metadata.title;
  }

  /**
   * 获取作者显示名
   */
  public getAuthor(): string {
    const authors = this.manifest.metadata.authors;
    if (authors.length > 0) {
      return authors[0].name;
    }
    return '';
  }

  /**
   * 获取阅读顺序资源数
   */
  /**
   * 获取元数据（快捷访问）
   */
  public get metadata(): Metadata {
    return this.manifest.metadata;
  }

  /**
   * 获取图书元数据（Book 接口实现，格式无关子集）
   */
  public getMetadata(): BookMetadata {
    const meta = this.manifest.metadata;
    const authors: string[] = [];
    for (const author of meta.authors) {
      authors.push(author.name);
    }
    let language = '';
    if (meta.language.length > 0) {
      language = meta.language[0];
    }
    return {
      title: meta.title,
      authors: authors,
      language: language,
      direction: this.pageProgressionDirection,
      coverPath: this.cover !== undefined ? this.cover.path : undefined
    };
  }

  /**
   * 获取 spine（快捷访问，供 CoverFinder 使用）
   */
  public get spine(): Spine {
    return { items: this.manifest.readingOrder, pageProgressionDirection: this.pageProgressionDirection };
  }

  public getChapterCount(): number {
    return this.manifest.readingOrder.length;
  }

  /**
   * 按索引获取章节 Link
   */
  public getChapterLink(index: number): Link | undefined {
    if (index >= 0 && index < this.manifest.readingOrder.length) {
      return this.manifest.readingOrder[index];
    }
    return undefined;
  }

  /**
   * 更新当前阅读位置
   */
  public updateCurrentPosition(locator: Locator): void {
    this.readingState.currentLocator = locator;
  }

  /**
   * 获取目录
   */
  public getToc(): TocItem[] { return this.toc; }

  /**
   * 添加标注
   */
  public addAnnotation(annotation: Annotation): void {
    this.annotations.push(annotation);
  }

  /**
   * 设置字号
   */
  public setFontSize(pt: number): void {
    this.styleConfig.fontSize = pt;
  }
}
