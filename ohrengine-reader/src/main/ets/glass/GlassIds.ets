/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0.
 *
 * GlassIds — 液态玻璃组件的登记 id（引擎按 id 解算矩形）。
 *
 * 约束：id 字符串在整个窗口中必须唯一；组件侧 .id() 与本表必须完全一致。
 */

export class GlassIds {
  /** 顶栏：返回圆钮 */
  static readonly TOP_BACK: string = 'lg:topBack';
  /** 顶栏：目录圆钮 */
  static readonly TOP_TOC: string = 'lg:topToc';
  /** 底部菜单栏（两行：进度行 + 按钮行）*/
  static readonly BOTTOM_BAR: string = 'lg:bottomBar';
}
