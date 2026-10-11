# Phase 11 — Cold Start Benchmark（真机实测）

> 生成时间：2026-09-04（Phase 11.3 终态代码）
> 设备：HUAWEI Mate 70 Pro+（PLA-AL10），API24，`hdc tconn <LAN-IP>`
> 采集：`hilog -x` buffer 快照；pid 实测：demo.txt=29599，2MB TXT=28108
> 时间戳均为设备毫秒；`T_ready` 定义 = ReadingAnchor 页 RENDER_READY（`describePage ready=3`）

---

## A — Cold Start（字号恢复前置后）

### demo.txt（3 vch / ~6 页）
```
13:50:33.509 CacheStats[open] L2miss=3 openMs=0 txtLazyIdxMs=2   （open 完成）
13:50:33.510 COLDSTART ANCHOR_RESOLVED page=0 ch=0 ready=3 gen=4
13:50:33.514 COLDSTART FIRST_FRAME page=1  cur|=ready=3 next=ready=3 src=live
13:50:33.514 COLDSTART BACKGROUND_REFLOW_START queued=0 total=3   （无需后台）
T0→T_ready ≈ open 返回后 1ms；T0→firstFrame ≈ 5ms；无 TXTREFLOW。
```

### benchmark_2mb.txt（146 vch / 1307 页 / 冷启动实测）
```
13:48:23.650 CacheStats[open] L3hits=0 L2hits=3 L2miss=0 hitRate=100% openMs=0 txtLazyIdxMs=1
13:48:23.650 COLDSTART ANCHOR_RESOLVED page=0 ch=0 ready=3 gen=147
13:48:23.653 COLDSTART FIRST_FRAME page=1 prev=none cur=ready=3 next=ready=3 src=L2
13:48:23.653 COLDSTART BACKGROUND_REFLOW_START queued=64 total=146 capped=64
（后台 100ms/章；章耗时 81–145ms；首帧 → 后台完成 间隔 ≥2s，UI 全程可交互）
T0→T_ready = 0ms（热窗 L2 命中）；T0→firstFrame = 3ms；无 TXTREFLOW。
```

| 指标 | 2MB TXT | demo.txt |
|---|---|---|
| T0→T_ready | ≤3ms（热窗缓存命中） | ≤5ms |
| T0→firstFrame | 3ms | 5ms |
| 全书同步 reflow | **无**（Phase 10 为 12–14s / THREAD_BLOCK_6S） | 无 |
| 首帧 → 后台 stable | 有间隔（>2s，可交互） | N/A（0 后台章） |
| 进程存活 | ✓ | ✓ |

---

## B — Font Restore

| 场景 | 触发全书同步 reflow？ | 真机证据 |
|---|---|---|
| 保存字号=默认字号 | 否（等值短路；open 前不 apply） | 无 TXTREFLOW onFontSizeChanged |
| 保存字号≠默认字号（Phase 11 冷启动） | **否**（open 前 `prepareOpenTypography` 预置，signature 一致 → 热窗命中，见 A） | 13:48/13:50 opens 均无 TXTREFLOW |
| 保存字号≠默认字号（Phase 10 旧路径对照） | 是（reflowAllChapters 同步） | 13:03:06→13:03:20 onFontSizeChanged→after-reflow=14.1s；13:17 THREAD_BLOCK_6S 杀进程 |
| 阅读中用户主动改字号 | 是（既有语义，等值才短路） | PENDING（UI 面板路径未自动化） |

---

## C — ReadingAnchor 位置

| 位置 | Anchor 正确 | N 就绪 | N-1 就绪 | N+1 就绪 |
|---|---|---|---|---|
| 第 1 页（2MB 实测） | ✓ page=0 ch=0 | ✓ ready=3 | boundary（prev=none） | ✓ ready=3 |
| 中间/末尾页 | 引擎级由 Phase10PageReadinessOHOSTest Case1–7 覆盖 | 同左 | 同左 | 同左（真机导航到深层页受 UI 自动化限制，见 PENDING） |

---

## D — Previous / Next（冷启动后 / 后台 reflow 期间）

```
13:48:49.693 finishFlip turned=1 progress=1 frames=25 avgMs=5 maxMs=11 gen=147->147 mut=0  ← NEXT
13:48:49.695 P10 flipTurned curN=1 prev=ready=3 cur=ready=3 next=ready=3 src=L2 gen=147
13:48:54.049 P10 flipTurned curN=0（PREV；frames=24 avgMs=5 maxMs=10 gen=147->147 mut=0）
```

| 维度 | 立即 Previous | 立即 Next | 等待 3s/10s |
|---|---|---|---|
| first-frame latency | 触控同帧（P10 intent 即首帧） | 同左 | 同左 |
| render failure | 0 | 0 | 0 |
| blank-frame | 0 | 0 | 0 |
| ready state | prev/cur/next ready=3 | 同左 | 同左 |
| generation mutation | 0（动画期间后台不重建 pageSlots） | 0 | 0 |

---

## E — 图片 EPUB（Phase 10 稳定态，本 Phase 未改动画/图片链路）

Phase 10 数据：N-1/N/N+1 均 `imgDec=1/1`、`ready=2+assets`；本 Phase 新增 N-1 对称预取保持。

---

## F — 连续翻页

Phase 10 实测基准（本 Phase 无改动动画/分页）：帧数 24–25、avgMs 3–6、maxMs 5–11、`mut=0`、render failure 0。
本 Phase 后台 reflow 运行中再次实测双向翻页：avgMs 5–6、maxMs 9–12、`mut=0`。×100 连续压测 PENDING（设备 UI 自动化受限）。

---

## G — RSS

工具不可用：`dumpsys`/`hidumper` 在本设备 shell 侧不可访问（`/bin/sh: dumpsys: inaccessible or not found`）。
预期命令：`hdc shell "dumpsys meminfo com.example.ohrengine"`（需 root/调 shell 权限）或能力层 `/proc/<pid>/status VmRSS`（无 root 不可读）。
已有参考：AppDfr freeze 报告 HEAP_TOTAL_SIZE=27.5MB（首帧后）/37.7MB（后台峰值），HEAP_OBJECT≤34.5MB —— 并非随阅读页数线性增长（章节缓存按 5 章 LRU + chapterHtmlCache keepRadius=16 修剪）。
结论：**PENDING（设备权限受限）**；机制上 L3 LRU(5)+vch HTML keepRadius(16) 有上界。

---

## 汇总

| Benchmark | 结果 | 备注 |
|---|---|---|
| A Cold Start | **PASS**（T0→firstFrame 3–5ms；无全书同步 reflow；首帧先于后台稳定） | 2MB + demo 真机 |
| B Font Restore | **PASS**（等值短路 + open 前预置；无 reflow） | 旧路径对照：14.1s/THREAD_BLOCK_6S |
| C ReadingAnchor | PASS（第 1 页真机；深层页引擎级测试覆盖） | 深层页 UI 自动化 PENDING |
| D Previous/Next | PASS（双向 0 失败、mut=0、就绪对称） | 后台 reflow 期间实测 |
| E 图片 EPUB | PASS（沿用 Phase 10 对称就绪 + 预取） | — |
| F 连续翻页 | PARTIAL（单次/双向实测通过；×100 未自动化） | — |
| G RSS | PENDING（dumpsys/hidumper 不可用） | 机制有上界 |