/**
 * MemoryPageCache — L3 运行时内存页缓存（Phase 3）
 *
 * 角色：介于「L2 磁盘分页缓存」与「可见页渲染」之间的热内存层：
 *   L3 hit → 直接显示（无需磁盘读 + JSON 反序列化）
 *   L3 miss → L2 磁盘 → 反序列化 → 写 L3 → 显示
 *   L2 miss → LayoutEngine 实时分页 → 写 L3
 *
 * 载体：按 chapterIndex 存放 CacheChapter（与 L2 磁盘格式同构，避免二次建模）。
 * 约束（Phase 3 硬性要求）：
 *   - 禁止全书常驻：LRU + maxChapterCount（默认 5，推荐 3–5）
 *   - 同时使用 total memory budget（maxTotalBytes，默认 24MB，估算自行盒文本）
 *   - memory pressure：shrinkToVisible(2) 缩到 1–2 章
 *   - 不是 correctness source：evict/drop 均为纯优化，丢失后可回退 L2/Layout
 */
import type { CacheChapter } from './PageCacheManager.ets';

/** LRU 链表节点 */
interface LruNode {
  chapterIndex: number;
  chapter: CacheChapter;
  /** 文本字符估算（用于字节预算） */
  charCount: number;
  prev: LruNode | undefined;
  next: LruNode | undefined;
}

/**
 * L3 内存页缓存 — 有界 LRU。
 * 线程模型：单线程（与引擎一致），所有方法同步。
 */
export class MemoryPageCache {
  private readonly maxChapterCount: number;
  private readonly maxTotalBytes: number;
  private readonly bytePerChar: number = 3;
  private head: LruNode | undefined = undefined;
  private tail: LruNode | undefined = undefined;
  private nodes: Map<number, LruNode> = new Map();
  /** Phase 10: 动画窗口 pin 集合——被 pin 的章不参与 LRU 逐出/收缩（非永久缓存，动画毕 unpin） */
  private pinnedSet: Set<number> = new Set();

  constructor(maxChapters: number = 5, maxTotalBytes: number = 24 * 1024 * 1024) {
    this.maxChapterCount = maxChapters;
    this.maxTotalBytes = maxTotalBytes;
  }

  /** Phase 10: pin 一章（保护动画窗口）；重复 pin 幂等 */
  pin(chapterIndex: number): void {
    this.pinnedSet.add(chapterIndex);
  }

  /** Phase 10: unpin（动画结束；幂等） */
  unpin(chapterIndex: number): void {
    this.pinnedSet.delete(chapterIndex);
  }

  /** Phase 10: 是否被 pin（动画窗口中不可逐出） */
  isPinned(chapterIndex: number): boolean {
    return this.pinnedSet.has(chapterIndex);
  }

  /**
   * 读一章（LRU 命中并置为最新；未命中返回 undefined）。
   */
  get(chapterIndex: number): CacheChapter | undefined {
    const node: LruNode | undefined = this.nodes.get(chapterIndex);
    if (node === undefined) {
      return undefined;
    }
    this.moveToHead(node);
    return node.chapter;
  }

  /**
   * 写入一章（LRU 尾淘汰 + 字节预算）；缓存满时按 LRU 淘汰直到满足约束。
   */
  put(chapterIndex: number, chapter: CacheChapter): void {
    const charCount: number = MemoryPageCache.estimateCharCount(chapter);
    const existing: LruNode | undefined = this.nodes.get(chapterIndex);
    if (existing !== undefined) {
      existing.chapter = chapter;
      existing.charCount = charCount;
      this.moveToHead(existing);
      this.evictExcess();
      return;
    }
    const node: LruNode = {
      chapterIndex: chapterIndex,
      chapter: chapter,
      charCount: charCount,
      prev: undefined,
      next: undefined
    };
    this.pushToHead(node);
    this.nodes.set(chapterIndex, node);
    this.evictExcess();
  }

  /** 是否存在 */
  has(chapterIndex: number): boolean {
    return this.nodes.has(chapterIndex);
  }

  /** 当前缓存章节数 */
  size(): number {
    return this.nodes.size;
  }

  /** 估算总字节 */
  estimatedBytes(): number {
    let acc: number = 0;
    const it = this.nodes.values();
    let v = it.next();
    while (!v.done) {
      acc += (v.value as LruNode).charCount * this.bytePerChar;
      v = it.next();
    }
    return acc;
  }

  /** 清空 */
  clear(): void {
    this.nodes.clear();
    this.head = undefined;
    this.tail = undefined;
  }

  /**
   * memory pressure 收缩：保留最近访问的 n 章（0 表示清空）。
   * 不抛错、不依赖正确性——丢失后回退 L2/Layout。
   * Phase 10：被 pin（动画窗口）的章不参与收缩，防止动画中逐出。
   */
  shrinkToVisible(n: number): void {
    while (this.nodes.size > n) {
      const removed: boolean = this.removeOldestUnpinned();
      if (!removed) {
        break;
      }
    }
  }

  // ==================== Private LRU helpers ====================

  private pushToHead(node: LruNode): void {
    node.prev = undefined;
    node.next = this.head;
    if (this.head !== undefined) {
      this.head.prev = node;
    }
    this.head = node;
    if (this.tail === undefined) {
      this.tail = node;
    }
  }

  private moveToHead(node: LruNode): void {
    if (node === this.head) {
      return;
    }
    // detach
    const prevNode: LruNode | undefined = node.prev;
    const nextNode: LruNode | undefined = node.next;
    if (prevNode !== undefined) {
      prevNode.next = nextNode;
    }
    if (nextNode !== undefined) {
      nextNode.prev = prevNode;
    }
    if (node === this.tail) {
      this.tail = prevNode;
    }
    // push front
    node.prev = undefined;
    node.next = this.head;
    if (this.head !== undefined) {
      this.head.prev = node;
    }
    this.head = node;
    if (this.tail === undefined) {
      this.tail = node;
    }
  }

  /** Phase 10: 从 LRU 尾部开始移除第一个未被 pin 的节点；全部被 pin 时不动并返回 false */
  private removeOldestUnpinned(): boolean {
    let node: LruNode | undefined = this.tail;
    while (node !== undefined) {
      if (this.pinnedSet.has(node.chapterIndex)) {
        node = node.prev;
        continue;
      }
      this.nodes.delete(node.chapterIndex);
      const prevNode: LruNode | undefined = node.prev;
      const nextNode: LruNode | undefined = node.next;
      if (prevNode !== undefined) {
        prevNode.next = nextNode;
      }
      if (nextNode !== undefined) {
        nextNode.prev = prevNode;
      }
      if (node === this.tail) {
        this.tail = prevNode;
      }
      if (node === this.head) {
        this.head = nextNode;
      }
      if (this.tail === undefined) {
        this.head = undefined;
      }
      return true;
    }
    return false;
  }

  /** 超过容量/预算时逐出最老条目（Phase 10：跳过 pin 的动画窗口章） */
  private evictExcess(): void {
    while (this.nodes.size > this.maxChapterCount) {
      if (!this.removeOldestUnpinned()) {
        break;
      }
    }
    while (this.estimatedBytes() > this.maxTotalBytes && this.nodes.size > 1) {
      if (!this.removeOldestUnpinned()) {
        break;
      }
    }
  }

  /** 估算一章内存（UTF-16 字符数 × 字节/字符） */
  static estimateCharCount(chapter: CacheChapter): number {
    let acc: number = 0;
    for (let p = 0; p < chapter.pages.length; p++) {
      const lines = chapter.pages[p].lines;
      for (let l = 0; l < lines.length; l++) {
        const t = lines[l].text;
        acc += t !== undefined ? t.length : 0;
      }
    }
    return acc;
  }
}