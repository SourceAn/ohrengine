# MODULE_BOUNDARIES — 模块职责与边界

> 生成：2026-10-11 ｜ 取代旧版 `MODULE_BOUNDARIES.md`。每模块回答：**负责什么 / 不负责什么 / 依赖什么 / 谁可依赖它 / 是否跨平台**。
> 约束：本轮未修改产品代码。

## 0. 现状模块（HAR）与目标映射

| 当前模块 | 现行职责 | 目标归属 |
|---|---|---|
| `ohrengine-common` | 模型 + 注册表 + 服务(PageCache/ParseCache/配额/迁移/检查点/SecureArchive/ReadingState/BookStorage) + font + types + controller | 拆入 `engine/{document,locator,style}`、`cache/*`、`platform/api`、`format/spi`、`render/api` |
| `ohrengine-parsers` | HtmlParser/CssParser/FontFaceParser | `engine/style` + `engine/document`(DOM) |
| `ohrengine-epub` | EPUB 解析(OPF/NCX/nav/SMIL/封面/媒体叠) | `format/epub` |
| `ohrengine-txt-exclusive` | TXT 解析 + 惰性索引 + chunk 读取（自带 taskpool） | `format/txt` + `platform/api.TaskScheduler` |
| `ohrengine-cbz-exclusive` | CBZ 图片书解析 | `format/cbz` |
| `ohrengine-pdf-exclusive` | PDF 解析 + 渲染路由 | `format/pdf` + `render/backend/pdf` |
| `ohrengine-feature` | 批注/书签/搜索/选词/主题/生词本/词典(网络)/TTS/历史 | `engine/{annotation,search}`(语义) + `application/` |
| `ohrengine-ui-render` | OhEngine facade + OhEngineCore + Page/Pipeline 管理 + 布局引擎 + 路由 + 图片渲染 | `api` + `engine/*` + `render/*` |
| `ohrengine-reader` | ReaderHost 宿主 + 面板 UI + 翻页/手势 + 玻璃(GL) + 电池 + 设置 | `application/` + `render/backend` + `platform/harmony` |
| `entry` | Ability / 书架 / 调试页 | `application/` |

## 1. 逐模块边界

### `ohrengine-common`（约定：**不再作为收容所**）
- **负责**：基础模型与纯工具（稳定、无业务）。
- **不负责**：布局缓存、解析缓存、ZIP 解压、磁盘配额、阅读位置持久化（这些属 Cache/Platform/Format/Engine）。
- **依赖**：无（叶子）。**可被谁依赖**：全体。**跨平台**：现否（`@kit.CoreFileKit/BasicServicesKit`，8 文件）。

### `ohrengine-ui-render`（实际是 Engine core，名不副实）
- **负责**：open 管线、分页、布局、CSS、页模型、导航、图片渲染、布局策略路由。
- **不负责**：UI（应仅 1 个组件例外）、具体格式解析、平台能力。
- **依赖**：`common`、`feature`(❌ 越界)、`parsers`。**被依赖**：`reader`、`entry`。**跨平台**：否（`@kit.ArkUI/ImageKit`）。

### `ohrengine-reader`（宿主 + UI + 渲染 + 平台混合）
- **负责**：阅读器页面组装、面板、手势、翻页渲染、玻璃材质。
- **不负责**：打开/解压/缓存门控（应属 Engine）、电池/传感器（应属 Platform）。
- **依赖**：`ui-render`、`feature`、`epub`、`txt-exclusive`、`common`、`libliquidglass.so`。**被依赖**：`entry`。**跨平台**：否（强 ArkUI/原生）。

### `ohrengine-feature`
- **负责**：阅读特性（批注/书签/搜索/选词）+ 应用特性（词典/TTS/生词本/历史/主题）。
- **不负责**：布局、渲染、平台。**依赖**：`common`。**被依赖**：`ui-render`(❌)、`reader`。**跨平台**：现否（NetworkKit/SpeechKit/ArkUI）。

### `ohrengine-parsers`
- **负责**：HTML DOM、CSS、@font-face 解析。**不负责**：布局/分页/渲染。**依赖**：`common`。**跨平台**：是（无 `@kit.*`）。

### `ohrengine-epub` / `txt-exclusive` / `cbz-exclusive` / `pdf-exclusive`
- **负责**：外部格式 → 文档模型（`format → Document`）。
- **不负责**：UI/GLES、平台线程（TXT 例外：含 taskpool，需抽）、渲染（PDF 例外：含 renderer/router，需抽）。
- **依赖**：`common`。**被依赖**：`entry`（注册）；`reader` 依赖 epub/txt。**跨平台**：部分（`@kit.CoreFileKit`）。

## 2. Format / Platform / Renderer 三道缝

| 缝 | 契约 | 现状 |
|---|---|---|
| **Format SPI** | `BookParser`（`common/parser/ParserRegistry.ets:121`）→ 产出 Document | 有；产出 `ParsedBook`（非 IR） |
| **Platform SPI** | FileSystem/FontProvider/ImageDecoder/TextShaper/TextMeasurer/TaskScheduler/MemoryManager/Logger/Clock | **缺失**（直接 `@kit.*`） |
| **Renderer SPI** | `StrategyRouter`（`common/parser/StrategyRegistry.ets:30`）+ Renderer Backend | 有；实现散在 `ui-render/router`、`reader`、`pdf` |

## 3. Reflow / Fixed / Image Sequence（内容模型分支）

保留差异，不建 `UniversalDocument`：Reflow→Document/Node；Fixed→FixedPage/DrawingObject（`createFXLSinglePage`）；ImageSequence→ImagePage（`CbzParser`）。

## 4. Cache 边界（不得统称 PageCache）

| 缓存 | 语义 | 现状 | 目标 |
|---|---|---|---|
| Document Cache | 语义模型（解析产物/IR） | `common/ParseCacheManager` | `cache/document` |
| Layout Cache | 布局/分页计算 | `common/PageCacheManager` + `chapterHtmlCache` + 段落缓存 | `cache/layout` |
| Page Cache | 视觉/内存页 | `common/MemoryPageCache` | `cache/page` |
| Asset Cache | 图片/字体/远程 | `ui-render/ImageRenderer`、`common/font/FontFallbackCache`、`layout/RemoteResourceLoader` | `cache/asset`（+ `platform.ImageDecoder`） |
| 生命周期 | 配额/迁移/检查点 | `common/{DiskCacheQuotaManager,CacheMigration,ImportCheckpoint}` | `cache/lifecycle` |

规则：Cache 依赖 **Platform SPI**，不直接 `@kit.*`；`CacheKey/Version/Fingerprint/Invalidation/Quota/Eviction/Migration` 需集中定义。

## 5. 文本系统边界

| 归 Engine/Layout | 归 Platform |
|---|---|
| 行断(Knuth-Plass)、段落、分页、禁则（`TextBreaker`/`JustifyEngine`/`PageSplitter`） | 字体发现/文件加载/glyph shaping/测量后端（`layout/FontLoader` 文件部分、`reader` `FontRegistrar`、`common/font/*`） |

现状 `TextBreaker` 用"字符类型×系数估算"（`ui-render/layout/TextBreaker.ets:1-20`）规避平台测量（好）；字体加载跨 Engine/Platform，需 `FontProvider`/`TextMeasurer` SPI。

## 6. Renderer 边界

`PageRenderer`(Canvas)、`OhGlass`(GLES/libliquidglass)、`PdfRenderer` = **Renderer Backend**；只消费 **Page Model → Render Model/Commands**；不得知道 EPUB/TXT/Navigation/ParseCache。Engine 不应知道具体后端。

## 7. 十条规则（保守版，落到本工程）

| 规则 | 内容 | 现状 |
|---|---|---|
| R1 | Engine Core 不得依赖 Application | FAIL（`ui-render→feature`）|
| R2 | Engine 不得直接依赖 ArkUI | FAIL（见 `DEPENDENCY_RULES.md §4`）|
| R3 | Engine 不得直接依赖 GLES | PARTIAL（GL 仅在 `reader/glass`）|
| R4 | Document IR 不得依赖 Layout | N/A（无独立 IR）|
| R5 | Layout 不得依赖 Format Adapter | PASS（0 直接依赖）|
| R6 | Renderer 不得决定 Locator | PARTIAL |
| R7 | Cache 不得成为业务唯一来源 | PARTIAL（`PageCacheManager` 深度参与 open）|
| R8 | Page 不得成为 canonical identity | PARTIAL（`ReadingAnchor` 已正确，但页槽仍大量按页导航）|
| R9 | Platform 实现可依赖 OS | PASS（但未收敛到 `platform/harmony`）|
| R10 | App 可依赖 Engine，Engine 不反向 | FAIL（`OhEngine` 聚合 Feature）|
