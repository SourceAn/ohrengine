# ARCHITECTURE — OHR Reading Engine 目标架构

> 生成：2026-10-11 ｜ 基于**实际源码与依赖扫描**（`node tests/architecture/check_boundaries.mjs`，扫描 204 个 `.ets`）。
> 本文件整合并取代旧 `docs/architecture/{CURRENT_ARCHITECTURE,TARGET_ARCHITECTURE,DEPENDENCY_GRAPH,DOCUMENT_IR}.md`（已移除，避免重复/矛盾）。
> 约束：本轮**未修改任何产品代码**。

## 0. 四个世界

| 世界 | 回答 | 归属 |
|---|---|---|
| **Application** | UI / 登录 / 设置 / 统计 / 书架 / 账号 / 主题 | `entry`、`application/*` |
| **Reading Engine** | 书是什么、怎么理解、怎么排版、读到哪 | `engine/*` |
| **Platform** | 文件/线程/字体/图片/时间/存储/内存从哪来 | `platform/*` |
| **OS** | 系统能力 | 不进仓库 |

依赖方向（硬性，单向）：

```
Application  ──▶  Engine API  ──▶  Reading Engine  ──▶  Platform SPI  ──▶  OS
```

**边界三缝**：`Format` 是 Engine 与文件格式之间的缝；`Platform` 是 Engine 与 OS 能力之间的缝；`Render API` 是 Engine 与图形后端之间的缝。

## 1. 目标架构图

```
                        ┌───────────────────────────────┐
   Application          │  entry (Ability/Bookshelf/UI)  │
                        │  panels / 设置 / 统计 / 词典    │
                        └───────────────┬───────────────┘
                                        ▼
                        ┌───────────────────────────────┐
   Engine API (facade)  │  ReaderEngine / ReaderSession  │   ← 兼容壳可保留 ReaderHost/OhEngine 名
                        └───────────────┬───────────────┘
                                        ▼
 ┌─────────────────────────────────────────────────────────────────────┐
   Reading Engine
   ├── publication · document(Model/Node/Resource) · locator · navigation
   ├── style · layout · pagination · page(model)
   ├── search · annotation · reading-state
   └── cache(document/layout/page/asset)
                                        │
                ┌───────────────────────┴───────────────────────┐
                ▼                                                ▼
        ┌───────────────┐                                ┌───────────────┐
        │  Format SPI   │                                │ Platform SPI  │
        │  epub/txt/pdf │                                │ FileSystem    │
        │  html/md/cbz  │                                │ FontProvider  │
        └───────┬───────┘                                │ ImageDecoder  │
                ▼                                        │ TextShaper    │
        External Format                                  │ TextMeasurer  │
                                                          │ TaskScheduler │
                                                          │ Memory/Logger │
                                                          └───────┬───────┘
                                                                  ▼
                                                          HarmonyOS/Android/Desktop ─▶ OS

   Page Model ─▶ Render API ─▶ Renderer Backend (Canvas | GLES | Skia | Native)
```

## 2. Engine 分层（主线数据流）

```
Format Adapter ─▶ Document(IR) ─▶ Style ─▶ Layout ─▶ Pagination ─▶ Page Model ─▶ Renderer
```

横向能力（跨主链，不得反向依赖上层）：`Locator`、`Navigation`、`Search`、`Annotation`、`Cache`、`Scheduler`、`Platform`。

## 3. Document IR 在系统内的位置（不实现，仅定位）

- **归属**：Engine 内层、Format 外层。上游 `format/*` 产出；下游 `style/layout/pagination/search/navigation/annotation` 消费。
- **负责**：Publication / Document(Node/Resource) / Navigation / Metadata / Locator 参照系。Resource 只存**引用**（href+mediaType），不存字节/像素。
- **不负责**：page / viewport / 字号 / 字体二进制 / 渲染 / UI / 缓存策略。
- **不变量**：Document/Publication/Node 中**禁止** `pageIndex / viewWidth / viewHeight / canvas / texture / GL / viewport / screenX / screenY`（视觉态属 Layout/Pagination/Page）。
- **Locator vs Page**：canonical 身份 = `Locator`（documentId + block + charOffset，可含 hash）；`Page` 是 Layout+Pagination 的**派生**。重分页时 Page 变、Locator 不变。
- **与现有类型**：`common/model/{Publication,Manifest,Metadata,Link}` 已接近 IR 组件；`ParsedBook`（含 `chapters[].content` HTML + `imagePaths` + `cssTexts` + `strategy`）是"解析产物＋渲染策略"混合体，需拆为纯文档结构 + 资源引用（`strategy` 移 Layout）；`ReadingAnchor/ReadingState` 已是正确的 Locator 参照系。
- **缓存键**：源指纹(size+mtime) + format version + **IR schema version**；**不含**字号/viewport（那是 Layout 键，满足 I6/I7）。

## 4. Reflow / Fixed / Image Sequence（不得强行统一）

统一的是 **语义层**：`Publication / Metadata / Resource / Navigation / Locator / ReaderSession`。
**内容模型分支**（禁止 `UniversalDocument` + `if format==EPUB/…`）：

| 内容形态 | 模型 | 现有代码佐证 |
|---|---|---|
| Reflow | Document / Node Tree | `ReflowRouter`、`LayoutEngine`、TXT/EPUB reflow |
| Fixed | FixedPage / DrawingObject | `isFXL`、`PageManager.createFXLSinglePage` |
| Image Sequence | ImagePage | `CbzParser`（每图一页）、`ImageRouter` |

## 5. Format / Platform / Renderer 边界

- **Format SPI**：`BookParser`（`common/parser/ParserRegistry.ets:121`）→ 产出 Document（未来为 IR）。Format Adapter **不得**调用 ArkUI/GLES/UI/线程。
- **Platform SPI**：`FileSystem/Storage/FontProvider/ImageDecoder/TextShaper/TextMeasurer/TaskScheduler/MemoryManager/Logger/Clock`。Engine 只见接口。
- **Renderer**：只消费 Page Model → Render Model/Commands；**不得**知道 EPUB/TXT/Navigation/ParseCache。

## 6. 当前 vs 目标（一句话）

当前：`entry → ReaderHost → ui-render(OhEngine/OhEngineCore/PageManager/PipelineManager) → common(模型+缓存+解压+配额)`，四世界与七关注点交织在巨型类里。目标：主链 `Format→Document→Style→Layout→Pagination→Page→Render` + 三缝（Format/Platform/Render）+ 四界（App/Engine/Platform/OS）。

> 目录如何把上述架构"说出来"：见 `DIRECTORY_STRUCTURE.md`；允许/禁止依赖：见 `DEPENDENCY_RULES.md`；模块职责：见 `MODULE_BOUNDARIES.md`；迁移：见 `MIGRATION_PLAN.md`。
