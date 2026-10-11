# Phase 8.0：分析决策表（只读，不写核心代码）

> 依据《08-Phase8-偏差修正-直开链路-多模态验收-Benchmark.md》§7 步骤 1。
> 目标：核对当前加载行为，产出本 Phase 决策表。

## 1. 关键事实核对（代码实证）

### 1.1 Parse 是否为全书 eager（D1 前提）
- `EpubParser.parse()`（EpubParser.ets:146）读全书 spine：`readTextFileSync(fullPath)` 逐章同步读入内存（:157），全部 XHTML 存
  入 `ParsedBook.chapters[].content`。**是全书 eager**，且 parser 结构上不可按章改造（00 禁止重写解析器）。
- L0 缓存：`ParseCacheManager.saveParsedBook` = 整本 `JSON.stringify(book)`（ParseCacheManager.ets:162-165）；`loadParsedBook`
  = `readTextSync` 整本 + `JSON.parse` 整本（:102-112）。**命中缓存时整书 JSON 反序列化**，200MB+ 首屏必卡。
- `OhEngineCore.open`（:545-561）：`totalChapters` 全部章 HTML push 进 `chapterHtmlCache`、全部 `plainText` push 进
  `chunkPlainTexts/Lengths`。**即使 L0 分块，open 仍全书展开**——问题不只在持久化格式，还在 engine 的展开点。
- 结论：要满足"200MB+ 首屏不整本加载"，必须同时改 ① L0 持久化(multi-file) + ② engine open 的**按需加载**（chapterHtmlCache
  改为按需填充，chunkPlainTextLengths 改为增量）。

### 1.2 TXT vchapter（D2）
- TxtParser：无 vchapter；href=`chapter-N` / `page-N`（TxtParser.ets:100,120）；整本读入内存（≤5MB 同步，>5MB 256KB
  流式 join 全文）；段落经 `TxtParagraphSplitter` 生成 `<p>` HTML。
- 现有 `extractParagraphs`（ReadingStateTypes）已能按块级边界切段落 → **无需重写 TxtParser**，在 engine 展开层
  （OhEngineCore open）对 TXT 的章节内容按 5000–10000 chars 段落边界切 `vchapter_XXXXX`。
- 目标书目《一念永恒》：7.4MB、GB18030 ≈ 3,957,539 chars → 可作 5m-char 样本（3.96m 接近 5m 档）＋
  demo.txt（5472B）作小数样本。

### 1.3 ImportCheckpoint（D3）
- 现状确认为"只写不读"：`markStage` 在 ReaderHost 写了 UNZIP/PARSE/CACHE_DONE，`isStageDone` 零调用。
- 真实消费点可选：**ReaderHost.resolveBookSource** 解压前 `isStageDone(UNZIP_DONE)&&isFingerprintValid` → 跳过重复解压（已有指纹逻辑，
  checkpoint 与指纹并作"已解压+未改文件"的强证据）；以及 OhEngineCore open 前 `isStageDone(PARSE_DONE)` + L0 分块命中 → 仅加载
  metadata + 热窗章（不全书反序列化）。

### 1.4 直开链路（§3）
- 现状：Bookshelf/DebugBookshelf 先拷贝 rawfile → filesDir → `pushUrl{bookPath}` → Index → ReaderHost(bookPath)。
  `ReaderHost.resolveBookSource` 已含拷贝/解压/指纹逻辑——**加载职责实际在 ReaderHost 而非书架 UI**（书架只做"准备源文件+导航"），
  直开只需 expose 一个引擎或 ReaderHost 侧 API：**给定任意路径 → resolveBookSource + openAndLoad**（TT同一条链路）。
- 同书一致性：直开与书架开同一书籍时，`bookPath` 相同→ `resolveBookSource` 同指纹/同缓存目录/同 checkpoint → 自动一致。
  测试证明用同一 EPUB/TXT 两条路径对拍 CacheKey/恢复位置。

### 1.5 API/工具
- 真机：<LAN-IP>（targetApi 60101024；compatible 26.0.0→API24 语义 OK）。
- 现有 bench 工具：`CacheStats`（L3/L2/L2miss/liveLayout/layoutMs）、`getCacheHitSummary`、`getPageCacheSaveStats`、
  `computeCurrentPageLogicalTextHash`。缺：**精确 ms 计时**（进程内需加 `performance`/Date.now 锚点）与 RSS 读取
  （`os.getProcessMemoryInfo`? 检查 API 可用性 – 若无，记录"设备不支持/降级"）。

## 2. Phase 8 决策表

| 议题 | 决策 | 说明/替代 |
|---|---|---|
| D1 L0 | **方案 B：持久化分块 + engine 按需加载组合**——ParseCacheManager 增加 `metadata.json`（TOC/chapterIndex/offset index/fingerprint）+ `chapter_{i}.json`（单章）读写；`OhEngineCore.open` 改为**只反序列化 metadata + 目标章 ± 热窗**，chapterHtmlCache/chunkPlainTexts 按需填充 | parser 不可改（00 约束），仅持久化分块不足以达标：engine 展开点也必须改。P0 冷启只读 meta + 热窗章 |
| D2 TXT vchapter | **engine 展开层切分**（不重写 TxtParser）：TXT 章节内容按 5000–10000 chars 段落边界切 `vchapter_XXXXX`；ReadingState/进度/跳转/缓存统一 vchapter ID；旧 `chapter-N` ReadingState 恢复时安全映射（fallback 到首个 vchapter 或原章节首页） | 2026: 段落边界用 `extractParagraphs` 结果 + 累计长度切分 |
| D3 checkpoint | **消费点落在 ReaderHost + OhEngineCore**：①解压前 `isStageDone(UNZIP_DONE)&&isFingerprintValid` 跳过重解压（日志为证）；②open 前 `isStageDone(PARSE_DONE)` 且 L0 分块 metadata 命中 → 跳过全书反序列化 | 若 ② 无收益（即 ① 已含全部语义）则仅保留 ①并记录 |
| 直开 | **ReaderHost 侧 expose `openBookByPath(path)`**：resolveBookSource→openAndLoad（与书架同链路，同一 resolve）；书架仅"源文件准备+导航"职责不变 | 与书架开同书时自动一致（同 bookPath） |
| 多模态 | screenshot-vision-analysis 技能（gpt-4o-mini 视觉判定）+ 固定书目清单 ≥5 场景 | 无法截图则降级 text-hash 对拍+手动 |
| Benchmark | 新增轻量计时锚点（open 阶段 ms、restore ms、font change ms、跳转 ms），RSS 用系统 API 检查可用性；≥3 采样中位数；固定书目：EPUB <5MB（test.epub≈2.2MB）、TXT 100k/1m（造样本）、5m（一念永恒 3.96m→按 5m 档口径记录）；>200MB 与 50–200MB 样本**在设备存储/网络受限时如实 ⚠️** | 无法造 200MB 样本时：记录"未测 + 原因"，禁止臆测 |
| CacheKey 兼容 | Phase 8 不改 CacheKey 语义；L0 分块属持久化格式变更 → ParseCacheManager 文件命名升级（.parsed.json→旧版识别+迁移删除，避免 stale） | PageCache 六元组不变 |

## 3. 本 Phase 执行顺序（对齐 §7）

1. 8.0 ✅（本文件）
2. 8.1：D1（ParseCacheManager 分块 + OhEngineCore 按需加载）→ compile + test + 证据
3. 8.1：D2（vchapter 切分 + 迁移）→ compile + test
4. 8.1：D3（checkpoint 消费点）→ compile + test
5. 8.2：直开 API + 同书一致性测试
6. 8.3：多模态验收（≥5 场景）
7. 8.4：Benchmark（造样本 + ≥3 采样）
8. 8.5：D8 回归 + Cache ON/OFF 对拍 + DoD 重标 + final 报告

## 4. 遗留风险（Phase 8 开始前明示）

- D2 会造成 TXT 页数显著变化（vchapter 更多、更小）——需同步确认 totalPages 口径（Phase 2 的 stub 估算依赖章数）。
- vchapter 切分需与 `chapterHtmlCache`/`paginatedChapters` 索引逐一对应，避免 CacheKey 不稳定（切分确定性=按段落边界+固定 chars 上限，同输入同输出）。
- TXT 整本读内存仍是现实（P2 独立任务），本 Phase 不解决，如实记录。
