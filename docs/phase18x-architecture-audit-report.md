# Phase 18.x Architecture Audit Report

> 生成时间：2026-09-04
> 角色：高级架构审查工程师（二次验证，只读）
> 范围：Phase 18 结论的复查（Task1–5 + 候选复核），未修改任何代码

---

## 1. Executive Summary

架构健康度：**稳定且边界良好**；**无 P0/P1 架构问题**；Phase 18 审查结论经源码二次实证全部成立（状态唯一所有权、生命周期闭环、依赖方向单向、Worker 边界隔离、Lazy Geometry/Pipeline 冻结点未破坏）。**Final = B. Keep Frozen**（OPT-001/002 均不构成当前必须实施的优化）。

## 2. Findings Table

| ID | Category | Severity | Result | Evidence |
|----|----|----|----|----|
| F1 | State Ownership | — | **PASS** | currentGlobalPage 生产侧 13 处写入全在 PageManager（仅 ohosTest 测试直写）；pageGeneration/navigationSerial 增写仅 PageManager（665/373/385） |
| F2 | Lifecycle | — | **PASS** | dispose 链路：statusTimer/autoTurnTimer clearInterval、paramBus.clear(OhEngineCore:1085)→shutdown:1095、bumpLayoutEpoch+cancel(PipelineManager:900/910)、disposeEngine(ReaderHost:381)、destroy 幂等；Worker await 后 destroyed/epoch/cancel 校验→DROP |
| F3 | Dependency | — | **PASS** | ui-render/common/parsers/txt-exclusive 无 `ohrengine-reader` import；Worker 仅 import parsers/common/hilog |
| F4 | Performance Debt | P2 | Defer | OPT-001/002 复核见 §6 |
| F5 | Memory (Lazy Geometry) | — | **PASS** | 正常阅读行数组为 []（懒序列化缺失键）；仅 ensureLineGeometry 按行写回；无 chapter-level geometry cache |
| F6 | Frozen Invariants | — | PASS | Worker JSON in/out、Lazy Geometry 单入口+line.ascent 源真相、155KB 协议、Session 验证协议均保持 |

## 3. State Ownership

| State | Owner | Writer（实证） | Reader |
|---|---|---|---|
| currentGlobalPage | PageManager | PageManager 13 处（273/291/312/341/553/634/736/906/923/962/1340/1368/1426）；ohosTest 测试直写（非生产） | OhEngine nav API→ReaderHost/Flip（只读） |
| pageGeneration | PageManager | rebuildPageSlots 单点（665） | Flip mut 校验 / ReaderHost 日志（只读） |
| navigationSerial | PageManager | commitNavigation/queueStub（373/385） | 队列 Latest-Wins（只读） |
| readingPosition（L1） | PageManager | updateReadingPosition/persist/FLUSH（engine 内） | ReadingStateStore |
| pageNum/totalPages（UI mirror） | ReaderHost | 恒 `engine.getGlobalPageNumber()/getTotalPages()`（474-475/701-702/756-757/1233-1234/1556-1557） | 状态栏/页码（只读镜像） |

**结论：无第二事实源；ReaderHost 镜像仅由引擎 getter 驱动。PASS。**

## 4. Dependency Graph（实证）

```
UI(Index) → ReaderHost → OhEngine(facade) → OhEngineCore
    └────────────→ PageManager → PipelineManager → Layout/Parser/Cache
                                        └────→ LayoutChapterWorker(纯 JSON in/out)
```
反向依赖检查（`rg "from 'ohrengine-reader'"`）：ui-render/common/parsers/txt-exclusive **0 命中**；Worker 无 UI/PageManager/PageSlot/Session 引用（imports 仅 parsers/common/hilog + 本地布局模块）。**PASS。**

## 5. Lifecycle Result

- Timers：statusTimer / autoTurnTimer / batteryMonitor → aboutToDisappear 清理 ✓
- Listeners：pageReady/fontSize → destroy→paramBus.clear ✓
- Promise/Worker：open 内各 await 后 `pipelineManager.destroyed` 护栏（SESSION_TASK_DROP）；Worker await 返回后 epoch/destroyed/cancel→LAYOUT_RESULT_DROP ✓
- Cache/引擎：txtLazyDoc.release + shutdown(clearAll) + destroy 幂等；ReadingState FLUSH→persist 先于 clear ✓
- **PASS（dispose 后无 callback/commit/缓存写/UI 更新残留）。**

## 6. Performance Review（候选复核）

### OPT-001 — 热窗 live-layout 卸载（现状：DEFER）
- 是否减少 wall time：**否**（冷首屏 832ms 为 CPU 成本，换线程不缩短；仅为 UI 免冻结）。
- 是否只是提高响应性：**是**（打开期间主线程解放）。
- 是否触碰冻结链路：**是**（open→layoutRangeSync 属 Anchor-first/FIRST_FRAME 冻结区）。
- 风险收益比：收益=一次性冷开响应性；风险=首帧路径回归面。用户可感知前提=“打开时明显卡顿”，当前 index-hit warm 已 465ms 无卡顿实证。
- **结论：DEFER（B. Keep Frozen）；仅在出现用户可感知的打开卡顿实证时立项。**

### OPT-002 — Deserialize 偶发 17–26ms
- 用户可感知：否（后台 cadence 内、动画互斥已保证、翻页 max≤10ms 未受影响）。
- 是否影响动画：否（实测 Flip avg5–6/max≤10/mut=0）。
- 是否值得动协议：否（动序列化/协议=冻结区；收益无法证明用户可感知）。
- **结论：Reject（维持现状；不因一次超 16ms 采样判定必须优化）。**

**其余：无其他可量化、低风险、有用户收益的 P1/P2 候选。** File-length / code-style 类不属于本审查范围。

## 7. MUST NOT TOUCH List

1. PageManager ownership（currentGlobalPage/generation/navigationSerial/readingPosition）
2. PipelineManager ownership（layoutEpoch/destroyed/cancellationToken/queue/commit）
3. Worker JSON boundary（LayoutChapterWorker 纯计算输入输出）
4. Lazy Geometry mechanism（ensureLineGeometry 单入口 + line.ascent 源真相 + 不整章/整页预生成）
5. Session validation protocol（epoch/layoutEpoch/navigationSerial/destroyed → DROP）
6. L2 cache compatibility（deserializer 兼容旧缓存；Worker lazy 传输与 L2 磁盘分离协议）
7. 155KB LayoutResult 传输协议

## 8. Final Recommendation

**B. Keep Frozen**

依据：Task1–5 全 PASS（无 P0/P1）；Phase 16/17 所有冻结点实证保持；OPT-001（响应性、碰冻结链路）与 OPT-002（用户不可感知、动冻结协议）均不足以构成当前实施优化的充分理由。稳定性 > 用户收益 > 性能数据 > 架构美观。若未来出现（1）用户可感知的打开卡顿实证 或（2）翻页/选择路径实测回归，再分别立项；否则维持冻结。

（未选择 A 或 C；无需提供收益/风险/回滚方案。）