# Legacy PageFlip Inventory — 旧翻页实现清单与处置映射（冻结版）

> 主任务：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`（P0 冻结点之一）。
> 用途：P4 原子切换时的精确操作依据；P0–P3 期间**禁止**按本清单执行任何移除/归档动作（A9）。
> 行号基准：~~2026-08-11 调研时工作区~~ → **2026-08-12 P4 复核时工作区**（P0→P4 期间
> `ReaderGestureController.ets` 有 0.9 方向推导整合改动，G8-G13 行号相应偏移；本清单已按
> P4 复核结果更新，其余隔离点无漂移）。
> 状态：冻结（变更须先修订主任务并重新评审；本清单行号复核修订属 P4 前置评审，已记录）。

---

## 1. 调研范围与事实基线

起始调研清单（主任务 Background §4 + P0 §1），均以实际代码核实：

- `entry/src/main/ets/reader/PageFlipController.ets`（797 行）—— 翻页控制器，GL 编排 + B2/B3 提交屏障。
- `entry/src/main/ets/reader/ReaderGestureController.ets`（220 行）—— 触摸分发，翻页分支转发给 PageFlipController。
- `entry/src/main/ets/reader/FlipDirection.ets`（45 行）—— 方向推导唯一纯函数（0.9，被 GestureController 与 PageFlipController 共用）。
- `entry/src/main/ets/pages/Index.ets`（925 行）—— XComponent 装配（:472 起注释"翻页渲染层：GL-only XComponent"、:473-485 GlFlipSurface 挂载）、PageFlipController 实例化与生命周期转发。
- `ohrengine-gl/` 整模块 —— ArkTS 薄封装 + native C++（EGL/GLES/soloist）。
- `build-profile.json5:130-131` —— `ohrengine_gl` 模块注册。
- `entry/oh-package.json5:15` —— `ohrengine-gl` 依赖声明（lock 文件同步引用）。
- 翻页相关资源/签名/CMake：`ohrengine-gl/src/main/cpp/CMakeLists.txt`（native 编译清单）、`ohrengine-gl/build-profile.json5`（externalNativeOptions，abiFilters arm64-v8a）、`ohrengine-gl/hvigorfile.ts`（harTasks）。**无翻页专属 resources**；仓库无 signingConfigs（签名本地注入，不入库，符合 constraints §5）。

### 1.1 旧翻页运行链路（现状，A9 保护中）

```text
Canvas.onTouch
  → ReaderGestureController.handleTouch()        (entry/.../reader/ReaderGestureController.ets)
  → PageFlipController.onTouchDown/Move/Up/Cancel (entry/.../reader/PageFlipController.ets)
  → captureFromPageSnapshot / captureBottomLayer  （renderPageToPixelMap → 纹理准备）
  → GlFlipEngine.beginGesture/updateGesture/endGesture（ohrengine-gl ArkTS 薄封装）
  → native C++（XComponent SURFACE + EGL + GLES3 + OH_DisplaySoloist 帧驱动）
  → 完成回调（常驻 TSFN）→ onNativeCompletion → B2 turnPage → B3 refreshPage
```

点击式翻页（animateTurnPage）同链路，仅手势为合成（synthetic=true）。

### 1.2 旧实现关键内部事实（供 P4 归档 README 与比对参考）

- 提交时机契约（constraints §3.5）：`PageFlipController.releaseCurl` 判定 → `engine.turnPage()` → native 收尾；现实现为 `onNativeCompletion`（result=completed）→ B2 校验（pageGeneration 快照比对）→ `turnPage()` → B3 `refreshPage()` → `releaseTextureTransaction`；900ms `glFallbackTimer` 兜底（PageFlipController.ets:134-182、:566-583）。
- 坐标换算：内容 vp + margins/avoidArea → Surface 全屏 px，仅存在于 PageFlipController.glPx/glPy（:113-120）。
- 纹理键：`chunkIndex:pageNumber:href:epoch:WxH:fontFamily:lineSpacing:letterSpacing:textAlign:bg:fg`（:599-611）。
- 底图预取：`bottomCache` LRU(2) + `prefetchBottomCache`（:727-796）；front 快照复用 `retainedPagePixelMap`。

---

## 2. 表格一 —— 处置映射

| 文件 | 职责 | 新 Engine 对应模块 | 处置 |
|------|------|--------------------|------|
| `entry/src/main/ets/reader/PageFlipController.ets` | 翻页控制器：手势 vp→px 换算、纹理捕获、begin/update/end/cancel 编排、B2/B3 提交屏障、900ms 兜底、底图预取 | `ohrengine-pageflip`（GestureController + FlipStateMachine + FlipAnimator + FlipRenderer）+ `entry/.../PageFlipBridge.ets`（B2 提交回调归属） | 归档（P4，`archive/legacy-pageflip/entry-reader/`） |
| `entry/src/main/ets/reader/ReaderGestureController.ets` | 触摸事件分发：翻页拖拽 / 点按 / 划选 | `ohrengine-pageflip` 公共接口（经 Bridge 接线） | 保留改造（P4 切换接线，白名单） |
| `entry/src/main/ets/reader/FlipDirection.ets` | 翻页方向推导唯一纯函数（0.9） | `ohrengine-pageflip` GestureController 内方向判定（1:1 语义迁入） | 归档（逻辑迁入新模块后源文件归档；P4） |
| `entry/src/main/ets/reader/PageRenderer.ets` | 正文绘制：LineBox→Canvas + 离屏页图输出（0.5x 降采样） | `ohrengine-pageflip/render/PageContentCache.ets`（消费方）+ 自身退居纯内容生产方 | 保留改造（仅"内容生产方"方向收窄，禁改正文绘制质量逻辑） |
| `entry/src/main/ets/pages/Index.ets` | 页面装配：Canvas + XComponent + 手势 + 面板 + 引擎 | `ohrengine-pageflip/components/PageFlipView.ets` + Bridge | 保留改造（P4 切换，白名单） |
| `ohrengine-gl/index.ets` | ohrengine-gl 唯一出口（GlFlipSurface/GlFlipEngine/类型） | `ohrengine-pageflip/index.ets` | 归档（P4，`archive/legacy-pageflip/ohrengine-gl/`） |
| `ohrengine-gl/src/main/ets/GlFlipEngine.ets` | ArkTS 薄封装：PixelMap→ArrayBuffer、意图级 API 转发 | `ohrengine-pageflip/core/FlipAnimator.ets`（帧驱动）+ Bridge（意图编排） | 归档 |
| `ohrengine-gl/src/main/ets/GlFlipSurface.ets` | XComponent(SURFACE) 挂载组件（libraryname 加载、透明背景、触摸穿透） | `ohrengine-pageflip/components/PageFlipView.ets`（全时段拥有正文显示区，D8） | 归档 |
| `ohrengine-gl/src/main/cpp/**`（napi/engine/geometry/shader/animation/core/CMakeLists.txt/types） | native GLES 翻页：EGL 生命周期、GLES3 shader、CurlGeometry、FlipStateMachine、soloist 帧驱动、spring 插值、perf 采集 | `ohrengine-pageflip`（ArkTS 优先，A8；无业务层 Native 能力） | 归档（整目录） |
| `ohrengine-gl/test/**`（geometry_test/state_machine_test/run_tests.sh） | native C++ 离线测试 | `entry/src/ohosTest/ets/unit/FlipMath/FlipCalculation/FlipStateMachine.test.ets`（hypium） | 归档（保留 git 历史；新单测在 P1/P3） |
| `ohrengine-gl/build-profile.json5` / `hvigorfile.ts` / `BuildProfile.ets` / `oh-package.json5` / `oh-package-lock.json5` | native 构建配置 / HAR 模块配置 | `ohrengine-pageflip` 对应构建文件（P1 起，P2 注册） | 归档 |
| `build-profile.json5:130-131` | `ohrengine_gl` 模块注册 | `ohrengine_pageflip` 模块注册（P2 加 / P4 移除 gl） | P4 修改（白名单） |
| `entry/oh-package.json5:15` + `entry/oh-package-lock.json5` | `ohrengine-gl` 依赖声明与 lock | `ohrengine-pageflip` 依赖（P2 加 / P4 移除 gl） | P4 修改（白名单） |
| `ohrengine-ui-render/.../PageManager.ets` | 分页模型：turnPage/peekPage 语义、RTL 映射、进度 | 不变（契约 A7） | 不动 |
| `ohrengine-ui-render/.../PipelineManager.ets` 等排版/核心 | 排版/页缓存/引擎门面 | 不变 | 不动 |
| `docs/ai/constraints.md` §1.3 | "GL 是唯一翻页渲染路径" | 修订为 PageFlipEngine 唯一路径（D1） | P4 修订（本阶段禁止改动原文） |
| `docs/tasks/iBooks风格仿真翻页动画重构.md` | GL 重构任务（v3 待评审） | 无（D2：批准即终止） | 本阶段加 superseded 横幅，正文保留 |

---

## 3. 表格二 —— 入口隔离点清单（P4 移除时的精确操作单）

> 每条可独立核验（文件:行 以调研时工作区为准）。"移除后的临时行为"描述该隔离点移除瞬间的期望状态（全部隔离点在**同一次原子提交**内完成，不产生中间态，D3）。

| 隔离点 | 文件:行 | 移除内容 | 移除后的临时行为 |
|--------|---------|----------|------------------|
| G1 XComponent 挂载 | `entry/src/main/ets/pages/Index.ets:473-485`（含 :472 注释"翻页渲染层：GL-only XComponent"） | `GlFlipSurface({...})` 组件与 `onReady` 内 `setGlEnabled` 分支（:476-483） | 由 `PageFlipView`（全时段正文显示区）替代；无 GL 挂载、无双表面切换窗口 |
| G2 GL import | `entry/src/main/ets/pages/Index.ets:16` | `import { GlFlipSurface, GlFlipEngine } from 'ohrengine-gl';` | 改为 `ohrengine-pageflip` 入口 import（PageFlipView/PageFlipEngine/Bridge） |
| G3 刷新率注入 | `entry/src/main/ets/pages/Index.ets:232` | `GlFlipEngine.setDisplayRefreshRate(refreshRate);` | 帧率期望由 FlipAnimator（displaySync setExpectedFrameRateRange）自主管理 |
| G4 书脊设置 | `entry/src/main/ets/pages/Index.ets:397` | `this.pageFlipController.setSpine(...)` | 改为 Bridge/Engine 侧书脊配置（D5 镜像在 Engine 边界发生一次） |
| G5 控制器实例化 | `entry/src/main/ets/pages/Index.ets:88-102` | `new PageFlipController({...})` 及依赖注入闭包 | 改为 `PageFlipBridge`（瘦适配层：内容生产/手势路由/提交 turnPage，A3） |
| G6 手势控制器接线 | `entry/src/main/ets/pages/Index.ets:124` | deps 中 `pageFlipController: this.pageFlipController` | 改传 Bridge；手势路由改接 PageFlipEngine 公共接口 |
| G7 生命周期转发 | `entry/src/main/ets/pages/Index.ets:173` | `this.pageFlipController.dispose();` | 改 Bridge/PageFlipView 销毁（displaySync stop + 资源释放） |
| G8 手势 Down 分支 | `entry/src/main/ets/reader/ReaderGestureController.ets:100-101`（P4 复核：原 :100-102） | `flipCtrl.onTouchDown(cx, cy);` | 改 Bridge.onTouchDown（触点标准化由 Engine 内 GestureController 负责） |
| G9 手势 Move 分支 | `entry/src/main/ets/reader/ReaderGestureController.ets:131-133`（P4 复核：原 :131-137） | `flipCtrl2.onTouchMove(cx, cy)` 及 consumed 返回 | 改 Bridge.onTouchMove；划选分支保留 |
| G10 手势 Up（拖拽）分支 | `entry/src/main/ets/reader/ReaderGestureController.ets:154-156`（P4 复核：原 :154-162） | `flipCtrl3.isDragging()` 判断 + `onTouchUp` | 改 Bridge 拖拽收尾判定 |
| G11 手势 Up（滑动/点击）分支 | `entry/src/main/ets/reader/ReaderGestureController.ets:163-199`（P4 复核：行号微移，内容不变） | `animateTurnPage` 调用（:176、:192）与 spine 读取（:165-167、:183-185） | 改 Bridge 点击/滑动翻页入口；`deps.turnPage` 无动画回退分支（:178、:194）随新引擎唯一路径删除 |
| G12 手势 Cancel 分支 | `entry/src/main/ets/reader/ReaderGestureController.ets:210-212`（P4 复核：原 :210-213） | `flipCtrl6.onTouchCancel();` | 改 Bridge.onTouchCancel（取消动画/回 Idle） |
| G13 手势依赖声明 | `entry/src/main/ets/reader/ReaderGestureController.ets:5,19` | `import { PageFlipController }` 与 `pageFlipController?: PageFlipController` | 改 Bridge 类型依赖（N1：Reader 不感知 FlipCalculation/FlipRenderer 等内部符号） |
| G14 控制器 import | `entry/src/main/ets/reader/PageFlipController.ets:21`（整文件归档） | 整文件移除；其 import `GlFlipEngine`（:21）、`deriveFlipDirection`（:22）、`FlipDirection.ets` 依赖一并解除 | 无 GL 控制器；提交回调（B2 turnPage）由 Bridge 在终帧渲染后统一触发（D6/F3） |
| G15 构建模块注册 | `build-profile.json5:130-131` | `ohrengine_gl` 模块条目 | 移除后根构建不再编译 GL 模块（ohrengine_pageflip 已注册，P2） |
| G16 构建依赖声明 | `entry/oh-package.json5:15` | `"ohrengine-gl": "file:../ohrengine-gl"` | 改为 `"ohrengine-pageflip": "file:../ohrengine-pageflip"`；`entry/oh-package-lock.json5:13,53-56` 同步 |
| G17 模块级构建文件 | `ohrengine-gl/`（build-profile.json5/hvigorfile.ts/BuildProfile.ets/oh-package.json5/oh-package-lock.json5） | 整模块 `git mv` 至 `archive/legacy-pageflip/ohrengine-gl/` | 不参与编译；archive 只读，禁止任何 import 回来（A2） |
| G18 方向推导归档 | `entry/src/main/ets/reader/FlipDirection.ets`（P4 复核补充登记） | 整文件 `git mv` 归档；其唯一导出 `deriveFlipDirection` 被 PageFlipController（归档）与 ReaderGestureController（本次改造移除）引用 | 方向判定语义由 Engine 内 GestureController 接管（P0 处置映射已登记）；Reader 不感知 |
| G19 PageRenderer 翻页截图配合 | `entry/src/main/ets/reader/PageRenderer.ets`（blitPixelMapToCanvas/renderPageToPixelMap 等翻页配合方法，P4 复核补充登记） | 保留离屏 PixelMap 产出（`renderPageToPixelMap` 供 PageContentCache 消费，D8/A8）；移除仅 GL 时代使用的 onscreen blit 配合逻辑 | 收窄为纯内容生产方；**禁改正文绘制质量逻辑**（drawPageContent 等正文排版绘制不动） |

---

## 4. 过程态说明登记

- **D2**：iBooks 重构任务自主任务批准起终止（本阶段已加 superseded 横幅）。
- **D3/A9**：P0–P3 只做分析/冻结/隔离点登记，不执行任何移除；物理归档 + Reader 切换全部在 P4 单次原子提交。
- **A1**：全程无双轨运行；P4 后项目内唯一有效翻页驱动 = `PageFlipEngine`。
- 本阶段 `git status` 白名单 = 本文档 + `stpageflip_mapping.md` + `ADR-PageFlip迁移架构决策.md` + iBooks 横幅 + project_context §7 + constraints.md §8；出现其他变更即越界。
