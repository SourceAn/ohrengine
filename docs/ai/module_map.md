# Module Map — OhEngine

> 模块职责表 + 关键代码位置索引（每处标注"做什么 / 不许做什么"）。
> 依赖图与分层见 `architecture.md`，红线见 `constraints.md`。

---

## 1. 模块职责表

| 模块 | 职责 | 禁止 |
|------|------|------|
| **Parser**（parsers / epub / txt / cbz / pdf） | 解析文件 → 统一 `ParsedBook` | **不能参与 UI**（禁 import ArkUI/Canvas/组件） |
| **Layout**（ui-render/layout/*） | 排版：DOM→RenderTree→分页 | **不能依赖翻页引擎**（禁 import ohrengine-pageflip / Canvas 翻页逻辑） |
| **Renderer**（PageRenderer / ImageRenderer） | 绘制：把 LineBox 画到 Canvas | **不能管理业务状态**（不持有/改写 engine 状态、标注、进度） |
| **PageFlip**（ohrengine-pageflip + Bridge） | 翻页动画：PageFlipEngine/状态机/动画器/Canvas 2D 渲染 | **不能修改分页**（分页提交由 Bridge 在终帧渲染后统一触发） |
| common | 类型 / 模型 / 注册表 / 服务 / 字体回退 | 零依赖，不得被反向依赖 |
| feature | 词典/生词/标注/书签/主题/划选/历史/搜索 | 只依赖 common |
| entry | UI 壳 / 组装 / Canvas / 手势 | 不做排版/分页逻辑 |

## 2. 关键代码位置索引

### 引擎层（ohrengine-ui-render）

## Engine Facade（对外唯一 API）

`ohrengine-ui-render/src/main/ets/OhEngine.ets`
职责:
- 所有对外方法委托给 OhEngineCore
- 构造时注册 ReflowRouter / ImageRouter + 内置 Feature
- 暴露 sub-component 访问器（fontLoader/themeManager/paramBus/pageManager…）
禁止:
- 不允许跳过它直接向外部暴露 OhEngineCore

## Engine Core（生命周期 / 开书 / 配置）

`ohrengine-ui-render/src/main/ets/OhEngineCore.ets`
职责:
- 状态机 INITIALIZED→LOADING→READY/ERROR→DESTROYED
- open()：解析器/策略解析、页缓存上下文、同步全量分页（layoutAllChaptersSync）
- configure/setLayoutProfile/recompileCss/onFontSizeChanged
- 实现 PageManagerHost + PipelineManagerHost（打破环形依赖）
禁止:
- 不得被外部直接当作公共 API 使用

## Pipeline Manager（排版调度 / CSS / 字体 / 页缓存读写）

`ohrengine-ui-render/src/main/ets/core/PipelineManager.ets`
职责:
- 逐章 HTML→DOM→RenderTree→Layout→splitChapter
- loadAndCompileCss、字体加载、@media 编译
- 布局队列后台化（50ms） + layoutEpoch 作废（ENG-005）
- 页缓存逐章命中/写穿（PageCacheManager）
- shutdown()/clearAll()/prepareReflowPipeline/prepareImagePipeline
禁止:
- 同步全量阻塞主线程的排版

## Page Manager（页导航 / 槽位 / 进度）

`ohrengine-ui-render/src/main/ets/core/PageManager.ets`
职责:
- 全局 pageSlots[] 重建与维护（rebuildPageSlots）
- turnPage/goToChapter/goToProgress/goToTocItem/goToAnnotation（含 RTL 映射）
- stub 页创建、ensureChapterReady 同步补齐、preload 前后 3 章
- 阅读进度记录（500ms 防抖）与阅读速度学习
禁止:
- 非 READY 状态响应导航

## Reflow / Image Router（渲染策略）

`ohrengine-ui-render/src/main/ets/router/ReflowRouter.ets`
`ohrengine-ui-render/src/main/ets/router/ImageRouter.ets`
职责:
- 按 ParsedBook.strategy 建 stub 页 + 准备管线（reflow→编译 CSS；image→预分配页）
禁止:
- 在 router 中写死格式判断（应走 ParserRegistry 分发）

### 解析层

## Parser Registry / Strategy Registry

`ohrengine-common/src/main/ets/parser/ParserRegistry.ets`
`ohrengine-common/src/main/ets/parser/StrategyRegistry.ets`
职责:
- BookFormat/ParsedBook/BookParser 契约定义；按扩展名解析解析器
- 支持实例化（ARCH-004）+ 静态过渡 API
禁止:
- 解析器之间互相依赖

## EPUB Parser

`ohrengine-epub/src/main/ets/parser/EpubParser.ets`
职责:
- container→OPF→Manifest→Spine→NCX/nav→封面；MIME 猜测；输出 ParsedBook
- 配合 NcxParser / SmilParser / XmlDomParser / CoverFinder / MediaOverlayController
禁止:
- 触碰 UI；TXT/CBZ 逻辑

## HTML / CSS Parser

`ohrengine-parsers/src/main/ets/html/HtmlParser.ets`
`ohrengine-parsers/src/main/ets/css/CssParser.ets`
`ohrengine-parsers/src/main/ets/css/FontFaceParser.ets`
职责:
- HTML→DOM、DOM→RenderNode（应用编译后样式）；CSS→规则集/选择器/@media/@font-face
- 检测 math/svg/table/ruby/float 等语义节点
禁止:
- 参与排版计算（只产出结构）

## TXT / CBZ / PDF（format-exclusive）

`ohrengine-txt-exclusive/src/main/ets/TxtParser.ets`      （分块异步读取 + 流式 UTF-8）
`ohrengine-cbz-exclusive/src/main/ets/CbzParser.ets`      （ZIP 解包 + 图片排序，IMAGE 策略）
`ohrengine-pdf-exclusive/src/main/ets/PdfParser.ets`      （**桩**，parse() 明确抛"不支持" ENG-006）
禁止:
- 移回 ohrengine-parsers（index.ets 已声明迁移）

### 排版层（ohrengine-ui-render/src/main/ets/layout/）

## Layout Engine（整体布局）

`layout/LayoutEngine.ets`
职责:
- 块级/行内流式布局、Box 计算、行定位
- 预留表格/float/flex/ruby/MathML/SVG 空间
禁止:
- 依赖 GL；不感知翻页动画

## Text Breaker（断行）

`layout/TextBreaker.ets`
职责:
- CJK 优先 + 拉丁断词、标点挤压、首行缩进（2em 联动）
- 输出 LineBox + startCharOffset（字符级定位依据）
禁止:
- 引入固定 vp 缩进覆盖

## Page Splitter（分页）

`layout/PageSplitter.ets`
职责:
- orphan/widow/avoidBreakInside；PaginatedChapter{ Page[]{LineBox[]} }
禁止:
- 管理全局页槽（那是 PageManager 的事）

## 样式 / 选择器 / 媒体查询

`layout/StyleMapper.ets`（CSS→计算值）
`layout/CssCompiler.ets`（规则编译 → CompiledStylesheet）
`layout/SelectorMatcher.ets`（RuleIndex O(1)+O(k) 匹配）
`layout/MediaQueryEvaluator.ets`（@media + prefers-contrast/reduced-motion/color-gamut）
`layout/CssImportResolver.ets`（@import，支持远程）
禁止:
- 样式层不参与 Canvas 绘制

## 复杂内容渲染器

`layout/FlexLayoutEngine.ets`、`layout/FloatLayoutEngine.ets`、`layout/ListRenderer.ets`
`layout/TableRenderer.ets`、`layout/RubyRenderer.ets`
`layout/MathMLRenderer.ets`、`layout/SvgRenderer.ets`、`layout/FauxBoldItalicRenderer.ets`
`layout/AnnotationRenderer.ets`、`layout/CssCounterManager.ets`
职责:
- 各自内容类型的测宽/占位/绘制辅助（供 LayoutEngine 预留空间、PageRenderer 绘制）
禁止:
- 不管理阅读业务状态

## 字体

`layout/FontLoader.ets`、`common/font/FontFallbackChain.ets`、`common/font/FontFallbackCache.ets`
`common/font/FontLoader.ets`、`common/controller/FontSizeController.ets`
职责:
- @font-face 加载/注册（ENG-002：UIContext.getFont().registerFont）
- Unicode 分段回退 + 回退缓存；基准字号与用户字号管理
禁止:
- 阻塞 UI 线程加载字体

## 远程资源 / 其余服务

`layout/RemoteResourceLoader.ets`
`common/service/PageCacheManager.ets`、`common/service/ParseCacheManager.ets`
`common/service/SecureArchive.ets`
`common/service/ParameterBus.ets`（事件总线：theme/pageReady 等）
职责:
- 远程 HTTPS 加载（超时/上限/取消令牌 ENG-013）
- 页缓存指纹/失效/逐章读写；EPUB 解析缓存
- 解压安全校验（路径穿越/符号链接/数量/大小）
禁止:
- 缓存写失败阻断打开；不安全解压

### 绘制层（entry + ui-render）

## Page Renderer（Canvas 正文绘制）

`entry/src/main/ets/reader/PageRenderer.ets`
职责:
- 把当前页/翻页目标页的 LineBox 绘制到 Canvas（含表格/标注/划选/远程图）
- 离屏页图输出降采样 0.5×；dispose() 后拦截异步解码回调（ENG-003）
- 远程请求取消令牌（ENG-013）
禁止:
- 不持有/改写业务状态（只读 engine 快照 + 绘制）

## Image Renderer（CBZ 图片页）

`ohrengine-ui-render/src/main/ets/render/ImageRenderer.ets`
职责:
- 从 ParsedBook 章节加载图片 → PixelMap
禁止:
- 不参与文本排版

### 翻页层（entry + ohrengine-pageflip）

## PageFlip Engine（翻页引擎门面，唯一驱动）

`ohrengine-pageflip/src/main/ets/PageFlipEngine.ets`
职责:
- Reader/Bridge 唯一感知入口（A1）：生命周期 attach/detach/destroy、内容 setContentProvider、
  手势 beginDrag/updateDrag/endDrag/cancel、程序化 flipNext/flipPrevious/flipToPage、
  事件 onFlipCommitted（终帧渲染后 → Bridge 提交 turnPage）/onFlipSettled
- 编排 FlipSM（状态机唯一真源）+ FlipAnimator（displaySync 帧驱动）+ FlipRendererInterface（A8 固定接口）
禁止:
- 公共 API 泄漏内部类型（FlipCalculation/FlipState/阴影等，E3b 信息隐藏）

## PageFlip State Machine（翻页状态机，唯一真源）

`ohrengine-pageflip/src/main/ets/core/FlipSM.ets`
职责:
- 状态转移表（IDLE/DRAGGING/SETTLING_COMPLETE/SETTLING_REBOUND/CANCELLING）逐行实现（D6）
- 提交时机契约：终帧渲染后触发提交回调
禁止:
- 执行几何/帧驱动（FlipCalculation/FlipAnimator 职责）

## PageFlip Animator（帧驱动动画器）

`ohrengine-pageflip/src/main/ets/core/FlipAnimator.ets`
职责:
- displaySync 帧驱动（期望 60），IDLE 必须 stop（静态零帧回调）
- 临界阻尼（ζ=1）收尾插值，输出"触点等效位置"（拖拽/收尾几何连续）
禁止:
- 高层动画 API（animateTo/transition/Swiper/PageSlider，T3）

## PageFlip Renderer（Canvas 2D 渲染后端）

`ohrengine-pageflip/src/main/ets/render/FlipRenderer.ets`（实现 FlipRendererInterface，A8）
`ohrengine-pageflip/src/main/ets/render/PageContentCache.ets`（LRU ≤8 页，0.5x 降采样）
职责:
- StPageFlip CanvasRender.drawFrame 1:1 映射（清屏→静态页→底层裁剪→书脊阴影→翻起页→外/内侧阴影）
- 只消费 FlipState 做绘制；性能冒烟埋点（P2 E3）
禁止:
- 计算几何/动画物理/状态转移/页索引提交（P3 职责）

## PageFlip View（渲染视图）

`ohrengine-pageflip/src/main/ets/components/PageFlipView.ets`
职责:
- 全时段拥有正文显示区（D8）；持有 Canvas 上下文，创建 Renderer/Cache 并注入 Engine
- 触摸事件路由（Reader 模式经 ReaderGestureController → Bridge；harness 默认直驱）
禁止:
- 计算几何/动画物理/状态转移

## PageFlip Bridge（适配层）

`entry/src/main/ets/reader/PageFlipBridge.ets`
职责:
- 内容生产（PageRenderer 离屏 → PageContentCache）、手势路由、onFlipCommitted → PageManager.turnPage
禁止:
- 几何/动画/阴影逻辑（A3 职责上限）

## 旧 GL 实现（已归档）

`archive/legacy-pageflip/ohrengine-gl/`（GlFlipEngine/GlFlipSurface/native C++）
`archive/legacy-pageflip/entry-reader/PageFlipController.ets`
职责:
- 历史保留；不参与编译与运行（A2 只读）
禁止:
- 任何 import 回来

## Reader Gesture（手势识别）

`entry/src/main/ets/reader/ReaderGestureController.ets`
职责:
- 触摸事件分发：翻页拖拽 / 点按唤出控件 / 划选
- 翻页手势经 PageFlipBridge 路由（beginDrag/updateDrag/endDrag/cancel/flipNext/flipPrevious）
禁止:
- 直接修改分页模型

### 功能层（ohrengine-feature）

## Feature Manager（能力编排）

`ohrengine-feature/src/main/ets/FeatureManager.ets`
职责:
- 词典调度（优先级链：自定义 5 > Free Dictionary 10 > 内置 20）
- 生词本/翻译/TTS（TTS 为桩）
- 词典 API 配置持久化
禁止:
- 不暴露/改动引擎核心内部

## 各功能模块

`annotation/AnnotationStorage.ets`、`annotation/AnnotationExporter.ets`（自定义导出模板）
`bookmark/Bookmark.ets`、`bookmark/BookmarkStorage.ets`
`dictionary/DictionaryScheduler.ets`、`dictionary/DictionaryService.ets`
`history/ReadingHistory.ets`、`search/SearchIndex.ets`（逐章 indexOf 全文搜索）
`selection/TextSelection.ets`（SelectionRenderer/GestureHandler/HitTester/ContextMenu）
`theme/ThemeManager.ets`、`theme/FontThemeManager.ets`、`theme/ThemePreferenceStorage.ets`
`vocabulary/VocabularyBook.ets`（JSON + CSV 导出）
`model/WordEntry.ets`
职责:
- 各自能力的持久化/查询/导出
禁止:
- 直接依赖 ArkUI 组件；只依赖 common

### 应用壳（entry）

## Entry Ability（应用入口）

`entry/src/main/ets/entryability/EntryAbility.ets`
职责:
- 注册解析器（EPUB/TXT/CBZ/PDF 桩）
- 沉浸式全屏（状态栏/导航栏透明）
- Debug/Release 入口分离（BuildProfile.DEBUG）
禁止:
- 业务逻辑（只做装配）

## Reader Page（阅读主页面）

`entry/src/main/ets/pages/Index.ets`
职责:
- 组装 Canvas + XComponent + 手势 + 面板 + 引擎
- 面板控制（主题/字体/目录/标注/API 配置/划选菜单）、参数总线联动
- TTS/词典/生词本 UI 入口
禁止:
- 排版/分页算法逻辑

## 书架 / 其他页面

`entry/src/main/ets/pages/Bookshelf.ets`（release 书架）
`entry/src/main/ets/pages/debug/DebugBookshelf.ets`（debug 书架 + 调试入口）
`entry/src/main/ets/pages/AnnotationListPage.ets`、`pages/VocabularyListPage.ets`、`pages/WordLookupDialog.ets`
`entry/src/main/ets/panels/*`（ReaderTopBar/ReaderBottomBar/ReaderMenuPanel/ThemePanel/FontPanel/TocPanel/AnnotationPanel/ApiConfigPanel/SelectionContextMenu）
`entry/src/main/ets/utils/FileUtils.ets`
职责:
- 书架/标注列表/生词本/查词对话框；阅读器各控制面板
禁止:
- 绕过引擎公共 API 直接操作 core

---

## 3. 加功能怎么走（决策路径速查）

| 想做什么 | 改哪里 |
|----------|--------|
| 支持新格式 | format-exclusive 模块实现 `BookParser` → `EntryAbility` 注册 → 按需 `StrategyRouter` |
| 改排版 | `layout/*`（TextBreaker/LayoutEngine/PageSplitter/StyleMapper） |
| 改正文绘制 | `entry/reader/PageRenderer.ets` |
| 改翻页动画 | `ohrengine-pageflip/`（PageFlipEngine/FlipSM/FlipAnimator/FlipRenderer）+ `entry/reader/PageFlipBridge.ets`（先读 `docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`） |
| 改页导航/进度 | `ui-render/core/PageManager.ets` |
| 改缓存 | `common/service/PageCacheManager.ets` / `ParseCacheManager.ets` |
| 加业务功能 | `ohrengine-feature`（只依赖 common） |
| 加共享类型 | `ohrengine-common/types/`，并在对应 index.ets 导出 |
