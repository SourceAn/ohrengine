# Task ID

HOS-STPAGEFLIP-001-P3 — PageFlipEngine 封装：状态机、动画器与接口冻结（从任务）

> 主任务：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`（A1-A9 / T1-T10 / D1-D9 以主任务为准）。
> 本阶段冻结 Reader 唯一入口 `PageFlipEngine` 的接口；仍**不接 Reader（P4 才接线），不触碰旧翻页链路（A9）**。

---

# 开始前提

- P2 验收全项达成（E1-E5），含性能冒烟数据已落盘（P2-E3）；
- harness 视觉基准比对已通过评审（P2-E2）。

# Objective

1. 交付 `core/FlipStateMachine.ets`（D6 状态机唯一真源）与 `core/FlipAnimator.ets`（displaySync + 临界阻尼插值）；
2. 交付 `PageFlipEngine.ets` 门面与 `components/PageFlipView.ets` 的最终装配，冻结 0.10 接口（见下）；
3. harness 改为**仅经 PageFlipEngine 公共 API 驱动**（移除 P2 的临时直驱路径）；
4. 交付 `entry/src/main/ets/reader/PageFlipBridge.ets` 骨架（内容生产/路由/提交职责定型，P4 才接线进 Reader）。

# Scope

## 新建

```text
ohrengine-pageflip/src/main/ets/core/FlipStateMachine.ets
ohrengine-pageflip/src/main/ets/core/FlipAnimator.ets
ohrengine-pageflip/src/main/ets/PageFlipEngine.ets
entry/src/main/ets/reader/PageFlipBridge.ets          // 骨架，本阶段不进 Reader 调用链
entry/src/ohosTest/ets/unit/FlipStateMachine.test.ets
```

## 修改

- `ohrengine-pageflip/src/main/ets/index.ets`（导出 PageFlipEngine/PageFlipView/公共类型）；
- `ohrengine-pageflip/src/main/ets/components/PageFlipView.ets`（改为经 Engine 驱动，删除 P2 临时直驱）；
- `entry/src/main/ets/pages/debug/PageFlipDemoPage.ets`（改为仅经公共 API 驱动）。

## 禁止

- 禁止修改 Index.ets / ReaderGestureController / PageRenderer（Reader 接线在 P4）；
- 禁止移除/降级旧翻页任何能力（A9）；
- 禁止在 Bridge 内写几何/动画/阴影逻辑（A3）。

# Implementation Requirements

## 1. 状态机（D6，唯一真源；转移表为权威描述，须逐行实现）

状态：`IDLE / DRAGGING / SETTLING_COMPLETE / SETTLING_REBOUND / CANCELLING`

| 当前状态 | 事件 | Guard | 动作 | 下一状态 |
|---|---|---|---|---|
| IDLE | beginDrag，落点在热区（FLIP_DEFAULTS，初值页宽 15%） | 目标方向存在相邻页 | 请求内容快照；锁定方向与起手角 | DRAGGING |
| IDLE | beginDrag 非热区 | — | 返回未消费，事件透传 | IDLE |
| IDLE | flipNext/flipPrevious/flipToPage | 存在目标页且无活跃手势 | 合成手势直接进入收尾插值 | SETTLING_COMPLETE |
| DRAGGING | updateDrag(point) | — | FlipCalculation.calc → FlipState → 渲染帧 | DRAGGING |
| DRAGGING | endDrag，越完成阈值 | — | 临界阻尼收尾插值 | SETTLING_COMPLETE |
| DRAGGING | endDrag，未越阈值 | — | 回弹插值 | SETTLING_REBOUND |
| DRAGGING | cancel / 尺寸变化 / 销毁 | — | 立即渲染静态当前页 | CANCELLING → IDLE |
| SETTLING_COMPLETE | t>=1 | — | 终帧 → onFlipCommitted 回调（Bridge 提交 turnPage）→ 静态刷新 | IDLE |
| SETTLING_REBOUND | t>=1 | — | 终帧（原始页），页索引不变 | IDLE |
| SETTLING_* | 新 beginDrag | — | 中断插值，以当前 FlipState 接管 | DRAGGING |

裁定要点：分页模型提交时机 = 视觉完成之后（终帧渲染后回调）；阈值判定与末速度估算全在 Engine 内；末速度 px/ms、最近 5 触点环形缓冲、单调时钟（禁 vp/px 混用）；turnPage 失败路径：Engine 渲染当前实际页，不播补救动画，保证模型与画面最终一致。

## 2. 动画器（D7）

- 帧驱动仅 displaySync（期望 60），IDLE 必须 stop（静态零帧回调）；禁 animateTo/属性动画/transition/setInterval 逐帧驱动；
- 收尾插值为临界阻尼弹簧（ζ=1），输出"触点等效位置"（非直接插值页索引），保证拖拽段与收尾段几何连续；时长按剩余距离与末速度 clamp 至 [220ms, 450ms]；
- 拖拽段以最新触点直驱；允许一阶低通且系数入 FLIP_DEFAULTS。

## 3. 接口冻结（Reader 唯一入口）

```text
生命周期：attach(hostContext) / detach() / destroy()
内容：   setContentProvider(provider)      // Bridge 实现，按需产出页 PixelMap
手势：   beginDrag(point) / updateDrag(point) / endDrag() / cancel()
程序化： flipNext() / flipPrevious() / flipToPage(index)
事件：   onFlipCommitted(direction)        // 视觉完成后回调，Bridge 据此提交 turnPage
        onFlipSettled(index)              // 视觉与模型均稳定
配置：   setDefaults(overrides)           // 仅覆盖 FLIP_DEFAULTS 命名项
渲染后端：内部经 FlipRendererInterface 调用（A8）；当前唯一实现为 Canvas 2D 后端
```

- Reader/Bridge 只感知上述接口；不得感知 FlipCalculation/阴影/几何参数；
- **信息隐藏清单（防内部类型泄漏，否则未来 Native Renderer 替换必然失败）**：以下内部类型/概念禁止出现在 `PageFlipEngine`/`PageFlipView` 的公共 API 签名、事件载荷、Bridge 与 Reader 代码中——FoldPoint/折叠点坐标、ShadowConfig/阴影参数、FlipProgress/FlipState、HardAngle、FlipCorner、canonical 坐标细节。Reader 可见的仅有：页索引、方向、生命周期与手势入口、事件回调（onFlipCommitted(direction)/onFlipSettled(index)）。公共 API 签名中只允许出现：number/string/boolean/枚举（方向）与 index.ets 显式导出的公共类型；
- 镜像逻辑（右书脊 → canonical）在 Engine 边界一次完成（D5）。

# 架构约束

- 主任务 A1-A9；A1（Reader 只感知门面）、A3（Bridge 职责上限）、A8（渲染后端接口固定）为本阶段重点。

# 技术约束

- T1-T10 全部适用；重点 T3（动画仅 FlipAnimator）、T6（不可见停绘）、T7（热路径零分配）。

# Non Goals

- 不接 Reader（P4）；不做性能达标优化（P5）；不做贝塞尔增强；不改 P1/P2 已定几何与渲染语义。

# Acceptance Criteria

- E1：状态机单测逐行覆盖转移表（含中断接管、CANCELLING、提交时机、turnPage 失败路径），全绿；
- E2：接口冻结：harness 仅经公共 API 驱动即实现拖拽/松手完成与回弹/点击翻页；视觉与 P2 基准无可见差异（抽验 50% 姿态截图比对）；
- E3：`rg "animateTo|\.transition\(|Swiper|PageSlider" ohrengine-pageflip entry/src/main/ets/reader/PageFlipBridge.ets` 为空；
- E3b（信息隐藏核验）：`rg "FoldPoint|ShadowConfig|FlipProgress|FlipState|HardAngle|FlipCorner" entry/src/main/ets/ ohrengine-pageflip/src/main/ets/index.ets` 为空（index.ets 导出清单走查确认无内部类型泄漏；FlipState 等类型允许存在于模块内部文件，禁止出现在公共出口与 entry）；
- E4：IDLE 状态 displaySync 已 stop（代码走查 + 运行期日志核验）；
- E5：Bridge 骨架编译通过但未接入 Reader 调用链；旧翻页链路运行能力完整（A9）；既有单测全绿，debug/release 双构建通过。

# Test Requirements

- 新增 FlipStateMachine.test.ets 全绿并纳入既有单测运行；
- 人工核验（harness）：动画中新触摸接管、快速甩动惯性、拖拽反手、连续翻页 20 次、横竖屏旋转中取消。
