# HANDOFF — OhEngine 打开延迟测试（交接给执行 agent）

> 交接时间：2026-10-09 ｜ 交接人：前一执行会话 ｜ 当前设备：HUAWEI Mate 70 Pro+（PLA-AL10，API 26，系统 7.0.0.109，USB 真机，串号 3EV0225122002756）
> **基线约束文件（必读）**：`docs/performance/spec-v2-opening-latency-test.md`（= 用户提供的《OhEngine 打开延迟测试规程 v2》，421 行，项目内副本）

---

## 1 交付物索引

### 1.1 基线 / 规格

| 文件 | 说明 |
|---|---|
| `docs/performance/spec-v2-opening-latency-test.md` | **测试规程 v2（硬约束）**；注意：其 §4「CBZ/CBR」章节在原文中缺失（文档止于 §3.9），CBZ/CBR 只能按 §1 通用条款 + EPUB/TXT 对等条款执行 |
| `tests/bench/README.md` | bench 标准流程与口径（语料、场景、指标定义、反作弊规则） |

### 1.2 已有结论与分析（**结论受限，见 §5**）

| 文件 | 内容 | 可信度 |
|---|---|---|
| `docs/performance/ohrengine-open-latency-audit-20261009.md` | 打开延迟审计（真实用户路径 + 真机）：逐格式达标表、根因 R1–R5、修复方案 | 数据有效；已含一次**口径修正声明**（7.24s≠解压耗时） |
| `docs/performance/code-logic-appendix-20261009.md` | **代码逻辑附录**（13 节，按点击→首帧调用链摊开，含文件行号与问题归属） | 代码级事实，可直接引用 |
| `docs/performance/strict-v2-execution-status.md` | 规程 v2 执行状态：门禁逐条核对、环境控制缺口、状态分级实现、已跑批次、待办计划 | 状态性事实 |
| `docs/performance/bench-real-device-20261009.md` | 真机基准（含模拟器对照）：TXT/EPUB/CBZ/PDF 档位数据、索引线性度 | 早期批次，口径见该文件声明 |

### 1.3 工具（`tests/bench/`）

| 文件 | 作用 | 注意 |
|---|---|---|
| `strict_bench.sh` | **按规程 v2 的合规执行脚本**：L0/L1/L2 状态分级、行前/行后校验、坐标当次解析、点击时刻设备钟配对、inode/files/bytes 判 re_extracted、30s 间隔、CSV 对齐 §1.9、P95 统计剔除预热 | 已验证可跑（EPUB L2 得 351/347/353 ms）；L3 未实现（需重启，人工） |
| `realpath_bench.sh` | 真实点击路径对照脚本（全语料遍历，冷+热各一次） | 口径为 `SESSION_INIT_START→OPEN_TOTAL`，非 T_total |
| `run_bench.sh` | 早期批量脚本（`aa start --ps bookPath` 直开 + 语料注入） | **口径不符规程**（跳过书架），仅供注入/批量冒烟 |
| `parse_bench.mjs` | hilog → metrics.json + report.md 解析器 | `block/crash` 正则已修正（曾误匹配系统 `sceneboard … isFreeze`） |
| `make_corpus.mjs` + `corpus.json` | 本机语料生成与标准清单 | 设备内生成档（cbz-l）以设备侧为准 |
| `bench_epub.mjs` / `bench_txt.mjs` | 桌面参考基准（Node） | 非设备测量，仅参考 |

### 1.4 设备侧语料注入用例（**关键**）

| 文件 | 说明 |
|---|---|
| `entry/src/ohosTest/ets/unit/BenchCorpusOHOSTest.ets` | 在设备内生成/释放标准语料到 `<filesDir>/books`（无 root 设备唯一可行通道）。含 TXT 各档程序化生成、rawfile 释放、大 CBZ 合成（200 页 × 1.5MB ≈ 313MB 解压量，`zlib.compressFile` + 改名，测完自删中间产物） |
| `entry/src/ohosTest/ets/test/List.test.ets` | 新增注册 `benchCorpusTest()` |
| `entry/src/ohosTest/ets/unit/Phase9TxtLazyOHOSTest.ets`、`Phase10PageReadinessOHOSTest.ets` | 修 SDK 兼容：`fileIo.writeTextSync` → `openSync` + `writeSync` + `closeSync`（原代码在 API 26 编译失败） |

### 1.5 原始数据（`tests/bench/results/`）

| 目录 | 内容 | 可用性 |
|---|---|---|
| `20261009-172839/` | 真机 TXT/EPUB 冷热（本机语料，直开口径） | 有效，口径见文件头 |
| `20261009-173136/` | 真机 cbz/pdf/txt-l/txt-xl（含 52MB 索引 89.2s 实测） | 有效 |
| `realpath-20261009-183034/` | 真实点击对照（EPUB 49ms vs CBZ-l 2051ms，inode 判定） | 有效 |
| `strict-bench_epub_s-L2-20261009-184233/` | EPUB L2 验证批（351/347/353ms） | 有效（脚本验证用） |
| `strict-bench_epub_s-L2-20261009-184557/` | EPUB L2 n=12（中断） | **作废**：CSV 列错位（脚本 bug，已修）；勿引用 |

---

## 2 环境事实与硬约束（换会话最容易踩的地方）

1. **hdc 路径**：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`
   注意用户 `~/.zshrc` 里 `DEVECO_HOME=/Applications/DevEco-Studio.app`（**缺 `/Contents`**）→ 脚本需自行补正。
2. **设备连接**：真机 USB 直连（`hdc list targets` 显示串号）；模拟器需 `hdc tconn 127.0.0.1:5555`（不会自动出现）。
3. **无 root 真机**：`hdc file send` 无法写入应用沙箱（`permission denied`），`hdc smode` 报 `undebuggable version`。
   → **语料唯一注入通道 = ohosTest**（`entry_test` 模块与应用同 bundle 共享沙箱）。
4. **应用侧路径视图**：给应用传路径必须用 `/data/storage/el2/base/haps/entry/files/...`；
   shell 侧（ls/rm）用 `/data/app/el2/100/base/<bundle>/haps/entry/files/...`。**两者不可混用**（混用会 `No such file or directory`）。
5. **应用读不到**：`/data/local/tmp`、`/storage/media/100/local/files/Docs`（SELinux）。别指望从这些路径喂书。
6. **重装清理**：`install -r` 覆盖安装会清空应用沙箱 → 语料需重新注入；`--skip-inject` 仅在未重装时可用。
7. **uitest 可用性**：真机 `uitest uiInput click / keyEvent 2 / dumpLayout` 全部可用（**模拟器上触摸注入失效**，仅能截图 + 日志）。
   坐标必须**当次 dumpLayout 解析**，不要硬编码（书列表顺序/位置会变）。
8. **深度冷定义**：清 `cache/` **且** `books/*_extracted`（两个命名都要清：`<name>_extracted` 与 `<file>.extracted`）+ `reading_state` + `*.tmp`；否则 EPUB/CBZ 是"伪冷"。
9. **bash 3.2（macOS）**：`$VAR` 后紧跟中文/全角字符必须写 `${VAR}`，否则 `unbound variable` 直接崩。
10. **heredoc 改脚本必须接 `&&`**：`python3 - <<EOF ... EOF && next_cmd`。否则 assert 失败也会继续执行下一步（本会话因此白跑 11 分钟）。
11. **`zlib.zipFile` 已废弃**（API 9+）且要求 `.zip` 扩展名，传 `.cbz` 静默失败 → 用 `zlib.compressFile` 产出 zip 再改名。
12. **`mkdirSync` 对已存在目录抛错** → 不能当"可写"判据，用探针文件。
13. **macOS 无 `timeout` 命令**。
14. **hilog 关键字必须限定应用 pid**（`grep | grep com.example.ohrengine`），否则 `THREAD_BLOCK` 会被系统 `sceneboard` 噪声污染。
15. **不可读**：设备电量/电池温度/亮度/性能模式（`/sys/class/power_supply/*`、`/sys/class/thermal/*`、`hidumper -s BatteryService` 均无输出）→ 规程 §1.3 的元数据需人工或 Profiler。
16. **模拟器数据仅作功能参考**：排版吞吐模拟器（宿主 M2）比真机快 20–45%，RSS 高 25–50%。

---

## 3 项目代码改动清单（本次会话产生，需评审时注意）

| 文件 | 改动 | 性质 |
|---|---|---|
| `entry/src/ohosTest/ets/unit/BenchCorpusOHOSTest.ets` | 新增（设备内语料注入） | 测试资产 |
| `entry/src/ohosTest/ets/test/List.test.ets` | 注册 `benchCorpusTest()` | 测试注册 |
| `entry/src/ohosTest/ets/unit/Phase9TxtLazyOHOSTest.ets` | `fileIo.writeTextSync` → `openSync/writeSync/closeSync` | **SDK 兼容修复**（原代码 API 26 编译失败） |
| `entry/src/ohosTest/ets/unit/Phase10PageReadinessOHOSTest.ets` | 同上 | 同上 |

**产品代码（`ohrengine-*/src`）未改一行** —— 根因缺陷（R1–R5）只在报告中记录，尚未修复。

---

## 4 打开链路的根因（供修复与验证）

详见 `code-logic-appendix-20261009.md`。摘要：

| ID | 位置 | 问题 |
|---|---|---|
| R1 | `ohrengine-reader/src/main/ets/ReaderHost.ets:675-679` | 三处 `endsWith('.epub')` ⇒ CBZ/CBR 永不命中解压缓存 ⇒ **每次打开都全量重解压**（inode 3/3 变化，实测复现） |
| R2 | `ReaderHost.ets:686` | `await SecureArchive.decompressArchive(...)` 在首帧路径上（解压 313MB ≈ 1.7s 直接计入 T_total） |
| R3 | `ParserRegistry.ets:213/298` + `SecureArchive.ets:105` | `.cbr`→`BookFormat.CBZ`→`zlib`（仅 ZIP），项目无 RAR 依赖 ⇒ 真 CBR 打不开 |
| R4 | `DiskCacheQuotaManager.ets:16` | 托管目录不含 `books/*_extracted` ⇒ 299MB/本 产物永久残留 |
| R5 | `TxtDocument.ets:61/68` + `TxtIndexBuilder.ets:601-665` | 首帧 `await` 索引（52MB→91s）；索引仅完成后落盘且非原子；扫描逐字节 5 遍 + 两遍全文扫描 |

---

## 5 当前状态与阻塞（**执行前必须先处理**）

规程 §1.2 硬性门禁：**未满足不得进入正式测试**。

| # | 门禁 | 状态 |
|---|---|---|
| 1 | 修 `openMs`/`restoreMs`（恒 0，`:OhEngineCore.ets:390`） | ❌ |
| 2 | 埋点统一字段 run_id/format/corpus_id/state/entry/pid/exit | ❌ |
| 3 | 埋点开销检验（开关各 20 次，中位差 <3ms） | ❌（无开关） |
| 4 | 一键 hilog→CSV（限应用 pid） | ✅ `strict_bench.sh` |

其他阻塞：D2 中端真机缺失（规程必选）；L3 需重启设备（需用户授权）；首帧交叉验证（hitrace/录屏）未做；竞品校准未做；规程 §4（CBZ/CBR 章节）缺失。

---

## 6 可直接执行的命令

```bash
# 0) 设备与沙箱
export PATH="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:$PATH"
hdc list targets
F=/data/app/el2/100/base/com.example.ohrengine/haps/entry/files   # shell 视图

# 1) 构建并安装（主 HAP + 测试 HAP）
cd $HOME/Code/Harmony/Project/ohrengine
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
node /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
     /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
     assembleHap --mode module -p product=default --no-daemon
DEVICE=3EV0225122002756 bash tests/bench/run_bench.sh --skip-build --only demo   # 安装+语料注入

# 2) 合规批次（规程口径）
DEVICE=3EV0225122002756 bash tests/bench/strict_bench.sh --corpus bench_epub_s.epub --format epub --state L2 --n 12 --wait 12
DEVICE=3EV0225122002756 bash tests/bench/strict_bench.sh --corpus bench_txt_m.txt  --format txt  --state L2 --n 12 --wait 12
DEVICE=3EV0225122002756 bash tests/bench/strict_bench.sh --corpus bench_cbz_l.cbz  --format cbz  --state L2 --n 12 --wait 25
# 状态：L2（深度冷）/ L1（进程冷）/ L0（同进程热）；次数按 §1.7：L0/L1 ≥20、L2 ≥10（+2 预热）

# 3) 语料重新注入（重装 HAP 后必须）
hdc shell "aa test -b com.example.ohrengine -m entry_test -s unittest OpenHarmonyTestRunner -s class BenchCorpusTest -s timeout 900000"

# 4) 清理设备上的测试语料（573MB）
hdc shell "rm -rf $F/books/bench_* $F/cache $F/reading_state"
```

---

## 7 数据可信度声明（勿越过）

1. 时长一律取**设备侧 hilog 时间戳**；`T_total` 由"点击前后设备 epoch 配对中点 → 首帧设备时刻"计算，**不确定度 = hdc 往返（实测 526–596 ms）**。
2. 是否重解压/重建索引以 **inode / 文件数 / 字节数**判定，日志仅辅证。
3. `openMs`/`restoreMs` **恒 0（埋点失效）→ 任何报告不得引用**。
4. `ABILITY_CREATE` 是 `aa start` 时刻，**不是点击时刻**——曾因此把 `sleep 7` 误算为解压耗时（已在该报告中修正，勿重犯）。
5. 窗口内未完成的场景标注"未完成"，不得填推算值。
6. 判定用 **P95**（§1.7），样本不足时不结论。
7. L2 未处理页缓存（设备无 root，无法 `drop_caches`；1.5× 内存大文件方案不可行）⇒ L2 数据偏乐观，报告须写明。
