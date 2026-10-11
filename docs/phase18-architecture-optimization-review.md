# Phase 18 — Architecture Optimization Review

> 生成时间：2026-09-04
> 角色：高级架构审查工程师（只读；未修改任何生产代码/未创建文件）
> 前置：Phase 17 Audit PASS（只读暂停点）

---

## 1. Executive Summary

- **健康程度**：当前架构处于“稳定且边界良好”状态。核心状态唯一所有权成立；依赖方向单向；Worker/LazyGeometry/Session 冻结不变式保持；性能基线全面达标（LayoutResult 155KB / JSON.parse 7–10ms / Deserialize 11–14ms / Commit 5–8ms / Flip avg 5–6ms·max≤10ms·mut=0）。
- **P0/P1 风险**：**无**。Task 1–5 全部无冲突/无泄漏/无违规。
- **是否建议继续优化**：**不建议在本阶段继续**。经量化评估，仅两个 P2 候选（OPT-001/2）具有可量化收益，但收益幅度有限且触及冻结路径；**Final Recommendation = B. Keep Frozen**（稳定 > 收益 > 美观）。

## 2. Architecture Risk Findings

| ID | 类型 | 等级 | 结果 |
|----|----|----|----|
| R1 | State Replication（Task1） | — | **NO STATE OWNERSHIP CONFLICT FOUND** |
| R2 | Lifecycle（Task2） | — | **NO LIFECYCLE LEAK FOUND** |
| R3 | Dependency（Task3） | — | **NO DEPENDENCY DIRECTION VIOLATION FOUND** |
| R4 | Performance Debt（Task4） | P2 | 两个可量化候选（见 §3），均 DEFER |
| R5 | Memory Lifecycle（Task5） | — | 无新问题（不重复提出 Phase 16 已解决的 charPositions 常驻） |
| R6 | Worker Boundary | — | 冻结保持（纯 JSON in/out，零 UI/PageManager/PageSlot 引用） |

### R1 证据
ReaderHost `currentPageNum/totalPages`：6 处赋值全部为 `this.engine.getGlobalPageNumber()/getTotalPages()`（ReaderHost.ets:474-475,701-702,756-757,1233-1234,1556-1557）——镜像只读，无独立写入；`engineState` 为 UI 进度字符串镜像。canonical Owner（PageManager.currentGlobalPage）无第二写入源（实证 13 处写入均在 PageManager）。

### R2 证据
- statusTimer/autoTurnTimer/batteryMonitor：aboutToDisappear 成对清理（stopAutoTurn/clearInterval/batteryMonitor.stop）。
- saveCacheTimer：PageManager.clearAll → clearAll 清理（destroy 链路）。
- pageReady/fontSize listener：engine.destroy → paramBus.clear（Phase 14 已加）。
- Worker/Promise 结果：layoutChapterInPool await 返回后校验 `destroyed/layoutEpoch/cancellationToken`，不满足 `LAYOUT_RESULT_DROP`；open() 各 await 后 destroyed 护栏（SESSION_TASK_DROP）。
- 无 dispose 后 callback/commit/缓存写/状态变更残留。

### R3 证据
ui-render / common / parsers / txt-exclusive 均不含 `from 'ohrengine-reader'`（实证空）；Worker 无会话访问。依赖方向：UI→ReaderHost→OhEngine(facade)→OhEngineCore→{PageManager,PipelineManager}→Layout/Parser→Worker，单向。

## 3. Optimization Candidates

### OPT-001 — 打开冷首屏热窗 live-layout 主线程停顿卸载（P2，DEFER）

- **问题**：200MB 冷缓存 FIRST_FRAME ≈ 832ms 中，热窗 3 章 live-layout 在主线程同步执行（`layoutRangeSync`，每章≈135–180ms → 主线程连续停顿≈0.4–0.6s）。
- **证据**：OhEngineCore.open（`layoutRangeSync(hotFrom,hotTo)`，+ worker 路径不变）；真机 pid 基线：200MB cold FIRST_FRAME 832ms（16.0/16.1 记录）。
- **用户收益**：打开期间 UI 不冻结（冷缓存一次成本）；Warm index-hit 路径不受影响。
- **性能收益（量化）**：主线程阻塞 ≈0.4–0.6s → 0（转 worker async）；**FIRST_FRAME wall 时间不变或微增**（worker 同样 CPU 成本）。净收益=响应性，非延迟。
- **修改范围**：OhEngineCore.open 热窗同步分页路径（首帧链路，触及 Anchor-first/FIRST_FRAME 冻结区）。
- **风险**：MEDIUM（首帧链路属于冻结区；若 worker 起停时序处理不当会回归 FIRST_FRAME 指标）。
- **推荐**：**DEFER**（有量化收益但触及冻结路径且不缩短 wall 时间；仅当“响应式打开”被列为独立用户优先级时立项实施，并严格按迁移纪律+回归回滚）。

### OPT-002 — Deserialize 偶发 >16ms 抖动（P2，DEFER/NOT RECOMMENDED）

- **问题**：基线多数 11–14ms，个别章 17–26ms（设备调度/大章），不触 16ms 目标常态。
- **证据**：Phase 16.4 记录（deserializer 已剪枝：out 155KB；重建仅 2–6ms；JSON.parse 7–10ms）。
- **用户收益**：轻微稳定性（后台章 cadence 内吞吐）；不涉及首屏/翻页动画（互斥已保证）。
- **性能收益（量化）**：修正调度抖动需更深协议改动，收益不足以覆盖风险 → **UNKNOWN**。
- **风险**：MEDIUM（动序列化/协议=冻结区）。
- **推荐**：**DEFER**（无足够证据证明用户可感知；不因指标好看而动冻结协议）。

> 其余候选审查结果：ReaderHost/OhEngineCore 文件长度 → code-organization only，**REJECT**；Worker serialize 占 worker 相对比例、L2 磁盘瘦身 → 无量化或隐私益，**NOT RECOMMENDED**。

## 4. MUST NOT TOUCH List

- **PageManager**（currentGlobalPage/generation/navigationSerial/readingPosition 唯一 Owner）
- **PipelineManager**（layoutEpoch/destroyed/cancellationToken/queue/commit 协议）
- **LayoutChapterWorker boundary**（纯 JSON in/out；零 UI/PageManager/PageSlot/Session）
- **Lazy Geometry mechanism**（ensureLineGeometry + line.ascent 源真相 + 四对齐 golden）
- **Session validation protocol**（epoch/destroyed/cancel→LAYOUT_RESULT_DROP；paramBus.clear；disposeEngine 顺序）
- **Worker↔Main 155KB 协议与 L2/内存序列化分离**（Phase 16.3）

## 5. Final Recommendation

**B. Keep Frozen**

依据：Task1–5 全部无 P0/P1 风险；现有性能基线全面达标；唯一量化候选（OPT-001）收益为“打开响应性”而非延迟且触及冻结首帧路径（DEFER 保留），OPT-002 收益无法证明用户可感知（DEFER）。不因文件长度/理论优雅破坏已通过 Phase 16/17 验证的稳定架构。稳定性 > 真实用户收益 > 性能数据 > 架构美观。若未来出现用户可感知的“打开卡顿”实证（非估计），再以独立专项启动 OPT-001。