# OhEngine 标准性能 Bench（便携 / 流程化）

> 目的：让**任意一台开发机 + 任意一台 HarmonyOS 设备（真机或 DevEco 模拟器/虚拟机）**用同一套命令、同一套语料、同一套口径，得到**可横向对比**的性能开销数字。
> 数字全部来自应用内埋点（hilog），不接受任何定性描述代替数值。

---

## 1 目录结构

```
tests/bench/
├── README.md            本文档（规范 + 口径 + 用法）
├── corpus.json          标准语料定义（单一事实来源：id / 文件名 / 字节数 / 用途）
├── make_corpus.mjs      本机生成语料（Node，输出到 corpus/）
├── run_bench.sh         一键流程：自检→语料→构建→部署→注入→场景→解析→报告
├── parse_bench.mjs      hilog → metrics.json + report.md
├── corpus/              本机语料产物（可再生，勿入库）
└── results/<时间戳>/    每次运行的日志 / metrics.json / report.md
```

语料注入的设备侧用例：`entry/src/ohosTest/ets/unit/BenchCorpusOHOSTest.ets`。

---

## 2 标准语料（corpus.json）

| id | 目标文件名 | 格式 | 规模 | 来源 | 测什么 |
|---|---|---|---|---|---|
| txt-s | bench_txt_s.txt | TXT | 256 KB | 设备内生成 | 冒烟：open/分页最短路径 |
| txt-m | bench_txt_m.txt | TXT | 2 MB | 设备内生成 | 冷启动索引 + L2/L3 命中对比（对齐历史 benchmark_2mb.txt） |
| txt-l | bench_txt_l.txt | TXT | 7.4 MB | 设备内生成 | 长篇小说规模分页 + 后台 reflow |
| txt-xl | bench_txt_xl.txt | TXT | 50 MB | 设备内生成 | 索引构建 / 内存上界压力 |
| epub-s | bench_epub_s.epub | EPUB | 304 KB | entry rawfile（test.epub） | EPUB 解析 + 排版基线 |
| cbz | bench_cbz.cbz | CBZ | 4 MB | entry rawfile（test.cbz） | 图片书 Image 策略 |
| pdf | bench_pdf.pdf | PDF | 5.3 MB | entry rawfile（微舆.pdf） | PDF 文本层提取 → 可重排 |
| demo | bench_demo.txt | TXT | 5 KB | entry rawfile（demo.txt） | 极小样本边界 |

> 本机侧 `make_corpus.mjs` 还会额外产出 epub-v3 / epub-m（Sherlock EPUB3、妹妹人生中文 EPUB）供**有直推通道的设备**（真机 + root，或手动导入）使用；模拟器走设备内注入，只用上表 8 项。

---

## 3 一键流程

```bash
# 全流程（含构建）：任意机器通用
bash tests/bench/run_bench.sh

# 复用已有 HAP
bash tests/bench/run_bench.sh --skip-build

# 指定设备（真机串号 或 模拟器 127.0.0.1:5555）
DEVICE=127.0.0.1:5555 bash tests/bench/run_bench.sh

# 只跑部分场景
bash tests/bench/run_bench.sh --scenarios cold,warm
```

流程阶段：

| 阶段 | 动作 | 产出 |
|---|---|---|
| 0 自检 | hdc/node/设备探测、记录型号·API·版本 | `meta.json` |
| 1 语料 | `make_corpus.mjs` 本机生成 | `corpus/*` |
| 2 构建 | hvigor assembleHap | `entry-default-signed.hap` |
| 3 部署 | uninstall + install + 沙箱目录就绪 | `run.log` |
| 4 注入 | ohosTest 设备内生成/释放到 `<filesDir>/books` | `BENCH_CORPUS*` 埋点 |
| 5 场景 | 逐样例 冷启动/热启动 + `--ps bookPath` 直达 + RSS 采样 | `logs/*.txt`、`scenarios.csv` |
| 6 解析 | `parse_bench.mjs` | `metrics.json` |
| 7 报告 | — | `report.md` |

---

## 4 设备侧的三个硬约束（实测结论，2026-10）

1. **无 root 的设备无法从主机写应用沙箱。**
   `hdc file send` 到 `<filesDir>` 报 `permission denied`（目录 0700、属主为应用 uid），
   `hdc smode`（root 模式）在非 debug 版返回 `Cannot set root run mode in undebuggable version`。
   → 语料注入唯一可靠通道 = **应用同 bundle 的 ohosTest 进程**（BencCorpusOHOSTest）。
2. **应用读不到主机可写目录。**
   `/data/local/tmp`、`/storage/media/100/local/files/Docs` 都不行：
   前者应用无权限（`Stat failed`），后者 shell 也无法在其下建目录（SELinux）。
   `--ps bookPath` 参数本身有效（`SESSION_OPEN book=<path>` 已复现），但路径必须落在应用可读范围。
3. **模拟器上 `uitest uiInput` 触摸注入不生效**（历史实测），因此翻页/字号交互场景
   走**引擎级 OHOS 测试**或**人工验证清单**，脚本不假装能自动翻页。

---

## 5 指标口径（全部来自埋点，禁止估算）

| 指标 | 埋点来源 | 单位 | 说明 |
|---|---|---|---|
| openMs | `CacheStats[<tag>] … openMs=` | ms | open() 总耗时（引擎自报） |
| restoreMs | 同上 `restoreMs=` | ms | 阅读位置恢复耗时 |
| txtLazyIdxMs | 同上 `txtLazyIdxMs=` | ms | TXT 惰性索引构建/加载（0 = 磁盘索引命中） |
| t_anchor_ms | `COLDSTART ANCHOR_RESOLVED` | ms | 以 `SESSION_OPEN` 为 T0 的锚点页就绪延迟（**设备钟**，避免主机时钟偏差） |
| t_firstFrame_ms | `COLDSTART FIRST_FRAME` | ms | 首帧可见延迟 |
| totalPages | `OPEN_TOTAL page=… total=` | 页 | 全书页数（分页结果） |
| LAYOUT_CHAPTER total | `LAYOUT_CHAPTER … total=` | ms | 单章排版总耗时（p50/p95/max） |
| COLDSTART 后台章 | `COLDSTART BACKGROUND_CHAPTER … ms=` | ms | 后台 reflow 每章耗时 |
| RSS | `/proc/<pid>/status VmRSS` | KB | 进程常驻内存（`dumpsys`/`hidumper` 在设备 shell 不可用） |
| flip avg/max | `finishFlip … avgMs/maxMs` | ms | 翻页动画每帧 JS 提交耗时（若该路径有埋点） |
| 稳定性 | `THREAD_BLOCK*` / `APPFREEZE` / crash | 次数 | 主线程阻塞与崩溃计数 |

**反作弊规则**：报告只允许出现上表指标；缺失（未触发）标记 `—`，不得用形容词替代；
同一指标的目标值与实测值必须分列。

---

## 6 单点复跑（调试用）

```bash
HDC="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc -t 127.0.0.1:5555"
B=com.example.ohrengine; F=/data/app/el2/100/base/$B/haps/entry/files

# 注入语料（设备内）
$HDC shell "aa test -b $B -m entry_test -s unittest OpenHarmonyTestRunner -s class BenchCorpusTest -s timeout 600000"
$HDC shell "ls -l $F/books"

# 冷启动单场景
$HDC shell "rm -rf $F/cache"
$HDC shell "aa force-stop $B"; $HDC shell "hilog -r"
$HDC shell "aa start -a EntryAbility -b $B --ps bookPath $F/books/bench_txt_m.txt"
sleep 12; $HDC shell "hilog -x" > cold-txt-m.txt
```

---

## 7 换机 / 换平台

| 变量 | 默认 | 说明 |
|---|---|---|
| `DEVECO_HOME` | `/Applications/DevEco-Studio.app/Contents` | DevEco 安装根（Linux/Windows 改这里） |
| `HDC` / `NODE` / `HVIGOR` | 由 DEVECO_HOME 推导 | 可单独覆盖 |
| `DEVICE` | 自动取 `hdc list targets` 第一个 | 真机串号 / 模拟器 `127.0.0.1:5555` |
| `WAIT_SEC` | 12 | 单场景采集等待（大书适当加大） |

模拟器启动：

```bash
/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator -list
/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator -start "Mate 70 Pro+"   # 后台长驻
hdc tconn 127.0.0.1:5555     # 模拟器 hdc 不自动可见，需手动 tconn
```
