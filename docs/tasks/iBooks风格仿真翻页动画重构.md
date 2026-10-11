# Task ID

iBooks 风格仿真翻页动画重构（v3）

> **SUPERSEDED：已被 HOS-STPAGEFLIP-001 v2 取代：GL 翻页路径将归档，不再重构。** 本任务自主任务批准起终止（主任务决策 D2）；正文与评审文档保留作历史，不得删除，不再作为开发依据。翻页子系统后续开发一律以 `docs/tasks/pageflip/HOS-STPAGEFLIP-001.md` 及其从任务为准。

> 状态：待评审（v3，已按 `docs/reviews/task_reviews/iBooks风格仿真翻页动画重构.md` 的架构评审结论修订）
> 版本历史：
> - v1：初版重构方案，经评审发现多处内部矛盾（Geometry/Shader 边界、Cone 定义、状态机归属、`shader_params.h` 跨语言真源、性能口径混淆）。
> - v2：新增"关键架构决策"（第 0 节）逐一裁定 v1 矛盾，收紧过度理想化的规则。
> - v3（本版）：v2 经架构评审判定 **FAIL**（4 项 Critical + 8 项 Warning + 8 项 Required Changes，详见评审文档）。本版按评审结论逐项修订：统一 `beginGesture` 返回值与失败语义、收紧 900ms 超时判定语义、补齐纹理事务与合成回弹的完整闭环、明确 B1→B3 空窗期的裁定、把速度计算收归 native、引入独立 `pageGeneration` 计数器、拆分 GL 可用/不可用回归矩阵、修正性能指标数量口径等。修订点在正文中以 `[v3]` 标注。
> 评审裁决（沿用至本版生效）：不允许直接执行完整开发；允许先执行前置设计、Cylinder 结构拆分、坐标/单位契约、状态机骨架（含本版新增的 token/纹理事务/`pageGeneration` 机制）与离线测试；待本版 Required Changes 均已在代码中落地并通过复审后，再进入 Cone/Hybrid 几何编码及分页提交链路改造。

---

# Background

阅读器当前的翻页动画由两部分协作实现：

```text
Canvas.onTouch
  -> ReaderGestureController.handleTouch()          (entry/.../reader/ReaderGestureController.ets)
  -> PageFlipController.onTouchMove()/onTouchUp()    (entry/.../reader/PageFlipController.ets, 689 行)
  -> OffscreenCanvas 渲染 front/bottom 两张 PixelMap
  -> XComponent(SURFACE) + GLES3 fragment shader     (ohrengine-gl/src/main/cpp/*)
  -> OH_DisplaySoloist 驱动逐帧渲染
```

静态页面仍由 ArkUI `Canvas` 绘制；翻页动画期间由一个透明的 `XComponent` 叠加在上层用原生 GLES 渲染卷曲效果，动画结束后清空 GL surface、`Canvas` 刷新到目标页。这套方案已经过多轮迭代（EGL 生命周期、坐标系、首帧延迟等问题的修复记录见 `docs/page-curl-current-status-and-issues.md`、`docs/page-flip-debugging-information.md`），目前具备：

- 单一圆柱（cylinder）近似卷曲，卷曲方向跟随手势向量；
- 拖拽跟手 + 松手后 native 侧临界阻尼插值收尾；
- 纸背半透出、褶皱阴影、高光、目标页投影等合成效果；
- 左右书脊、四角/边缘拖拽的方向判定；
- `OH_DisplaySoloist` 独立帧回调（避免每帧回 JS 线程）。

现在需要把这套"能用的圆柱近似"升级为 **iBooks 级别的仿真翻页**：原生 GLES 渲染、真正可插拔的 Cylinder / Cone 几何模型、二者混合、更稳的跟手与回弹手感，同时不能影响其他格式（EPUB/PDF/TXT/CBZ）现有的分页与渲染稳定性。

本任务已经过两轮架构评审。v1 存在多处内部矛盾（见上方版本历史）；v2 对矛盾逐一裁定后仍被判定 FAIL，核心原因是：新 API 的返回值/token 生成语义未落地、900ms 超时条件引用了不存在的确认机制、B2 提交失败后的合成回弹缺少纹理与状态闭环、B1 清屏与 Canvas 刷新之间的空窗期未被明确裁定。本版（v3）针对以上问题给出可执行的裁定，作为进入编码前的最终前置条件。

---

# Objective

在**优化现有代码结构**的基础上（而不是推倒重写整条渲染管线），实现 iBooks 风格的仿真翻页动画，具体包括：

1. 继续使用 HarmonyOS 原生 OpenGL ES（`XComponent(SURFACE)` + `EGL` + `GLES3`）渲染，不引入 Skia/Vulkan 等其他图形 API 作为本次交付的主路径（Vulkan 仅预留接口余量，不作为本次验收项，见"技术约束"）。
2. 页面卷曲效果由 GPU Shader 逐像素驱动；CPU（Geometry 层）每帧只计算并更新**一组曲率场描述参数**（数量级为几十个 float，不是逐像素数据），不做逐帧 CPU 端像素级计算，也不通过 CPU 生成大网格/位移贴图占用额外带宽。
3. 实现独立的 **Cylinder Page Curl（圆柱模型）** 几何参数化，作为一等公民、可独立验证。
4. 实现独立的 **Cone Page Curl（圆锥模型）** 几何参数化（真正的锥面/可展曲面数学，而不是现有的"圆柱 + 楔形裁剪"近似），且必须先产出正式的几何设计说明并通过评审，才能进入编码。
5. 实现 Cylinder 与 Cone 的**混合模式**：以一个可连续变化的混合因子在统一曲率场参数之间插值，而不是在两套写死公式之间做二选一切换。
6. 手势实时跟手：拖拽全过程逐帧响应触摸位置，卷曲状态与手指位置强相关、无可感知的滞后跳变。
7. 松手后的动画：**由 native 状态机**根据释放位置与内部计算出的速度判定进入"完成翻页"或"回弹原位"（ArkTS 不再自行判定阈值、不再自行计算速度），动画曲线自然（无速度突变），并与拖拽阶段的手感保持连续性。
8. 阅读器分页模型的提交时机与视觉动画完成时机严格对齐，消除"模型已翻页但画面未完成"的竞态窗口；对于提交失败的场景，必须有可闭环的合成回弹补救与最终兜底（`[v3]`）。
9. 保持现有阅读器功能稳定：EPUB/PDF/TXT/CBZ 各格式的分页、渲染、书签、划线、搜索、目录等既有功能在明确定义的回归矩阵下验证通过；GL 引擎不可用时的降级/报错路径（`isGlEnabled()`）保持可预期。

---

# Scope

## 涉及模块

| 模块/文件 | 改动性质 |
|---|---|
| `ohrengine-gl`（`src/main/cpp/*`） | 核心重构：拆分为 `core/`（渲染后端编排）、`geometry/`（Cylinder/Cone/Hybrid 纯数学）、`shader/`（GLSL + 参数表）、`animation/`（状态机 + 阻尼/滤波/速度估算）、`engine/`（瘦身后的编排层） |
| `ohrengine-gl/src/main/ets/GlFlipEngine.ets` | 按新的意图级 API（`beginGesture`/`updateGesture`/`endGesture`/`cancelGesture`）重新设计薄封装 |
| `entry/src/main/ets/reader/PageFlipController.ets` | 收敛为只描述原始手势 + 方向决策；移除动画时长/惯性/阈值判定；改造分页提交时机 |
| `entry/src/main/ets/reader/ReaderGestureController.ets` | 点击式翻页方向判定改为调用统一的 `deriveFlipDirection()` |
| `ohrengine-ui-render/src/main/ets/core/PageManager.ets` | **新增**（`[v3]`）：独立的 `pageGeneration` 计数器，覆盖所有影响 `pageSlots` 的重排入口（见"重构要求 0.13"） |
| `ohrengine-common/src/main/ets/types/EngineTypes.ets` | 如需要，补充 `pageGeneration` 相关只读访问类型（不改变现有 `PageSlot.epoch` 语义） |

## 明确不在本次范围内改动

- `OhEngine` 对外分页 API（`turnPage`/`peekPage`/`getCurrentPage` 等）的语义与签名。
- `PageRenderer` 的渲染契约（Canvas 绘制正文的方式）。
- EPUB/PDF/TXT/CBZ 各解析器与排版管线（`layout/*`）。
- Vulkan 后端的实现（仅接口余量预留，见"重构要求 0.7"）。

## 参考资料

`docs/page-curl-current-status-and-issues.md`、`docs/page-flip-debugging-information.md`、`docs/lib/page-curl/*`（第三方实现仅供算法参考，禁止直接引入）。

## 分阶段实施顺序（沿用评审裁决）

- **Phase A（当前允许立即执行）**：坐标/单位契约（0.8/0.14）定稿评审、Cylinder Geometry 结构拆分、状态机骨架（含本版新增的 token 返回值语义、纹理事务、`pageGeneration` 机制）、`deriveFlipDirection()` 纯函数与单测、性能采集代码解耦拆分。
- **Phase B（前置条件：Phase A 完成 + 本版 Required Changes 均已实现并复审通过）**：Cone 几何设计说明（0.3）编码落地、Hybrid 混合模式、分页提交链路改造（0.11/0.12/0.13）的完整实现与真机测试。
- 不允许跳过 Phase A 直接开始 Cone/Hybrid 或分页提交链路的正式编码（对应"禁止事项"）。

---

# Current Problems

以下问题基于对现有代码的实际阅读得出，均可在代码中定位：

### 1. `GlFlipEngine` 是一个承担过多职责的单体类（God Object）

`ohrengine-gl/src/main/cpp/gl_flip_engine.h`（147 行）+ `gl_flip_engine.cpp`（849 行）用**一个单例类**同时承担：

- EGL/Surface 生命周期管理（`InitEGL`/`QuerySurfaceSize`/`ReleaseGles`）；
- GL 资源管理（program、VAO/VBO、双缓冲纹理 ping-pong）；
- 卷曲几何数学（隐式内嵌在 shader 里，见问题 2）；
- 动画插值、临界阻尼弹簧、速度惯性预估、触摸低通滤波（`SetTouch`，`gl_flip_engine.cpp:360-442`）；
- 帧率档位策略（`SetFrameRate`，`gl_flip_engine.cpp:618-640`）；
- 逐帧性能采样（`RenderFrame` 内嵌静态数组统计 P50/P95，`gl_flip_engine.cpp:648-680`）；
- NAPI 线程安全回调（TSFN）生命周期管理。

`stateMutex_` 一把锁保护 15+ 个互相关联的可变字段（`gl_flip_engine.h:119-140`），`SetTouch` 一个函数里同时做惯性预估、半径目标计算、低通滤波、帧率分档四件事。这是过去多轮 "P0/P1/FLIP-BOOT-*" 级别 bug（TSFN 回调丢失、EGL 跨线程 `current` 竞争、首帧位置跳变）反复出现的根本原因之一——**改一处经常波及另一处**。

### 2. Renderer / Geometry / Shader 完全没有解耦——事实上不存在独立的 Geometry 层

`gl_flip_shaders.h`（204 行）是**唯一**描述卷曲曲面的地方：卷曲曲面没有任何顶点网格或几何表示，而是对一张静态全屏 quad 做**逆向 UV 采样**的 fragment shader 数学（`gl_flip_shaders.h:113-201`）。所谓的"Cone/角落卷曲"并不是独立的圆锥几何模型，而是在圆柱数学基础上叠加一个 "wedge 裁剪权重"来近似锥形收窄效果（`gl_flip_shaders.h:84-137`）——`docs/page-curl-current-status-and-issues.md` 第 4 节也明确写到 "Corner mode approximates the unfolded paper corner with wedge clipping, not full developable-surface topology"。

结果：

- Cylinder 与"Cone"共用同一套数学分支，无法作为两个独立模型分别验证、调参、替换；
- 无法实现题目要求的"两者混合模式"——因为没有两个可插值的几何输出可供混合，只有一份写死的组合公式；
- Renderer（EGL/绘制调用）、Geometry（曲率数学）、Shader（着色/合成）三者的代码物理上写在同一个 `.h` 字符串常量里，无法单独测试、替换或复用。

### 3. Shader 参数散落为字面量，没有统一管理

`gl_flip_shaders.h` 中的书脊留边（1.2%）、卷曲带宽反走样系数、角落判定阈值（12% / 88%）、纸背渐变区间（`PI*0.30~0.78`）、褶皱阴影强度（0.26）、目标页投影强度（0.36）、高光强度系数（0.08~0.26）等**全部是硬编码在 GLSL 字符串里的数值字面量**。C++ 侧只暴露了 8 个 uniform location（`gl_flip_engine.h:91-98`），没有任何统一的参数结构体/UBO/配置表。调整任意一个视觉系数都必须改字符串、重新编译整个 so。

### 4. 手势/动画状态机被拆成两半，靠隐式布尔组合表达

- ArkTS 侧：`curlDragging` / `flipAnimating` / `flipDirection` / `flipFromPage` / `flipToPage` 等字段（`PageFlipController.ets:24-51`）；
- Native 侧：`animMode_` / `animFromX_/Y_` / `animToX_/Y_` / `targetRadius_` / `filteredTouchX_/Y_` / `frameRateMode_` 等字段（`gl_flip_engine.h:119-140`）。

没有任何一处用**枚举/显式状态机**描述 `Idle / Dragging / SettlingToComplete / SettlingToRebound / Cancelling` 这几种状态，而是靠两侧各自的布尔组合隐式表达，且两侧状态不是同一个真源（ArkTS 不知道 native 何时真正进入插值收尾，只能靠 900ms 兜底超时 `scheduleGlFlipFallback` 猜测 native 回调是否丢失，`PageFlipController.ets:82-94`）。

### 5. ArkTS 与 Native 之间存在重复且不一致的"动画物理"实现，且完成/回弹阈值判定错误地留在了 ArkTS 侧

- ArkTS `selectAnimationDuration()`（`PageFlipController.ets:466-470`）用拖拽距离启发式算出动画时长（220ms~440ms）；
- Native `SetTouch()` 又独立用末帧速度重新估算惯性终点（`animToX = touchX + velX_ * 250.0f`，`gl_flip_engine.cpp:379-403`），并统一套用 `ζ=1` 临界阻尼曲线（`gl_flip_engine.cpp:723-728`）。
- 更关键的是：**"松手后是否完成翻页"这个判定本身也在 ArkTS 侧做**——`releaseCurl()` 用内容坐标中线比较 `spineSign * this.flipDirection * (fx - midX) > 0` 来决定 completed（`PageFlipController.ets:401-402`），并在 completed 分支里**先调用 `engine.turnPage(direction)` 提交分页模型，再启动 native 收尾动画**（`PageFlipController.ets:404-417`）。这意味着分页模型的提交时机早于视觉动画的完成，一旦收尾动画被取消或完成回调丢失（依赖 900ms 兜底），会出现"数据模型已翻页，但画面可能仍在回弹/卡在中间态"的竞态窗口。

两套时长/惯性系数在两个语言里各自硬编码，任何一侧单独调参都可能与另一侧产生不一致的手感；完成阈值判定分散在 ArkTS 也使得"状态机唯一真源在 native"这个目标名不副实。此外 ArkTS 侧还直接做 GL 表面坐标换算（`glPx`/`glPy`，`PageFlipController.ets:73-80`）——渲染坐标系的细节泄漏到了业务/状态机层。ArkTS 应该只描述**原始手势**（起点、当前点、松手位置），不应计算时长、惯性、速度、阈值判定，也不应先于视觉完成就提交分页模型。

### 6. 已知/潜在性能问题，且现有的帧耗时统计口径并不能代表真实渐染性能

- `RenderFrame()` 内嵌的逐帧耗时统计（`gl_flip_engine.cpp:648-680`）统计的是**两次 `OnSoloistFrame` 回调之间的 CPU 时间间隔**，不是 GPU 实际渲染耗时、也不是端到端掉帧率——这只能反映"soloist 有没有按预期节奏被调度"，不能证明 fragment shader 本身在目标设备上的真实开销，需要在重构后补充口径更明确的量化指标（见"验收标准 · 性能"）。
- Fragment shader 每像素多次 `texture()` + `acos()` + `pow()` + `exp()`（`gl_flip_shaders.h:121,140,143,153,160,166,171,174,183,190-194`），在高分辨率平板 XComponent 上尚**未做真机验证**；
- 该逐帧统计逻辑（静态数组 + 每 256 帧排序一次）与渲染热路径写在同一函数体内，无法独立开关，也无法在 release 构建中零成本剔除；
- 纹理上传路径：`PixelMap.readPixelsToBuffer` 全量像素回读 + UI 线程临时 `eglMakeCurrent` 切换（`GlFlipEngine.ets:96-132`、`gl_flip_engine.cpp:308-357`），没有分块/流式上传或 mipmap 策略；
- 没有针对大尺寸（平板）surface 的卷曲区域降采样/自适应分辨率策略；
- 每次 `SetTouch` 在 UI 线程写、`RenderFrame` 在 soloist 线程读，仅用一把 `mutex` 做快照复制（`gl_flip_engine.cpp:696-743`），高频拖拽场景下锁竞争与快照拷贝的开销未做基准测量。

### 7. 没有为未来 Vulkan 预留抽象层（但也不应本次就做完整 RHI 抽象）

`InitEGL` / `BuildShaders` / `RenderFrame` 里 EGL 上下文管理调用和 GLES draw call 直接混写在业务方法内部，完全没有后端抽象。按当前结构，未来接入 Vulkan 后端的改造量会比"新增一个后端实现"大得多，但这只是一个需要预留接口余量的问题，不代表本次就要交付完整的多后端 RHI（过度设计本身也是一种风险）。

### 8. 相对本次目标的能力缺口

- 没有独立的 Cone Page Curl 几何模型（只有圆柱 + 楔形裁剪近似），且现有代码/文档均未给出严谨的锥面参数化定义；
- 没有 Cylinder/Cone 混合模式所需的可插值几何维度；
- Shader 是"全效果一把梭"的单一组合；
- 跟手滤波只有一阶低通（系数硬编码 0.5，`gl_flip_engine.cpp:412-421`），没有可配置的弹簧-阻尼跟手参数化；
- ArkTS→Native 之间没有统一的 canonical 坐标系契约文档，Cone 模型对锚点/方向高度敏感，缺少这份契约会直接导致左右书脊镜像错误或方向错误。

### 9. `peekPage`/`turnPage` 之间存在真实的并发竞态窗口，且现状机制无法覆盖

经代码调研确认（非推测）：`peekPage(direction)` 与 `turnPage(direction)`（真正实现在 `ohrengine-ui-render/src/main/ets/core/PageManager.ets:177-212`）分别独立读取可变的 `currentGlobalPage`/`pageSlots.length`，两次调用之间没有任何快照或锁。`PageFlipController.animateTurnPage()` 在两次 `await`（`captureFromPageSnapshot`/`captureBottomLayer`，`PageFlipController.ets:251,257`）期间，若发生窗口尺寸变化（`entry/src/main/ets/pages/Index.ets:63-78` → `recompileCss` → `PageManager.reflowFromCurrentPage()`，`PageManager.ets:805-822`）、字体/排版参数变化，或异步章节排版完成（`PipelineManager.processNextInQueue()` 触发的 `rebuildPageSlots()`），`pageSlots` 会被整体替换为新数组，原本合法的 `peekPage` 结果可能变得越界，导致后续 `turnPage()`（`PageFlipController.ets:273`）返回 `false`。现状 `gestureSerial` 机制（`PageFlipController.ets:37`）**完全不检查**上述引擎侧重排路径，无法防护这一竞态；`animateTurnPage()` 遇到此失败时也只是静默复位，没有向用户呈现任何过渡。

### 10. `PageFlipController` 内的松手惯性速度存在单位不一致 bug

`touchVelX`/`touchVelY` 是用 `onTouchMove` 收到的**内容 vp 坐标**差值除以时间差计算的（`PageFlipController.ets:192-201`），但随后未经密度换算就直接作为 `velX`/`velY` 传给 native（`PageFlipController.ets:210-211`），而 native 侧的接口文档与实现明确把该参数当作 **Surface px/ms** 使用（`gl_flip_engine.h:43`；惯性预估公式 `animToX = touchX + velX_ * 250.0f`，`gl_flip_engine.cpp:382`，其中 `touchX` 已经是 px）。这意味着在高密度设备上，惯性预估的预判距离被系统性缩小了约 `density` 倍。`[v3]` 本版不再仅"修复该 bug"，而是从架构上**把速度计算完全移到 native**（见"重构要求 0.6/0.14"），使这一类单位不一致问题不再可能出现（ArkTS 不再计算、也不再传递速度）。

---

# Implementation Requirements

本次任务的**前置条件**是先按下面第 0 节锁定的架构决策，把现有代码整理为后续的模块边界。新增能力（Cone/混合）必须落在新的分层上，不允许继续往 `GlFlipEngine`/`gl_flip_shaders.h` 里堆料；也不允许在实现阶段绕开或重新讨论第 0 节已锁定的决策——如确有必要变更，须先修订本文档并重新评审。

## 0. 关键架构决策（先于拆分与编码，本版已按评审意见修订）

### 0.1 Geometry / Renderer / Shader 的边界如何同时成立

裁定：

- **Geometry 层（CPU，每帧一次，非逐像素）** 的职责是：根据当前模型选择（Cylinder/Cone/Hybrid）与手势状态，计算出一组**曲率场描述参数**——包括但不限于：模型混合权重 `blendFactor∈[0,1]`、canonical 坐标系下的锥心/锥轴/圆柱轴锚点、有效半径、母线长度上限、纸背/褶皱相关的强度系数等。这组参数量级是"几十个 float"，通过 uniform（或后续可选的 UBO）传给 GPU，符合"CPU 每帧只更新少量参数"的目标。
- **Shader 侧保留统一的、与模型无关的隐式曲率场求值函数**（`curl_field` 数学库）：对每个像素，用 Geometry 传入的参数在 GPU 上逐像素求出 theta/位移/源 UV/合成权重。也就是说，**求值公式（cylinder 反解、cone 反解、blend 插值）本身仍然逐像素跑在 GPU 上**，Geometry 层不预计算逐像素结果。
- 因此："Renderer 不含卷曲数学"specifically 指 **`core/`、`engine/` 目录下的渲染编排代码**（EGL/绘制调用、uniform 灌入、draw call）不允许内嵌曲率公式；而 `curl_field` 数学库本身允许同时存在两份**互为镜像**的实现：一份 GLSL（GPU 逐像素求值，实际渲染路径），一份 C++（用于离线单元测试/调试可视化，不参与线上渲染）。这两份实现必须共享同一份设计文档中的公式定义，且不允许 Renderer 自行调整或派生系数。
- 这样同时满足：CPU 只传少量参数（不逐像素）、Shader 仍是 GPU 逐像素驱动、Renderer 不决定曲率取值、Geometry 可脱离 EGL 做纯数值单测（测试对象是"给定手势输入应产出的曲率场参数"，不是"给定像素坐标应输出的颜色"，后者由 shader 单独用截图/离线渲染比对验证）。

### 0.2 Cylinder / Cone / Hybrid 不再对应三份独立 shader 文件

裁定：

- 只存在**一个**曲率场求值数学库（`curl_field.common.glsl.h` + 对应 C++ 镜像实现），内部同时包含圆柱反解与圆锥反解两条数学分支，由 Geometry 层传入的 `blendFactor` 和模型专属参数决定两条分支的插值权重；不允许再拆出"每个模型一个 shader program"。
- Cylinder/Cone 在 C++ 侧仍各自是独立的 `Geometry` 实现类（各自输出参数），但它们产出的参数最终汇入**同一套参数结构体契约**，交给同一个 shader 数学库使用。这是"两个独立模型可分别验证、又能被统一消费"的关键。
- **混合职责的精确划分**（`[v3]` 收紧措辞，对应评审 Warning7）：`hybrid_curl_geometry` **只**负责计算 `blendFactor` 与两个模型各自的专属参数（不做任何插值运算）；**逐像素的场插值（位移/theta/源 UV 在 Cylinder 与 Cone 两条数学分支之间的混合）完全由 `curl_field.common.glsl.h` 在 GPU 上完成**；`core/`、`engine/` 目录下的 Renderer 编排代码不参与、不感知混合逻辑，只负责把 `blendFactor` 与两组参数一并灌入 uniform。

### 0.3 Cone 几何在本文档中不给出最终公式，但必须作为独立设计交付物先行评审

裁定：

- 在 Cone Geometry 编码开始前，必须先产出一份独立的设计说明（建议落在 `docs/adr/` 或 `spec/` 下，命名如 `ADR-Cone-Curl-几何设计.md`），并完成评审。该设计说明**必须**包含：
  1. **锥心（apex）的精确定义**：固定为该页在 canonical 坐标系下的书角坐标（四角之一），而不是拖拽点本身；拖拽点只决定锥轴方向与张开角度。
  2. **锥轴方向**：从锥心指向当前拖拽点（或其在 canonical 坐标系下的等效表达）的单位向量。
  3. **母线（generatrix）参数化**：沿锥轴方向的距离如何映射为该点的局部曲率半径，给出显式函数（不是文字描述），并说明该函数在锥心处（母线长度→0）的数值稳定性处理（如设置 `epsilon` 下限，避免除零/半径为负）。
  4. **与 Cylinder 的边界连续性条件**：`blendFactor = 0` 时必须与纯 Cylinder 模型逐像素完全重合，`blendFactor = 1` 时是纯 Cone；过渡区间内一阶连续（不能有肉眼可见的斜率突变）。
  5. **背面纸张映射规则**：与现有 Cylinder 的 `backWeight`/`paperBack` 方案（`gl_flip_shaders.h:159-166`）在数学上保持一致的可展开映射，不能是另一套不相关的贴图规则。
  6. **纹理展开（unrolling）的正向/反向映射公式**：给出严格的数学表达式（源 UV = f(屏幕坐标, 锥心, 锥轴, 半径函数)），可与现有 Cylinder 的 `srcPos` 公式（`gl_flip_shaders.h:122`）对照。
- 在该设计说明评审通过之前，Cone 相关的 Geometry/Shader 代码不允许合入主干；可以有原型验证分支，但不计入本任务的正式交付范围。

### 0.4 Shader 参数统一管理的范围：只针对"视觉/模型调参项"，不要求消灭所有数值字面量

裁定：

- **必须集中管理、禁止裸写字面量**的范围收紧为：**视觉调参项**（阴影强度、高光强度、纸背渐变区间、书脊留边比例、褶皱宽度系数等）与**几何模型调参项**（角落判定阈值、半径上下限比例、混合过渡宽度等）。这些必须来自统一参数结构体/常量表（见 0.5）。
- **不受此限制**：数学恒等式中的 `0`/`1`/`PI`、归一化/单位向量运算、`clamp` 的值域边界（如 UV 必须在 `[0,1]`）等纯算法常量。
- 验收时的判定方式：审查新增/修改的 shader 代码，凡是"改这个数字会改变翻页的视觉效果或模型行为"的常量，都必须能在参数表中找到对应命名项；纯数学恒等式常量不作为审查对象。

### 0.5 `shader_params.h` 的"唯一真源"范围收紧为 native 内部；ArkTS 不直接引用该结构体

裁定：

- `shader_params.h`（及配套的模型/滤波/阻尼参数表）是 **native 内部**的唯一真源，供 C++ Renderer/Geometry/Shader（通过生成或手写同步到 GLSL 端）共同引用。
- **ArkTS 不需要、也不允许直接引用或复制这份参数表**。ArkTS 传给 native 的只能是**意图级参数**：模型选择枚举（`Cylinder`/`Cone`/`Hybrid`）、可选的混合因子提示（如果产品需要用户可调）、原始手势数据（位置、时间戳）。所有具体的视觉/物理系数取值（包括速度估算，见 0.6）完全由 native 内部决定。
- 如果未来确有需求（例如允许运营/配置远程调整视觉参数），应通过明确的、版本化的配置协议（如 JSON schema）传递"覆盖值"，而不是让 ArkTS 引用 C++ 头文件；该协议不在本次任务默认范围内，需要单独评审。

### 0.6 状态机唯一真源 = native；`beginGesture` 返回值与失败语义、速度计算归属、TSFN 生命周期统一裁定 `[v3 全面修订]`

裁定：

- **完成/回弹阈值判定 100% 归 native**：ArkTS 不再计算 `fx` 相对中线的位置来决定 completed，而是把 `releaseX/releaseY` 交给 native；native 状态机内部判定进入 `SettlingToComplete` 还是 `SettlingToRebound`，并通过回调把判定结果告知 ArkTS。
- **速度计算归属 native**（对应评审 Warning2）：ArkTS 不再自行计算 `velX`/`velY`。`updateGesture` 除位置外必须携带**时间戳**（`timestampMs`，两端约定统一使用同一种单调时钟源，避免受系统时间调整影响）；native 内部维护最近若干帧的位置-时间样本环形缓冲，在 `endGesture` 判定阈值时基于最近样本自行估算末速度（沿用现状 native 侧低通滤波逻辑，迁移至 `animation/spring_damper.h`）。`endGesture` **不再携带** `velX`/`velY` 参数，这从架构上消除了问题 10 描述的单位不一致风险类别。
- **分页模型提交延后到动画真正完成之后**（详见"实现要求 6"）：ArkTS 不再在动画开始前调用 `engine.turnPage()`；只有当 native 的完成回调（含兜底超时）真正触发、且 GL 表面已清空后，ArkTS 才提交分页模型并刷新 `Canvas`。这从根本上消除"模型已翻页但画面未完成"的竞态。
- **`beginGesture` 返回值统一为结构化结果**（对应评审 Critical1，取代 v1/v2 中"返回 `void`"的表述）：

  ```ts
  const enum GestureFailureReason { NONE = 0, TSFN_UNAVAILABLE = 1, OPERATION_IN_PROGRESS = 2 }

  interface BeginGestureResult {
    operationToken: number;   // 有效范围 [1, 2^31-1] 的进程内单调递增整数；失败时恒为 0（0 是保留的"无效 token"值）
    success: boolean;
    failureReason: GestureFailureReason;
  }

  // 意图级 API，native 内部持有状态机、自行计算时长/惯性/阈值判定
  beginGesture(direction: TurnDirection, spine: 'left' | 'right',
               downX: number, downY: number, model: CurlModel,
               synthetic?: boolean): BeginGestureResult;
  updateGesture(token: number, touchX: number, touchY: number, timestampMs: number): void;
  endGesture(token: number, releaseX: number, releaseY: number): void;
  cancelGesture(token: number): void;
  ```

  - `direction` 必须作为显式参数传入（对应 0.9），且在 `beginGesture` 时一次性确定，生命周期内不可变；`updateGesture`/`endGesture` 不携带 `direction`，native 不重新推导或允许其翻转。
  - 失败（`success=false`）时 `operationToken` 恒为 `0`；ArkTS 不得对失败结果调用后续任何带 token 的 API，须走既有"GL 不可用"防御路径（`failureReason=TSFN_UNAVAILABLE`）或直接放弃本次手势（`failureReason=OPERATION_IN_PROGRESS`，理论上不应发生，出现即为 bug，需记录日志）。
  - `updateGesture`/`endGesture`/`cancelGesture` 均以 `token` 作为第一个参数；native 发出的完成回调同样以 `token` 作为首个字段，双向校验规则见 0.13。
  - **TSFN 生命周期**（对应评审 Warning1）：TSFN 通道在 native context 随 `XComponent` Surface 创建时（`OnSurfaceCreated`）一次性建立，与单次手势生命周期无关，**不在 `beginGesture` 内创建**；`beginGesture` 只检查该常驻 TSFN 是否处于可用状态（非空且未被 `OnSurfaceDestroyed` 释放）。Surface 销毁时释放 TSFN，之后任何 `beginGesture` 必须返回 `failureReason=TSFN_UNAVAILABLE`。
  - native 通过该常驻 TSFN 发出携带 `token`、`result`（`completed(direction)` / `rebound`）的完成回调；ArkTS 收到回调后的处理顺序见"实现要求 6"。

### 0.7 Vulkan：降级为接口预留，不作为本次验收项

裁定：

- 本次只要求 `core/render_backend.h` 的**接口签名**不直接把 `EGLContext`/`GLuint` 等 GLES 专属类型暴露到调用方（`engine/` 编排层只通过抽象接口调用，不感知具体是 GLES 还是别的后端），作为未来扩展的**接口余量**。
- **不要求**本次实现、验证或部分实现 Vulkan 后端；**不作为本次的验收项**（"验收标准"中不包含任何 Vulkan 相关检查项）。
- Geometry/Shader 参数契约避免把 GLSL 特有语法细节（如 `sampler2D` 类型）泄漏到 C++ 参数结构体定义中即可，不需要为此额外设计跨语言 shader 生成体系。

### 0.8 坐标系契约：Cone 编码前必须先锁定

裁定：在 Cone Geometry 编码开始前（可与 0.3 的设计说明合并），必须先产出并评审一份坐标系契约，至少包含：

- Geometry/Shader 内部统一使用的 **canonical 坐标系**定义：原点位置、X/Y 轴方向、书脊固定在哪一侧；
- 左/右书脊（`spine: left/right`）的镜像规则：镜像操作只允许发生**一次**，且只在 ArkTS→Native 边界或 Renderer 入口处（与现状 `mirrorSpine` 的语义一致，`gl_flip_shaders.h:52-63`），Geometry 内部数学一律基于 canonical 坐标系，不再感知 spine；
- 页面四个角点在 canonical 坐标系下的固定表达式（Cone 锥心取值直接来自这份契约）。

### 0.9 方向（direction）的归属与显式推导规则 `[v3：补充坐标空间标注]`

`direction`（翻页方向，FORWARD/BACKWARD）本质上是**分页域决策**——ArkTS 必须在调用 `beginGesture` **之前**就已经确定 direction，因为它要用 direction 去 `engine.peekPage(direction)` 拿到目标页并渲染/上传纹理，而这一步发生在通知 native 开始手势之前。因此 direction 不能像时长/惯性/阈值那样完全交给 native 计算，但必须收敛为**唯一一处、显式的推导规则**，不允许分散实现或临场发挥：

- **推导公式**（收敛自现状 `PageFlipController.startCurlDrag()` 的方向判定逻辑，`PageFlipController.ets:316-320`，提炼为单一可测试的纯函数 `deriveFlipDirection(downX, downY, touchX, touchY, spine, contentW): TurnDirection`）：

  ```ts
  forwardSign = spine === 'right' ? 1 : -1
  dx = touchX - downX
  dy = touchY - downY
  direction =
    |dx| > |dy| * 0.35
      ? (dx * forwardSign > 0 ? FORWARD : BACKWARD)          // 横向位移主导：跟随拖拽方向
      : ((downX - contentW / 2) * forwardSign > 0 ? FORWARD : BACKWARD)  // 纵向位移主导：按按下点所在半区推断
  ```

  点击式翻页（`ReaderGestureController` 的边缘点击/滑动判定，`ReaderGestureController.ets` 中 `dx < -60`/`cx < contentWidth*0.25` 等分支）与拖拽式翻页必须调用**同一个**推导函数或显式传入等价的 direction 值，不允许两条路径各自维护一份方向判断代码。
- **不可变性（轴锁定语义）**：direction 在 `beginGesture` 时确定后，在整个手势生命周期内（`Dragging` → `SettlingToComplete`/`SettlingToRebound`）**不可更改**——对应现状注释"T040：拖动中不更新 down_，卷曲轴保持锁定"（`gl_flip_engine.cpp:375-378`）。`updateGesture`/`endGesture` 不携带 direction 参数，native 也不重新推导或允许其翻转。
- **点击式翻页（无手势起点）**：`animateTurnPage(direction)` 视为一种"合成手势"（synthetic gesture）：`down = touch = ` 起始边缘点（沿用现状 `PageFlipController.ets:282-288` 的 `startX`/`contentW` 计算），direction 由调用方显式传入，不经过上面的几何推导公式，但同样统一走 `beginGesture(direction, spine, downX, downY, model, synthetic:true)` 入口，复用同一套状态机与提交屏障（见 0.11），不允许保留一条独立于状态机之外的"直接调用动画插值"旁路。
- **坐标空间标注**（对应评审 Warning6）：本节推导公式所用的 `downX/downY/touchX/touchY/contentW` 均为**内容坐标系（vp，未经 0.14 的 Surface px 换算）**，与 `beginGesture`/`updateGesture`/`endGesture` 使用的 Surface px 坐标是两个独立的坐标空间。ArkTS 必须先在内容坐标系下完成方向推导，再按 0.14 换算为 Surface px 后传给新 API；代码中两类坐标不得共用未标注单位的变量名（建议统一使用 `xVp`/`yVp` 与 `xPx`/`yPx` 的命名后缀区分）。

### 0.10 状态转移表（native 状态机，唯一权威描述）`[v3：新增 ReboundRecovery 状态、修订超时语义、补充返回值]`

下表是 `animation/flip_state_machine.h` 必须实现的完整状态转移表，覆盖正常路径与异常路径；ArkTS 侧不得实现与此表不一致的另一份状态推断逻辑。

| 当前状态 | 触发事件 | 前置条件（Guard） | 动作 | 下一状态 |
|---|---|---|---|---|
| `Idle` | `beginGesture(direction, spine, down, model)` | 无其他活跃 `operationToken`；常驻 TSFN 通道可用（0.6） | 分配新 `operationToken`（≥1）；记录 direction/spine/model；渲染首帧；返回 `{success:true, operationToken, failureReason:NONE}` | `Dragging` |
| `Idle` | `beginGesture(...)` | 常驻 TSFN 通道不可用 | 同步返回 `{success:false, operationToken:0, failureReason:TSFN_UNAVAILABLE}`，不产生任何状态/资源变化 | `Idle`（不变） |
| 非 `Idle` 状态 | `beginGesture(...)` | 已有其他活跃 `operationToken` | 同步返回 `{success:false, operationToken:0, failureReason:OPERATION_IN_PROGRESS}` | 不变 |
| `Dragging` | `updateGesture(token, x, y, timestampMs)` | `token` 匹配当前活跃 token | 记录位置-时间样本；更新曲率场参数并逐帧渲染 | `Dragging`（不变） |
| `Dragging`/任意状态 | `updateGesture(旧token, ...)` | `token` 不匹配 | 丢弃，记录日志 | 不变 |
| `Dragging` | `endGesture(token, releaseX, releaseY)` | `token` 匹配；native 基于样本估算末速度，按 release 位置/速度判定越过完成阈值 | 登记纹理事务（0.12/0.13）；记录 `pendingResult = completed(direction)`，开始收尾插值 | `SettlingToComplete` |
| `Dragging` | `endGesture(token, ...)` | `token` 匹配；内部判定未越过阈值 | 登记纹理事务；记录 `pendingResult = rebound`，开始收尾插值 | `SettlingToRebound` |
| `Dragging` | `cancelGesture(token)` | `token` 匹配 | 立即执行 B1（清屏，见 0.11）；不登记纹理事务（无需回弹补救） | `Cancelling` → `Idle` |
| `SettlingToComplete`/`SettlingToRebound` | 帧回调，`t < 1` | — | 渐进渲染收尾插值帧 | 不变 |
| `SettlingToComplete`/`SettlingToRebound` | 帧回调，`t >= 1` | — | 渲染 Terminal Frame（B0）→ 执行 B1 → 纹理事务转入 pending-commit 保留期（0.12）→ 触发携带 `token` 的完成回调，回调内容 = `pendingResult` | `Idle`（`pendingResult` 与纹理事务保留供 ArkTS 消费） |
| `SettlingToComplete`/`SettlingToRebound` | 900ms 超时：进入该状态后 900ms 内帧回调链路未推进到 `t>=1`（`[v3]` 删除"完成回调已发出但未被确认消费"这一模糊条件，理由见下方说明） | — | 强制执行 B1；纹理事务转入保留期；`pendingResult` 降级为 `rebound`（见 0.12"兜底超时语义"） | `Idle` |
| `Idle`（存在保留期内的纹理事务） | `beginReboundRecovery(prevToken, direction)` | `prevToken` 对应纹理事务仍在保留期内；当前无其他活跃 token | 分配新 `operationToken`；复用纹理事务（不重新截图/上传）；渲染首帧 | `ReboundRecovery` |
| `ReboundRecovery` | 帧回调，`t < 1` | — | 渐进渲染回弹插值帧 | 不变 |
| `ReboundRecovery` | 帧回调，`t >= 1` | — | 渲染 Terminal Frame（原始页态）→ 执行 B1 → 释放纹理事务 → 触发完成回调，`pendingResult = rebound` | `Idle` |
| `ReboundRecovery` | 900ms 超时 | — | 强制 B1 + 释放纹理事务，`pendingResult = rebound` | `Idle` |
| 任意状态 | 收到 `token` 不匹配的完成回调（迟到回调） | — | 丢弃，不触发任何 ArkTS 侧模型/画面变更 | 不变 |

**关于删除"完成回调已发出但未被确认消费"这一超时触发条件的说明**（对应评审 Critical2）：v2 版本试图用该条件覆盖"TSFN 调度延迟导致回调迟迟未被 ArkTS 处理"的场景，但 ArkTS→Native 之间并不存在、也不需要新增一个"确认消费"的握手 API——状态机在 B1 完成、回调发出的同一时刻已经切换为 `Idle`，900ms 定时器在进入 `Idle` 时必须被显式取消（不存在"回调已发出但状态机仍在等待确认"的悬挂计时器）。因此该条件在设计上不成立，本版直接删除，只保留"未能在 900ms 内推进到 `t>=1`"这一条唯一、可判定的超时条件。

**互斥约束**：状态机同一时刻只允许一个活跃 `operationToken`（覆盖 `Dragging`/`SettlingToComplete`/`SettlingToRebound`/`Cancelling`/`ReboundRecovery` 五种非 `Idle` 状态）；处于上述状态时调用 `beginGesture` 必须直接失败（`OPERATION_IN_PROGRESS`），不允许打断当前操作。ArkTS 侧必须等到收到当前 token 的最终回调（或调用 `cancelGesture` 并确认其生效）才能发起下一个 `beginGesture`。

### 0.11 提交屏障（GL 终帧 → 清屏 → 分页提交 → Canvas 刷新的强制顺序）`[v3：裁定 B1→B3 空窗期]`

**Terminal Frame 不变量（B0）**：状态机进入 `t >= 1.0` 时，**必须先渲染一次终帧**，其合成结果需与目标静态状态（`SettlingToComplete` → 完全展开的目标页；`SettlingToRebound` → 完全收起的原始页）逐像素一致或视觉不可区分，然后才允许清屏。现状实现在 `t>=1` 时直接跳过渲染、硬切到透明清屏（`gl_flip_engine.cpp:642-647` 与 `:781-786`），存在潜在的"半卷曲画面→透明"跳变风险，重构后必须消除。

**屏障顺序**（Completed 路径，四道屏障必须严格按序发生，且每道屏障对下一道构成前置条件）：

1. **B0 终帧渲染**：native 渲染 Terminal Frame。
2. **B1 GL 已清屏（GL Cleared）**：native 执行 `glClear`（透明）→ `eglSwapBuffers` → 释放 EGL current → 状态机切换为 `Idle`，`pendingResult` 与纹理事务挂起。**B1 完成之前不允许触发任何完成回调**。
3. **B2 分页已提交（Pagination Committed）**：ArkTS 收到携带 token 的完成回调后，先完成 `pageGeneration` 重新校验（见 0.13），通过后才调用 `engine.turnPage(direction)`。校验失败或 `turnPage()` 返回 `false` 时**不得**继续到 B3，转入 0.12 描述的补救路径。
4. **B3 Canvas 已刷新（Canvas Refreshed）**：B2 成功后调用 `refreshPage()` 重绘 `Canvas`。

**Rebound/Cancel 路径**：只需 B0+B1（渲染终帧并清屏，暴露 `Canvas` 上从未改变过的原始页面），不需要 B2/B3。

**B1→B3 空窗期的可见性裁定**（对应评审 Critical4，新增）：B1 完成后 GL 表面透明，此时 `Canvas` 展示的是**当前（旧）页面内容**——这是预期状态，不是缺陷：因为此刻分页模型确实还未提交（B2 尚未发生），Canvas 展示"翻页前的真实状态"在语义上是正确的，不存在"必须让 Canvas 提前展示目标页"的合理替代方案（那样会违反 0.6"提交延后到视觉完成之后"的裁定）。因此本版明确裁定：**接受最多一帧性能预算内的旧内容展示**，其时长纳入"性能要求"的量化指标（Commit Barrier，目标 ≤1 帧预算）；超出该预算视为不达标，需在性能报告中说明原因并给出优化方案（如 0.13 的 `pageGeneration` 重新校验耗时、`turnPage()` 内部同步排版计算耗时占比）。

**约束**：

- B1 必须先于 B2，B2 必须先于 B3；B1→B3 全程 GL 表面保持透明，中间不允许有第二次卷曲绘制。
- B1→B3 的端到端延迟必须纳入"性能要求"的量化指标（Commit Barrier 延迟）。
- 根据 0.10 的互斥约束，B1→B3 完成（或 0.12 补救路径完成）之前，状态机不接受新的 `beginGesture`（但接受 0.12 定义的 `beginReboundRecovery`，因为它本身就是补救路径的一部分）。

### 0.12 TSFN 丢失、`turnPage()` 失败、迟到回调的最终语义，以及纹理事务与合成回弹的完整闭环 `[v3 全面修订]`

**TSFN 通道不可用**：`beginGesture` 必须同步返回 `failureReason=TSFN_UNAVAILABLE`，不进入 `Dragging` 状态（0.6/0.10 已定义）。ArkTS 视为"GL 翻页当前不可用"，走既有的"GL 不可用拒绝翻页"防御路径，不允许静默挂起或退化为无提示的卡死状态。

**纹理事务（TextureTransaction）**（对应评审 Critical3，新增机制）：

- 每次 `beginGesture` 成功进入 `Dragging` 时，ArkTS 已完成的 `fromPage`/`toPage` 纹理上传（`captureFromPageSnapshot`/`captureBottomLayer`）在 native 侧以该操作的 `operationToken` 为 key 登记为一份"纹理事务"，内容包括：两张已上传纹理的 handle、`direction`、`pageGeneration` 快照（供 0.13 复用）。
- 进入 `SettlingToComplete`/`SettlingToRebound` 并完成 B1 后，纹理事务**不立即释放**，而是转入"pending-commit"保留期（默认 900ms，与兜底超时同量级），期间纹理继续驻留显存，供可能发生的补救回弹复用（避免重新截图/上传）。
- ArkTS 在完成 token/`pageGeneration` 校验并确定最终结果后（成功提交 `turnPage()`+`refreshPage()`，或结果本来就是 `rebound`），必须显式调用 `releaseTextureTransaction(token)` 通知 native 释放；保留期超时未被释放也会被 native 自动清理，避免显存泄漏。

**兜底超时触发时的语义**：900ms 超时触发 = 视为"视觉收尾未能在预算内自行完成"，无论原本处于 `SettlingToComplete` 还是 `SettlingToRebound`，统一执行 B1 强制清屏、纹理事务转入保留期，`pendingResult` **降级为 `rebound`**（不是 `completed`）。核心原则：**完成必须被明确证实，否则不提交分页模型**。

**`turnPage()` 失败的语义与合成回弹补救闭环**（对应评审 Critical3 + Warning4）：

- 补救规则：ArkTS 检测到 B2 失败（`pageGeneration` 校验未通过，见 0.13，或 `turnPage()` 直接返回 `false`）后，调用专用 API（不复用通用 `beginGesture`，避免与常规手势入口混淆）：

  ```ts
  beginReboundRecovery(prevToken: number, direction: TurnDirection): BeginGestureResult;
  ```

  - 前置条件：`prevToken` 对应的纹理事务仍在保留期内且未释放；当前无其他活跃 `operationToken`（对应 0.10 新增的 `ReboundRecovery` 状态）。
  - native 直接复用纹理事务中的纹理（不重新截图/上传），以"目标页完成态"为起点、原始页态为终点播放一次收尾插值，结束后执行 B1、释放纹理事务，`pendingResult` 恒为 `rebound`，不提交模型（模型本就未变）。
  - **最多尝试一次**（对应评审 Warning4）：若 `beginReboundRecovery` 本身失败（纹理事务已被清理/保留期已过期/状态机非 `Idle`），ArkTS **不得**递归重试或再次调用 `beginReboundRecovery`；必须立即执行最终兜底——请求 native 强制清屏（若纹理事务已不存在则为空操作）、调用 `refreshPage()` 用 `engine.getCurrentPage()` 的当前实际内容刷新 `Canvas`（不依赖任何缓存纹理），状态回到 `Idle`。该兜底路径不播放过渡动画（已无可用于动画的纹理来源），但保证模型与画面最终一致，不产生递归补救。
  - 该补救路径与最终兜底必须在"验收标准"中分别单独测试。

**迟到回调（Stale Callback）语义**：见 0.10 状态表最后一行与 0.13 的 `operationToken` 机制——任何 `token` 不匹配当前活跃操作的回调，双向一律丢弃，不产生任何模型/画面副作用。

### 0.13 操作 Token、纹理事务与页-生成（`pageGeneration`）机制 `[v3：新增独立计数器]`

**操作 Token（`operationToken`）**：

- 由 native 状态机在 `beginGesture` 成功进入 `Dragging` 时生成（进程内单调递增整数，范围 `[1, 2^31-1]`），作为返回值传给 ArkTS；`0` 是保留的"无效 token"值，不允许作为合法 token 出现在任何 API 调用或回调中。
- ArkTS 后续所有 `updateGesture`/`endGesture`/`cancelGesture`/`beginReboundRecovery`/`releaseTextureTransaction` 调用、以及 native 发出的完成回调，都必须携带该 token（作为首个参数/字段）。
- **双向校验**（缺一不可）：native 校验 ArkTS 传入的 token 是否为当前活跃 token；ArkTS 校验回调携带的 token 是否为自己记录的"当前手势" token（防止 native 一次迟到的完成回调污染已被新手势覆盖的状态——`EndAnimation()` 调用 `OH_DisplaySoloist_Stop` 后，一次已排队的 `napi_call_threadsafe_function` 不保证被同步撤回，是真实存在的风险）。
- 该机制直接取代/收编现状 ArkTS 侧局部的 `gestureSerial` 字段——`operationToken` 覆盖范围更广（跨 ArkTS/Native 边界，覆盖手势与合成动画），`gestureSerial` 退化为 `operationToken` 在 ArkTS 侧的本地缓存/别名，不再独立维护。

**页-生成（`pageGeneration`）**（`[v3]` 对应评审 Warning3，不再复用 `PageSlot.epoch`）：

- 现状 `PageSlot.epoch`（定义于 `ohrengine-common/src/main/ets/types/EngineTypes.ets:14-22`）其值来自 `OhEngineCore.epoch`，**仅**在每次 `updateReadingPosition()` 时递增，语义是"阅读进度/内容版本"，**不覆盖** `reflowFromCurrentPage`/`rebuildPageSlots` 等布局重排入口，不能满足"检测页面槽位是否发生过重排"的需求，故不再作为本机制的校验依据。
- 新增一个**独立**的 `pageGeneration` 计数器（`PageManager` 内维护，进程内单调递增整数，与 `epoch` 语义完全分离），**递增点必须覆盖以下所有会替换/修改 `pageSlots` 内容或布局结果的入口**（逐一列出，作为代码审查检查项）：
  1. `rebuildPageSlots()`
  2. `reflowFromCurrentPage()`
  3. `relayoutAllChapters()`（字号变化触发）
  4. `relayoutCurrentPageOnly()`（`setLayoutProfile` 触发）
  5. `recompileCss()` 触发的 reflow
  6. `PipelineManager.processNextInQueue()` 中异步完成的 `rebuildPageSlots()`
  - 任何新增的、会替换/修改 `pageSlots` 内容的入口都必须同步递增该计数器；代码审查需给出一份"递增点清单 vs 实际实现清单"的对照表。
- `beginGesture` 前（ArkTS 内部准备阶段），快照当前 `pageGeneration` 值，随 `operationToken` 一并持有；B2（提交分页模型）之前，重新读取当前 `pageGeneration` 与快照比较：
  - **不一致** → 判定"页-生成已变化"，本次提交视为失效，**不**调用 `turnPage()`，直接走 0.12 的合成回弹补救路径。
  - **一致** → 才继续调用 `turnPage()`。
- 该规则堵住了现状 `gestureSerial` 完全未覆盖的竞态窗口，是"分页模型提交时机验证"这一验收项能够被正确实现的前提。

### 0.14 坐标单位契约（补充 0.8：0.8 定义坐标系原点/方向，本节定义单位换算链路）`[v3：速度改由 native 计算]`

| 层 | 坐标空间 | 单位 | 是否含 `margins` | 是否含 `avoidArea` | 转换点 |
|---|---|---|---|---|---|
| `ReaderGestureController`（原始触摸事件） | 窗口坐标 | px（系统触摸事件原始值） | 否 | 否 | 事件入口 |
| `ReaderGestureController`（转换后，传给 `PageFlipController`） | 内容坐标（content） | **vp**，已减去 `margins.left/top` 并 clamp 到内容区 | 否（已减去） | 否 | `ReaderGestureController.ets:73-84` |
| `PageFlipController` 公开方法参数（`onTouchDown/Move/Up`） | 内容坐标 | vp | 否 | 否 | 同上直传 |
| `PageFlipController.glPx/glPy`（ArkTS→Native 边界，唯一换算点，对应 0.8 的"唯一镜像/换算入口"） | Surface 坐标 | px（= vp × density），加回 `margins` 与 `avoidAreaTopVp` | 是（加回） | 是（加回） | `PageFlipController.ets:73-80` |
| Native（Geometry/Shader canonical，见 0.8） | Surface px → canonical（spine 镜像后） | px | 已并入 | 已并入 | native 内部 |

- 新 API（`beginGesture`/`updateGesture`/`endGesture`）的所有位置参数**必须是换算后的 Surface 坐标系 px**（即 `glPx`/`glPy` 之后的值），不允许传 vp 或内容坐标。
- **速度不再由 ArkTS 计算或传递**（`[v3]` 对应评审 Warning2，取代 v1/v2"速度参数单位为 px/ms"的表述）：`updateGesture` 传入的位置本身已经是 Surface px（经 `glPx`/`glPy` 换算），native 在收到带时间戳的位置序列后，内部按 Surface px/ms 自行估算末速度。由于 ArkTS 从不计算速度，问题 10 描述的"内容 vp 差值当作 Surface px/ms 使用"这一类单位不一致风险从架构上被消除——**验证方式相应调整为**：验证 `glPx`/`glPy` 换算本身在不同 `density` 下的正确性（同一物理位移，`density` 越高换算出的 px 差值应等比例越大），这是该单位契约链路仍需保证正确的唯一环节。

## 1. C++（`ohrengine-gl/src/main/cpp/`）目标分层

```text
cpp/
  core/                      渲染后端编排，不感知"翻页"具体曲率数学（0.1/0.7）
    render_backend.h          抽象接口（Init/Resize/BeginFrame/EndFrame/Destroy 等，不直接暴露 GLES 类型到签名）
    gles_render_backend.cpp/h 当前 EGL+GLES3 实现（从 gl_flip_engine.cpp 拆出）
  geometry/                  纯几何/数学，禁止出现任何 GL* / EGL* 调用（0.1）
    curl_geometry.h            CurlGeometryModel 抽象接口：输入手势状态，输出统一曲率场参数结构体
    cylinder_curl_geometry.*    Cylinder 模型：产出圆柱专属参数（半径、轴、带宽）
    cone_curl_geometry.*        Cone 模型：产出锥面专属参数（锥心、锥轴、母线函数系数）——需先完成 0.3 设计评审
    hybrid_curl_geometry.*      混合：输出统一参数中的 blendFactor + 两模型参数的合并结果（不做插值运算，见 0.2）
  shader/                    Shader 源码与其参数契约
    shader_params.h            统一参数结构体/常量表（native 内部唯一真源，见 0.5；仅登记视觉/模型调参项，见 0.4）
    curl_field.common.glsl.h    唯一的曲率场求值数学库（GLSL），Cylinder/Cone/Hybrid 共用（0.2）
    composite.frag.h            合成/着色（纸背、阴影、高光）的 fragment shader 主体
  animation/                 状态机与插值/阻尼/惯性，不含 GL 调用
    flip_state_machine.h       显式枚举状态机（Idle/Dragging/SettlingComplete/SettlingRebound/Cancelling/ReboundRecovery），完整转移表见 0.10；
                                持有 operationToken 生成、纹理事务与双向校验（0.12/0.13）；完成/回弹阈值判定与速度估算归属见 0.6
    spring_damper.h             阻尼弹簧/低通滤波/惯性预估/速度估算（0.6），参数可配置（速度输出单位固定为 Surface px/ms，见 0.14）
  engine/
    gl_flip_engine.cpp/h        瘦身后的编排层：串联 core/geometry/shader/animation，不再自己实现任何数学
  napi/
    napi_init.cpp
```

拆分原则：

- **Geometry 层不允许出现任何 `GL*`/`EGL*` 符号**，只产出曲率场参数结构体（见 0.1）。
- **Renderer（core + engine）不允许内嵌曲率数学**，只负责把 Geometry/参数表的值灌入 uniform 并 draw。
- **Shader 中的视觉/模型调参项必须来自 `shader_params.h`**（范围界定见 0.4），算法必要的数学常量不受此限制。
- `gl_flip_engine.cpp` 拆分后应显著缩小，只保留：surface 生命周期回调转发、soloist 帧回调触发、跨线程状态快照传递、调用 `render_backend`/`geometry`/`animation`/`flip_state_machine` 模块。
- **拆分必须同步更新 `ohrengine-gl/src/main/cpp/CMakeLists.txt`**：当前 `CMakeLists.txt` 只登记了 `napi_init.cpp` 与 `gl_flip_engine.cpp` 两个源文件；新增的 `core/`、`geometry/`、`shader/`、`animation/` 目录下的所有 `.cpp` 必须加入 `add_library(ohrengine_gl SHARED ...)` 的源文件列表，且需验证 `include_directories` 覆盖新增子目录，否则构建会静默漏掉新文件。

## 2. ArkTS 侧职责收敛

- `GlFlipEngine.ets` 保持"薄封装"定位，但需要按 0.6/0.10 的新 API 形态（`beginGesture`/`updateGesture`/`endGesture`/`cancelGesture`/`beginReboundRecovery`/`releaseTextureTransaction`，均带 `operationToken` 出入参，见 0.13）重新设计，移除 `animToX`/`animToY`/`animMs`/`velX`/`velY` 等业务动画参数；新增模型选择枚举（`Cylinder`/`Cone`/`Hybrid`）的传参；所有坐标参数按 0.14 的单位契约传递（Surface px），`updateGesture` 额外携带 `timestampMs`。
- `PageFlipController.ets` 需要收敛为**只描述原始手势 + 方向决策**：起点、当前点、松手位置，以及按 0.9 的唯一公式 `deriveFlipDirection()` 推导出的 direction（这是分页域决策，不属于"物理量"，仍需 ArkTS 在调用 `beginGesture` 前算好）。当前由 ArkTS 独立计算的动画时长（`selectAnimationDuration`）、惯性预估参数、速度采样、以及完成/回弹阈值判定（`fx` vs 中线比较）**全部移除**，迁移为 native 状态机内部职责（0.6）。ArkTS 收到 native 携带 `token` 的 `completed`/`rebound` 回调后，先校验 token 匹配、再按 0.13 做 `pageGeneration` 重新校验，只在两项校验都通过且 `turnPage()` 成功时才提交分页模型（见"实现要求 6"）；任一校验失败则触发 0.12 的合成回弹补救路径。
- GL 坐标换算（`glPx`/`glPy`）保留在 ArkTS→Native 边界的转换函数中（这属于"手势输入坐标系转换"，且是 0.8/0.14 中"唯一一次镜像/换算入口"的合理位置），但不应扩展出更多渲染相关的计算逻辑；现状 `gestureSerial` 字段按 0.13 收编为 `operationToken` 的本地别名，不再独立维护校验逻辑。

## 3. 状态机统一

- 按 0.10 的状态转移表实现显式的翻页状态枚举 `Idle / Dragging / SettlingToComplete / SettlingToRebound / Cancelling / ReboundRecovery`，作为 native 动画状态机（`animation/flip_state_machine.h`）的唯一状态源，且**唯一负责完成/回弹阈值判定与速度估算**。ArkTS 侧不再维护 `flipAnimating`/`curlDragging` 之外的判定逻辑，这两个字段仅作为"是否正在与 native 交互"的轻量镜像状态，真正的判定结果以 native 携带 `operationToken` 的回调为准（0.13）。
- 900ms 完成回调超时兜底（`scheduleGlFlipFallback`）保留作为最后一道安全网，但其触发语义按 0.10/0.12 收紧为：仅当"进入 Settling 状态后 900ms 内未推进到 `t>=1`"时触发，统一执行 B1 强制清屏并把 `pendingResult` 降级为 `rebound`，绝不默认当作"翻页已完成"处理。
- 状态机需实现 0.10 定义的互斥约束：非 `Idle` 状态下拒绝新的 `beginGesture` 调用（`ReboundRecovery` 除外，它本身是从 `Idle` 触发的补救分支）。

## 4. Cylinder Page Curl（圆柱模型）

- 保留现有弧长守恒（arc-length-conserving）圆柱反向映射的核心思路（`theta = acos(s/R)`），但迁移到独立的 `cylinder_curl_geometry` 模块，输出标准化的曲率场参数（半径、轴、带宽等，符合 0.1 的参数契约），由 `curl_field.common.glsl.h` 逐像素求值消费。
- 半径 `R` 的手感调参（拖拽距离/π、阻尼弹簧收敛）保留在 `animation/spring_damper.h` 中，作为可配置项而非散落常量。

## 5. Cone Page Curl（圆锥模型）

- **前置条件**：必须先完成 0.3 要求的设计说明并通过评审，明确锥心/锥轴/母线函数/边界连续性/背面映射/展开公式，才能开始编码。
- 实现结果需体现真正的锥面收窄：仅拖拽书角时应观察到锥形收窄的褶皱（半径沿母线方向连续变化，且在锥心附近数值稳定，不出现除零/负半径/闪烁），而不是当前的硬边楔形裁剪。
- Cone 模型作为独立 `Geometry` 单元，需可脱离 EGL 做纯数值单测（验证半径场、边界条件、与设计说明公式的一致性）。

## 6. 混合模式（Cylinder ⇄ Cone Blend）

- 按 0.1/0.2 的裁定：混合发生在 **Geometry 层**（`hybrid_curl_geometry`），产出统一参数结构体中的 `blendFactor` 及合并后的模型参数；`hybrid_curl_geometry` 不做任何逐像素插值运算，Shader 侧的 `curl_field` 数学库内部根据 `blendFactor` 在圆柱/圆锥两条数学分支之间做逐像素插值，Renderer 不参与、不感知混合逻辑。
- 需要明确混合因子的默认策略（例如：拖拽起点到最近书角的归一化距离；具体映射曲线在设计说明中给出），并在 `blendFactor = 0/1` 两端与纯 Cylinder/纯 Cone 结果完全一致（0.3 第 4 条边界连续性条件）。

## 7. 手势实时跟手

- 拖拽过程中的输入坐标处理（去抖/低通/预测）集中在 `animation` 模块内，参数（滤波系数等）通过独立的动画参数配置结构体暴露，不再像现状把系数（如 `0.5`）写死在 `SetTouch`/`updateGesture` 函数体内。
- 跟手延迟目标：手指移动到卷曲响应之间的可感知延迟应不高于 1 帧（在设备刷新率下）；需要在重构后重新验证 `docs/page-curl-current-status-and-issues.md` 第 3 节记录的"异步纹理准备期间首帧从旧位置起跳"问题是否已解决，并给出结论。

## 8. 释放后的自然完成/回弹动画

- 收尾曲线延续现有临界阻尼思路（避免终点速度突变），统一在 `animation` 状态机中管理，且必须与拖拽阶段的曲率/位置保持连续（不能因为从"拖拽读数"切换到"动画插值读数"而产生跳变）。
- 完成与回弹两种收尾都必须走同一套状态机分支（`SettlingToComplete`/`SettlingToRebound`），判定逻辑与速度估算完全在 native（0.6），ArkTS 不再对 completed/rebound 两种情况分别拼接调用序列。
- **Terminal Frame 不变量（0.11）**：`t >= 1.0` 时必须先渲染一次与目标静态状态逐像素一致/视觉不可区分的终帧，再执行清屏；不允许像现状（`gl_flip_engine.cpp:642-647,781-786`）一样在 `t>=1` 时跳过渲染直接清屏。

## 9. 分页提交时机与竞态防护（对应 0.6/0.11/0.12/0.13）

- **提交策略**：native 状态机进入 `SettlingToComplete` 并开始收尾动画时，**不**立即通知 ArkTS 提交分页模型；只有当收尾动画真正结束（B0 终帧 + B1 清屏，含正常完成回调、或兜底超时后的强制清屏路径），native 才通过携带 `operationToken` 的完成回调把"本次手势的最终结果"（`completed(direction)` 或 `rebound`）一次性告知 ArkTS。
- ArkTS 收到回调后，依次执行：① 校验 `token` 匹配当前活跃操作（不匹配则丢弃，0.13）；② 校验 `pageGeneration` 与提交前重新读取的当前值一致（不一致则判定页-生成已变化，0.13）；③ 结果为 `completed` 且上述两项校验通过时才调用 `engine.turnPage(direction)`（B2）并刷新 `Canvas`（B3），随后调用 `releaseTextureTransaction(token)`；④ 结果为 `rebound`/`Cancelling`，或 ②/③ 校验失败/`turnPage()` 返回 `false`，均不提交分页模型，且后一种情况需触发 0.12 的合成回弹补救路径（`beginReboundRecovery`，最多尝试一次，失败后走最终兜底）。
- 需要同步修改现状代码中"先 `turnPage` 后播放动画"的两处调用点：`PageFlipController.animateTurnPage()`（点击翻页路径，`PageFlipController.ets:273-277`）与 `PageFlipController.releaseCurl()`（拖拽释放路径，`PageFlipController.ets:404-417`）。两处均需改为"动画完成回调触发、且 token/`pageGeneration` 校验通过后再提交"。
- 由于分页模型的变更被推迟到动画完成且校验通过之后，`Cancel`/超时兜底场景不再需要任何模型回滚；但**新增的合成回弹补救路径与最终兜底**（应对 B2 校验失败）本身需要被正确实现和测试——这是本节在验收阶段需要专门验证的场景（见"验收标准"）。

## 10. 坐标系契约与速度计算架构迁移落地（对应 0.8/0.9/0.14）

- 在 Cone 相关代码合入前，产出并评审坐标系契约文档，明确 canonical 坐标系定义（0.8）与坐标单位换算链路（0.14，含 `margins`/`avoidArea` 的处理位置、内容 vp 坐标与 Surface px 坐标的边界划分，见 0.9 坐标空间标注）、spine 镜像的唯一入口、四角点在 canonical 坐标系下的固定表达式。
- `cylinder_curl_geometry`/`cone_curl_geometry`/`hybrid_curl_geometry` 均基于该契约实现，内部不再各自处理 spine 镜像或坐标换算。
- 提炼现状 `PageFlipController.startCurlDrag()` 中的方向判定逻辑为独立、可单测的纯函数 `deriveFlipDirection()`，点击翻页与拖拽翻页统一调用该函数，不允许两条路径各自维护方向判断代码；`animateTurnPage(direction)` 改造为经由 `beginGesture(direction, ..., synthetic:true)` 统一入口。
- **速度计算完全迁移到 native**（不再是"修复 ArkTS 侧换算 bug"，而是移除 ArkTS 侧速度计算代码本身，见 0.6/0.14）：删除现状 `touchVelX`/`touchVelY` 的计算与传递代码（`PageFlipController.ets:192-201`/`:210-211`）；`endGesture` 不再携带 `velX`/`velY`。需要补充单元测试覆盖"`glPx`/`glPy` 换算在不同 `density` 下对相同物理位移应产出等比例缩放的 px 差值"这一断言（即换算链路本身正确，而不是"速度换算正确"，因为 ArkTS 已不再计算速度）。

---

# Architecture Constraints

1. **Geometry 与 Renderer 必须解耦**：Geometry 层（Cylinder/Cone/Hybrid）不得出现任何 `GL*`/`EGL*` 调用；Renderer（`core/`、`engine/`）不得内嵌曲率/展开数学公式；曲率场逐像素求值公式允许存在于 Shader（GLSL）与用于单测的 C++ 镜像实现中，但不允许存在于 Renderer 编排代码中（边界定义见 0.1）。
2. **不允许把核心渲染逻辑放入 ArkUI**：任何卷曲几何计算、shader 合成、EGL/GLES 调用都必须留在 native 层（`ohrengine-gl` 的 C++ 部分）；ArkUI/ArkTS 侧只允许出现"原始手势转发 + 意图/枚举参数编组 + XComponent 挂载"，参照现有 `GlFlipEngine.ets`/`GlFlipSurface.ets` 的职责边界，并按 0.6 移除动画物理与速度计算相关的传参。
3. **GL 是唯一翻页渲染路径**：GL 不可用时明确降级/不可用，禁止回退 2D 翻页；不允许在未评审的情况下把"GL 不可用时拒绝翻页"静默改为回退到旧的 2D/Canvas 翻页路径。
4. **不允许破坏现有分页和渲染逻辑**：`OhEngine`（`ohrengine-ui-render`）的分页模型、`PageRenderer` 的页面渲染管线、`ReaderGestureController` 的手势分发协议必须保持向后兼容；如需调整接口，须评估对 EPUB/PDF/TXT/CBZ 各 exclusive 模块的影响；不得修改 `OhEngine` 分页模型语义（`turnPage`/`peekPage`/`getCurrentPage` 等）、不得改变 `PageRenderer` 对外渲染契约，除非提交独立的兼容性评审并获得批准。
5. **状态机唯一权威在 native**：ArkTS 不得维护第二套动画物理公式或阈值判定逻辑（动画时长、惯性预估、阻尼曲线、速度估算、完成/回弹阈值判定只能有一个真源）；不得由 ArkTS 或 Native 任一方单独重新实现 `direction` 推导逻辑的第二个版本（0.9）；不允许用隐式布尔组合代替显式状态机，翻页生命周期状态必须用显式枚举表达并可查询。
6. **分页模型提交顺序是唯一合法顺序（B0→B1→B2→B3）**：不允许在动画/视觉完成之前提交分页模型变更；不允许在 `turnPage()` 提交失败时静默停留在原页面（必须按 0.12 触发合成回弹补救，失败后走一次性最终兜底，不允许递归）；不允许把 900ms 兜底超时默认当作"翻页已完成"处理（必须降级为 `rebound` 语义）。
7. **Vulkan 仅作接口预留，不作为本次验收项**：`core/render_backend.h` 的接口签名不直接暴露 GLES 专属类型即可（0.7），不要求实现、验证或部分实现 Vulkan 后端；不要求本次完成任何多后端 RHI 抽象。
8. **Cone/Hybrid 合入门禁**：不允许在没有 0.3/0.8 设计说明评审通过的情况下合入 Cone/Hybrid 相关代码到主干；不允许跳过"Scope · 分阶段实施顺序"中的 Phase A 直接开始 Phase B 的正式编码。
9. **不允许绕过 XComponent + EGL/GLES3 的既定渲染路径**：不得为了实现某个效果临时改用 ArkUI 自带的 transform/滤镜/`Canvas 2D` 绘制卷曲相关像素。

---

# Technical Constraints

1. **新手势 API 的每个调用（`beginGesture`/`updateGesture`/`endGesture`/`cancelGesture`/`beginReboundRecovery`/`releaseTextureTransaction`）及每个完成回调必须携带 `operationToken`**（见 0.13），native 与 ArkTS 双向校验 token 匹配；不匹配的调用/回调必须被丢弃，不产生状态或视觉副作用；不允许假设"native 是单例、同一时刻只有一个动画在跑"就省略校验。
2. **`beginGesture` 必须返回结构化结果**（`BeginGestureResult`，见 0.6），不允许保留"返回 `void`"的旧签名；失败时 `operationToken` 恒为 `0`，`0` 不得作为合法 token 出现在任何其他 API/回调中。
3. **纹理事务生命周期**：每个 `operationToken` 对应的纹理事务在 B1 完成后必须转入保留期（默认 900ms），供合成回弹补救复用；ArkTS 必须在确定最终结果后显式调用 `releaseTextureTransaction`，或依赖保留期超时自动清理；不允许在 B1 之后立即释放纹理（这会导致合成回弹补救无法复用纹理，见 0.12）。
4. **坐标/速度单位契约**：所有跨 ArkTS→Native 边界传递的位置参数必须严格遵循 0.14 的坐标单位契约（Surface px）；速度不再由 ArkTS 计算或传递（0.6/0.14），`endGesture` 不携带 `velX`/`velY`。
5. **视觉/模型调参项不允许继续散落为字面量**：新增/修改的视觉或模型系数（范围见"重构要求 0.4"）必须登记到统一参数结构体/常量表中；纯数学恒等式常量不受此限制，不得以此为由要求"零字面量"式的不可执行审查。
6. **`pageGeneration` 必须覆盖 0.13 列出的全部 6 个入口**：任何新增的会替换/修改 `pageSlots` 的入口都必须同步递增该计数器，代码审查需给出对照表。
7. **性能采集与渲染热路径解耦**：帧耗时统计等诊断代码必须可通过编译宏或独立采集模块开关，不得无条件常驻在 release 构建的渲染主路径中；不得把"Soloist 回调间隔"当作 GPU 渲染性能或掉帧率的证据，涉及性能结论的报告必须按"验收标准 · 性能"中的指标分类分别陈述。
8. **不允许引入第三方翻页库**：不得直接依赖或移植任何开源 page-curl/page-flip 库（包括 `docs/lib/page-curl/` 下已归档的参考代码、`docs/archive/page-curl-ref/` 下的参考实现），仅供算法设计阅读参考，不得整段搬运进产品代码。
9. **TSFN 机制**：ArkTS/Native 边界继续使用现有的 N-API + `napi_threadsafe_function`（TSFN）机制传递完成回调，通道随 Surface 生命周期常驻（0.6），不引入新的 IPC/共享内存机制，除非有明确性能证据支持。
10. **兼容现有 SDK 版本约束**（`compatibleSdkVersion 6.1.0(23)` / `targetSdkVersion 6.1.1(24)`，见 `docs/page-curl-current-status-and-issues.md` 第 6 节），不依赖更高版本才有的 API。

---

# Non Goals

1. 不引入 Skia/Vulkan 等其他图形 API 作为本次交付的主渲染路径；不要求实现、验证或部分实现 Vulkan 后端（0.7），只要求接口签名不暴露 GLES 专属类型作为未来扩展余量。
2. 不要求本次交付完整的多后端 RHI 抽象（`IRenderBackend`/`IGeometryProvider`/`IShaderProgram` 式设计）。
3. 不要求消灭 shader 代码中所有数值字面量，只要求登记"视觉/模型调参项"（范围见 0.4），数学恒等式常量不受限制。
4. 不要求 ArkTS 直接引用或复制 C++ `shader_params.h`（0.5）；不做跨语言"唯一真源"机制。
5. 不在本次任务默认范围内设计/实现"运营远程配置协议"（JSON schema 覆盖视觉参数），该协议若未来确有需要须单独评审。
6. 不在 GL 不可用时新增 2D 降级回退路径，除非产品明确要求并提交独立评审。
7. 不在本文档中给出 Cone 几何的最终数学公式，该公式必须由独立的 ADR/设计说明产出并评审通过后才能进入编码（0.3）；评审通过前 Cone/Hybrid 代码不合入主干。
8. 不修改 EPUB/PDF/TXT/CBZ 各解析器与排版管线（`layout/*`）的实现，仅验证其翻页/渲染在本次改造下不发生回归。
9. 不在本次任务中改变 PDF 桩（ENG-006）的现有行为。

---

# Acceptance Criteria

## 功能性

- [ ] Cylinder 模式：边缘/中部拖拽表现为均匀宽度的圆柱卷曲带，方向跟随手势向量，四个书角外的直边拖拽行为与现状一致或更优。
- [ ] Cone 模式：靠近书角拖拽表现为锥形收窄的卷曲（半径沿母线方向连续变化），与现有"楔形裁剪近似"相比，褶皱形态在贴近书角处应明显更贴近真实纸张锥形卷曲，且符合 0.3 评审通过的设计说明；锥心附近无数值不稳定（无闪烁/无负半径伪影）。
- [ ] 混合模式：在书角与边缘之间连续拖拽时，卷曲形态从 Cone 平滑过渡到 Cylinder（或反之），过渡过程中不出现几何断层/跳变/闪烁；`blendFactor` 取 0 与 1 时分别与纯 Cylinder、纯 Cone 结果一致。
- [ ] 拖拽全程手指与卷曲响应同步，不出现"首帧从旧位置起跳"（对照 `docs/page-curl-current-status-and-issues.md` 第 3 节记录的已知问题，需给出该问题在重构后是否复现的验证结论）。
- [ ] 松手后由 **native 状态机**正确判定"完成翻页"或"回弹"，动画曲线连续、无速度突变，且与拖拽阶段视觉连续（无跳变）；ArkTS 侧代码中不存在阈值比较逻辑，也不存在速度计算逻辑。
- [ ] **`beginGesture` 返回值验证**（0.6）：审查/单测确认 `beginGesture` 返回 `BeginGestureResult` 结构体而非 `void`；正常成功、TSFN 不可用、操作互斥三种路径均有对应单测覆盖各自的 `success`/`operationToken`/`failureReason` 组合。
- [ ] **Terminal Frame 验证（0.11）**：`t=1.0` 时渲染的终帧与目标静态页面（completed）或原始静态页面（rebound）逐像素对比无可感知差异；截图/录屏证据需随测试记录一并提交，不允许出现"半卷曲画面直接跳变为透明"的现状问题。
- [ ] **分页模型提交时机验证（0.6/0.11/0.13）**：人为制造"完成回调丢失/被取消"的场景（例如强制断开 TSFN 或注入延迟），验证分页模型**不会**在动画完成前被提交，且兜底超时触发后的最终状态（模型 + 画面）一致，不出现"模型翻页但画面未翻"或反之的情况。
- [ ] **Commit Barrier 空窗期验证（0.11）**：测量 B1→B3 端到端耗时，验证 Canvas 展示旧内容的时长控制在 1 帧预算内（或超出时报告中给出原因），确认这不是"跳变/丢帧"而是可量化、可解释的既定行为。
- [ ] **迟到回调丢弃验证（0.13）**：人为构造"旧 `operationToken` 的完成回调在新手势已开始后才到达"的场景（例如注入延迟或连续快速滑动触发新手势），验证该回调被正确丢弃，不影响当前手势的状态/画面/分页模型。
- [ ] **纹理事务与合成回弹补救路径验证（0.12/0.13）**：在收尾动画播放期间人为触发一次内容重排（如模拟窗口尺寸变化触发 `reflowFromCurrentPage()`），使得完成时的 `pageGeneration` 校验失败或 `turnPage()` 直接返回 `false`；验证系统自动调用 `beginReboundRecovery` 并复用已保留的纹理事务把 GL 曲面动画式地收回（而非硬切/重新截图/静默卡死），且最终模型与画面保持一致、无残留状态。
- [ ] **补救失败后的最终兜底验证（0.12，`[v3]` 新增）**：在纹理事务保留期已过期（或人为强制清理）的情况下触发上述补救路径，验证 `beginReboundRecovery` 失败后**不发生递归重试**，系统直接走强制清屏 + `refreshPage()` 的最终兜底，最终画面与 `engine.getCurrentPage()` 的实际内容一致。
- [ ] **TSFN 通道不可用的防御验证（0.6/0.12）**：人为构造常驻 TSFN 通道不可用场景（如模拟 Surface 销毁后调用），验证 `beginGesture` 同步返回 `failureReason=TSFN_UNAVAILABLE` 且不进入 `Dragging` 状态，ArkTS 侧正确走"GL 不可用"防御路径，不产生卡死或无提示的挂起状态。
- [ ] **方向推导单一实现验证（0.9）**：审查代码确认点击翻页与拖拽翻页调用同一个 `deriveFlipDirection()`（或点击路径显式传入等价结果），不存在第二份独立的方向判断逻辑；四角/四边混合拖拽（横向为主、纵向为主两种分支）方向判定结果与设计公式一致；确认该函数入参为内容 vp 坐标，且与传给 `beginGesture` 的 Surface px 坐标不混用（0.9 坐标空间标注）。
- [ ] **速度计算架构迁移验证（0.6/0.14）**：审查确认 ArkTS 侧不再存在任何速度计算代码（`touchVelX`/`touchVelY` 及其传递路径已删除），`endGesture` 签名不含 `velX`/`velY`；在至少两种不同 `density`（如 1x 与 3x）的设备/模拟环境下验证 `glPx`/`glPy` 换算对相同物理位移产出等比例缩放的 px 差值。
- [ ] 左右书脊（`spine: left/right`）、四角+四边共 8 种拖拽起点组合均验证通过（沿用 `docs/page-curl-current-status-and-issues.md` 第 7 节的"视觉复现记录模板"逐项记录）。
- [ ] `Cancel` 手势（如手势被系统打断）能正确回到 Idle 状态，无残留卷曲画面、无残留半透明 GL 表面覆盖静态页面，且分页模型未发生任何变更（因提交已延后，天然无需回滚）。
- [ ] GL 引擎初始化失败时，现有的"拒绝执行翻页并报错"行为保持不变（除非本任务明确产出新的降级方案）。
- [ ] **回归矩阵按 GL 可用状态拆分验证**（`[v3]` 对应评审 Warning8，不再把"卷曲模型"与"GL 初始化失败"交叉）：
  - GL 可用场景的回归矩阵：

    | 维度 | 取值范围 |
    |---|---|
    | 格式 | EPUB / PDF / TXT / CBZ |
    | 功能 | 翻页、书签、划线、搜索、目录、主题切换 |
    | 卷曲模型 | Cylinder / Cone / Hybrid |
    | 书脊 | left / right |

    至少覆盖「每种格式 × 每个功能」与「每种卷曲模型 × 左右书脊」两组组合，形成正式的回归记录文档随 PR 一并提交。
  - GL 初始化失败场景的回归矩阵（**不与卷曲模型维度交叉**，因为 GL 不可用时本就拒绝翻页，只验证防御路径本身）：

    | 维度 | 取值范围 |
    |---|---|
    | 格式 | EPUB / PDF / TXT / CBZ |
    | 功能 | 翻页（应报错/拒绝）、书签、划线、搜索、目录、主题切换（应不受影响） |

    验证"拒绝执行翻页并报错"的行为在每种格式下保持一致，非翻页功能不受 GL 状态影响。

## 架构性

- [ ] Geometry 模块（Cylinder/Cone/Hybrid）可在不初始化 EGL 的前提下被单元测试覆盖，验证曲率场参数输出的正确性（包括边界条件、0.3 中定义的连续性条件）。
- [ ] Renderer 编排代码（`core/`、`engine/`）中不出现任何卷曲几何公式；`acos`/`theta`/`srcPos` 等卷曲专用计算只允许出现在 `geometry/`（C++ 镜像实现，用于单测）与 `shader/curl_field.common.glsl.h`（GPU 实际路径）中。
- [ ] Shader 中的视觉/模型调参项（按 0.4 界定的范围）均可追溯到 `shader_params.h`；审查报告需列出所有新增的调参类常量及其登记位置，纯数学常量不计入审查范围。
- [ ] 翻页状态机在 native 侧以显式枚举实现（含 `ReboundRecovery`），其转移逻辑与 0.10 状态转移表一致，且是完成/回弹阈值判定与速度估算的唯一归属方；ArkTS 侧代码审查确认不存在动画时长/惯性预估/速度计算/阈值比较逻辑，且新的手势 API 中不包含 `animToX`/`animToY`/`animMs`/`velX`/`velY` 等参数，但包含显式的 `direction`（0.9）与双向 `operationToken`（0.13）。
- [ ] Cone 设计说明（0.3）与坐标系/单位契约（0.8/0.14）已完成评审并合入文档库，Cone/Hybrid 相关代码的 PR 描述中引用该设计说明。
- [ ] `operationToken`、纹理事务与 `pageGeneration` 三重机制存在于代码中且有对应单元测试；现状 `gestureSerial` 已被收编为 `operationToken` 的本地别名，不存在两套并行的序号机制；`pageGeneration` 的递增点清单与 0.13 列出的 6 个入口逐一对照通过。
- [ ] `GlFlipEngine`（native 单例）的职责经拆分后，单文件行数与职责数量相对当前版本（849 行 / 7 类职责）有可衡量的下降，并在 PR 描述中说明拆分前后的模块清单对比；`CMakeLists.txt` 已同步更新且构建通过。

## 性能

以下指标口径分开定义，避免用单一的"soloist 回调间隔"代表全部性能结论（现状 `RenderFrame` 内建统计仅覆盖第 4 类）。所有指标均需在**真机**（非模拟器）上验证并记录设备型号、刷新率、屏幕分辨率、HarmonyOS/DevEco 版本：

### 指标分类（共 6 类，`[v3]` 修正数量口径，对应评审 Warning5）

1. **输入到首帧提交（Input-to-first-frame）**：从手势判定进入拖拽/`beginGesture()` 调用，到 `eglSwapBuffers` 首次提交包含卷曲画面的帧，端到端延迟（对照现有 `METRIC flip first-frame` 日志埋点，`gl_flip_engine.cpp:840-846`）。
2. **CPU 帧准备耗时（CPU frame preparation）**：Geometry 层计算曲率场参数 + Renderer 灌入 uniform 所耗费的 CPU 时间，与 GPU 渲染时间分开统计。
3. **GPU 渲染耗时**：优先使用可用的 GPU 时间戳查询机制（如 `EXT_disjoint_timer_query` 或平台等价能力）测量 fragment shader 实际执行耗时；若目标设备/驱动不支持时间戳查询，需明确记录并采用替代代理指标，不得用 CPU 侧的回调间隔冒充 GPU 耗时。
4. **Soloist 回调间隔统计（现状口径）**：延用现有 P50/P95 统计方式，但明确标注这一指标衡量的是"帧调度节奏"，不是"渲染耗时"或"真实掉帧"，报告中需注明该局限性。
5. **纹理上传耗时**：单次 front+bottom 纹理上传（PixelMap 回读 + GPU 上传）耗时，延用现状日志埋点 `METRIC flip texture upload`（`gl_flip_engine.cpp:356`），CPU 回读与 GPU 上传两段分开记录。
6. **Commit Barrier 延迟（B1→B3，见 0.11）**：从 native 完成回调触发（B1 已完成）到 ArkTS 完成 `turnPage()`+`refreshPage()`（B3）的端到端耗时；这段时间内屏幕仍显示旧内容（0.11 已裁定为可接受的既定行为，但需受限于目标预算），需单独统计并给出优化前后对比（现状代码没有对应埋点，需要新增）。

### 具体性能目标

1. 输入到首帧提交延迟应控制在 1 帧预算内（对照基线给出优化前后实测数值）。
2. 拖拽跟手阶段的 soloist 回调节奏应达到设备刷新率上限；GPU 渲染耗时（或替代代理指标）需保证在目标刷新率的单帧时间预算内完成，留有余量。
3. 长距离/高速收尾不低于 90Hz 上限档位（受设备实际能力约束），短距离回弹不低于 60Hz 档位。
4. 纹理上传耗时需给出优化前后对比数据。
5. **Commit Barrier（B1→B3）延迟应控制在 1 帧预算内**，超出需在报告中说明原因（如 `pageGeneration` 重新校验、`turnPage()` 内部同步排版计算的耗时占比）——这是 0.11 裁定"接受最多一帧旧内容展示"的量化约束条件，不达标即视为该裁定的前提被违反。
6. 新增 Cone/混合模式后，若 GPU 渲染耗时相对基线（纯 Cylinder）有显著增加，需评估对中低端设备的影响，必要时提供画质分档（简化版 `curl_field` 求值，减少纹理采样次数）。
7. 内存：双缓冲纹理 ping-pong 策略在新增模型后不应引入额外的常驻大内存分配；纹理事务的保留期机制（0.12）需评估显存占用上限（同一时刻最多存在的纹理事务数 = 1，因为互斥约束保证同一时刻只有一个活跃操作）。
8. 性能采集代码（帧耗时统计等）需与渲染热路径解耦，不得无条件常驻在 release 构建的渲染主路径中造成额外开销。

---

# Test Requirements

## 单元测试（可脱离 EGL/真机）

1. **Geometry 纯数值单测**：Cylinder/Cone/Hybrid 各自的曲率场参数输出，覆盖边界条件（半径上下限、锥心 epsilon 稳定性）与 0.3 定义的连续性条件（`blendFactor=0/1` 时与纯模型逐像素一致的参数层等价性）。
2. **`deriveFlipDirection()` 纯函数单测**：覆盖横向位移主导、纵向位移主导两种分支，左右书脊镜像，与设计公式逐一核对。
3. **状态机单测**（`flip_state_machine.h`）：覆盖 0.10 完整状态转移表的每一行，包括正常路径、TSFN 不可用、操作互斥、迟到回调丢弃、900ms 超时降级、`ReboundRecovery` 的进入/完成/超时。
4. **`operationToken`/`pageGeneration`/纹理事务双向校验单测**：覆盖 token 不匹配丢弃、`pageGeneration` 变化触发补救、纹理事务保留期到期后自动清理。
5. **`glPx`/`glPy` 坐标换算单测**：验证不同 `density` 下相同物理位移换算出等比例缩放的 px 差值（取代旧的"速度单位一致性"测试，因为速度计算已移至 native）。
6. **`pageGeneration` 递增点覆盖测试**：对 0.13 列出的 6 个入口逐一编写触发测试，验证计数器确实递增。

## 集成/真机测试（需 EGL + 真机设备）

1. **Terminal Frame 像素级对比**：`t=1.0` 终帧与目标/原始静态页面的截图对比，附录到测试记录。
2. **分页模型提交时机竞态注入测试**：强制断开 TSFN、注入完成回调延迟，验证模型不早于视觉完成被提交。
3. **迟到回调注入测试**：连续快速滑动触发新手势，验证旧 token 回调被丢弃。
4. **`turnPage()` 失败与合成回弹补救注入测试**：动画播放期间模拟窗口尺寸变化触发 `reflowFromCurrentPage()`，验证 `beginReboundRecovery` 被正确调用且复用纹理事务；再模拟纹理事务保留期过期后重复该场景，验证走最终兜底且不递归重试。
5. **TSFN 不可用防御测试**：模拟 Surface 销毁后调用 `beginGesture`，验证返回 `TSFN_UNAVAILABLE` 且不产生卡死。
6. **回归矩阵测试**（按 Acceptance Criteria 中拆分的 GL 可用/不可用两张表逐项执行），形成正式回归记录文档随 PR 提交，不接受笼统的"无行为变化"结论。
7. **8 种拖拽起点组合（左右书脊 × 四角 + 四边）视觉复现记录**，沿用 `docs/page-curl-current-status-and-issues.md` 第 7 节模板逐项记录。

## 性能测试方法与矩阵

- **基线版本**：以本任务开始前的主干版本（当前 `GlFlipEngine` 实现）作为基线，在同一批设备、同一测试页面内容、同一分辨率/密度、同一系统刷新率下采集"Acceptance Criteria · 性能"中定义的 **6 类**指标（`[v3]` 修正为 6 类，对应评审 Warning5）；重构后的实现在完全相同条件下重新采集，两组数据一一对应对比，禁止跨设备/跨内容做对比。
- **设备矩阵**：至少覆盖高中低三档设备（不同 GPU/刷新率能力），每台设备明确记录支持的最高刷新率档位；性能目标（如"90Hz 上限档位不低于 90Hz"）在不支持该刷新率的设备上自动降级为"不低于该设备支持的最高档位"，不得直接判定为不达标。
- **采样方式**：每种场景（拖拽跟手 / 长距离收尾 / 短距离回弹）至少连续采样 256 帧以上，重复至少 3 次取中位数；报告需注明是否包含首次 shader 编译等冷启动开销（建议冷启动单独记录一次，不计入稳态统计）。
- **测试页面**：固定 1~2 组具有代表性的页面内容（文字密集页、图文混排页），避免因页面复杂度不同导致纹理上传/合成耗时不可比。
