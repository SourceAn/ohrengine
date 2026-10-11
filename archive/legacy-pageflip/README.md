# Legacy PageFlip Archive — 旧翻页实现归档说明

> 归档日期：2026-08-12
> 归档决策：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`（HOS-STPAGEFLIP-001 主任务，P4 原子切换）
> 决策依据：主任务决策 D3（原子切换）/ D1（约束修订）；P0 冻结 `docs/ai/legacy_pageflip_inventory.md` 处置映射。

## 归档内容

| 原路径 | 归档路径 | 说明 |
|--------|----------|------|
| `ohrengine-gl/`（整目录，含 cpp/CMake/module.json5） | `archive/legacy-pageflip/ohrengine-gl/` | GLES 翻页引擎（ArkTS 薄封装 + native C++），已由 `ohrengine-pageflip`（StPageFlip ArkTS Engine）取代 |
| `entry/src/main/ets/reader/PageFlipController.ets` | `archive/legacy-pageflip/entry-reader/PageFlipController.ets` | 旧翻页控制器（GL 编排 + B2/B3 提交屏障） |
| `entry/src/main/ets/reader/FlipDirection.ets` | `archive/legacy-pageflip/entry-reader/FlipDirection.ets` | 旧方向推导纯函数（0.9；逻辑迁入新 Engine 手势判定） |

## 回滚方式

- P4 后回滚 = `git revert` P4 原子提交（恢复 GL 路径；Reader 切换一并还原）。
- 归档目录**只读**：不参与编译，禁止任何 import 回来（主任务 A2）。

## 历史追溯

- `PageFlipController.ets` 与 `ohrengine-gl` 部分文件的 git 历史可经 `git log --follow` 追溯
  （注：`ohrengine-gl/` 与 `FlipDirection.ets` 在归档前处于未跟踪状态，属工作区既有脏树，
  其内容以归档时点为快照）。
- GL 翻页已知问题与旧重构方向见 `docs/tasks/iBooks风格仿真翻页动画重构.md`（已加 superseded 横幅）。

## 相关文档

- 主任务：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`
- 旧实现清单与处置映射：`docs/ai/legacy_pageflip_inventory.md`
- 源函数映射表：`docs/ai/stpageflip_mapping.md`
- 迁移架构决策：`docs/adr/ADR-PageFlip迁移架构决策.md`
