/**
 * IconAssets — 阅读器统一标准图标资源入口。
 *
 * - 图标资源集中于此，便于后续统一替换 / 调整（仅改本文件即可全量生效）。
 * - 栅格图标取自 HarmonyOS_Icons 官方图标库，优先使用「填充型」图标
 *   （media 资源，经 Image.fillColor 着色）；
 * - 状态类图标（单手等）采用 HarmonyOS 系统标准 Symbol（SymbolGlyph，填充型）。
 * - 不在此处混入页面结构 / 业务逻辑，仅负责图标资源映射。
 */
export class IconAssets {
  /** 返回按钮（填充型） */
  static back(): Resource {
    return $r('app.media.ic_public_back');
  }

  /** 目录（表格内容列表，填充型） */
  static toc(): Resource {
    return $r('app.media.ic_public_view_list');
  }

  /** 书签（填充型缎带） */
  static bookmark(): Resource {
    return $r('app.media.ic_public_bookmark');
  }

  /** 设置（填充型齿轮） */
  static settings(): Resource {
    return $r('app.media.ic_public_settings_filled');
  }

  /** 取消（弹窗右上角统一关闭符号 ic_public_cancel，明暗一致） */
  static cancel(): Resource {
    return $r('app.media.ic_public_cancel');
  }

  /** 关闭填充（背景横条右侧，与背景色块同规格 ic_public_close_filled） */
  static closeFilled(): Resource {
    return $r('app.media.ic_public_close_filled');
  }

  /** 删除（垃圾桶） */
  static delete(): Resource {
    return $r('app.media.ic_public_delete');
  }

  /** 下一页（填充型右箭头） */
  static nextPage(): Resource {
    return $r('app.media.ic_public_arrow_right_filled');
  }

  /** 字号右侧拖动调整（填充型拖拽手柄） */
  static fontDrag(): Resource {
    return $r('app.media.ic_public_drag_handle_filled');
  }

  /** 行间距右侧展开/调节（填充型抽屉） */
  static spacingAdjust(): Resource {
    return $r('app.media.ic_public_drawer_filled');
  }

  /** 单手模式（填充 Symbol：点击手势） */
  static singleHand(): Resource {
    return $r('sys.symbol.hand_point_up_tap_fill');
  }

  /** 深色模式（填充型免打扰图标） */
  static themeDark(): Resource {
    return $r('app.media.ic_public_donotdisturb_filled');
  }

  /** 明亮模式（填充型亮度图标） */
  static themeLight(): Resource {
    return $r('app.media.ic_public_brightness_filled');
  }

  /** 对齐方式入口图标（官方填充图标） */
  static alignEntry(): Resource {
    return $r('app.media.align_entry');
  }

  /** 字体选择（ic_public_text 图标 + 文字标签） */
  static font(): Resource {
    return $r('app.media.ic_public_text');
  }

  /** 背景 / 主题（填充型色板图标） */
  static theme(): Resource {
    return $r('app.media.ic_public_themes_filled');
  }

  /** 字号减小（A-） */
  static fontSmaller(): Resource {
    return $r('sys.symbol.character_upper_minus');
  }

  /** 行间距收紧（文字 + 向下箭头） */
  static lineSpacingTight(): Resource {
    return $r('sys.symbol.text_and_arrow_down');
  }

  /** 电池图标（填充型实心电池，按电量档位着色） */
  static batteryFilled(): Resource {
    return $r('app.media.ic_public_battery_filled');
  }
}