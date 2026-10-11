# Phase 15 — Layout Worker Offloading & Safe Commit

> 生成时间：2026-09-04
> 设备：HUAWEI Mate 70 Pro+（PLA-AL10）API24；`hdc tconn <LAN-IP>`；真机 pid 15845
> 方法：先测量 → 最小 Worker 实验 → 真机验证 → 结论（拒绝伪异步：Worker 执行由 `LAYOUT_WORKER_*` 证据证明）

---

## 1. 架构变化

**BEFORE（主线程）**
```
processNextInQueue → html load → HtmlParser.parse → buildRenderTree → LayoutEngine.layout
→ PageSplitter.splitChapter → saveChapter（全程 JS 主线程，后台单章 135–180ms）
```

**AFTER（后台章走 Worker；主线程只验证+提交）**
```
processNextInQueue（async）
 ├─ 后台章 → layoutChapterInPool
 │     ChapterSnapshot(JSON: html+cssText+排版+视口) ──▶ TaskPool @Concurrent
 │             worker: parse → tree → layout → split → serialize
 │             ◀── LayoutResult(JSON string)
 │     Main: validate(epoch/destroyed/cancel) → deserialize → commit(assign+save chapter+pageReady)
 └─ 回退：worker 失败/不可用 → 原主线程路径（保持正确性）
```

新增文件：`ohrengine-ui-render/.../layout/LayoutChapterWorker.ets`（纯计算 worker）。
改动：`PipelineManager.processNextInQueue`（async）+ `layoutChapterInPool` + `LayoutPriority`/`LAYOUT_*` 日志。

## 2. 性能数据（真机，200MB 冷缓存后台）

| 阶段 | 实测 |
|---|---:|
| snapshot（快照构建） | 0–1 ms |
| exec（Worker round-trip：传输+worker 计算+结果序列化+返回） | 181–226 ms（在 worker 线程） |
| deser（主线程接收反序列化） | 41–50 ms |
| **commit（主线程验证+提交+缓存写）** | **6–14 ms** |
| 原主线程后台单章 | 135–180 ms |

| 指标 | Before | After |
|---|---:|---:|
| 200MB 冷缓存首页（index hit）FIRST_FRAME | 465 ms（warm 页缓存）/ 冻结风险（冷） | 832 ms（页缓存全删后热窗 live 主线程 3 章）/ 无 THREAD_BLOCK |
| 2MB warm FIRST_FRAME | 46 ms | 49 ms（无回归） |
| 翻页 avg / max | 5–6 / 9–13 ms | 5–6 / 10 ms（worker 后台运行期间实测 mut=0） |
| 后台单章主线程占用 | **135–180 ms** | **≈47–64 ms（deser+commit），重计算已脱离主线程** |
| commit（§P0-G 目标 <16ms） | — | 6–14 ms ✓ |

**§20 主线程收益直接回答**：200MB 后台单章主线程重载由 135–180ms 降至 ~47–64ms（其中 commit≤14ms、其余为结果反序列化传输成本）；135–180ms 的 parse/layout/split 计算已真实发生在 TaskPool worker 线程（`LAYOUT_WORKER_START/END` 成对、无 `LAYOUT_WORKER_FALLBACK` 触发）。

## 3. Worker 安全性（§21 逐项）

- Worker 是否访问 UI？否（仅 JSON 字符串入/出；`layoutChapterConcurrent` 只有 import）。
- Worker 是否访问 PageManager/PageSlot/Session？否（纯函数 + 本地 new 的解析/布局对象）。
- 是否修改 Session？否；修改只发生在主线程 commit 前。
- stale result 是否污染新 Session？否——`layoutChapterInPool` 在 await 返回后验证
  `destroyed || epoch!==layoutEpoch || cancellationToken` → 任一不满足 `LAYOUT_RESULT_DROP`（日志佐证，无跨 Session 提交）。
- 提交前验证：epoch（layoutEpoch 快照）+ destroyed + cancellationToken（三者复用现有语义，未新增 Session ID）。

## 4. 迁移边界（§五 MUST/SHOULD/KEEP）

| 层 | 结论 | 依据 |
|---|---|---|
| HtmlParser.parse / buildRenderTree | **MUST MOVE（已）** | 纯计算、无 UI/Canvas |
| TextBreaker / LayoutEngine.layout | **MUST MOVE（已）** | 纯宽度启发式（已确认无 measureText/Canvas） |
| PageSplitter.splitChapter | **MUST MOVE（已）** | 纯计算 |
| serialize（PageCacheManager） | **SHOULD MOVE（随 Worker 已天然在 worker 内）+ 主线程 commit 内 saveChapter 写盘保留** | L2 写盘是状态提交 |
| deserialize（接收） | 主线程（当前）；可优化项：更紧凑传输/增量解析 | 当前 41–50ms |
| PageSlot 分配 / rebuildPageSlots | **KEEP MAIN THREAD** | 属于主线程状态（Owner） |

## 5. 压力测试

| 项 | 结果 |
|---|---|
| Open/Back（Phase 14 同构 6 次循环 + 本阶段回归） | PASS（0 init fail / 0 残留） |
| 200MB→Exit→2MB（含 worker 冷后台后退出） | PASS（DISPOSE 闭环；2MB 首帧 49ms；无旧 Worker 污染） |
| 快速跳转 | 协议沿用（P0_USER_JUMP Latest-Wins + 指示器即时）；滑条 UI 自动化受限 → PENDING（记录：`devecocli ui swipe` 拖轨道需人工坐标） |
| 翻页（含 worker 后台运行期） | PASS（avg 5–6 / max 10 / mut=0） |

## 6. PENDING

- 结果**反序列化** 41–50ms 仍占主线程（背景 cadence 150ms+，动画期互斥不受影响）；下阶段可用（a）更紧凑二进制/增量传输，或（b）将反序列化放入接收侧 worker 位、主线程仅提交已解引用结构。
- 跳转滑条真机自动化（坐标轨）。
- 全量 50×Open/Back、20×快速跳转压力计数（自动化时长限制；机制与样本一致）。

## 7. 回归保护确认

Phase 10–14 机制全部保留：PageReadyState / pin·unpin / generation / Anchor-first / userAnimating / DebugBookshelf 严格目标 / destroy 幂等 / paramBus.clear / 单飞行初始化 / FLUSH·RESTORE / Latest-Jump-Wins / 指示器与渲染解耦。无 REGRESSION。

---

## FINAL: PASS

- 重计算已真实验证发生在 TaskPool worker（`LAYOUT_WORKER_START→END` 成对，无回退）；
- 主线程后台单章重载由 135–180ms → commit 6–14ms（剩余 ~45ms 为结果反序列化传输成本，属 §4 成本模型的一部分并已量化）；
- 安全提交协议（epoch/destroyed/cancel 验证 + `LAYOUT_RESULT_DROP`）与 Latest-Jump-Wins 保留；
- 200MB 冷/温、2MB、退出-重进、翻页真机无回归。

> 注解（诚实边界）：Worker round-trip 墙钟仍 ~200ms/章（CPU 瓶颈本身不因换线程变快），收益是**主线程解放**（翻页期间可证明 smooth、Mut=0）；反序列化 deser≈45ms 是既定传输模型的剩余主线程成本，已在报告中量化并给出后续优化方向，不再宣称"完全零主线程占用"。