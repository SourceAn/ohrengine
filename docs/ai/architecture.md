# ARCHITECTURE — OHR Reading Pipeline（重构后）

> 生成：2026-10-11 ｜ 本文件反映**已完成的物理结构**（本轮真实移动 `ohrengine-common` 与 `ohrengine-ui-render` 目录）。
> 取代旧的 `docs/ai/architecture.md`（保留为历史）。

## 1. 阅读 Pipeline（主数据流）

```
File → Import → Format Detection → Format Parser → Semantic IR → Style → Typography
     → Layout → Pagination → Page → Locator / Navigation → Render Model → Renderer → Screen
```

外围（横切）：`Cache`、`Platform`、`Application`、`Test`、`Tools`。

## 2. 模块（HAR）与 Pipeline 落点

| HAR | Pipeline 角色 |
|---|---|
| `entry` | Application（Ability/书架/装配） |
| `ohrengine-reader` | Application UI + Renderer(Canvas/GL) + Host |
| `ohrengine-ui-render` | **Engine**：Style / Typography / Layout / Pagination / Page / Navigation + Render Model |
| `ohrengine-common` | **Document / Cache / SPI / Typography(字体) / Storage / Runtime / Types**（基础域） |
| `ohrengine-parsers` | Style/Document 解析（HTML/CSS/font-face） |
| `ohrengine-epub` / `txt-exclusive` / `cbz-exclusive` / `pdf-exclusive` | **Format Parser** |
| `ohrengine-feature` | Application 特性（批注/书签/搜索/词典/TTS/主题） |

## 3. `ohrengine-common` 目录（本轮重构）

```
document/    Publication Book Manifest Metadata Link CssDefinitions      → Semantic model
typography/  FontLoader FontFallbackChain FontFallbackCache FontSizeController → Font/Typography
cache/       PageCacheManager ParseCacheManager MemoryPageCache
             DiskCacheQuotaManager CacheMigration ImportCheckpoint       → Cache(derived)
storage/     BookStorage SecureArchive                                   → Storage/Archive
spi/         ParserRegistry StrategyRegistry                             → Format/Render SPI
runtime/     CancellationToken ParameterBus MemoryPressureHub ReadingStateStore → Runtime/state
types/       EngineTypes HtmlTypes FontTypes ThemeTypes …                → cross-domain DTOs
```

## 4. `ohrengine-ui-render` 目录（本轮重构）

```
style/       CssCompiler CssCounterManager CssImportResolver
             MediaQueryEvaluator SelectorMatcher StyleMapper              → Style stage
typography/  TextBreaker JustifyEngine ReadingMetrics FontLoader          → Typography stage
layout/      LayoutEngine FlexLayoutEngine FloatLayoutEngine ListRenderer
             TableRenderer RubyRenderer SvgRenderer MathMLRenderer
             AnnotationRenderer FauxBoldItalicRenderer PageSplitter
             RemoteResourceLoader LayoutChapterWorker                    → Layout/Pagination stage
core/        PageManager PipelineManager DefaultMediaOverlayController    → Engine orchestration
render/      ImageRenderer                                               → Render Model/asset
router/      ReflowRouter ImageRouter                                    → Layout strategy
OhEngine.ets OhEngineCore.ets                                            → Engine facade/core
```

## 5. 不变量（数据流方向）

- 上游不依赖下游实现：`Format Parser` ↛ Renderer/ArkUI/Canvas/GLES；`Layout` ↛ ArkUI/ReaderHost；`Renderer` ↛ EPUB/TXT/OPF/NCX。
- `Cache` 是派生态（derived），非 source of truth。
- `Page` 不是 canonical identity（`ReadingAnchor` 为 canonical）。

## 6. 方向证明（`check_boundaries.mjs`）

- `INV-FORMAT-IN-ENGINE` PASS、`INV-COMMON-LEAF` PASS、`INV-CYCLES` PASS。
- **遗留**（本轮未处理，属后续 P1/P6）：`INV-PLATFORM`(Engine 直接 `@kit.*`)、`INV-UI`(`OhEngineCore` 用 ArkUI)、`INV-RENDER-FORMAT`(`ReaderHost` 触 ParseCache)。详见 `REFACTOR_RESULT.md §8`。
