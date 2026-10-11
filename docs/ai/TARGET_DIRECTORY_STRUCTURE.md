# TARGET_DIRECTORY_STRUCTURE — 目标目录与本轮达成度

> 生成：2026-10-11 ｜ 原则：**逻辑目录 ≠ HAR**；优先整理 HAR 内部目录，不无理由增加 HAR。

## 1. 目标 Pipeline 逻辑目录
```
src/
├── import/        File → Import → Format Detection
├── document/      Semantic IR / model
├── style/         CSS / cascade / computed style
├── typography/    TextBreaker / KnuthPlass / metrics / font load
├── layout/        block/inline layout, geometry
├── pagination/    content → pages
├── locator/       canonical reading identity
├── navigation/    TOC / spine / prev-next
├── cache/         document/layout/page/asset + lifecycle
├── render/        Page/Render Model → Renderer Backend
├── platform/      FileSystem/Archive/Font/TaskScheduler/Logger
└── application/   ReaderHost/UI/Bookshelf/Settings/TTS/Dictionary/Theme
```

## 2. 物理 HAR（不按逻辑目录逐一建 HAR）
`common` · `parsers` · `epub` · `txt-exclusive` · `cbz-exclusive` · `pdf-exclusive` · `feature` · `ui-render` · `reader` · `entry`（10，本轮**未增减 HAR**）。

## 3. 逻辑目录 → 物理落点（本轮达成）
| 逻辑 | 物理落点 | 达成 |
|---|---|---|
| document | `common/document/` | ✅ 本轮（model→document） |
| typography | `common/typography/` + `ui-render/typography/` | ✅ 本轮 |
| style | `ui-render/style/` | ✅ 本轮（自 layout 拆出） |
| layout | `ui-render/layout/` | ✅ 本轮（保留 13） |
| pagination | `ui-render/layout/PageSplitter.ets`（+ `core/PageManager`） | ⚠️ 部分（未单列 pagination/，未拆 PageManager） |
| locator | `common/runtime/ReadingStateStore` + `common/types/ReadingStateTypes` | ⚠️ 部分（无独立 locator/，无 canonical Locator 类型） |
| navigation | `ui-render/core/PageManager`(导航部分) + `reader/panels/TocPanel` | ⚠️ 部分（未单列 navigation/） |
| cache | `common/cache/` | ✅ 本轮 |
| storage | `common/storage/` | ✅ 本轮 |
| spi | `common/spi/` | ✅ 本轮 |
| render | `ui-render/render/` + `reader/reader`(Canvas) + `reader/glass`(GL) + `pdf/Renderer` | ⚠️ 部分（后端分散，未统一到 render/backend） |
| platform | 无独立 dir；各层直接 `@kit.*` | ❌ 未开始（P1） |
| application | `entry/*` + `reader/*`(panels/host) + `feature/*` | ⚠️ 部分（未聚拢到 application/） |

## 4. 本轮已消除的泛名目录
`common/{model,font,parser,service,controller}`（5 个）→ 替换为 `document/typography/spi/cache/storage/runtime`。
泛名目录总数 **9 → 7**（剩余：`common/types`、`epub/model`、`feature/model`、`reader/{common,service,utils}`、`ui-render/core`）。

## 5. 后续（未执行）
- P1 Platform SPI（`ohrengine-platform-api`）。
- P3 Engine 拆分（`core/{PageManager,PipelineManager}` → pagination/navigation/session）。
- P6 Renderer 后端化（reader Canvas/GL + pdf → `render/backend`）。
- P7 Application 收敛（reader/feature → `application`）。
- 剩余泛名目录治理（`reader/{common,service,utils}`、`epub/feature model`、`ui-render/core`、`common/types`）。
