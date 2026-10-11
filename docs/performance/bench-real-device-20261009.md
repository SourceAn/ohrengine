# OhEngine 真机性能 Bench 报告（标准语料 / 便携流程）

> 生成：2026-10-09　设备：**HUAWEI Mate 70 Pro+（PLA-AL10）**，HarmonyOS 7.0.0.109(SP6C00E105R7P3)，API 26，USB 真机
> 对照设备：DevEco 模拟器 "Mate 70 Pro+"（emulator 7.0.0.32，API 26，跑在 MacBook Air M2 上）
> 流程与口径：`tests/bench/README.md`；原始数据：`tests/bench/results/20261009-172839`（批 A）、`20261009-173136`（批 B）、`20261009-170913`（模拟器批）
> 所有数字来自应用内 hilog 埋点，无一条为估算或定性描述。

---

## 0 目标值（体验阈值参考）

| 指标 | 优质 | 可接受 | 不可接受 |
|---|---|---|---|
| 首帧（T0→FIRST_FRAME） | < 500 ms | < 1 s | > 3 s |
| 页数/翻页延迟 | < 100 ms | < 200 ms | > 500 ms |
| 单章排版（Worker） | < 200 ms | < 400 ms | > 800 ms |
| 稳定性 | 0 崩溃 / 0 THREAD_BLOCK | 同左 | 任一非零 |

---

## 1 汇总（真机实测）

| 样例 | 规模 | 冷启动首帧 | 热启动首帧 | 索引构建(idx) | 页数 | RSS 冷/热 |
|---|---|---|---|---|---|---|
| demo | 5 KB TXT | 69 ms | 11 ms | 29 / 1 ms | 6 | 208 / 158 MB |
| epub-s | 2.2 MB EPUB | **70 ms** | **10 ms** | 0 / 0 | 305 / 318 | 245 / 170 MB |
| cbz | 76 KB CBZ | **4 ms** | **4 ms** | 0 / 0 | 3 / 3 | 156 / 158 MB |
| txt-s | 291 KB TXT | 1692 ms | 43 ms | 438 / 1 ms | 227 / 198 | 231 / 181 MB |
| txt-m | 2.1 MB TXT | 3987 ms | 49 ms | 2685 / 0 ms | 1683 / 1655 | 238 / 229 MB |
| txt-l | 7.8 MB TXT | 窗口内未完成（索引 10.85 s）※ | 74 ms | 10850 / 2 ms | — / 6258 | 218 / 219 MB |
| txt-xl | 52 MB TXT | **窗口外补测：91.14 s**（索引 89.17 s） | 窗口内未完成 | 89172 ms | **42087** | 236 MB |
| pdf | 5.3 MB PDF | 未完成（见 §5，功能缺陷非性能） | — | — | — | 151 / 150 MB |

※ txt-l 冷启动的等待窗口为 12 s，索引第 10.85 s 才就绪，首帧超出窗口；warm 沿用该次索引，74 ms 出首帧。

**线性证据（TXT 索引 vs 体积，真机）**

| 体积 | 索引耗时 | 归一 |
|---|---|---|
| 291 KB | 0.44 s | 1.5 ms/KB |
| 2.1 MB | 2.69 s | 1.3 ms/KB |
| 7.8 MB | 10.85 s | 1.4 ms/KB |
| 52 MB | 89.17 s | 1.7 ms/KB |

≈ **1.4–1.7 ms/KB（真机）**，近似线性，无上界保护。

---

## 2 关键结论

### 2.1 索引已在 TaskPool，主线程不再被冻结（P0-A 改造有效）✅
代码路径 `TxtDocument.ets:61 → TxtIndexBuilderTask.buildInTaskPool()`。
16 个场景（含 52 MB）**THREAD_BLOCK = 0、appfreeze = 0、ProcessExit = 0**。
→ 52 MB 场景主线程未被冻结，是"首帧被 gate"而非"系统杀进程"。

### 2.2 但首帧被 `await` 索引 gate 住（当前第一性能问题）🔴
`OhEngineCore.open()` 中 `await lazyOpen(...)` 后才继续排版/首帧。
后果：52 MB 首帧 **91.14 s**（索引 89.17 s + 排版 1.9 s），期间用户可见的是等待态。
→ 修复方向不是"再挪线程"（已在 TaskPool），而是**首帧不等索引**：先出可渲染首屏（预置/惰性采样/目录态），索引完成后校正页数。

### 2.3 索引持久化在被打断时无效 🔴
txt-xl 冷启动场景（60 s 窗口）结束时索引尚未完成，force-stop 后 warm 场景**重新构建**（同样 89 s 量级）。
→ 需要"索引构建可续/原子落盘 + 部分索引可用"，否则大文件每次打开都付全价。

### 2.4 章级排版是真机体感瓶颈（400–1050 ms/章）🟡
| 样例 | 后台章 n | p50 | p95 | max |
|---|---|---|---|---|
| epub-s cold | 10 | 212 ms | 413 ms | 413 ms |
| txt-m cold | 11 | 702 ms | 864 ms | 864 ms |
| txt-m warm | 19 | 306 ms | 804 ms | 804 ms |
| txt-l warm | 18 | 558 ms | 855 ms | 855 ms |

txt-xl：3238 章 / 42087 页，后台按 capped=32 排队，实测 ~2 章/1.3 s → 全量约 **35 分钟**；翻到未就绪章需等。

### 2.5 排版吞吐：模拟器（M2）比真机快 —— 用真机测更严格 ⚠️
| 指标 | 真机 | 模拟器(M2) |
|---|---|---|
| txt-m cold Worker p50 | 558 ms | 464 ms |
| txt-m cold 后台章 p50 | 702 ms | 485 ms |
| txt-m 冷启动首帧 | 3987 ms | 5176 ms |
| txt-m 热启动首帧 | 49 ms | 198 ms |
| txt-m RSS | 238 MB | 319 MB |

启动/索引真机快 20–75%（IPC/系统开销少）；**纯 CPU 排版真机慢 ~20–45%**（M2 单核强于手机 SoC）。
→ 结论：模拟器适合功能回归，**性能结论必须用真机**；模拟器在排版项上会低估问题。

### 2.6 内存：真机比模拟器省 25–50% ✅
真机 RSS 峰值 158–245 MB，热启动后回落至 158–181 MB；模拟器同本语料 270–320 MB（QEMU 侧放大）。
50 MB TXT 索引完成后 RSS 236 MB，未见线性膨胀（章节缓存有 LRU 上界）。

---

## 3 稳定性

| 场景数 | THREAD_BLOCK | appfreeze | 崩溃/退出 | 白屏渲染失败 |
|---|---|---|---|---|
| 16（真机 8×2） | 0 | 0 | 0 | 0 |

`CacheStats[open]`：冷启动 `L2miss=3`，热启动 `L2hits=3 hitRate=100%`（L2 页缓存命中路径正确）。

---

## 4 埋点可信度声明（引用前必读）

1. `openMs` / `restoreMs` **恒为 0 = 埋点失效**，本报告一律不引用；有效替代为 `txtLazyIdxMs` 与设备钟时间戳差（SESSION_OPEN → ANCHOR/FIRST_FRAME）。
2. 冷/热 `totalPages` 存在差异（txt-m 1683 vs 1655）——抓取时刻不同，热启动时后台仍在重排，非分页 bug；跨场景比较页数须在同一稳定点（后台 stable）采样。
3. 早期版本报告出现的 `THREAD_BLOCK×3` 为解析正则误匹配系统日志（`sceneboard … isFreeze: false`），已修正；真实值为 0。
4. 等待窗口不足的场景（txt-l cold、txt-xl）标记为"窗口内未完成"，未用推算值填充。

---

## 5 非性能问题（本轮附带发现）

- **PDF 打开未完成**：`SESSION_INIT_START` 之后无 `SESSION_OPEN`／无 `SESSION_INIT_FAIL`，流程静默中断（`bench_pdf` 冷热均如此）。需查 `PdfParser` 异常是否被上层吞掉。属功能缺陷，不产生性能结论。
- `pidof` 与 `/proc/<pid>/status` 在真机**可读**（RSS 采样可用）；`dumpsys`/`hidumper` 仍不可用。

---

## 6 复现

```bash
# 全流程（真机）
DEVICE=3EV0225122002756 bash tests/bench/run_bench.sh
# 只跑某几档
DEVICE=3EV0225122002756 bash tests/bench/run_bench.sh --skip-build --only txt-xl
# 复用语料（不重装，避免清空沙箱）
DEVICE=3EV0225122002756 bash tests/bench/run_bench.sh --skip-build --skip-deploy --skip-inject --only txt-l
```

大文件请调大等待：`WAIT_SEC=120`（脚本对 >8 MB 档自动 ×5，52 MB 档实测需 >95 s 才能出首帧）。

## 7 行动建议（按优先级）

| 级别 | 措施 | 目标 |
|---|---|---|
| 🔴 P0 | open() 首帧不等索引：先渲染首屏/目录态，索引完成后校正页数 | 52 MB 首帧从 91 s → < 1 s |
| 🔴 P0 | 索引原子落盘 + 可续构建（被打断不白跑） | 二次打开 52 MB 不重建 |
| 🟡 P1 | 章级排版优先级：按阅读位置插队 + 更细粒度（vch 级） | 后台章 700 ms → < 200 ms 体感 |
| 🟡 P1 | `openMs`/`restoreMs` 埋点修复 | 指标可用于回归门禁 |
| 🟢 P2 | 修复 PDF 打开静默中断 | 恢复 PDF 可测 |
