# FEATURE_IMPLEMENTATION_MATRIX — 功能实现状态（据实）

> 生成：2026-10-11 ｜ 状态：`IMPLEMENTED` / `PARTIAL` / `PLANNED` / `LEGACY`。**未实现功能不得标记为已实现。**

| 功能 | 状态 | 证据 / 说明 |
|---|---|---|
| EPUB 解析 | IMPLEMENTED | `epub/parser/EpubParser.ets`（OPF/NCX/nav/SMIL/封面/媒体叠入口） |
| TXT 解析 + 惰性索引 | IMPLEMENTED | `txt-exclusive/{TxtParser,TxtIndexBuilder,TxtDocument,TxtChunkReader}` |
| CBZ 解析 | IMPLEMENTED | `cbz-exclusive/CbzParser.ets` |
| PDF 解析 | PARTIAL | `pdf-exclusive/PdfParser.ets` 存在；渲染/路由在 format 内（越层），打开链路曾静默失败 |
| HTML/CSS 解析 | IMPLEMENTED | `parsers/{HtmlParser,CssParser,FontFaceParser}` |
| Style（CSS 级联/计算） | IMPLEMENTED | `ui-render/style/{CssCompiler,StyleMapper,SelectorMatcher,...}` |
| Typography（Knuth-Plass 换行/两端对齐） | IMPLEMENTED | `ui-render/typography/{TextBreaker,JustifyEngine,ReadingMetrics}` |
| Layout（块/行/Flex/Float/List/Table/Ruby/SVG/MathML） | IMPLEMENTED | `ui-render/layout/*` |
| Pagination | IMPLEMENTED | `ui-render/layout/PageSplitter.ets` |
| Document IR | PLANNED | 无独立 IR；`ParsedBook` 为事实 IR（含 strategy），尚未抽象 |
| Locator（canonical 阅读身份） | PARTIAL | `ReadingAnchor/ReadingState` 存在并正确；无独立 `Locator` 类型 |
| Navigation（TOC/章节跳转） | IMPLEMENTED | `PageManager.goToTocItem/goToChapter`；`reader/panels/TocPanel` |
| Cache（Parse/Page/Memory） | IMPLEMENTED | `common/cache/{ParseCacheManager,PageCacheManager,MemoryPageCache}` |
| Cache（Asset：图片/字体/远程） | PARTIAL | `typography/FontFallbackCache`、`render/ImageRenderer`、`layout/RemoteResourceLoader`（分散，无统一 AssetCache） |
| Cache 生命周期（配额/迁移/检查点） | IMPLEMENTED | `common/cache/{DiskCacheQuotaManager,CacheMigration,ImportCheckpoint}` |
| Import（文件选择器） | IMPLEMENTED | `entry/debug/DebugBookshelf.importBook`（Debug 构建） |
| Bookshelf | IMPLEMENTED | `entry/pages/Bookshelf.ets`（Release）+ `debug/DebugBookshelf.ets` |
| Annotation（高亮/下划线/笔记） | IMPLEMENTED | `feature/annotation/AnnotationStorage`(RDB) + `layout/AnnotationRenderer` |
| Bookmark | IMPLEMENTED | `feature/bookmark/BookmarkStorage`(Preferences) |
| Search（全文） | PARTIAL | `feature/search/SearchIndex.FullTextSearch` 存在；未见 UI 装配 |
| Selection（选词/复制） | IMPLEMENTED | `feature/selection/TextSelection` + `reader/panels/SelectionContextMenu` |
| Theme（主题/字体主题） | IMPLEMENTED | `feature/theme/*` + `common/types/ThemeTypes` + `reader/common/ReaderTheme` |
| Vocabulary（生词本） | PARTIAL | `feature/vocabulary/VocabularyBook` + `entry/pages/VocabularyListPage` |
| Dictionary（在线词典） | PARTIAL | `feature/dictionary/DictionaryScheduler`（网络 http；依赖外网） |
| TTS（朗读） | PARTIAL | `FeatureManager.speakWord`（`@kit.SpeechKit`） |
| Translation（翻译） | PLANNED/PARTIAL | `@kit.TranslationKit` 引用；无完整流程 |
| MediaOverlay（EPUB 音频叠） | PLANNED（占位） | `epub/media/MediaOverlayController.ets`（注释自述“当前为占位实现”） |
| ReadingState（阅读位置恢复） | IMPLEMENTED | `common/runtime/ReadingStateStore` + `PageManager.saveProgress/loadProgress` |
| ReadingHistory | PARTIAL | `feature/history/ReadingHistory`（Preferences） |
| Renderer Backend（Canvas） | IMPLEMENTED | `reader/reader/PageRenderer.ets` |
| Renderer Backend（GL 玻璃材质） | IMPLEMENTED | `reader/glass/OhGlass.ets` + `libliquidglass.so` |
| Renderer Backend（PDF） | PARTIAL | `pdf-exclusive/PdfRenderer.ets`（应迁 render，未迁） |
| Platform SPI | PLANNED | 无接口；各层直接 `@kit.*`（见 `PLATFORM_SPI_PROPOSAL.md`） |
| Page Curl / Slide 翻页 | IMPLEMENTED | `reader/reader/{FlipPageController,SlideTurnController,FlipGeometry}` |
| Material/沉浸光感 | IMPLEMENTED | `reader/common/MaterialConfig` + `libliquidglass` |
| Legacy pageflip（GL 引擎） | LEGACY | `archive/legacy-pageflip/*`、`docs/ai/legacy_pageflip_inventory.md` |

**未伪装**：Document IR / Platform SPI / MediaOverlay / Translation 均标注 PLANNED/PARTIAL，不写作 IMPLEMENTED。
