# DIRECTORY_STRUCTURE — 当前 / 目标 目录与映射

> 生成：2026-10-11 ｜ 依据实际 `src` 扫描。**本轮未移动任何产品文件**（原因见 §4 Rationale 与 §5 本轮边界）。

## 1. Current（当前真实目录）

工程是 **9 个 HAR + 1 个 HAP**；每模块 `src/main/ets/` 下的目录：

```
ohrengine-common/src/main/ets/         ohrengine-ui-render/src/main/ets/
  controller/                            core/          ← {PageManager, PipelineManager, DefaultMediaOverlayController}
  font/                                  layout/        ← 24 files (LayoutEngine, TextBreaker, CssCompiler, …)
  model/        ← 泛名                  render/        ← ImageRenderer
  parser/                                router/        ← ReflowRouter, ImageRouter
  service/      ← 泛名(垃圾桶)
  types/        ← 泛名

ohrengine-epub/src/main/ets/           ohrengine-txt-exclusive/src/main/ets/   (12 files 平铺)
  media/ parser/ model/ ← 泛名
                                       ohrengine-cbz-exclusive/…/ets/          (1 file)
ohrengine-parsers/…/ets/
  css/ html/                           ohrengine-pdf-exclusive/…/ets/          (4 files 平铺)

ohrengine-feature/src/main/ets/        ohrengine-reader/src/main/ets/
  annotation/ bookmark/ dictionary/      common/   ← 泛名
  history/ model/ ← 泛名                 glass/    ← libliquidglass.so (GLES)
  search/ selection/ theme/ vocabulary/  panels/   ← 16 个 UI 面板
                                         reader/   ← PageRenderer(Canvas)/Flip/Gesture
                                         service/  ← 泛名
                                         utils/    ← 泛名

entry/src/main/ets/
  debug/ entryability/ pages/
```

**目录复杂度指标（Current）**

| 指标 | 值 |
|---|---|
| 顶层模块 | 10 |
| 架构叶子目录（合计） | 40 |
| `.ets` 文件 | 161（含 entry ohosTest 计 204） |
| 平均文件/目录 | 4.03 |
| 单文件目录 | 11 |
| **泛名目录** | **9**：`common/model/service/types`、`epub/model`、`feature/model`、`reader/common/service/utils`、`ui-render/core` |
| 含跨模块 `ohrengine-*` import 的文件 | 71 |
| 模块环 | 0（DAG 成立） |
| Engine 内 `@kit.*` 文件 | ui-render 8 / common 8 / reader 21 |
| Engine → Format 直接依赖文件 | 0（模块级已隔离） |

## 2. Target（目标目录）

> 不机械照搬；**只保留有稳定边界的目录**。真·可替换处才建 `spi/`（§12 任务原则）。

```
ohrengine/
├── api/                 ReaderEngine / ReaderSession / Publication / Locator / ReadingState / Navigation / Bookmark / SearchResult / Page
├── engine/
│   ├── publication/     Publication, Metadata, Manifest, Resource
│   ├── document/        Document, Node, Resource, Navigation, DocumentBuilder SPI
│   ├── locator/         Locator, ReadingAnchor, offset 语义
│   ├── navigation/      TOC / spine / reading order
│   ├── style/           CssCompiler, StyleMapper, SelectorMatcher, CssCounter, MediaQuery, HtmlParser, CssParser
│   ├── layout/          reflow/ fixed/ image-sequence/ ; TextBreaker, JustifyEngine, LayoutEngine, *Renderer
│   ├── pagination/      PageSplitter, Page Model, page-count
│   ├── page/            PageSlot, materialization window
│   ├── search/          SearchIndex
│   └── annotation/      Annotation, Bookmark, Selection（语义）
├── format/
│   ├── spi/             BookParser（= DocumentBuilder）
│   ├── epub/  txt/  pdf/  cbz/  (html/ markdown/ mobi/ azw/ 未来)
├── cache/
│   ├── document/        ParseCacheManager（语义缓存）
│   ├── layout/          byte→(PageCacheManager) 分页缓存
│   ├── page/            MemoryPageCache（视觉/内存）
│   ├── asset/           image/font/remote 资源缓存
│   └── lifecycle/       DiskCacheQuotaManager, CacheMigration, ImportCheckpoint, BookStorage
├── render/
│   ├── api/             Renderer SPI (RenderModel/Command)
│   ├── model/           RenderNode → RenderModel/Commands
│   └── backend/         canvas/ (PageRenderer)  gles/ (OhGlass)  pdf/
├── platform/
│   ├── api/             PlatformFileSystem/Storage/FontProvider/ImageDecoder/TextShaper/TextMeasurer/TaskScheduler/MemoryManager/Logger/Clock
│   └── harmony/         上述的 HarmonyOS 实现（现散落各处）
└── application/         entry(Ability/Bookshelf)、panels、settings、stats、dictionary/TTS/vocabulary、theme UI
```

**到 Target 时的指标（目标值）**：泛名目录 **0**；Engine 内 `@kit.*` **0**；Engine→Format 直接依赖 **0**；单文件目录尽量 0；平均文件/目录 ≈ 5–8。

## 3. Mapping（旧 → 新 → 原因）

| OLD | NEW | REASON |
|---|---|---|
| `common/model/{Publication,Manifest,Metadata,Link}` | `engine/document/` + `engine/publication/` | model 泛名；这些是文档/出版物语义 |
| `common/parser/{ParserRegistry,StrategyRegistry}` | `format/spi/` + `render/api/` | 是 SPI 契约，不是"common" |
| `common/service/PageCacheManager` | `cache/layout/` | 分页缓存＝Layout 类缓存 |
| `common/service/ParseCacheManager` | `cache/document/` | 解析结果＝语义缓存 |
| `common/service/MemoryPageCache` | `cache/page/` | 视觉/内存缓存 |
| `common/service/{DiskCacheQuotaManager,CacheMigration,ImportCheckpoint,BookStorage}` | `cache/lifecycle/` | 缓存生命周期/路径约定 |
| `common/service/SecureArchive` | `platform/harmony/`(+`format/`) | ZIP 解压＝平台 IO |
| `common/service/{CancellationToken,ParameterBus}` | `engine/`（session 运行时） | session 运行时原语 |
| `common/service/ReadingStateStore` | `engine/locator/`(+session) | 阅读位置＝Locator 语义 |
| `common/{types,font,controller}` | 按职责拆入 `engine/document`、`platform/api.FontProvider`、`engine/layout` | types 泛名；字体跨 Platform/Engine |
| `parsers/{HtmlParser,CssParser,FontFaceParser}` | `engine/style/` | 样式/文档解析 |
| `ui-render/OhEngine`(facade) | `api/`(纯) + `application/`(feature 聚合) | 门面聚合了 Feature/网络 |
| `ui-render/OhEngineCore` | `engine/`(session) + `cache/` + `format/` | open 管线混 document/cache/layout |
| `ui-render/core/PipelineManager` | `engine/layout` + `engine/pagination` + `cache/layout` + `platform/api.TaskScheduler` | CSS/排版/线程/写穿交织 |
| `ui-render/core/PageManager` | `engine/pagination` + `engine/navigation` + `engine/session` | 页模型+导航+进度+分页 |
| `ui-render/layout/*` | `engine/{style,layout,pagination}` | 24 文件按职责重分 |
| `ui-render/render/ImageRenderer` | `render/backend/` | 渲染后端 |
| `ui-render/router/{ReflowRouter,ImageRouter}` | `engine/layout/`(策略实现) | 布局策略 |
| `feature/{annotation,bookmark,search,selection}` | `engine/{annotation,search}`（语义）+ 存储入 cache/app | 阅读语义 vs 持久化 |
| `feature/{dictionary,vocabulary,tts,history,theme}` | `application/` | 应用/网络能力 |
| `epub/*` | `format/epub/` | 职责正确，仅搬家 |
| `txt-exclusive/*`（含 taskpool） | `format/txt/` + `platform/api.TaskScheduler` | 抽线程，格式留 adapter |
| `cbz-exclusive/CbzParser` | `format/cbz/` | 职责正确 |
| `pdf-exclusive/{Parser}` | `format/pdf/` | 职责正确 |
| `pdf-exclusive/{Renderer,Router}` | `render/backend/pdf/` | 越层到渲染 |
| `reader/reader/PageRenderer` | `render/backend/canvas/` | Canvas 后端 |
| `reader/glass/OhGlass` | `render/backend/gles/` | GLES 后端（材质） |
| `reader/{panels,common,utils}` | `application/` | UI/应用 |
| `reader/service/BatteryMonitor` | `platform/harmony/` | 平台能力 |
| `reader/ReaderHost`（打开管线部分） | `engine/{session,format}` + `cache/lifecycle` | 宿主越权到引擎 |
| `reader/ReaderHost`（页面组件） | `application/` | UI |

## 4. Rationale（为什么目标结构更易理解）

1. **看到目录即知层级**：`engine/layout`、`format/epub`、`platform/harmony`、`render/backend` ⇒ 比 `common/…`、`ui-render/layout` 一眼可判。
2. **消除泛名桶**：`common/service/types/model/core/utils` 9 个泛名目录 → 0；不再用"不知道放哪就放 common"。
3. **职责唯一**：`PageCacheManager`（Layout 缓存）与 `ParseCacheManager`（Document 缓存）不再同处 `service/`；`Page` 与 `Document` 分离。
4. **可替换缝显现**：`format/spi`、`platform/api`、`render/api` 让"换格式/换平台/换渲染器"在目录层可读。

## 5. 本轮边界（为什么"未移动"）

- 任务 §1P1「先建立边界，再迁移实现」+ §13.12「禁止为架构而大规模移动代码」+ §13.15/§20「禁止大量单文件/空抽象目录」。
- **跨 HAR 移动**（如 `common/*` → 新 `engine/*`）会改变模块依赖与 `index.ets` 公共 API，属"大迁移"，本轮禁止。
- **HAR 内桶拆分**（如 `common/service/` → `cache/…`）在当前职责未完成归类前，会**被迫制造** `runtime/`、`concurrency/` 之类新泛名目录（§13.15 违例）。
- 结论：**本轮只交付设计 + 可执行边界校验**（`tests/architecture/check_boundaries.mjs`）；物理迁移按 `MIGRATION_PLAN.md` Phase 2 起**分批**执行。

## 6. 陌生开发者测试（只看 `src/`）

| 问题 | 现状（10 模块 HAR 目录） | 目标 |
|---|---|---|
| Engine 在哪？ | ❌（`ui-render` 名字不含"engine"） | ✅ `engine/` |
| Document 在哪？ | ❌（`common/model`） | ✅ `engine/document/` |
| Layout 在哪？ | ⚠️（`ui-render/layout`，需猜） | ✅ `engine/layout/` |
| Format Adapter 在哪？ | ⚠️（`ohrengine-epub` 等命名尚可） | ✅ `format/epub/` |
| Cache 在哪？ | ❌（`common/service`） | ✅ `cache/` |
| Renderer 在哪？ | ❌（`reader/reader`+`reader/glass`） | ✅ `render/backend/` |
| Platform 在哪？ | ❌（散落各模块 `@kit.*`） | ✅ `platform/harmony/` |
| Application 在哪？ | ⚠️（`entry` + `reader/panels`） | ✅ `application/` |
| EPUB 实现在哪？ | ✅ `ohrengine-epub` | ✅ `format/epub/` |
| HarmonyOS 专属在哪？ | ❌（无边界） | ✅ `platform/harmony/` |

⇒ 现状 **3/10 秒答**，目标 **10/10**。
