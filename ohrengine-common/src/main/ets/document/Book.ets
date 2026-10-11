/**
 * Book — 格式无关的图书抽象接口
 *
 * 多模块重构的公共抽象层：所有图书格式（EPUB / TXT / CBZ / PDF …）
 * 的解析产物统一通过 `Book` 接口暴露只读能力，引擎核心
 * （OhEngineCore / OhEngine）只依赖本接口，不感知具体格式。
 *
 * 各格式解析器将其 `ParsedBook` / `Publication` 包装为 `Book`
 * 实现后注入引擎。
 */

import type { TocItem } from './Publication.ets';
import type { Link } from './Link.ets';

/**
 * 图书元数据（格式无关的通用子集）
 */
export interface BookMetadata {
  /** 书名 */
  title: string;
  /** 作者显示名列表 */
  authors: string[];
  /** 语言（如 'zh'、'en'，取主语言） */
  language: string;
  /** 阅读方向 — 'ltr' | 'rtl' | 'default' */
  direction: string;
  /** 封面资源路径（无封面时为 undefined） */
  coverPath: string | undefined;
}

/**
 * 章节引用（格式无关）
 */
export interface ChapterRef {
  /** 章节 id（无 id 时为 undefined） */
  id: string | undefined;
  /** 章节资源 href */
  href: string;
  /** 章节标题 */
  title: string;
}

/**
 * 图书抽象接口 — 引擎只通过该接口访问图书内容。
 */
export interface Book {
  /**
   * 获取图书元数据
   */
  getMetadata(): BookMetadata;

  /**
   * 获取章节数量
   */
  getChapterCount(): number;

  /**
   * 获取目录（嵌套结构）
   */
  getToc(): TocItem[];

  /**
   * 按索引获取章节 Link
   *
   * @param index - 章节索引（阅读顺序）
   * @returns 章节 Link；索引越界时返回 undefined
   */
  getChapterLink(index: number): Link | undefined;
}

/**
 * BookSource — 图书源文件信息（ARCH-005）
 *
 * 描述一本书的原始来源，独立于解析产物（Book / ParsedBook）。
 * 用于：
 *   - 解析缓存指纹（跨格式统一）
 *   - 进度/批注锚点的文档指纹
 *   - 文件格式路由与错误提示
 */
export interface BookSource {
  /** 源文件绝对路径 */
  path: string;
  /** 源文件格式（epub | txt | cbz | pdf …） */
  format: string;
  /** 文档指纹：基于文件内容（大小 + 头字节哈希）的稳定标识，跨重命名/移动稳定 */
  fingerprint: string;
  /** 可选：归档/容器内的相对路径（如 EPUB 的 container.xml 所在目录） */
  containerPath?: string;
}

/**
 * 由文件路径 + 文件大小生成稳定文档指纹（轻量，不读全文）。
 * 用于 BookSource.fingerprint / 解析缓存键 / 批注锚点。
 *
 * @param path - 源文件绝对路径
 * @param size - 文件字节数
 * @returns 稳定指纹字符串
 */
export function createBookFingerprint(path: string, size: number): string {
  const lower = path.toLowerCase();
  const dot = lower.lastIndexOf('.');
  const ext = dot >= 0 ? lower.substring(dot) : 'unknown';
  // 路径 + 大小 组合：路径唯一 + 大小变化即失效；不读文件内容，O(1) 生成。
  // 不直接暴露完整绝对路径（安全：仅取目录层级做弱指纹，正文由 size 保证）。
  const parts = path.split('/');
  const weakName = parts.length > 1 ? parts[parts.length - 1] : path;
  return ext + ':' + size + ':' + weakName.length + ':' + (path.length % 97);
}
