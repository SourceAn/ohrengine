# FILE_OWNERSHIP_MATRIX — 文件归属（本轮重构后）

> 生成：2026-10-11 ｜ 记录本轮**实际移动**的文件与关键类归属。旧路径 → 新路径。

## 1. `ohrengine-common`（本轮移动 24 个文件，目录 6→7）

| 旧 | 新 | 领域 |
|---|---|---|
| `model/Book.ets` | `document/Book.ets` | Document |
| `model/CssDefinitions.ets` | `document/CssDefinitions.ets` | Document(style config) |
| `model/Link.ets` | `document/Link.ets` | Document |
| `model/Manifest.ets` | `document/Manifest.ets` | Document |
| `model/Metadata.ets` | `document/Metadata.ets` | Document |
| `model/Publication.ets` | `document/Publication.ets` | Document |
| `font/FontLoader.ets` | `typography/FontLoader.ets` | Typography(字体加载) |
| `font/FontFallbackChain.ets` | `typography/FontFallbackChain.ets` | Typography |
| `font/FontFallbackCache.ets` | `typography/FontFallbackCache.ets` | Typography(cache) |
| `controller/FontSizeController.ets` | `typography/FontSizeController.ets` | Typography |
| `parser/ParserRegistry.ets` | `spi/ParserRegistry.ets` | Format SPI |
| `parser/StrategyRegistry.ets` | `spi/StrategyRegistry.ets` | Renderer SPI |
| `service/PageCacheManager.ets` | `cache/PageCacheManager.ets` | Cache(layout) |
| `service/ParseCacheManager.ets` | `cache/ParseCacheManager.ets` | Cache(document) |
| `service/MemoryPageCache.ets` | `cache/MemoryPageCache.ets` | Cache(page) |
| `service/DiskCacheQuotaManager.ets` | `cache/DiskCacheQuotaManager.ets` | Cache(lifecycle) |
| `service/CacheMigration.ets` | `cache/CacheMigration.ets` | Cache(lifecycle) |
| `service/ImportCheckpoint.ets` | `cache/ImportCheckpoint.ets` | Cache(lifecycle) |
| `service/BookStorage.ets` | `storage/BookStorage.ets` | Storage(path) |
| `service/SecureArchive.ets` | `storage/SecureArchive.ets` | Storage(archive) |
| `service/CancellationToken.ets` | `runtime/CancellationToken.ets` | Runtime |
| `service/ParameterBus.ets` | `runtime/ParameterBus.ets` | Runtime |
| `service/MemoryPressureHub.ets` | `runtime/MemoryPressureHub.ets` | Runtime |
| `service/ReadingStateStore.ets` | `runtime/ReadingStateStore.ets` | Runtime(state) |

其他：`types/*`（10 文件）保留；`index.ets` 公共 API **未变**（仅内部路径更新）。

## 2. `ohrengine-ui-render`（本轮移动 10 个文件，layout 23→13）

| 旧 | 新 | 领域 |
|---|---|---|
| `layout/CssCompiler.ets` | `style/CssCompiler.ets` | Style |
| `layout/CssCounterManager.ets` | `style/CssCounterManager.ets` | Style |
| `layout/CssImportResolver.ets` | `style/CssImportResolver.ets` | Style |
| `layout/MediaQueryEvaluator.ets` | `style/MediaQueryEvaluator.ets` | Style |
| `layout/SelectorMatcher.ets` | `style/SelectorMatcher.ets` | Style |
| `layout/StyleMapper.ets` | `style/StyleMapper.ets` | Style |
| `layout/TextBreaker.ets` | `typography/TextBreaker.ets` | Typography(Knuth-Plass) |
| `layout/JustifyEngine.ets` | `typography/JustifyEngine.ets` | Typography |
| `layout/ReadingMetrics.ets` | `typography/ReadingMetrics.ets` | Typography |
| `layout/FontLoader.ets` | `typography/FontLoader.ets` | Typography |

保留 `layout/`（13）：LayoutEngine, FlexLayoutEngine, FloatLayoutEngine, ListRenderer, TableRenderer, RubyRenderer, SvgRenderer, MathMLRenderer, AnnotationRenderer, FauxBoldItalicRenderer, PageSplitter, RemoteResourceLoader, LayoutChapterWorker。
`render/ImageRenderer.ets`、`router/{ReflowRouter,ImageRouter}.ets`、`core/*`、`OhEngine.ets`、`OhEngineCore.ets` **未动**。
`index.ets` 公共 API **未变**（仅 export 路径更新）。

## 3. 巨型类归属（本轮**未拆分**，登记为后续）
| 类 | 现位置 | 拟归属 | 状态 |
|---|---|---|---|
| `ReaderHost` | `reader/ReaderHost.ets` | Application(host) + Engine(open pipeline) | 未拆（deferred） |
| `OhEngine` | `ui-render/OhEngine.ets` | Engine(api) + Application(feature) | 未拆 |
| `OhEngineCore` | `ui-render/OhEngineCore.ets` | engine(core) | 未拆 |
| `PageManager` | `ui-render/core/PageManager.ets` | pagination + navigation + session | 未拆 |
| `PipelineManager` | `ui-render/core/PipelineManager.ets` | style/layout/pagination + task scheduler | 未拆 |

> `index.ets` 公共导出保持兼容 ⇒ **无需 facade 即可迁移**（文件路径变、符号名不变）。

## 4. 孤儿 / 遗留
- 本轮无孤儿文件；`common/{controller,font,model,parser,service}` 5 个旧目录已**清空并删除**（非遗留）。
- 未产生 `misc/unknown/temp` 类目录。
