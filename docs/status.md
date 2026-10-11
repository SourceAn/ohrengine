# OhEngine 功能实现状态总览

> 本文档基于当前工作区源码（`$HOME/Code/Harmony/ohrengine`）逐模块审计生成，标注**已实现**、**部分实现**与**未实现**功能。  
> 生成时间：2026-08-18。  
> 说明：部分内部设计文档（如 `docs/ai/*.md`、`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`）描述的架构目标与当前源码存在差异，本文档以**实际检出的源码**为准，并在 §6 单独列出这些不一致项。

---

## 1. 总体状态

| 维度 | 状态 |
|------|------|
| 项目类型 | HarmonyOS（ArkTS）原生电子书阅读引擎 + 阅读器 App |
| 已注册构建模块 | 9 个（entry HAP + 8 个 HAR），见 `build-profile.json5` |
| 核心阅读管线 | **已实现**：解析 → 样式计算 → 排版 → 分页 → Canvas 2D 渲染 |
| 翻页动画 | **已实现（entry 内嵌实现）**：基于 StPageFlip 几何模型的 Canvas 2D 翻页；**未实现**：独立 `ohrengine-pageflip` HAR 模块 |
| 支持格式 | EPUB 2/3 ✅、TXT ✅、CBZ/CBR ✅、PDF ✅（文本层提取→可重排） |

---

## 2. 已完成功能

### 2.1 文件解析层

| 功能 | 位置 | 说明 |
|------|------|------|
| EPUB 2.0.1 / 3.2 / 3.3 解析 | `ohrengine-epub/src/main/ets/parser/EpubParser.ets` | container → OPF → manifest → spine → NCX/nav → 封面；支持 MIME 猜测 |
| EPUB XML DOM 解析 | `ohrengine-epub/src/main/ets/parser/XmlDomParser.ets` | `parseXmlToDom` / `querySelector(All)` |
| NCX / SMIL 解析 | `ohrengine-epub/src/main/ets/parser/NcxParser.ets` | 目录与媒体叠加控制 |
| TXT 流式解析 | `ohrengine-txt-exclusive/src/main/ets/TxtParser.ets` | 大文件分块异步读取 + `TextDecoder` 流式 UTF-8 解码；空行分章 |
| CBZ/CBR 解析 | `ohrengine-cbz-exclusive/src/main/ets/CbzParser.ets` | `SecureArchive` 安全解压 + 图片过滤 + 自然排序 |
| 安全解压 | `ohrengine-common/src/main/ets/service/SecureArchive.ets` | 路径穿越、符号链接、条目数量、总大小上限校验 |
| 解析器注册表 | `ohrengine-common/src/main/ets/parser/ParserRegistry.ets` | 按扩展名 + 目录探测分发，支持实例化与静态 API |
| 策略注册表 | `ohrengine-common/src/main/ets/parser/StrategyRegistry.ets` | Reflow / Image 策略路由 |
| EPUB 解析缓存 | `ohrengine-common/src/main/ets/service/ParseCacheManager.ets` | `.parsed.json` 命中跳过解析 |

### 2.2 HTML / CSS 引擎

| 功能 | 位置 | 说明 |
|------|------|------|
| HTML → DOM | `ohrengine-parsers/src/main/ets/html/HtmlParser.ets` | 构建 DOM 树并检测 math/svg/table/ruby/float 等语义节点 |
| CSS 解析 | `ohrengine-parsers/src/main/ets/css/CssParser.ets` | 规则集、选择器、@media、@font-face、@import |
| CSS 编译 | `ohrengine-ui-render/src/main/ets/layout/CssCompiler.ets` | 规则编译为 `CompiledStylesheet` |
| 选择器匹配 | `ohrengine-ui-render/src/main/ets/layout/SelectorMatcher.ets` | `RuleIndex` O(1)+O(k) 匹配 |
| 样式映射 | `ohrengine-ui-render/src/main/ets/layout/StyleMapper.ets` | CSS → 计算值 |
| 媒体查询 | `ohrengine-ui-render/src/main/ets/layout/MediaQueryEvaluator.ets` | `@media` + `prefers-contrast` / `reduced-motion` / `color-gamut` |
| CSS @import | `ohrengine-ui-render/src/main/ets/layout/CssImportResolver.ets` | 支持远程 @import |
| 字体加载 | `ohrengine-ui-render/src/main/ets/layout/FontLoader.ets` | `@font-face` 注册走 `UIContext.getFont().registerFont()` |
| 字体回退 | `ohrengine-common/src/main/ets/font/FontFallbackChain.ets` | Unicode 分段回退 + 缓存 |

### 2.3 排版与分页

| 功能 | 位置 | 说明 |
|------|------|------|
| 主布局引擎 | `ohrengine-ui-render/src/main/ets/layout/LayoutEngine.ets` | 块级/行内流式布局、Box 计算、行定位 |
| 断行 | `ohrengine-ui-render/src/main/ets/layout/TextBreaker.ets` | CJK 优先 + 拉丁断词、标点挤压、首行缩进 2em |
| 分页 | `ohrengine-ui-render/src/main/ets/layout/PageSplitter.ets` | orphan/widow/avoidBreakInside；输出 `PaginatedChapter` |
| 两端对齐 | `ohrengine-ui-render/src/main/ets/layout/JustifyEngine.ets` | 含标点挤压 |
| Flex 布局 | `ohrengine-ui-render/src/main/ets/layout/FlexLayoutEngine.ets` | flex/cross 尺寸 min/max 约束 |
| Float 布局 | `ohrengine-ui-render/src/main/ets/layout/FloatLayoutEngine.ets` | 左/右浮动、clear、行宽扫描 |
| 列表渲染 | `ohrengine-ui-render/src/main/ets/layout/ListRenderer.ets` | 列表测宽/占位/绘制辅助 |
| Ruby 标注 | `ohrengine-ui-render/src/main/ets/layout/RubyRenderer.ets` | Ruby 渲染辅助 |
| CSS 计数器 | `ohrengine-ui-render/src/main/ets/layout/CssCounterManager.ets` | 计数器管理 |
| 仿粗体/斜体 | `ohrengine-ui-render/src/main/ets/layout/FauxBoldItalicRenderer.ets` | 字体效果辅助 |
| SVG 渲染 | `ohrengine-ui-render/src/main/ets/layout/SvgRenderer.ets` | viewport/viewBox、rect/circle/ellipse/line/polyline/polygon/path/text |
| MathML 渲染 | `ohrengine-ui-render/src/main/ets/layout/MathMLRenderer.ets` | fraction/radical/superscript/subscript/text 布局与绘制 |
| 远程资源加载 | `ohrengine-ui-render/src/main/ets/layout/RemoteResourceLoader.ets` | HTTPS + 超时 + 响应体上限 + 取消令牌 |

### 2.4 引擎核心

| 功能 | 位置 | 说明 |
|------|------|------|
| 公共门面 | `ohrengine-ui-render/src/main/ets/OhEngine.ets` | 对外唯一 API；委托 `OhEngineCore` |
| 引擎核心 | `ohrengine-ui-render/src/main/ets/OhEngineCore.ets` | 状态机、生命周期、`open()`、配置、缓存上下文 |
| 排版调度 | `ohrengine-ui-render/src/main/ets/core/PipelineManager.ets` | 逐章 HTML→DOM→RenderTree→Layout→Split；后台 50ms 队列 + `layoutEpoch` 作废 |
| 页导航 | `ohrengine-ui-render/src/main/ets/core/PageManager.ets` | `turnPage` / `goToChapter` / `goToProgress` / `goToTocItem`；RTL 映射；stub 同步补齐 |
| Reflow 策略 | `ohrengine-ui-render/src/main/ets/router/ReflowRouter.ets` | EPUB/TXT 重排策略 |
| Image 策略 | `ohrengine-ui-render/src/main/ets/router/ImageRouter.ets` | CBZ 图片策略 |
| 页缓存 | `ohrengine-common/src/main/ets/service/PageCacheManager.ets` | 逐章读写 + 指纹失效 |
| 字号控制器 | `ohrengine-common/src/main/ets/controller/FontSizeController.ets` | 基准字号与用户字号管理 |
| 参数总线 | `ohrengine-common/src/main/ets/service/ParameterBus.ets` | theme/pageReady 等事件 |

### 2.5 业务功能层

| 功能 | 位置 | 说明 |
|------|------|------|
| 词典调度 | `ohrengine-feature/src/main/ets/dictionary/DictionaryScheduler.ets` | 优先级链：自定义 > Free Dictionary API > 内置 |
| 内置词典 | `ohrengine-feature/src/main/ets/dictionary/DictionaryService.ets` | 10 条内置词条 |
| Free Dictionary API | `ohrengine-feature/src/main/ets/dictionary/DictionaryService.ets` | HTTPS 在线查词 + 缓存 + 50KB 上限 |
| 自定义 API 查词 | `ohrengine-feature/src/main/ets/dictionary/DictionaryScheduler.ets` | 用户可配置 `{word}` 占位符端点 |
| 生词本 | `ohrengine-feature/src/main/ets/vocabulary/VocabularyBook.ets` | JSON 持久化 + CSV 导出 |
| 标注存储 | `ohrengine-feature/src/main/ets/annotation/AnnotationStorage.ets` | 标注增删改查 |
| 标注导出 | `ohrengine-feature/src/main/ets/annotation/AnnotationExporter.ets` | 自定义导出模板 |
| 书签 | `ohrengine-feature/src/main/ets/bookmark/BookmarkStorage.ets` | 书签持久化 |
| 主题管理 | `ohrengine-feature/src/main/ets/theme/ThemeManager.ets` | 主题切换与持久化 |
| 字体主题 | `ohrengine-feature/src/main/ets/theme/FontThemeManager.ets` | 字体主题管理 |
| 阅读历史 | `ohrengine-feature/src/main/ets/history/ReadingHistory.ets` | 500ms 防抖落盘 |
| 全文搜索 | `ohrengine-feature/src/main/ets/search/SearchIndex.ets` | 逐章 `indexOf` |
| 划选框架 | `ohrengine-feature/src/main/ets/selection/TextSelection.ets` | `HitTester` / `SelectionRenderer` / `SelectionGestureHandler` |

### 2.6 应用层（entry）

| 功能 | 位置 | 说明 |
|------|------|------|
| 书架 | `entry/src/main/ets/pages/Bookshelf.ets` | 扫描 `filesDir/books`、扩展名/大小过滤、排序、打开书籍 |
| Debug 书架 | `entry/src/main/ets/pages/debug/DebugBookshelf.ets` | Debug 入口 + 调试按钮 |
| 阅读页 | `entry/src/main/ets/pages/Index.ets` | 组装 Canvas/XComponent/手势/面板/引擎 |
| 正文渲染 | `entry/src/main/ets/reader/PageRenderer.ets` | `LineBox` → 离屏 PixelMap / 屏上绘制；0.5× 降采样 |
| 翻页动画 | `entry/src/main/ets/reader/FlipPageController.ets` + `FlipGeometry.ets` | StPageFlip 几何 1:1 移植；拖拽/点击/自动翻页；阴影/裁剪 |
| 手势控制 | `entry/src/main/ets/reader/ReaderGestureController.ets` | 拖拽/点击/划选事件分发 |
| 顶部/底部栏 | `entry/src/main/ets/panels/ReaderTopBar.ets` / `ReaderBottomBar.ets` | 阅读器控制栏 |
| 目录面板 | `entry/src/main/ets/panels/TocPanel.ets` | 目录导航 |
| 主题面板 | `entry/src/main/ets/panels/ThemePanel.ets` | 主题切换 |
| 字体面板 | `entry/src/main/ets/panels/FontPanel.ets` | 字号/字体调整 |
| 标注面板 | `entry/src/main/ets/panels/AnnotationPanel.ets` | 标注列表与管理 |
| API 配置面板 | `entry/src/main/ets/panels/ApiConfigPanel.ets` | 自定义词典 API 配置 |
| 划选菜单 | `entry/src/main/ets/panels/SelectionContextMenu.ets` | 划选操作菜单 |
| 标注列表页 | `entry/src/main/ets/pages/AnnotationListPage.ets` | 标注列表 |
| 生词本页 | `entry/src/main/ets/pages/VocabularyListPage.ets` | 生词列表 |
| 查词弹窗 | `entry/src/main/ets/pages/WordLookupDialog.ets` | 单词查询弹窗 |

### 2.7 测试与工程

| 功能 | 位置 | 说明 |
|------|------|------|
| Hypium 单测 | `entry/src/ohosTest/ets/unit/` | FontFallbackChain、TextBreaker、StyleMapper、SelectorMatcher、PageSplitter、PageCacheManager、SecureArchive、PageGeneration |
| 本地签名注入 | `hvigorfile.ts` + `signing/` | Debug/Release 构建期分离 |
| BuildProfile 生成 | `entry/src/main/ets/BuildProfile.ets` | ENG-012 |

---

## 3. 部分实现功能

| 功能 | 位置 | 已实现部分 | 缺失部分 |
|------|------|-----------|----------|
| 表格渲染 | `ohrengine-ui-render/src/main/ets/layout/TableRenderer.ets` | 表格布局（列/跨行跨列/行高/分页/边框/文本） | 单元格内图片仅渲染 `"[img] <path>"` 占位文本；`renderCellImage` 未完成真实图片加载 |
| 划选查词 | `ohrengine-feature/src/main/ets/selection/TextSelection.ets` | 命中测试、选择渲染、手势处理 | `ContextMenuManager.lookupText()` 为空 stub，仅保留向后兼容 |
| 翻译 | `ohrengine-feature/src/main/ets/dictionary/DictionaryService.ets` | 接口定义 | `BuiltinTranslationProvider.translate()` 返回占位字符串 `"Translation service not configured..."` |
| TTS 朗读 | `ohrengine-feature/src/main/ets/FeatureManager.ets` | 接口与调用位置 | `speakWord()` / `stopSpeaking()` 为空实现；`ttsEngine` 未初始化（`CoreSpeechKit` 当前 SDK 不可用） |
| 句子上下文捕获 | `entry/src/main/ets/pages/Index.ets:492` | 查词入口 | 查词时未捕获所在句子，标记为 `TODO` |
| 分页孤儿行处理 | `ohrengine-ui-render/src/main/ets/layout/PageSplitter.ets` | 基础分页 | 存在 `TODO: 回溯到前一页合并` |

---

## 4. 未实现功能

### 4.1 格式支持

| 功能 | 位置 | 状态 |
|------|------|------|
| PDF 解析与渲染 | `ohrengine-pdf-exclusive/` | **已实现（文本层提取→可重排）**：`PdfParser` 自包含扫描对象树、解码 FlateDecode、ToUnicode CMap 映射、提取 Tj/TJ 文本，产出 REFLOW 策略章节；扫描版 PDF（纯图像无文本层）仍无法提取。`PdfRenderer` 仍为占位（不参与 reflow 渲染） |

### 4.2 翻页子系统

| 功能 | 位置 | 状态 |
|------|------|------|
| 独立 `ohrengine-pageflip` HAR 模块 | `ohrengine-pageflip/` | **源码目录不存在**。当前翻页实现内嵌在 `entry/src/main/ets/reader/FlipPageController.ets` 与 `FlipGeometry.ets` 中，并非设计文档规划的独立模块 |
| `PageFlipBridge.ets` | `entry/src/main/ets/reader/PageFlipBridge.ets` | **文件不存在**。当前由 `FlipPageController.ets` 直接耦合手势/几何/渲染 |
| `PageFlipDemoPage.ets` | `entry/src/main/ets/pages/debug/PageFlipDemoPage.ets` | **文件不存在** |
| FlipMath / FlipCalculation / FlipStateMachine / FlipAnimator / FlipRenderer / PageContentCache / PageFlipView | 规划于 `ohrengine-pageflip/src/main/ets/` | **源码不存在**；这些职责当前集中在 `entry/src/main/ets/reader/FlipPageController.ets` 一个类中 |

### 4.3 文档与配套

| 功能 | 位置 | 状态 |
|------|------|------|
| 公共 API 文档 | `docs/公共API.md` | **不存在**（README 引用但目录下无此文件） |
| 性能基准文档 | `docs/性能基准.md` | **不存在**（README 引用但目录下无此文件） |
| 主任务总控文档 | `docs/tasks/[主任务]OhEngine长任务总控.md` | **不存在**（README 引用但目录下无此文件） |

---

## 5. 已归档/不再运行的旧实现

| 旧实现 | 位置 | 状态 |
|--------|------|------|
| GL 仿真翻页（`ohrengine-gl` native C++ + GLES3） | `archive/legacy-pageflip/ohrengine-gl/` | 已归档，不参与构建 |
| 旧 GL 翻页控制器 | `archive/legacy-pageflip/entry-reader/PageFlipController.ets` | 已归档，不参与构建 |

> 注：`docs/ai/constraints.md` §8 声称翻页已切换为 `ohrengine-pageflip` HAR，但实际源码中该 HAR 不存在，当前运行的是 entry 内嵌 Canvas 2D 实现。详见 §6。

---

## 6. 文档与代码不一致项

| 设计文档描述 | 当前源码事实 | 备注 |
|-------------|-------------|------|
| `ohrengine-pageflip` 是独立 HAR，零模块依赖，为唯一翻页驱动（`docs/ai/architecture.md`、`docs/ai/constraints.md`、`docs/ai/module_map.md`） | `ohrengine-pageflip/` **源码目录不存在**，`build-profile.json5` 未注册该模块 | 翻页功能实际由 `entry/reader/FlipPageController.ets` 内嵌实现 |
| Reader 侧翻页适配层为 `entry/src/main/ets/reader/PageFlipBridge.ets` | 该文件**不存在**；当前为 `FlipPageController.ets` 直接耦合 | 职责未按设计拆分 |
| 翻页迁移已完成（`constraints.md` §8：2026-08-12 迁移完成） | 独立模块未检出，无法确认迁移完成 | 可能是源码被删除或从未创建；`entry/build/` 缓存中残留 `ohrengine_pageflip` 编译产物，说明历史上曾存在 |
| 存在 `docs/公共API.md`、`docs/性能基准.md`、主任务总控文档 | 文件**不存在** | README 中链接失效 |
| `docs/performance/pageflip-canvas-benchmark.md` 记录的是 `ohrengine-pageflip` P5 优化数据 | 该模块源码不存在，数据无法与当前代码对应 | 可能是规划/预写文档 |

---

## 7. 已知限制

- **PDF 有限支持**：文本层可提取的 PDF 可重排阅读；扫描版（纯图像无文本层）无法提取文本。
- **翻页方式动画**：仿真为富动画；横滑/上下滑动/无动效为即时换页（暂无滑动补间动画）。
- **TTS 不可用**：`CoreSpeechKit` 在当前 SDK 中不可用，相关接口为空实现。
- **表格内图片未加载**：表格布局可用，但单元格内图片仅显示占位文字。
- **划选查词菜单**：菜单 UI 存在，但 `lookupText()` 回调为空 stub。
- **CFI 定位**：`navigateToCfi` 为近似实现，只取章节号 + 段落索引做字符偏移估算。
- **性能指标均为设计目标**：README 与 constraints 均声明未在真机实测。

---

## 8. 附录：关键源码速查

| 想查看什么 | 去哪里 |
|----------|--------|
| 对外 API | `ohrengine-ui-render/src/main/ets/OhEngine.ets` |
| 引擎生命周期/开书 | `ohrengine-ui-render/src/main/ets/OhEngineCore.ets` |
| 排版管线 | `ohrengine-ui-render/src/main/ets/core/PipelineManager.ets` |
| 页导航 | `ohrengine-ui-render/src/main/ets/core/PageManager.ets` |
| 正文绘制 | `entry/src/main/ets/reader/PageRenderer.ets` |
| 当前翻页动画 | `entry/src/main/ets/reader/FlipPageController.ets`、`entry/src/main/ets/reader/FlipGeometry.ets` |
| EPUB 解析 | `ohrengine-epub/src/main/ets/parser/EpubParser.ets` |
| TXT 解析 | `ohrengine-txt-exclusive/src/main/ets/TxtParser.ets` |
| CBZ 解析 | `ohrengine-cbz-exclusive/src/main/ets/CbzParser.ets` |
| PDF 桩 | `ohrengine-pdf-exclusive/src/main/ets/PdfParser.ets` |
| 词典/生词本 | `ohrengine-feature/src/main/ets/dictionary/`、`ohrengine-feature/src/main/ets/vocabulary/` |
| 书架 | `entry/src/main/ets/pages/Bookshelf.ets` |
| 阅读主页面 | `entry/src/main/ets/pages/Index.ets` |
| 构建配置 | `build-profile.json5`、`hvigorfile.ts` |
