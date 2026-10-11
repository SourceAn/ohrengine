# Task ID

HOS-STPAGEFLIP-001-P2 — Canvas Renderer、视觉基准比对与性能冒烟 Gate（从任务）

> 主任务：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`（A1-A9 / T1-T10 / D1-D9 以主任务为准）。
> 本阶段在 debug harness 内验证渲染；**不接 Reader，不触碰旧翻页链路（A9）**。

---

# 开始前提

- P1 验收全项达成（E1-E5），几何层单测全绿、`stpageflip_mapping.md` 验证结果列回填完毕；
- `ohrengine-pageflip` 模块可编译，core 层接口稳定。

# Objective

1. 交付 `render/FlipRenderer.ets`（Canvas 2D 渲染后端）、`render/PageContentCache.ets`、`components/PageFlipView.ets`；
2. 按 StPageFlip `CanvasRender.drawFrame` 绘制流程 1:1 映射：清屏 → 底层页（裁剪）→ 书脊中缝阴影 → 翻起页（旋转+裁剪）→ 折叠外侧阴影 → 折叠内侧阴影；顺序不得调换；
3. 交付 debug harness（20 页图片），完成主任务验收 V1 固定姿态比对；
4. **性能冒烟 Gate**：把渲染开销在 Phase 2 就量化暴露，禁止把性能风险带到 P4 才发现。

# Scope

## 新建

```text
ohrengine-pageflip/src/main/ets/render/FlipRenderer.ets
ohrengine-pageflip/src/main/ets/render/PageContentCache.ets
ohrengine-pageflip/src/main/ets/components/PageFlipView.ets
entry/src/main/ets/pages/debug/PageFlipDemoPage.ets   // 20 页图片 harness（仅 debug，ENG-012）
.verify-shots/pageflip/                               // 姿态比对截图
```

## 修改

- `ohrengine-pageflip/src/main/ets/index.ets`：导出新符号；
- debug 入口（`pages/debug/DebugBookshelf.ets` 或既有 debug 导航）：挂载 harness 入口；release 不含；
- `docs/ai/stpageflip_mapping.md`：回填绘制流程（CanvasRender/ImagePage 各函数）验证结果。

## 禁止

- 禁止修改 entry 阅读器运行代码（Index.ets / ReaderGestureController / PageRenderer / PageFlipController 一律不碰）；
- 禁止移除/降级旧翻页任何能力（A9）；
- 禁止在 harness 之外引用 PageFlipView（Reader 接线是 P4）。

# Implementation Requirements

1. **绘制 1:1（D4）**：渲染流程逐步骤映射 `CanvasRender.drawFrame/drawBookShadow/drawOuterShadow/drawInnerShadow` 与 `ImagePage.draw/simpleDraw`；阴影仅用 createLinearGradient（T4），渐变 stop 初值照抄 StPageFlip 并入 `FLIP_DEFAULTS`（D9）；soft/hard 两种密度语义对齐 StPageFlip（hard = 绕书脊受限旋转）。
2. **Renderer 职责边界（防越权，本阶段重点）**：数据流向唯一——`FlipCalculation → FlipState（几何输出） → FlipRenderer → Canvas API`。FlipRenderer **只消费 FlipState 做绘制**，禁止上探 Engine 职责：
   - 禁止在 Renderer 内计算折叠点/折叠角（那是 FlipCalculation 的输出）；
   - 禁止在 Renderer 内出现速度、弹簧、插值、状态转移、阈值判定、翻页完成/回弹判定相关逻辑（P3 的 Animator/StateMachine 职责）；
   - 禁止 Renderer 修改 progress 或任何 FlipState 字段（只读消费）；
   - 禁止 Renderer 感知页索引提交（turnPage 是 Bridge 职责，本阶段甚至不存在于代码库）。
3. **页面显示归属（D8）预埋**：PageFlipView 的静态帧 = 当前页 PixelMap drawImage；本阶段 harness 内验证该路径。
4. **页内容缓存**：PageContentCache（pageIndex→PixelMap，LRU ≤8 页，短边超组件 1.5 倍时 0.5x 降采样，尺寸变化全失效，销毁全释放）；harness 页内容为图片解码（ImageKit）。
5. **harness 交互**：本阶段允许 PageFlipView 内部以最小临时驱动（onTouch → 直接调 FlipCalculation → 渲染）验证视觉；状态机/动画器是 P3 的事，本阶段不实现收尾插值（松手可瞬时复位/完成）。
6. **性能冒烟埋点**：FlipRenderer 内置可开关的统计（常量开关，release 可零成本剔除），每帧记录：renderFrame 总耗时、drawImage 调用次数、clip 次数、PixelMap 复制/解码次数（目标值为 0）。
7. **T5/T6/T7 落地**：尺寸校验与降级提示；不可见停绘；热路径零分配（对象复用）。

# 架构约束

- 主任务 A1-A9；A5（harness 仅 debug）、A8（FlipRenderer 须实现渲染后端接口形态，为 P3 接口冻结做准备）为本阶段重点。

# 技术约束

- T1-T10 全部适用；特别：T3 本阶段只做拖拽直驱渲染，禁止引入 animateTo 等任何高层动画 API；T7 热路径零分配。

# Non Goals

- 不做状态机/收尾动画（P3）；不接 Reader（P4）；不做性能达标优化（P5，本阶段只测量）；不做贝塞尔折叠边缘。

# Acceptance Criteria

- E1：harness 内四角起手拖拽翻页，折叠角、双裁剪、页背、三道阴影视觉正确；soft/hard 密度行为正确；
- E2：**主任务验收 V1 固定基准比对完成**：25%/50%/75% + 回弹中点四姿态成对截图存入 `.verify-shots/pageflip/`，评审通过（真实感 ≥ StPageFlip Canvas 版 80%）；
- E3（**性能冒烟 Gate，必测不判定**）：在目标设备上单次完整 drag，记录并落盘（附在 benchmark 文档"冒烟"节）：renderFrame 帧耗时分布（P50/P95）、drawImage 次数/帧、clip 次数/帧、PixelMap 复制次数（必须为 0）；**数据不齐不得进入 P3**；是否达标不由本阶段判定（判定在 P5）；
- E4：mapping 表绘制流程函数验证结果回填完毕；核心几何 1e-6 / 绘制顶点 1e-4 容差结论成立（T10）；
- E5：Renderer 边界核验：`rg -in "velocity|spring|turnPage|StateMachine|interpolat" ohrengine-pageflip/src/main/ets/render/` 为空；走查确认 FlipRenderer 只读消费 FlipState（无写回、无几何计算）；
- E6：既有单测全绿；debug/release 双构建通过；旧翻页链路运行能力完整（A9）。

# Test Requirements

- 既有 hypium 单测不得破坏；渲染层不做像素级自动化断言（以 V1 人工比对为准）；
- 人工核验清单：四角落起手、快速甩动、拖拽中反手、横竖屏旋转（harness 内）。
