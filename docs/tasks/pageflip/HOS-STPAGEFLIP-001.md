# Task ID

HOS-STPAGEFLIP-001 — 翻页子系统替换迁移：StPageFlip ArkTS Engine 成为唯一翻页驱动（主任务，v2.3）

> 状态：待评审（v2.3）
> 版本历史：
> - v1：独立 Canvas 组件定位。
> - v2：策略变更为子系统替换迁移；v2.1：评审修缮（A8 语言策略、映射冻结、Phase 0 冻结点、中间态禁令、视觉基准）。
> - v2.2：按评审意见二次修缮并拆分一主多从：移除时机后移至 P4 原子提交；数值容差分级（T10）；P2 性能冒烟 Gate；A8 渲染后端接口固定。
> - v2.3（本版）：按评审意见三次修缮（均落在从任务）：P0 mapping 表升级为函数级契约（输入/输出/坐标约束/容差/用例五字段，示例条目入文）；P1 禁止/允许清单穷尽式显式化（禁公式改写/参数私调/新增曲面）；P2 新增 Renderer 职责边界与 grep 验收（render/ 不得出现 velocity/spring/turnPage/StateMachine 等符号）；P3 新增信息隐藏清单与公共出口 grep（FoldPoint/ShadowConfig/FlipProgress/HardAngle 等内部类型禁入公共 API 与 entry）；P4 原子提交升级为硬性验收（禁半切换提交，git log 可核验）；P5 贝塞尔增强四门禁（ADR+benchmark+视觉比对+默认关闭可回滚），默认基线恒为 1:1 StPageFlip 几何。
> 执行方式：从任务严格按 P0→P5 顺序执行；每个从任务的开始前提全部满足后才允许动工；禁止跨从任务提前编码（P5 的性能埋点除外）。

---

# 从任务索引（执行入口）

| 从任务 | 文件 | 内容 | 开始前提（上一从任务出口） |
|---|---|---|---|
| P0 | `docs/tasks/pageflip/HOS-STPAGEFLIP-001-P0.md` | 旧实现分析、依赖映射与决策冻结（不移除运行入口） | 主任务批准 |
| P1 | `docs/tasks/pageflip/HOS-STPAGEFLIP-001-P1.md` | StPageFlip 数学模型 1:1 移植（纯函数，无 UI） | P0 三份冻结文档齐备 |
| P2 | `docs/tasks/pageflip/HOS-STPAGEFLIP-001-P2.md` | Canvas Renderer + 视觉基准比对 + 性能冒烟 Gate | P1 单测全绿 |
| P3 | `docs/tasks/pageflip/HOS-STPAGEFLIP-001-P3.md` | PageFlipEngine 封装（状态机/动画器/接口冻结） | P2 出口达成 |
| P4 | `docs/tasks/pageflip/HOS-STPAGEFLIP-001-P4.md` | 原子切换：归档旧实现 + Reader 接管 + 文档修订 | P3 出口达成 |
| P5 | `docs/tasks/pageflip/HOS-STPAGEFLIP-001-P5.md` | 性能优化与视觉微调（可选贝塞尔增强） | P4 验收通过 |

---

# Background

项目决策层已确定翻页子系统替换策略：**不做双轨运行，不保留两套翻页实现**。现有 GL 仿真翻页（`ohrengine-gl` native GLES + `PageFlipController` 编排）提取归档，新移植的 StPageFlip ArkTS Engine 完全接管，最终项目内只允许一个有效翻页驱动 `PageFlipEngine`。

目标架构：

```text
Reader（Index.ets / ReaderGestureController / PageFlipBridge）
        │  只感知 PageFlipEngine 公共接口
        ▼
PageFlipEngine（ohrengine-pageflip HAR，ArkTS 优先实现，语言策略见 A8）
        ├── GestureController   触点标准化 + 热区判定
        ├── FlipCalculation     StPageFlip 几何模型 1:1 移植
        ├── FlipStateMachine    翻页状态机（唯一真源）
        ├── FlipAnimator        displaySync 帧驱动 + 自主插值物理
        └── FlipRenderer        Canvas 2D 绘制 + 页内容缓存（渲染后端接口见 A8）
```

现状关键事实（执行前必读）：

1. 现有翻页动画由 `ohrengine-gl`（XComponent + EGL + GLES3 shader，native C++）实现，ArkTS 侧编排为 `entry/src/main/ets/reader/PageFlipController.ets`；静态正文由 `PageRenderer.ets`（Canvas 2D）绘制。
2. `docs/ai/constraints.md` §1.3 现行规定"GL 是唯一翻页渲染路径，禁止回退 2D 翻页"。**主任务批准后该条进入待修订状态**，正式修订在 P4 与代码切换同提交（见决策 D1）。
3. 进行中的 `docs/tasks/iBooks风格仿真翻页动画重构.md`（GL 重构，v3 待评审）自本主任务批准起终止；P0 负责在其文件顶部加 superseded 横幅。
4. GL 引用点起始清单（P0 以代码调研补全）：`entry/src/main/ets/reader/PageFlipController.ets`、`entry/src/main/ets/reader/ReaderGestureController.ets`、`entry/src/main/ets/pages/Index.ets`（:472 "翻页渲染层：GL-only XComponent"）、`entry/oh-package.json5`（`ohrengine-gl` 依赖）、`build-profile.json5`（`ohrengine_gl` 模块注册，:130-131）。

StPageFlip 事实核查（防止脑补不存在的算法）：

- 软页（soft）**不是**贝塞尔曲面变形。真实模型 = **旋转矩形 + 多边形裁剪 + 渐变阴影**（`src/Flip/FlipCalculation.ts`、`src/Render/CanvasRender.ts`、`src/Page/ImagePage.ts`）：折叠角 `2·acos(left / hypot(top, left))`；页矩形四角绕触点旋转；线段求交得页边交点，产出"翻起页/底层页"双裁剪多边形；真实感来自三道线性渐变阴影（书脊中缝、折叠外侧、折叠内侧）。
- 硬页（hard）= 绕书脊边的受限 2D 旋转（hardAngle），不做曲面。
- "贝塞尔折叠边缘"仅为 P5 可选增强且须 ADR 先行；几何主体必须 1:1 移植。

已核验 ArkUI API 事实（SDK 6.1.1(24) / compatible 6.1.0(23)）：

- `CanvasRenderingContext2D` 具备移植所需全部 2D 能力：路径、clip、save/restore、变换、createLinearGradient、fillRect、`drawImage(ImageBitmap | PixelMap, ...)`。
- 绘制调用进入指令队列于下一渲染阶段执行；组件不可见时继续提交会导致指令堆积、内存膨胀——必须停止提交。
- Canvas 单边超过 8000px 走 CPU 渲染，性能显著下降。
- 帧驱动用 `@ohos.graphics.displaySync`：`create()` → `on('frame', cb)`（`IntervalInfo{timestamp, targetTimestamp}` 纳秒）→ `setExpectedFrameRateRange()` → `start()/stop()`。

# Objective

1. 旧 GL 翻页实现完整归档（保留 git 历史），StPageFlip ArkTS Engine 接管阅读器全部翻页动画；
2. 最终状态项目内**只允许一个有效翻页驱动 `PageFlipEngine`**，无任何旧翻页运行路径，无新旧切换开关；
3. 翻页几何模型 1:1 移植 StPageFlip（折叠几何/页面裁剪/阴影模型/soft/hard 密度）；
4. 动画物理完全由 `FlipAnimator` 自主计算（时间/速度/弹簧方程/进度/几何更新），不依赖任何高层动画 API；
5. 阅读器既有功能（EPUB/TXT/CBZ 打开、翻页、字号调整、横竖屏、标注/划选/目录导航）零回归；
6. 目标设备 60fps（设计目标值，P5 实测记录）。

# Scope（全局汇总；各从任务的 Scope 是其子集）

## 新建

```text
ohrengine-pageflip/                        # 新 HAR，零模块依赖（对标 ohrengine-gl 架构槽位）
    oh-package.json5 / build-profile.json5 / hvigorfile.ts / src/main/module.json5
    src/main/ets/index.ets                 # 唯一出口
    src/main/ets/PageFlipEngine.ets        // 门面
    src/main/ets/core/FlipTypes.ets        // 类型 + FLIP_DEFAULTS 参数表（零依赖）
    src/main/ets/core/FlipMath.ets         // 纯几何函数库
    src/main/ets/core/FlipCalculation.ets  // StPageFlip FlipCalculation 1:1 移植
    src/main/ets/core/FlipStateMachine.ets // 状态机（唯一真源）
    src/main/ets/core/FlipAnimator.ets     // displaySync + 临界阻尼插值 + 帧耗时统计
    src/main/ets/render/FlipRenderer.ets   // Canvas 2D 渲染后端（实现渲染后端接口，A8）
    src/main/ets/render/PageContentCache.ets
    src/main/ets/components/PageFlipView.ets
entry/src/main/ets/reader/PageFlipBridge.ets           // 瘦适配层（P3 建、P4 接线）
entry/src/main/ets/pages/debug/PageFlipDemoPage.ets    // P2/P3 验证 harness（仅 debug，ENG-012）
entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets / FlipStateMachine.test.ets
docs/ai/legacy_pageflip_inventory.md       // P0 冻结：旧实现清单与处置映射
docs/ai/stpageflip_mapping.md              // P0 冻结：StPageFlip 源函数 → 新模块函数映射表
docs/adr/ADR-PageFlip迁移架构决策.md        // P0 冻结：决策表 D1-D9 冻结版
docs/performance/pageflip-canvas-benchmark.md // P5 产出
archive/legacy-pageflip/README.md          // P4 归档说明
.verify-shots/pageflip/                    // 视觉基准截图（P2/P5）
```

## 修改（白名单，除此之外不得改）

- `build-profile.json5`（P2 新增 ohrengine_pageflip；P4 移除 ohrengine_gl）、`entry/oh-package.json5` 与 lock 文件（同步）；
- `entry/src/main/ets/pages/Index.ets`、`reader/ReaderGestureController.ets`（P4 切换）；`reader/PageRenderer.ets`（仅"内容生产方"方向收窄，禁改正文绘制质量逻辑）；
- 文档：`constraints.md`、`module_map.md`、`architecture.md`、`project_context.md`、iBooks 任务横幅（修改时机见各从任务）。

## 归档（P4 单次原子提交，`git mv`）

`ohrengine-gl/` → `archive/legacy-pageflip/ohrengine-gl/`；`PageFlipController.ets` → `archive/legacy-pageflip/entry-reader/`；P0 inventory 登记的其他翻页专属文件一并归档。归档要求：历史可追溯、附 README、不参与编译、禁止任何 import 回来。

## 禁止触碰

`ohrengine-ui-render` / `ohrengine-common` / `ohrengine-parsers` / `ohrengine-feature` / 各 format-exclusive 模块；`PageManager.ets` 分页模型语义；archive 目录（只读）。

# 关键架构决策（总表；冻结版由 P0 落入 ADR）

| ID | 决策 | 要点 |
|---|---|---|
| D1 | 约束修订 | P4 将 constraints.md §1.3 修订为"PageFlipEngine 是唯一翻页渲染路径（当前渲染后端 ArkTS Canvas 2D，扩展见 A8）；旧 GL 实现已归档"；§2 决策表新增反转记录；已知取舍（旧 GL 高光/褶皱/锥形收窄不保留，视觉基准只对齐 StPageFlip）写入修订说明 |
| D2 | iBooks 任务 | 批准即终止，P0 加 superseded 横幅，正文与评审文档保留作历史 |
| D3 | 移除时机与原子切换 | P0 只做分析/冻结/隔离点登记，**不移除运行入口**；物理归档 + Reader 切换在 P4 单次原子提交完成；**全程无双轨、无切换开关、无无动画中间态**（v2.2 修订） |
| D4 | 1:1 移植 | 禁止重新设计/自行推导几何模型；交付物必须是 StPageFlip Port 而非 Inspired by；判定 = 映射表逐函数登记 + 数值一致（核心几何容差 1e-6，最终绘制顶点经变换链后容差 1e-4，v2.2 分级）；贝塞尔边缘仅 P5 可选增强且 ADR 先行 |
| D5 | 坐标契约 | canonical：活动页局部 px，原点左上，书脊 x=0；右书脊镜像只在 Engine 边界发生一次；vp→px 只在 GestureController 出口一次；坐标变量带单位后缀（`xVp`/`xPx`） |
| D6 | 状态机与提交时机 | 唯一真源 FlipStateMachine（IDLE/DRAGGING/SETTLING_COMPLETE/SETTLING_REBOUND/CANCELLING，转移表见 P3）；**分页模型提交在视觉完成之后**（终帧渲染 → Bridge 回调 → turnPage）；阈值判定与末速度估算全在 Engine 内（末速度 px/ms，最近 5 触点环形缓冲，单调时钟） |
| D7 | 动画 API 边界 | 允许：Canvas2D/OffscreenCanvas、displaySync、PixelMap/ImageBitmap、onTouch 原始事件、Matrix、Path clip、Gradient、ImageKit 解码；禁止：animateTo/属性动画/transition/router 转场/Swiper/PageSlider/WebView 翻页；帧驱动仅 displaySync，IDLE 必须 stop |
| D8 | 页面显示归属 | PageFlipView 全时段拥有正文显示区（静态帧=当前页 PixelMap drawImage，无 GL 时代双表面切换窗口）；PageRenderer 退居纯内容生产方（LineBox→OffscreenCanvas→PixelMap，保留 0.5x 降采样） |
| D9 | 视觉参数表 | 全部视觉/几何调参常量集中 `FLIP_DEFAULTS`（初值照抄 StPageFlip）；改数值会变效果 = 必须入表；数学恒等常量不受限 |

# 架构约束（全局红线，从任务只引用不重复定义）

- A1（最高优先级）：迁移完成后唯一翻页驱动 = `PageFlipEngine`；禁止新旧双实现并存运行；Reader 只感知 PageFlipEngine/PageFlipView。
- A2：归档目录只读，不参与编译，禁止从 archive import。
- A3：`ohrengine-pageflip` 零模块依赖；entry 仅经其 `index.ets` 消费；Bridge 是 entry 侧唯一适配层（职责上限：内容生产/手势路由/提交 turnPage；禁几何/动画/阴影逻辑）。
- A4：几何模型 1:1 移植（D4 判定标准唯一）。
- A5：Demo/harness 仅 debug 入口（ENG-012），release 不含。
- A6：文档同步是切换的组成部分，与 P4 代码同提交，缺失视为未完成。
- A7：分页模型契约不变（`turnPage/peekPage` 语义与签名）。
- A8：语言策略——ArkTS 优先，本次渲染后端为 Canvas 2D，不设"纯 ArkTS"硬限制；禁止依赖业务层 Native 能力；**渲染后端经固定接口抽象：`PageFlipEngine → FlipRendererInterface → Canvas2D 实现（本次）/ 未来 Native 实现`**；任何未来 Native Renderer 不得改变 FlipCalculation/FlipStateMachine/FlipAnimator 的接口与语义，且须经 ADR 评审（v2.2 补充，防架构裂开）。
- A9：移除时机——旧实现运行入口的物理移除只允许发生在 P4 原子提交中；P0-P3 禁止删除/破坏旧链路任何运行能力（v2.2 新增）。

# 技术约束（全局）

- T1：ArkTS strict-mode：禁 any/unknown/解构赋值/结构类型违规；显式类型标注；const enum。
- T2：渲染仅用 D7 允许清单；禁止 WebView/DOM 模拟/动态执行 JS。
- T3：动画仅 FlipAnimator 自主计算 + displaySync；禁止 D7 禁止清单全部高层动画/翻页 API。
- T4：阴影仅 createLinearGradient；禁 shadowBlur/shadowColor。
- T5：Canvas 单边 ≤ 8000px；onSizeChange 校验并降级提示。
- T6：Canvas 不可见时停止提交绘制指令。
- T7：热路径每帧零对象分配；PixelMap 只经 PageContentCache 读写；禁止每帧解码图片。
- T8：hilog tag `OhEngine-PageFlip`（性能 `OhEngine-Perf`）；禁 emoji；注释只写"为什么"。
- T9：StPageFlip（MIT）仅供算法对照，禁止整文件复制。
- T10：数值容差分级（v2.2）：核心几何函数（折叠角/页边交点/矩形四角，canonical 坐标）与 StPageFlip 同输入一致，容差 1e-6；经完整变换链后的最终绘制顶点/裁剪多边形顶点，容差 1e-4；单测按级断言，禁止为追平 1e-15 级浮点顺序差返工。

# Non Goals

- 不保留任何旧翻页运行路径（无 GL 回退、无双轨开关）。
- 不重写 PageRenderer 正文绘制质量逻辑；不改 PageManager 分页契约。
- 不做双页书 spread（横屏仅单页自适应）；不做自定义 ArkUI 组件页内容（仅预留接口形态）。
- 不做 3D 曲面网格/Vulkan；贝塞尔折叠边缘仅为 P5 可选增强且 ADR 先行。
- 不做翻页音效、缩略图导航、多指缩放等周边功能。
- 不修复与翻页无关的既有问题（PDF 桩、TTS 桩等维持现状）。
- Native 渲染后端（A8 预留扩展，非本次交付/验收项）。

# 全局验收标准（从任务验收的汇总；各从任务另有自身验收项）

## 旧系统（归档核验，P4 执行）

- O1：`archive/legacy-pageflip/` 完整保存旧实现，git 历史可追溯；README 齐备；
- O2：`rg "PageFlipController|GlFlipEngine|ohrengine-gl|gl_flip" entry/src ohrengine-* --glob '!archive/**'` 无运行引用；构建配置无 gl 注册/依赖。

## 新系统（唯一驱动）

- N1：Reader 翻页全部经 `PageFlipEngine`；Reader 代码不出现 FlipCalculation/FlipRenderer 等内部符号；
- N2：`rg "animateTo|\.transition\(|Swiper|PageSlider" ohrengine-pageflip entry/src/main/ets/reader/PageFlipBridge.ets entry/src/main/ets/pages/Index.ets` 为空；IDLE 状态 displaySync 已 stop；
- N3：映射表逐函数登记完整；数值一致满足 T10 分级容差。

## 功能与回归

- F1：EPUB/TXT/CBZ 打开→拖拽/点击翻页→字号/行距调整→横竖屏旋转→标注/划选/目录/进度导航全矩阵通过；RTL 书方向映射正确；
- F2：soft 页折叠角/双裁剪/三道阴影/页背正确；hard 页受限旋转与更强阴影；
- F3：页索引提交严格在终帧渲染之后；`turnPage` 失败路径画面与模型最终一致；
- F4：debug/release 双构建通过；既有 + 新增 hypium 单测全绿。

## 视觉（固定基准程序）

- V1：相同页尺寸比例下，固定拖拽进度 25%/50%/75% 及回弹中点四姿态，StPageFlip 官方 Demo 与本实现成对截图存入 `.verify-shots/pageflip/`（`pose-25-stpageflip.png`/`pose-25-arkts.png` 等）；比对折叠角度、双裁剪边界、页背位置、三道阴影方向与强度；评审并排截图，真实感 ≥ StPageFlip Canvas 版 80%。
- V2：视觉基准只对齐 StPageFlip，不与旧 GL 效果比对；禁止以"缺少旧 shader 效果"为由返工。

## 性能（目标值，实测记录 benchmark 文档）

- P1：拖拽与收尾帧 P95 < 16ms（displaySync IntervalInfo 帧间隔 + JS 绘制提交耗时，两项都报）；
- P2：连续 20 次翻页无掉帧；IDLE 零帧回调消耗；
- P3：热路径每帧零分配；8 页 LRU 缓存内存上界可证明；
- 未达标处理：允许保留实测偏差+分析，报告必须区分目标值 vs 实测值，禁止混用。

# 回滚

P4 前：新实现未接 Reader，回滚 = 删除新模块与 harness（旧链路未被破坏，A9 保障）。P4 后：回滚 = `git revert` P4 原子提交，恢复 GL 路径；archive 目录永不参与运行。

# Test Requirements（全局）

- 单测：FlipMath / FlipCalculation / FlipStateMachine（范围见各从任务）；既有单测不得破坏。
- 迁移核验：O2/N2 grep 命令作为 CI 人工核验项。
- 人工核验：20 页 harness 全姿态；阅读器全回归矩阵；动画中新触摸接管；快速甩动；拖拽反手；旋转中取消；连续翻页 20 次。
- 文档核验：P0 冻结点三文档齐备且按表回填；D1 文档修订与 P4 代码同提交。
