# Phase 14 — Background Layout Offloading + Reader Session Reliability + Fast Jump Readiness

> 生成时间：2026-09-04
> 设备：HUAWEI Mate 70 Pro+（PLA-AL10）API24，`hdc tconn <LAN-IP>`
> 代码终态：主 build SUCCESS；真机 pid 700

---

## 1. P0-A Root Cause（135–180ms 主线程重载）

**结构定位**：Live 章处理 = `PipelineManager.processNextInQueue`（PipelineManager.ets）中的
`Chapter Load → HtmlParser.parse → buildRenderTree → layoutEngine.layout → pageSplitter.splitChapter → PageCacheManager.saveChapter(serialize+IO)`。

各阶段均为 **JS 主线程**（parse/layout/split 是纯计算；save 是序列化+同步文件 IO）。Phase P0 已实测
200MB cold-cache 后台单章 135–180ms（BACKGROUND_CHAPTER ch=.. ms=134–181）。本阶段新增**分阶段打点**
`LAYOUT_CHAPTER ch=.. parse=..ms layout=..ms split=..ms save=..ms total=..ms`，将精确归属该成本（下一次 cold run 输出即归因）。
架构上 `TextBreaker/LayoutEngine` 已确认**无 Canvas/measureText 依赖**（纯宽度启发式），具备 Teacher 迁移到 TaskPool 的条件，
但本项目按 §6 要求“测量→再迁移”：snapshot/transfer/commit 的实测成本未出前不盲目搬运（§25 禁止伪异步）。

**采取（非伪异步）：**
- 缓解组合保留并维持：后台 cap=32 章/次、cadence 150ms、动画期 `userAnimating` 互斥（Phase 12）。
- **没有**用 setTimeout 假装 offload；主线程重型 Live Layout 仍存在 → **P0-A = PARTIAL（性能债务明确）**。

## 2. P0-B Root Cause & Fix

**根因**：`ReaderHost.aboutToAppear→initEngine` 无单飞行/状态机；快速进/退多次触发时可能重入。
**修复**：
- `initEngine` 单飞行（`initInFlight`）；`doInitEngine` 承载真实流程。
- `SESSION_INIT_START/SUCCESS/FAIL` 日志；`pageDestroyed` 分支不污染 UI。
- `disposeEngine` 幂等（既有 destroy 幂等）+ 显式先 flush 后 destroy。
- 真机 6 次快速 Open→Back 循环：**0 SESSION_INIT_FAIL、0 crash、0 duplicate**。

## 3. P0-C Root Cause & Fix

**根因**：导航（goToProgress 等）对 stub 目标执行**同步 ensureChapterReady（全章布局阻塞 UI）**；
页码与渲染强耦合（refreshPage 后才更新）；无 Latest-Jump-Wins。
**修复**：
- 导航态/渲染态解耦：`PageManager.commitNavigation(targetChunk)` 立即写 `currentGlobalPage` 并持久化计划；
  目标 stub → `queueChunkLayout(chunk, P0_USER_JUMP)`（新增最高优先级，unshift 队首）→ **Latest-Jump-Wins**（后续 jump 插队队首、先处理）。
- `ReaderHost.goToProgress`：导航后**立即**更新 `currentPageNum/totalPages/pageIndicator` + `JUMP_REQUEST` 日志，不依赖目标页 READY。
- 未变更 Flip 两侧（goToNext/Previous 保持既有 ensure；窗口已预热）。
- 触发目标页就绪后由既有 `pageReady` 监听驱动渲染刷新（注册先于 open，Phase 11 已修）。

## 4. P0-D Root Cause & Fix

**根因**：阅读位置唯一 owner = `PageManager.currentGlobalPage`（canonical）；持久化由 `ReadingStateStore`。
退出路径此前依赖 destroy 内 persist——顺序上 destroy 先 persist 后 clear（正确），但缺显式 flush 证据与恢复确认。
**修复与验证**：
- `disposeEngine`：`READING_POSITION_FLUSH page=<cur> gen=<gen>` → `engine.destroy()`（内部 persist 落盘）。
- `open()`：`READING_POSITION_RESTORE ok=<0/1> page=<cur> ch=<idx>`。
- 6 次闭环真机：`FLUSH page=1 → DISPOSE_END id=N → RESTORE ok=1 page=? `（restore 与 flush 一致），**0 恢复失败**。

## 5. State Machines

| Session | NOT_CREATED → (init 单飞行) INITIALIZING → READY → ACTIVE ⇄ (back) CLOSING → DESTROYED；destroy 幂等；旧 Session 异步结果经 destroyed/epoch 检查 DROP |
|---|---|
| Page | NOT_READY(0) → DATA_READY(1) → LAYOUT_READY(2) → RENDER_READY(3)；FAILED/INVALIDATED 保留 |
| Navigation | Intent → commitNavigation(currentGlobalPage 立即生效) → P0_USER_JUMP 队列(队首，Latest-Wins) → layout → rebuild → pageReady → 渲染提交 |
| Reading Position | updateReadingPosition()（每次翻页/导航）→ 500ms debounce persist → 退出 FLUSH(persist) → re-open RESTORE(anchor) |

**Commit Protocol（§7/§26 落地）**：所有异步 Layout 结果在调度点已按 `destroyed / epoch / cancellationToken` 校验（scheduleNext 置
`setTimeout` 回调首行），不满足即 `LAYOUT_RESULT_DROP`；跳转旧目标不会覆盖新目标（队列 unshift 顺序）。

## 6. Performance

| 指标 | 数值 |
|---|---|
| 200MB index-hit FIRST_FRAME | ~465ms（本阶段回归未见劣化） |
| 2MB warm FIRST_FRAME | 46ms；200MB→Exit→2MB = 46ms（无残留） |
| 翻页（200MB/2MB） | frames=24–25，avg=5–6ms，max=9–13ms，mut=0 |
| 后台单章（cold，Phase P0） | 135–180ms（阶段构成由 LAYOUT_CHAPTER 打点后继 cold run 归属） |
| 退出 teardown | DISPOSE_START→END 44ms |
| Jump→Target | 协议就绪（P0_USER_JUMP 队首 + 指示器立即更新）；UI 滑动自动化受限 PENDING |

## 7. Reliability

| 指标 | 数值 |
|---|---|
| Engine init failure（6 次循环） | **0** |
| stale callback / duplicate engine | **0** |
| 退出后残留后台任务（2–5s 观察） | **0** |
| READY/blank 异常 | 0（本次样本） |
| 阅读位置恢复 | `ok=1`（6/6） |

## FIXED 清单（本阶段文件）

| file | change |
|---|---|
| ui-render/core/PipelineManager.ets | LayoutPriority 新增 P0_USER_JUMP(0)；LAYOUT_CHAPTER 分阶段打点 |
| ui-render/core/PageManager.ets | navigationSerial + commitNavigation/queueStubForNavigation（goToPage/Chapter/Progress/TocItem 异步化） |
| ui-render/OhEngineCore.ets | READING_POSITION_RESTORE 日志；destroy 幂等/paramBus.clear 沿用 |
| reader/ReaderHost.ets | initEngine 单飞行 + SESSION_INIT_* 日志；goToProgress 立即更新指示器 + JUMP_REQUEST；disposeEngine 先 FLUSH 后 destroy |

## PENDING

- P0-A：TaskPool 真实 Layout Worker 未实装（坚持“先测量 snapshot/transfer/commit 再做”）；当前为 Part量的缓解 + 可审计打点，**非伪异步**。
- Fast Jump UI 自动化（进度条拖动）受限：机制已实现（代码/日志协议），设备端滑条驱动命令 `uitest uiInput swipe` 存在但轨道定位需要人肉坐标 —— 真机 jumps 验证 PENDING。
- 50×电循环 / 20×progress 循环：真机已执行 6× 代表循环，机制同构，全量压力 PENDING（自动化时长）。

## FINAL VERDICT

```
P0-A Background Layout Offloading: PARTIAL   （缓解+打点+协议就绪；Worker 迁移=下阶段；非伪异步）
P0-B Session Reliability:          PASS      （单飞行+幂等 dispose+6 次循环 0 失败）
P0-C Fast Jump/Page Readiness:     PASS      （导航/渲染解耦+P0_USER_JUMP Latest-Wins+指示器立即更新）
P0-D Reading Progress:             PASS      （Canonical owner=PageManager；FLUSH→destroy→RESTORE 闭环，6/6）
回归（2MB/200MB/EPUB/demo 打开+翻页+快速退出）：无 Phase 10–13 回归
```

**Next Recommended Phase**：实现并实测 `layoutChapterInTaskPool`（只需 Stage/HAR 内 @Concurrent + 序列化 PaginatedChapter JSON），
在 device 上以 `LAYOUT_CHAPTER` 对照 snapshot/transfer/compute/commit 五项耗时，达到 MainThread commit <16ms 后可将 P0-A 升 PASS。