/**
 * Bookshelf — 正式书架（Release 入口，ENG-012）
 *
 * 薄封装（FR-009/D5）：仅渲染统一极简书架组件 `MinimalBookshelf`。
 * 极简列表 / 点按打开 / 长按删除 / 导入 / 空态 / 自动打开参数消费均由该组件承载，
 * 与调试书架（debug/DebugBookshelf）共用同一实现，消除分叉。
 *
 * 安全要求：不使用运行时字符串判断隐藏功能；Debug/Release 入口在构建期由
 * buildProfileFields 注入的 BUILD_MODE 区分（编译期常量，见 EntryAbility）。
 */

import { MinimalBookshelf } from '../components/MinimalBookshelf';

@Entry
@Component
struct Bookshelf {
  build() {
    Column() {
      MinimalBookshelf()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
