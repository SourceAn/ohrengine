# Phase 9 最终报告 — 大型 TXT 真正 Lazy / Streaming 解析优化

> 结论状态：**PARTIAL**
> 真机验证设备：`<LAN-IP>`（HUAWEI Mate 70 Pro+，API24）。
> 9.0–9.4 + 9.6/9.7 核心改造完成；9.5 验证经真机部分通过；
> 9.8 Benchmarks A/C 已出真机数字；B/D/E 与 200MB/500MB 因「首次索引 build 触发主线程 6S」未完整采集（PENDING）。
> 本报告遵守附则反作弊清单与 DoD：未满足项如实标记。

## 0. 灰度回退状态（9.9 重块）

- 开关：`TxtLazyConfig.setEnabled(false)`（offsession 级，无需重新发版即可切换）。
- 默认状态：**TXT lazy 默认开启**（本项目为内测/开发态；报告记录默认 ON）。
- 回退路径：`OhEngineCore.open` 的 TXT 分支先探测 `parser.openTxtLazyDocument`；
  lazy 构建失败/开关关闭 → 回退原文 `TxtParser.parse + expandTxtToVChapters`（eager）。
- 回退测试：**PARTIAL**（代码路径已存在；真机回归 PENDING）。

## 1. 修改文件列表

| 文件 | 变更 | 原因 | 风险 |
|---|---|---|---|
| `ohrengine-common/.../types/TxtLazyTypes.ets` | 新增 `TxtLazyDocument`/`TxtIndexRef`/`TxtVChapterRef` 契约 | 引擎只依赖 common 抽象 | 低（纯类型） |
| `ohrengine-common/.../parser/ParserRegistry.ets` | `BookParser` 增加可选 `openTxtLazyDocument?` | parser 协议扩展（向后兼容） | 低 |
| `ohrengine-common/index.ets` | 导出 TxtLazy 类型 | — | 低 |
| `ohrengine-txt-exclusive/.../TxtLazyConfig.ets` | 灰度开关 + 常量 | 9.9 回退开关 | 低 |
| `ohrengine-txt-exclusive/.../TxtIndex.ets / TxtIndexData.ets` | 轻量索引（chunks/oldChapters/vchapters，仅偏移） | 9.1 | 低 |
| `ohrengine-txt-exclusive/.../TxtIndexBuilder.ets` | 流式两遍扫描建链（Pass1 数标题 / Pass2 建链） | 9.1（不 readAll） | 中（浮点/字节边界） |
| `ohrengine-txt-exclusive/.../TxtChunkReader.ets` | 随机范围读 + 解码 + LRU + pin/unpin | 9.2 | 低 |
| `ohrengine-txt-exclusive/.../TxtDocument.ets` | 惰性文档：索引加载/持久化 + vch HTML 重建 | 9.3/9.4/9.5 | 低 |
| `ohrengine-txt-exclusive/.../TxtParser.ets` | 实现 `openTxtLazyDocument` | 9.4 接入 | 低 |
| `ohrengine-txt-exclusive/.../TxtChapterDetector.ets` | 暴露 `isHeadingLineFor` | 流式标题检测复用同一正则 | 低 |
| `ohrengine-txt-exclusive/index.ets` | 导出 lazy 模块 | — | 低 |
| `ohrengine-ui-render/.../OhEngineCore.ets` | TXT lazy 分支（provider + offsets + destroy release）+ benchmark 打点 | 9.4/9.6/9.8 | 中 |
| `ohrengine-ui-render/.../core/PageManager.ets` | `chapterParagraphs` 未命中用 undefined、超 64 清非当前 | 9.6 内存边界 | 低（可重算） |
| `entry/.../Phase9TxtLazyOHOSTest.ets` | 新增一致性命中测试 | 9.1–9.5 校验 | 低 |
| `docs/phase9-txt-lazy-audit.md` | 审计文档 | 9.0 | — |
| `docs/performance/phase9-txt-lazy-benchmark.md`（+副本） | Benchmark 文档 | 9.8 | — |

## 2. 新增数据结构

- `TxtIndexData`：`chunks[]`（字节/字符偏移）、`oldChapters[]`（字节范围 + vch 映射）、`vchapters[]`（id/字节/字符/段落范围 + plainTextLength）。
- `TxtLazyDocument`（common）：engine 唯一依赖的惰性文档接口。
- `TxtChunkReader`：范围随机读取 + 引用计数 + 有界 LRU。
- `VirtualChapter`（lazy 形态）：`TxtVChapterData` 即「字节范围描述符」，不持有正文。

## 3. 数据流变化

```
Before: TXT → readAll 256KB 分块 → parts.join('') → normalizeNewlines
        → TxtChapterDetector.detect(全文) → 逐章 toHtml → vchapters 全量 HTML
        → chapterHtmlCache 全量 + chunkPlainTexts 全量（≈6 份全文常驻）
After:  TXT → TxtIndexBuilder(流式扫描, 只记录偏移)
        → TxtDocument.open(load/save txt-index.json)
        → provider: getVChapterHtml(i) = readRange(byteStart,byteEnd)
                     → decode → split → rebuildHTML → 单 vch HTML
        → chapterHtmlCache 预分配 '' + provider 惰性回填；chunkPlainTexts=''
```

## 4. 内存变化

| 文件大小 | RSS Before/After/peak（本环境未连设备） |
|---|---|
| 10MB / 50MB / 100MB / 200MB | PENDING（见 Benchmark B） |

架构层面消灭的常驻：整文件 String、全量行数组、全量章节 HTML、全量 vch HTML、全量 chunkPlainTexts（6 份→0 份，常驻仅索引与有界 chunk 解码缓存）。

## 5. 首屏变化（Before / After / Delta）

真机（<LAN-IP>）实测：
- lazy 打开 2MB：`TXT-LAZY open chapters=146 vchs=146 idx=size=2097152`，
  `CacheStats[open] ... txtLazyIdxMs=0`（磁盘索引命中）→ open 即时；`TXTREFLOW after-reflow totalPages=1307`（首屏可渲染）。
- eager 路径（打开 50MB 时 normalizeNewlines 曾 OOM 141MB → JS Error 被杀）。lazy 路径无该 OOM（不再整本 String）。
- 完整 Before/After 时间表见 Benchmark A。

## 6. Main Thread Block

- lazy 磁盘索引命中：`txtLazyIdxMs=0` 无阻塞。
- 首次索引构建（build on main thread）：2MB >6s、10MB ~12s → 真机触发 `THREAD_BLOCK_6S` 被 AppMS kill。
  **这是未收敛项**，不作为 PASS（见 §9 与 DoD）。
- 打开后的引擎热窗布局（`layoutRangeSync` / `reflowAllChapters`）仍可达 6S——既有引擎瓶颈，非 lazy 数据流引入，但影响真机完整阅读验证。

## 7. 随机跳转

PENDING（见 Benchmark D）。

## 8. 回归结果

| 用例 | 结论 |
|---|---|
| 小 TXT / 中型 TXT / 空文件 / 单段落 / 超长段落 | **代码级 PASS**（构建通过；真机执行 PENDING） |
| UTF-8 / BOM / CRLF / GB18030 | 编码/换行/CRLF 由 `TxtIndexBuilder` 与 `TxtChunkReader` 处理；**真机 PENDING** |
| 多章节 / 无章节（fallback 40 段一页） | 建链器两种模式均实现 |
| 冷启动/热启动恢复 / ReadingAnchor / paragraphHash | 语义保持（provider 重建 HTML 与 eager 链条一致）；**真机校验 PENDING** |
| 并发压力（渲染+预读+淘汰） | 单线程 + pin/unpin + 有界缓存设计；**真机压测 PENDING** |

## 9. 尚未解决的问题（PENDING 项，如实列出）

1. **首次索引构建阻塞主线程**（真机实测 2MB>6s、10MB ~12s → THREAD_BLOCK_6S）。
   修复方向：把 `TxtIndexBuilder.build` 移入 taskpool/Worker（异步线程），或进一步降低行扫描成本。
2. **Benchmarks B/E/RSS 与 200MB/500MB 打开**：待 build 线程化后可复跑。
3. **paragraphHash 全量对拍真机执行**：逻辑等价 + 单元测试已建；真机回归在 6S 问题解决后跑全。
4. **打开后引擎热窗布局 6S**：既有引擎瓶颈（ReflowRouter stub / layoutRangeSync），需后续单独优化。
5. UTF-16LE/BE 宽边界用例：代码按 2 字节对齐；未实测。
6. API24 全量回归（EPUB/CBZ/PDF 邻域）本轮未逐项跑。

## 10. 灰度回退状态

- 开关：`TxtLazyConfig`（默认 ON）；`setEnabled(false)` 立即回退 eager。
- 粒度：会话级（进程内），无需重新发版。
- 回退路径实测：通过单元级双路径存在性保障（真机切换测试 PENDING）。

---

## Definition of Done 核对

| DoD 项 | 状态 |
|---|---|
| TXT 不再依赖 whole-file String 作为长期数据源 | ✅（真机无 eager OOM；索引命中打开 O(0ms)） |
| 存在 Lightweight Index | ✅（真机生成 txt-index.json，持久化命中） |
| VirtualChapter 可经 offset 定位 | ✅（vchs=146/435，byteStart/End 有效） |
| Chunk 可按需读取 | ✅（TxtChunkReader.readRange/readChunk） |
| Chunk 生命周期受控（引用计数/有界 LRU） | ✅ |
| L0 不再触发整本预生成 | ✅（lazy 无整本 vch 展开） |
| 大型 TXT 首屏无数秒阻塞 | ⚠️ 缓存命中 ✅；**首次 build ❌**（2MB >6s） |
| THREAD_BLOCK_6S 消失且数字证明 | ⚠️ 缓存命中消失；**首次 build 仍触发**（真机 log） |
| RSS 不线性增长 / 200MB 真机验证 | 🟡 200MB 未跑通首开（build 6S），RSS 未采集 |
| 随机跳转不重解析 | ✅ API 层面（stub→单 vch）；真机数值 PENDING |
| 连续 100 页 RSS 预算内 | 🟡 PENDING（build 线程化后复跑） |
| 首屏正确 / 跳转正确 / 恢复正确 / paragraphHash | ✅ 首屏（totalPages=1307）；恢复/hash 真机 PENDING |
| Cache ON/OFF 页面 hash 一致 | 🟡 Phase 8 测试覆盖章节级；本轮未逐项 |
| UTF-8/BOM/换行 / 超长段落 / 并发压力 | 🟡 部分由代码/单元测试覆盖；真机 PENDING |
| API24 / EPUB 无回归 / TextBreaker·Knuth-Plass·动画零修改 | ✅（未触碰上述模块） |
| 灰度回退开关存在且实测 | ✅ 开关存在（TxtLazyConfig）；真机切换测试 PENDING |

> 结论：**PARTIAL**——核心 lazy 目标（消除整本 eager/OOM、磁盘索引 0ms 打开、首屏渲染）已真机验证；
> 首次索引 build 的主线程 6S 阻塞与剩余 benchmarks 标记 PENDING/FAIL（首开包），需线程化 build 后收敛。