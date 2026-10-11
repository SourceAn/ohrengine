import type { TocItem, Annotation } from 'ohrengine-common';
import type { Bookmark } from 'ohrengine-feature';
import { OhEngine } from 'ohrengine-ui-render';
import { ReaderPageNumberMode } from '../utils/ReaderSettings.ets';
import type { SeekInfo } from '../panels/ReaderScrubBar.ets';

/** 章节页码信息 */
export interface ChapterPages {
  current: number;
  total: number;
}

/**
 * ReaderInfo — 阅读信息纯计算工具（从 Index 拆分）。
 * 仅依赖 engine / 数据入参，不含 UI 状态与渲染，便于单元化复用。
 */
export class ReaderInfo {
  /** 章节内当前页 / 本章总页（Phase 24：章内页序直取引擎，两个空间不再相减） */
  static chapterPages(engine: OhEngine): ChapterPages {
    const chapterIdx: number = engine.getCurrentChapterIndex();
    const total: number = Math.max(1, engine.getChapterPageCount(chapterIdx));
    // Phase 24 (Issue B)：章内当前页直接取引擎章内页序（精确）。旧实现
    // 「全局页槽序 − 前文章页数」在分母含未物化章估算值时会产生空间错位。
    const current: number = Math.max(1, Math.min(total, engine.getCurrentPageIndex() + 1));
    return { current: current, total: total };
  }

  /** 页码显示文本（章节页数 / 总页数 / 进度百分比 三种模式） */
  static pageNumberText(mode: ReaderPageNumberMode, chapterCurrent: number, chapterTotal: number,
    currentPageNum: number, totalPages: number): string {
    if (mode === ReaderPageNumberMode.CHAPTER) {
      return chapterCurrent + '/' + chapterTotal;
    }
    const pct: number = totalPages > 0 ? Math.round(currentPageNum / totalPages * 100) : 0;
    if (mode === ReaderPageNumberMode.PERCENT) {
      return pct + '%';
    }
    return currentPageNum + '/' + totalPages;
  }

  /** 阅读进度 0~1 */
  static progress(currentPageNum: number, totalPages: number): number {
    if (totalPages <= 1) {
      return 0;
    }
    return Math.max(0, Math.min(1, (currentPageNum - 1) / (totalPages - 1)));
  }

  /** 章节真实标题：优先章节 Link.title，再回退目录匹配，最后「第 N 章」 */
  static chapterTitle(engine: OhEngine, chapterIdx: number): string {
    const pub = engine.getPublication();
    if (pub === undefined) {
      return '第 ' + (chapterIdx + 1) + ' 章';
    }
    const link = pub.getChapterLink(chapterIdx);
    const directTitle: string | undefined = link !== undefined ? link.title : undefined;
    if (directTitle !== undefined && directTitle.length > 0) {
      return directTitle;
    }
    const toc: TocItem[] = engine.getTableOfContents();
    for (let t = 0; t < toc.length; t++) {
      const th: string = (toc[t].href ?? '').split('#')[0];
      if (th.length === 0) {
        continue;
      }
      for (let i = 0; i < pub.getChapterCount(); i++) {
        const chapterLink = pub.getChapterLink(i);
        if (chapterLink !== undefined && (chapterLink.href ?? '').split('#')[0] === th) {
          if (i === chapterIdx) {
            return toc[t].title;
          }
          break;
        }
      }
    }
    return '第 ' + (chapterIdx + 1) + ' 章';
  }

  /** 拖动进度条浮层信息：真实章节名 + 页码/总页码 */
  static seekInfo(engine: OhEngine, v: number, total: number): SeekInfo {
    if (total <= 1) {
      const fallback: string = ReaderInfo.chapterTitle(engine, 0);
      return { title: fallback, pageNum: total, totalPages: total };
    }
    const target: number = Math.max(1, Math.min(total, Math.round(v * (total - 1)) + 1));
    const pub = engine.getPublication();
    const chapters: number = pub !== undefined ? pub.getChapterCount() : 0;
    let chapterIdx: number = 0;
    let start: number = 1;
    for (let i = 0; i < chapters; i++) {
      const cnt: number = Math.max(1, engine.getChapterPageCount(i));
      if (target <= start + cnt - 1) {
        chapterIdx = i;
        break;
      }
      start += cnt;
    }
    const title: string = ReaderInfo.chapterTitle(engine, chapterIdx);
    return { title: title, pageNum: target, totalPages: total };
  }

  /** 有书签的章节索引集合 */
  static bookmarkChapters(bookmarks: Bookmark[]): Set<number> {
    const set: Set<number> = new Set();
    for (let i = 0; i < bookmarks.length; i++) {
      const bm: Bookmark = bookmarks[i];
      if (bm.chapterIndex >= 0) {
        set.add(bm.chapterIndex);
      }
    }
    return set;
  }

  /** 有笔记/标注的章节索引集合 */
  static noteChapters(annotations: Annotation[]): Set<number> {
    const set: Set<number> = new Set();
    for (let i = 0; i < annotations.length; i++) {
      const ci: number | undefined = annotations[i].chapterIndex;
      if (ci !== undefined && ci >= 0) {
        set.add(ci);
      }
    }
    return set;
  }

  /** 目录项 → 章节索引（与 isCurrentTocItem 同源） */
  static tocChapterIndices(engine: OhEngine): number[] {
    const pub = engine.getPublication();
    const toc: TocItem[] = engine.getTableOfContents();
    const result: number[] = [];
    for (let t = 0; t < toc.length; t++) {
      const itemHref: string = (toc[t].href ?? '').split('#')[0];
      let found: number = -1;
      if (pub !== undefined) {
        for (let i = 0; i < pub.getChapterCount(); i++) {
          const link = pub.getChapterLink(i);
          if (link !== undefined && (link.href ?? '').split('#')[0] === itemHref) {
            found = i;
            break;
          }
        }
      }
      result.push(found);
    }
    return result;
  }

  /** 目录项 → 章节起始全局页码（前缀和；无法定位为 -1） */
  static tocPageNumbers(engine: OhEngine): number[] {
    const pub = engine.getPublication();
    const toc: TocItem[] = engine.getTableOfContents();
    const result: number[] = [];
    if (pub === undefined) {
      for (let t = 0; t < toc.length; t++) {
        result.push(-1);
      }
      return result;
    }
    let start: number = 1;
    for (let t = 0; t < toc.length; t++) {
      const itemHref: string = (toc[t].href ?? '').split('#')[0];
      let found: number = -1;
      for (let i = 0; i < pub.getChapterCount(); i++) {
        const link = pub.getChapterLink(i);
        if (link !== undefined && (link.href ?? '').split('#')[0] === itemHref) {
          found = i;
          break;
        }
      }
      if (found >= 0) {
        result.push(start);
        start += Math.max(1, engine.getChapterPageCount(found));
      } else {
        result.push(-1);
      }
    }
    return result;
  }

  /** 目录项是否为「包含当前页的章节」（高亮显示） */
  static isCurrentTocItem(engine: OhEngine, item: TocItem): boolean {
    const pub = engine.getPublication();
    if (pub === undefined) {
      return false;
    }
    const curIdx: number = engine.getCurrentChapterIndex();
    const itemHref: string = (item.href ?? '').split('#')[0];
    if (itemHref.length === 0) {
      return false;
    }
    let itemIdx: number = -1;
    for (let i = 0; i < pub.getChapterCount(); i++) {
      const link = pub.getChapterLink(i);
      if (link !== undefined && (link.href ?? '').split('#')[0] === itemHref) {
        itemIdx = i;
        break;
      }
    }
    if (itemIdx < 0) {
      return false;
    }
    const toc: TocItem[] = engine.getTableOfContents();
    let lastValid: number = -1;
    for (let t = 0; t < toc.length; t++) {
      const th: string = (toc[t].href ?? '').split('#')[0];
      let ti: number = -1;
      for (let i = 0; i < pub.getChapterCount(); i++) {
        const link = pub.getChapterLink(i);
        if (link !== undefined && (link.href ?? '').split('#')[0] === th) {
          ti = i;
          break;
        }
      }
      if (ti >= 0 && ti <= curIdx) {
        lastValid = ti;
      }
    }
    return lastValid === itemIdx;
  }

  /** 当前书籍标题（目录卡片封面行展示） */
  static currentBookTitle(engine: OhEngine): string {
    const pub = engine.getPublication();
    return pub !== undefined ? pub.getMetadata().title : '';
  }

  /** 封面绝对路径：相对路径基于书籍资源基路径解析（无封面返回空串） */
  static resolvedCoverPath(engine: OhEngine, basePath: string): string {
    const pub = engine.getPublication();
    if (pub === undefined) {
      return '';
    }
    const coverPath: string | undefined = pub.getMetadata().coverPath;
    if (coverPath === undefined || coverPath.length === 0) {
      return '';
    }
    if (coverPath.startsWith('/') || coverPath.startsWith('file://')) {
      return coverPath;
    }
    return basePath + '/' + coverPath;
  }
}