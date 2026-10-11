# Project Context — OhEngine

> **AI 修改代码前必读。** 本文是系统约束与架构地图的入口：先建立"数据如何流动、谁不许碰谁"的心智模型，再动手。
> 详细设计见 `architecture.md`，硬性边界见 `constraints.md`，代码位置索引见 `module_map.md`。

---

## 1. 项目是什么

自研 HarmonyOS（ArkTS）原生电子书阅读引擎 + 阅读器 App：从"文件解析 → HTML/CSS → 样式计算 → 排版 → 分页 → Canvas/GL 渲染"的完整管线。参考 crengine（C++）布局算法与 Readium（Kotlin）架构模型，CJK 排版深度优化。

## 2. 技术栈速览

- ArkTS（strict-mode，禁 `any`/`unknown`/解构/结构类型违规）
- ArkUI 声明式；正文用 **Canvas 2D 自渲染**（非 Text 组件）
- 翻页动画：PageFlipEngine（StPageFlip 几何 1:1，Canvas 2D 渲染后端 + `displaySync` 帧驱动）
- SDK 6.1.1(24) / compatible 6.1.0(23)；hvigor + ohpm 多 HAR 模块

## 3. 心智模型（三件事，一条流水线）

```text
① 解析层：  文件(.epub/.txt/.cbz) ──解析器──> ParsedBook（统一结构）
② 排版层：  ParsedBook ──Router──> HTML→DOM→RenderTree→Layout→分页──> PaginatedChapter
③ 绘制层：  PaginatedChapter ──> PageSlot{LineBox[]} ──> PageRenderer 离屏 PixelMap / PageFlipEngine 翻页
```

- **解析器只产出 `ParsedBook`**；渲染器只消费 `ParsedBook`；核心不直接读源文件。
- **格式扩展零侵入**：注册 `BookParser` 进 `ParserRegistry`，注册 `StrategyRouter` 进 `StrategyRegistry`，核心无 `switch(format)`。
- **引擎不依赖 ArkUI 组件**：页面层拿 `PageSlot.lines: LineBox[]` 自己画；引擎核心对 UI 无感知。

## 4. 目录总览（按职责）

| 目录 | 职责 | 一句话 |
|------|------|--------|
| `ohrengine-common/` | 基础 | 类型/模型/注册表/服务/字体回退（无任何依赖） |
| `ohrengine-parsers/` | 解析 | HTML / CSS 通用解析 |
| `ohrengine-epub/` | 解析 | EPUB container/OPF/NCX/SMIL/封面 |
| `ohrengine-txt-exclusive/` | 解析 | TXT 大文件流式读取 |
| `ohrengine-cbz-exclusive/` | 解析 | CBZ 解包 + 图片排序 |
| `ohrengine-pdf-exclusive/` | 解析 | PDF **桩**（明确抛"不支持"） |
| `ohrengine-ui-render/` | 引擎+排版 | OhEngine 门面/Core、Pipeline、PageManager、layout/* |
| `ohrengine-feature/` | 业务 | 词典/生词/标注/书签/主题/划选/历史/搜索 |
| `ohrengine-pageflip/` | 翻页 | PageFlipEngine/状态机/动画器/Canvas 2D 渲染后端（StPageFlip 1:1） |
| `entry/` | 应用壳 | 书架/阅读页/面板/PageRenderer（内容生产）/PageFlipBridge（翻页适配） |
| `archive/legacy-pageflip/` | 归档 | 旧 GL 翻页实现（只读，不参与编译） |

## 5. 修改代码前必须知道的 10 条约束

> 完整版见 `constraints.md`。这里的每条都是**红线**：

1. **模块单向依赖**：`common ← {parsers, feature, epub, txt, cbz, pdf}`、`{common, feature, parsers} ← ui-render`、`ui-render ← entry`、`pageflip` 独立。反向 import = 架构违规。
2. **外部只能从各模块 `index.ets` 入口 import**，禁止跨模块 import `src/main/ets/...` 内部路径。
3. **解析器不碰 UI**（禁 import ArkUI/Canvas）；**排版不依赖翻页引擎**；**绘制层不管理业务状态**；**翻页不修改分页模型**。
4. **PageFlipEngine 是唯一翻页渲染路径**（当前渲染后端 ArkTS Canvas 2D，扩展见 A8）；旧 GL 已归档，禁止回退/复用。
5. **分页模型的提交（`engine.turnPage()`）必须发生在视觉动画完成后（终帧渲染后回调）**，由 PageFlipBridge 统一触发，不得在别处另起。
6. **`open()` 返回时全书已同步分页**（`layoutAllChaptersSync`，缓存优先+写穿）；翻页到 stub 章节用同步 `ensureChapterReady`，不许留下"解析中闪现"。
7. **排版后台化**：`setTimeout` 50ms 逐章 + `layoutEpoch` 代数作废（ENG-005）；销毁后回调一律丢弃，禁止阻塞主线程。
8. **缓存指纹**：页缓存键 = 源文件 mtime/size + 布局签名；layoutProfile/字号变化必须让缓存失效。
9. **安全**：解压必经 `SecureArchive`（路径穿越/符号链接/数量/大小）；远程资源仅 HTTPS + 超时 + 上限 + 可取消。
10. **编码**：strict ArkTS 无 `any`；不加冗余注释；签名/密钥永不入库。

## 6. 行为契约（改这里必须保持）

- `OhEngine`（门面）是**唯一**对外 API；`OhEngineCore` 非公开。
- 引擎状态机：`INITIALIZED → LOADING → READY / ERROR → DESTROYED`；非 READY 不响应导航。
- RTL 书籍（OPF page-progression-direction=rtl）：视觉 FORWARD ⇄ 逻辑 BACKWARD 映射在 `PageManager.turnPage`。
- 首行缩进语义 = 2em（两个汉字宽，随字号联动），不做固定 vp 覆盖。

## 7. 文档地图（从哪读起）

1. `module_map.md` — 模块职责表 + 每个关键文件"做什么/不许做什么"
2. `architecture.md` — 依赖图、分层、数据流、生命周期、ARCH-* 决策
3. `constraints.md` — 全部红线与已知限制
4. `README.md` — 快速开始 / 支持范围 / 性能目标
5. `docs/tasks/[主任务]OhEngine长任务总控.md` — 长任务唯一入口
6. `docs/tasks/iBooks风格仿真翻页动画重构.md` — GL 翻页已知问题与重构方向（**改 GL 前必读**；已被 HOS-STPAGEFLIP-001 v2 取代，见文件顶部横幅）
7. `docs/tasks/pageflip/HOS-STPAGEFLIP-001.md` — 翻页子系统替换迁移主任务（StPageFlip ArkTS Engine 接管；P0-P5 从任务唯一入口，**改翻页动画前必读**）
8. `spec/<feature>/` — 各特性 spec/plan/tasks

## 8. 快速定位（详情见 module_map.md）

- 改对外 API → `OhEngine.ets`
- 改开书/生命周期/缓存上下文 → `OhEngineCore.ets` + `PipelineManager.ets`
- 改翻页/导航/进度 → `PageManager.ets`
- 改正文绘制/内容生产 → `entry/reader/PageRenderer.ets`（LineBox→离屏 PixelMap）
- 改翻页动画 → `ohrengine-pageflip/`（PageFlipEngine/FlipSM/FlipAnimator/FlipRenderer）+ `entry/reader/PageFlipBridge.ets`
- 加新格式 → 实现 `BookParser` → 注册进 `ParserRegistry` → 按需加 `StrategyRouter`
