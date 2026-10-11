# Phase 10 最终报告 — 冷启动页面恢复与双向翻页动画稳定性

> 生成时间：2026-09-04
> 审计：`docs/phase10-page-readiness-audit.md`；数据：`docs/phase10-page-readiness-benchmark.md`
> 范围：Phase 10.0（审计）→ 10.1（就绪状态 + instrumentation）→ 10.2（最小修复）→ 回归

---

## 1. Bug 根因

**真正根因（真机实证，双层）：**

**(F1 · 冷启动冻结墙 — 主导）** 打开图书时，`restoreSettings → applyFontSizeLevel`（ReaderHost.ets:380）在已保存字号 ≠ 默认字号时触发 `onFontSizeChanged → reflowAllChapters`（OhEngineCore.ets:1152）——**全书同步布局**。

```
13:17:29.523 onFontSizeChanged base=17 spacing=0        （2MB lazy TXT，146 vch）
13:17:40.548 AppMS faultData: com.example.ohrengine … THREAD_BLOCK_6S → 杀进程（signal 9）
```
实测 onFontSizeChanged → after-reflow：**12–14 s**（13:03/13:01 两次存活态的 14.1/14.2s；13:17 被杀）。这就是「打开图书→立即翻上一页出现严重渲染问题」的真实来源：open 完成后 UI 仍被全书同步 reflow 冻结 10+s，期间的任何交互/动画都在「一边布局一边渲染」状态下进行；reflow 结束（等待一段时间）→ 页面稳定 →「逐渐改善」。F1 是独立性能瓶颈（§13 → 记录 PENDING，不重写 reflow 系统）。

**(S2 · 首次反向无会话空白动画 — 代码实证）** `FlipPageController.start()` 的 BACKWARD 分支在无 FlipSession 时只做 peek 非空校验，不初始化 `flipPageRef/bottomPageRef`（修复前 FlipPageController.ets:510-523）→ 首次「上一页」的动画帧只画背景+阴影。已修复。
**(S3 · 仅 N+1 图片预取 — 代码实证）** `ReaderHost.refreshPage` 只 `prefetchNextPageImages()`，从不预取 N-1（PageRenderer.ets:785）→ 图片书冷启动翻回 N-1 时图片区空白，解码完成后「改善」。已修复为对称预取。

> 存活样本（小书/图片书）实测 N-1/N/N+1 全部 RENDER_READY 且对称（Benchmark B），说明 ±1 热窗内页本身无 stub 问题；「等待后改善」的量级与 F1 冻结时长、S2/S3 解码时长吻合。

**ROOT CAUSE = PARTIAL**（F1 已实证为主因并记录 PENDING；S2/S3 已修复并代码实证）。

---

## 2. 修改了什么

| file | change | reason | risk |
|---|---|---|---|
| common/types/EngineTypes.ets | 新增 `PageReadyState` 枚举；`PageSlot` 增加 `globalIndex/readyState/generation/imageCount` | 页就绪可观测、动画入口可校验 | 无（扩展字段，旧构造可选） |
| common/index.ets | 导出 PageReadyState | 跨模块引用 | 无 |
| common/service/MemoryPageCache.ets | `pin/unpin/isPinned`；LRU 逐出与 shrink 跳过被 pin 章 | 动画窗口 L3 保护（§12） | 低（仅逐出偏好，非正确性源） |
| ui-render/core/PageManager.ets | rebuildPageSlots 标注 readyState（stub=NOT_READY；文本=RENDER_READY；图=LAYOUT_READY） | 就绪状态机落地 | 低 |
| ui-render/core/PipelineManager.ets | `chapterOriginMap`（L3/L2/live/stub） | 缓存层诊断（Benchmark B） | 低 |
| ui-render/OhEngineCore.ets | `describePage/describeNeighborWindow/pinChapters/unpinChapters` | 诊断 + 动画保护入口 | 低 |
| ui-render/OhEngine.ets | facade 透传 | 供 reader 与测试调用 | 无 |
| reader/FlipPageController.ets | P10 intent 日志；动画期 gen 变更检测（mut）；**S2 修复**（首次反向建立 {prev,cur} 会话）；**动画窗口 pin/unpin**（start/finish/cancel/dispose） | 实现 §七/§十二；修「空白动画帧」 | 中（动画角色赋值路径变更，已真机回归） |
| reader/PageRenderer.ets | `describePageImages`；`prefetchPreviousPageImages` | S3 对称预取 + 资产诊断 | 低 |
| reader/ReaderHost.ets | `logPageTurnSnapshot`（翻页后 N-1/N/N+1 快照）；refreshPage 增加 prev 图片预取 | 全模式观测 + S3 | 低 |
| ohosTest/unit/Phase10PageReadinessOHOSTest.ets（新建） | Case1–7 | §十五最小复现 | 中（测试 HAP 构建环境 PENDING，用例逻辑已 Review） |
| ohosTest/test/List.test.ets | 注册 Phase10 测试 | 跑测入口 | 无 |

**未改动**（§24 禁改项）：翻页动画算法、TextBreaker、Knuth-Plass、分页算法、reflow 全系统、未新增 L4/L5/L6 缓存层。

---

## 3. 页面状态（冷启动后 N-1/N/N+1 实际状态变化）

```
Open → 【F1 冻结墙】→ 小书 65ms 内就绪；2MB 书 10-14s 或被杀
Restore N → renderPage（N 就绪）→
  首次 Previous：
    修复前（S2）：无会话 → flip/bottom 引用未初始化 → 空白动画帧；动画毕后才渲染 N-1
    修复后：{N-1(from), N(to)} 会话建立 → 动画即刻渲染真实 N-1
翻转完成 → flipTurned 快照：
  prev=g=N-1 ready=3  cur=g=N ready=3  next=g=N+1 ready=3（文本）
  或  img=1 imgDec=1/1（图片页，LAYOUT_READY+资产就绪）
动画期间：gen 不变（mut=0），L3 中 N-1/N/N+1 章节被 pin（不逐出）
```

---

## 4. Previous / Next 对比

| 维度 | Previous | Next |
|---|---|---|
| 首帧延迟 | 0–16ms（触摸同帧起动画） | 0–16ms |
| 动画时长 | ~400ms | ~400ms |
| 帧耗时 avg/max | 5–6 / 9–10 ms | 5–6 / 10–11 ms |
| render failure | 0（存活样本） | 0 |
| 目标页 ready | RENDER_READY（文本）/LAYOUT_READY+imgDec=1/1（图） | 同左 |
| 缓存命中 | L3/L2 | L3/L2 |
| 首次反向会话 | 修复前无会话→空白帧；修复后正常 | 恒有会话（preparePages） |

---

## 5. 动画期间稳定性

| 指标 | 计数 |
|---|---|
| PageModel mutation（gen 变化，mut） | 0（`gen=10->10 mut=0` 全部样本） |
| RenderNode replacement | 本工程无 RenderNode 依赖（直绘 PageSlot.lines） |
| Asset replacement | 0（FlipSession 冻结纹理更新 + S3 预取后 imgDec=1/1） |
| L3 eviction（动画窗口） | 0（动画期 pin N-1/N/N+1 章节） |
| blank-frame（S2 路径） | 修复前=整段空白；修复后=0 |

---

## 6. 最终结论

**PARTIAL**

PASS 项：
- PageReadyState + instrumentation 全链路落地（N-1/N/N+1 每页快照可复现）
- S2 首次反向会话修复；S3 N-1 图片对称预取；动画期 pin/unpin
- 构建通过（`build_project` SUCCESS）；小型 TXT/图片 EPUB 真机双向翻页 0 失败、mut=0、帧耗时稳定
- Phase10PageReadinessOHOSTest Case1–7 已编写并登记（用例逻辑走查通过）

PARTIAL / PENDING 项：
- F1：2MB TXT 冷启动全书同步 reflow 12–14s / THREAD_BLOCK_6S 杀进程 —— 独立性能瓶颈，记录 PENDING（§13）；其消除需 reflow 走异步/分片（超出本阶段禁改边界）
- Benchmark E 设备级 Cache OFF 路径 PENDING（应用无运行时开关）
- Phase10PageReadinessOHOSTest 真机执行受测试 HAP 构建环境（DEVECO_SDK_HOME）限制，暂未在设备跑通；用例逻辑经静态走查
- 冷启动 2MB 样本能否在冻结墙后稳定交互：达到存活态时（如 13:03 例）与小型样本一致对称就绪

**一句话**：本阶段证明并修复了可独立验证的 S2/S3（首次反向会话、N-1 资产对称），建立了可供任何后续阶段观测的 PageReadyState 体系；冷启动「立即翻上一页严重问题」的主导来源（F1 全书同步 reflow 冻结墙）已用设备日志实证，作为独立性能瓶颈移交后续 Phase 处理。