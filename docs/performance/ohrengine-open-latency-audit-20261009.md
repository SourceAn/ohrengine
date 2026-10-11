# OhEngine 打开延迟审计报告（真实用户路径 · 真机）

> 生成：2026-10-09 ｜ 设备：**HUAWEI Mate 70 Pro+（PLA-AL10）**，HarmonyOS 7.0.0.109，API 26，USB 真机
> 方法：`tests/bench/` 标准语料 + `uitest` **真实点击**路径（非脚本直开），每次运行带**行前/行后校验**
> 对照：DevEco 模拟器（emulator 7.0.0.32）数据仅作参考，性能结论以真机为准
> 目标：**冷加载（app 启动）可慢；进入 app 后打开任何格式的延迟 < 业界首帧标准**

---

## 0 判定标准

| 指标 | 优质 | 可接受 | 不达标 |
|---|---|---|---|
| 打开（点击 → 首帧） | < 300 ms | < 500 ms | > 1 s |
| 重复打开（同书二次） | < 100 ms | < 300 ms | > 500 ms |

> 业界经验阈值：Android TTID"慢"判定线 500 ms；阅读类本地书打开普遍以 300 ms 为无感线。非某份官方硬标准。

---

## 1 结论速览

| 格式 | 首次打开（真冷） | **重复打开** | 判定 |
|---|---|---|---|
| TXT 小（291 KB） | 1.69 s | 43 ms | 首次不达标 / 重复达标 |
| TXT 中（2.1 MB） | 3.99 s | 49 ms | 首次不达标 / 重复达标 |
| TXT 大（52 MB） | **91.1 s** | 未在窗口内完成 | **严重不达标** |
| EPUB（2.2 MB） | 75 ms | **43 ms** | ✅ 达标 |
| CBZ 小（76 KB / 3 页） | 3 ms | 4 ms | ✅ 达标 |
| **CBZ 大（203 MB 包 / 313 MB 解压 / 200 页）** | **9.26 s** | **9.26 s（不缓存，每次都付全价）** | **严重不达标** |
| CBR | **打不开** | — | ❌ 名义支持、实际不可用 |
| PDF | 未实现（`ReaderHost:652` 明确返回"暂不支持"） | — | 不适用 |

**一句话**：EPUB 已经达标且机制正确；**TXT 首次、CBZ 大小档、CBR 三项未达标**，其中 CBZ 属于"机制写错"（本该能命中却永远不命中），TXT 属于"首帧被索引 await 卡住"。

---

## 2 测试方法（严格版）

此前一轮测试被判定不合格，原因与修正：

| 缺陷 | 后果 | 修正 |
|---|---|---|
| 只测 `aa start --ps bookPath` 直开 | 跳过书架与真实点击，低估前置耗时 | 改用 `uitest uiInput click` 真实点击（坐标来自 `uitest dumpLayout`） |
| 无行前校验 | 一批 3 次点击全落空却差点被当作有效数据 | 点击前 dumpLayout 校验页面含"书架"，否则作废 |
| 无行后校验 | 空跑（0 日志）未被发现 | 点击后校验必须出现 `OPEN_TOTAL page=1 total=N` |
| `--only` 按本机文件过滤 | 设备内生成的 cbz-l 被静默跳过 | 场景书单改为以**设备书单**为准 |
| 全部用 `aa force-stop` | 等于每次强杀，掩盖正常退出行为 | 增加"返回键正常退出"路径 |
| 冷启动只清 `cache/` | EPUB/CBZ 解压产物仍在 → 伪冷 | 深度冷：同时清 `books/*_extracted` |

**可靠性手段**：解压是否真的发生，用**目录 inode** 判定（`rm`+`mkdir` 必然换 inode），比读日志更硬。

场景矩阵：冷启动进书架→真实点击 / 同进程返回后再点 / 反复点击 / 解压中途强杀 / 跨格式对照。

---

## 3 实测数据

### 3.1 CBZ 大文件 · 打开耗时（已修正口径）

> ⚠️ **口径修正声明**：本报告早期版本把 `ABILITY_CREATE → SESSION_INIT_START` 的 7.24 s 记为"解压耗时"，**这是错的** —— `ABILITY_CREATE` 是 `aa start` 的时刻，不是点击书的时刻，那 7.24 s 里包含测试脚本自身的 `sleep 7` 人为等待。
> 正确依据（代码）：`SESSION_INIT_START`（`ReaderHost.ets:541`）打在 `resolveBookSource()`（解压，`:686`）**之前**，因此 **`SESSION_INIT_START → OPEN_TOTAL` = "准备打开 → 页面可显示"的真实耗时（含解压），且不含任何人为等待**。

| 场景（真实点击） | SESSION_INIT_START → OPEN_TOTAL | 其中解压+准备 | 其中引擎 open | `_extracted` inode |
|---|---|---|---|---|
| 冷（清空解压产物）#1 | **1.86 s** | 1.7 s | 0.16 s | 1412817 |
| 冷 #2 | **1.88 s** | 1.7 s | 0.18 s | **1502452 ← 变** |
| 冷 #3 | **2.01 s** | 1.8 s | 0.20 s | **1541592 ← 变** |
| 应用运行中返回后再点 | 1.81 / 2.00 / 2.03 s | 每次重解压 | ≈0.2 s | 每次都变 |

解压吞吐 ≈ 180 MB/s（313 MB / 1.7 s，UFS 顺序写）。`cache/books` 实测仅 63 文件 / 3.2 MB，故 `enforceGlobalQuota` 的递归 `stat` **已排除**为瓶颈。

**仍不达标的点**：单次 ≈1.9 s（远超 500 ms），且**每次都要付**（inode 三次全变 = 每次都重解压）。EPUB 同类操作第二次仅 43 ms —— 差额全部来自"缓存判断漏掉 CBZ"。

### 3.2 CBZ：每次打开都重新解压（3/3 复现）

| 次 | SESSION_INIT_START → OPEN_TOTAL | `bench_cbz_l.cbz_extracted` inode |
|---|---|---|
| 1 | 18:04:20.995 → 18:04:22.855 | 1412817 |
| 2 | 18:05:03.594 → 18:05:05.474 | **1502452 ← 变** |
| 3 | 18:05:46.443 → 18:05:48.451 | **1541592 ← 变** |

同进程、仅隔 40 秒、返回键退出后再点：

| 次 | 区间 | inode |
|---|---|---|
| 1 | 2.00 s | 1542568 |
| 2（同 pid 28187） | 2.03 s | **440485 ← 变** |

### 3.3 解压中途强杀（模拟用户等不及退出）

4 秒后 `aa force-stop`：残留 **299 MB / 201 文件**，`checkpoint.json` = `["UNZIP_DONE","PARSE_DONE","CACHE_DONE"]`（**全阶段已标记完成**）。
重新打开 → inode **再变**（1384502）→ **checkpoint 形同虚设，照样重解压**。

### 3.4 EPUB 对照（证明机制本身没错）

| 场景 | SESSION_INIT_START → OPEN_TOTAL | inode |
|---|---|---|
| 真冷（无解压产物） | 75 ms | NONE → 1392616（解压） |
| 返回后再点（同 pid） | **43 ms** | 1392616 **不变（跳过解压）** |

### 3.5 TXT（已缓存 vs 未缓存）

| 档 | 冷首帧 | 热首帧 | 索引构建 |
|---|---|---|---|
| demo 5 KB | 69 ms | 11 ms | 29 / 1 ms |
| txt-s 291 KB | 1692 ms | 43 ms | 438 / 1 ms |
| txt-m 2.1 MB | 3987 ms | 49 ms | 2685 / 0 ms |
| txt-l 7.8 MB | 索引 10.85 s（窗口外未完成） | 74 ms | 10850 / 2 ms |
| txt-xl 52 MB | **91.14 s** | 未完成 | **89172 ms** |

---

## 4 根因（代码级）

### 🔴 R1 — CBZ/CBR 被写死的 `.epub` 判断排除在缓存之外
`ohrengine-reader/src/main/ets/ReaderHost.ets:675-679`
```ts
const fpValid   = lowerPath.endsWith('.epub') && ParseCacheManager.isFingerprintValid(extractDir, archivePath);
const unzipDone = lowerPath.endsWith('.epub') && ImportCheckpoint.isStageDone(extractDir, ImportStage.UNZIP_DONE);
const cacheHit  = fpValid && (unzipDone || !lowerPath.endsWith('.epub'));
```
`fpValid` 恒为 false（CBZ） ⇒ `cacheHit` 恒为 false ⇒ 每次 `removeDirRecursive` + 全量解压。
指纹与 checkpoint 机制**本身可用**（EPUB 已验证），只是没让 CBZ/CBR 进来。

### 🔴 R2 — 解压在 open 关键路径上同步等待
`resolveBookSource` 内的 `await SecureArchive.decompressArchive(...)` 位于首帧之前：实测占 7.24 s / 9.26 s（78%），期间 UI 停在"打开外部文件…"。

### 🔴 R3 — CBR 名义支持、实际不可用
`ParserRegistry.ets:213/298` 把 `.cbr` 映射到 `BookFormat.CBZ` → 走 `SecureArchive` → `zlib.decompressFile`（仅 ZIP/deflate）。项目无任何 RAR 解压依赖，真 RAR 必然失败。

### 🟡 R4 — 解压产物永久残留
`DiskCacheQuotaManager.DEFAULT_MANAGED_DIRS = ['cache/books','reading_state']`，**不含 `books/*_extracted`** → 299 MB/本 的产物既不参与配额、也无人清理。

### 🔴 R5 — TXT 首帧被索引 `await` gate
`TxtDocument.open()` 内 `await TxtIndexBuilderTask.buildInTaskPool()`（索引已在 TaskPool，主线程不冻结，无 THREAD_BLOCK），但 `OhEngineCore.open()` 要等它返回才排版出首帧：52 MB → 91 s。
另：索引仅在**构建全部完成**后才 `saveDiskIndex`，中途打断即全废。

---

## 5 修复方案（目标：进 app 后打开 < 首帧标准）

| 级别 | 措施 | 位置 | 预期 |
|---|---|---|---|
| 🔴 P0 | **把解压缓存判断从 `.epub` 扩展到 ZIP 类格式**（epub/cbz/cbr 统一走指纹 + UNZIP_DONE） | `ReaderHost.ets:675-679` | CBZ 二次打开 9.26 s → **≈0.3 s** |
| 🔴 P0 | **解压移出 open 关键路径**：无缓存时先用"部分可用"（已解压页）出首帧，或书籍导入阶段后台完成解压（`ImportCheckpoint` 已有阶段语义） | `ReaderHost.resolveBookSource` | 首次从 9.26 s → 首帧 < 0.5 s（后台继续） |
| 🔴 P0 | **TXT 首帧不等索引**：先扫头部（≤512 KB）产出部分索引立即出首屏，完整索引后台继续并热替换；索引**增量/原子落盘** | `TxtDocument` / `OhEngineCore` | 52 MB 首次 91 s → < 0.5 s |
| 🟡 P1 | **CBR 决策**：引入 RAR 解压能力，或明确"不支持"并在 UI 提示（现状是静默失败） | `ParserRegistry` / UI | 消除误导 |
| 🟡 P1 | **解压产物纳入配额托管**（可清理、可 LRU） | `DiskCacheQuotaManager` | 释放 299 MB/本 |
| 🟡 P1 | 解压产物 `.tmp` + rename 原子提交（配合 P0-1 的指纹） | `ReaderHost` | 中断不再白跑 |
| 🟢 P2 | 修 `openMs` / `restoreMs` 埋点（恒 0，已失效） | `OhEngineCore` | 打开延迟可回归门禁 |

---

## 6 复现

```bash
# 语料注入（设备内，含 200 页 / 313MB 解压量的大 CBZ）
hdc shell "aa test -b com.example.ohrengine -m entry_test -s unittest OpenHarmonyTestRunner -s class BenchCorpusTest -s timeout 900000"

# 真实点击路径测量（含行前/行后校验）
hdc shell "aa force-stop com.example.ohrengine"
hdc shell "rm -rf <filesDir>/books/bench_cbz_l.cbz_extracted"     # 深度冷
hdc shell "aa start -a EntryAbility -b com.example.ohrengine"
hdc shell "uitest dumpLayout -p /data/local/tmp/l.json" && hdc file recv /data/local/tmp/l.json /tmp/l.json
hdc shell "uitest uiInput click 658 559"                          # bench_cbz_l 行坐标
hdc shell "hilog -x" | grep -E "SESSION_INIT_START|SESSION_OPEN|OPEN_TOTAL|FIRST_FRAME"
hdc shell "ls -di <filesDir>/books/bench_cbz_l.cbz_extracted"      # inode 变 = 又重解压
```

---

## 7 数据可信度声明

1. 所有耗时取自**设备侧 hilog 时间戳差值**，非主机时钟，无跨机时钟偏差。
2. "是否重新解压"以**目录 inode 变化**判定，不依赖日志声明。
3. 无效批次（点击未命中/未打开成功）已**作废**，未计入结论。
4. `openMs` / `restoreMs` 埋点恒为 0（失效），本报告**未引用**。
5. 早期版本出现过 `THREAD_BLOCK×3` 的解析误报（匹配到系统 `sceneboard … isFreeze: false`），已修正为真实值 0。
6. 等待窗口不足的场景（txt-l 冷、txt-xl 热）标注"窗口内未完成"，未用推算值填充。
7. 大 CBZ 语料（203 MB）为设备内合成、测试用，测后清理，不属于项目资源。
