/**
 * ReaderFeatureFlags — 阅读界面可复用能力开关（供宿主工程裁剪功能）。
 *
 * 默认全部开启（与既有行为一致）；宿主按需关闭尚未交付/未经验证的能力：
 * - annotations：批注（高亮 / 下划线 / 笔记）
 * - bookmarks：书签（含下拉添加书签）
 * - exportAnnotations：批注导出
 * - listen：听书（占位）
 * - translation：选词翻译（占位）
 * - anchorFirst：Phase 11 冷启动 Anchor-first（open 前应用持久化排版参数 + 等值短路，
 *   消除字号恢复触发的全书同步 reflow；关闭后回到 Phase 10 旧路径）
 */
export class ReaderFeatureFlags {
  /** 批注（高亮/下划线/笔记） */
  annotations: boolean;
  /** 书签（下拉添加书签 / 目录书签标记） */
  bookmarks: boolean;
  /** 批注导出（JSON/Markdown/CSV/HTML） */
  exportAnnotations: boolean;
  /** 听书（占位入口） */
  listen: boolean;
  /** 选词翻译（占位） */
  translation: boolean;
  /** Phase 11: 冷启动 Anchor-first（默认 ON；灰度回退开关） */
  anchorFirst: boolean;

  constructor(annotations: boolean, bookmarks: boolean, exportAnnotations: boolean,
    listen: boolean, translation: boolean, anchorFirst: boolean = true) {
    this.annotations = annotations;
    this.bookmarks = bookmarks;
    this.exportAnnotations = exportAnnotations;
    this.listen = listen;
    this.translation = translation;
    this.anchorFirst = anchorFirst;
  }

  /** 全部能力开启（默认 / 兼容既有行为） */
  static allOn(): ReaderFeatureFlags {
    return new ReaderFeatureFlags(true, true, true, true, true, true);
  }

  /** 最小可用集（阅读 + 菜单 + 翻页动画，不含批注/书签/导出/听书/翻译） */
  static minimal(): ReaderFeatureFlags {
    return new ReaderFeatureFlags(false, false, false, false, false, false);
  }
}