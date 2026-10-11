/**
 * DebugBookshelf — 调试书架（Debug 构建入口 / debugShelf=1 直达）
 *
 * 薄封装（FR-009/D5）：仅渲染统一极简书架组件 `MinimalBookshelf`，与正式书架
 * （pages/Bookshelf）共用同一实现与交互（纯文字列表 / 点按打开 / 长按删除 /
 * 导入 / 空态）。已**移除**调试专有内容：沉浸光感清单探针入口、缓存状态文案。
 *
 * 入口区分：Debug/Release 由构建期常量 BuildProfile.DEBUG 决定（见 EntryAbility）。
 */

import { MinimalBookshelf } from '../components/MinimalBookshelf';

@Entry
@Component
struct DebugBookshelf {
  build() {
    Column() {
      MinimalBookshelf()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
