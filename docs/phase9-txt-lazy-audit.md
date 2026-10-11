# Phase 9.0 — TXT 数据流审计（Gate：未完成不允许进入 9.1）

> 生成时间：2026-09-04
> 审计对象：工作区源码
> 结论均带文件路径 + 行号/函数名。数据流图中标注每步数据结构与量级。

---

## 1. 当前 TXT 数据流（打开文件 → 显示第一页）

```
ReaderHost.openAndLoad (ohrengine-reader/src/main/ets/ReaderHost.ets:562)
   └─ engine.open(bookBasePath)  // TXT: bookBasePath = .txt 文件本身 (ReaderHost.ets:506)
        └─ OhEngineCore.open (ohrengine-ui-render/src/main/ets/OhEngineCore.ets:493)
             ├─ ParserRegistry.resolveByExtension('.txt') → TxtParser (OhEngineCore.ets:505)
             ├─ parser.parse(bookBasePath) (OhEngineCore.ets:587)
             │    └─ TxtParser.parse (ohrengine-txt-exclusive/src/main/ets/TxtParser.ets:41)
             │         ├─ safeFileSize() stat (TxtParser.ets:42)
             │         ├─ readTextFileChunked(fileSize>5MB) (TxtParser.ets:188)
             │         │    = 256KB 分块异步读 + TextDecoder{stream:true} 流式解码
             │         │      → parts: string[] → parts.join('')  ⇒ 全文件 String（UTF-16 内存≈2×文件字节）
             │         │   或 readTextFileSync (≤5MB) (TxtParser.ets:152) ⇒ 同样全文件 String
             │         ├─ buildChapters(normalizeNewlines(content)) (TxtParser.ets:47)
             │         │    ├─ normalizeNewlines: 全文本正则替换 (TxtParser.ets:127) ⇒ 第二个全文本 String
             │         │    ├─ TxtChapterDetector.detect(normalizedText) (TxtChapterDetector.ets:72)
             │         │    │    = normalizedText.split('\n') ⇒ 全量行数组（大对象拆小对象，eager）
             │         │    └─ per chapter: TxtParagraphSplitter.split(body) + toHtml (TxtParser.ets:99)
             │         │         ⇒ 全量章节 HTML（ChapterData.content = 整个正文的 <p> HTML）
             │         └─ 产出 ParsedBook.chapters = 全量章节 HTML ⇒ 全书正文第三次全量驻留
             ├─ TXT 分支: expandTxtToVChapters(parsedBook) (OhEngineCore.ets:596, 800)
             │    = 逐章 extractParagraphs(ch.content) + buildVChapters()
             │      切为 8000±2000 chars 的 vchapter_XXXXX (VChapterTypes.ets:88)
             │      ⇒ vchapters[] 全文 HTML：全书正文第四次全量驻留（每次 5 章让步，不阻断但不减少内存）
             ├─ chapterHtmlCache 填充 (OhEngineCore.ets:599-607)
             │    = parsedBook.chapters[i].content 全量拷贝进 PipelineManager.chapterHtmlCache (PipelineManager.ets:88)
             │      ⇒ 全书正文第五次驻留
             ├─ chunkPlainTexts 填充 (OhEngineCore.ets:604-606)
             │    = extractPlainText(html) 每 vchapter ⇒ 全书正文第六次驻留
             ✓ 另有 chunkPlainTextLengths 数字数组（微小）
             ├─ buildPlainPublication (OhEngineCore.ets:625, 774) — vch 标题目录（微小）
             ├─ layoutRangeSync(target±2) (OhEngineCore.ets:717) — 仅热窗分页 ✅
             └─ restoreLastReadingState (OhEngineCore.ets:733) — L1 恢复
```

## 2. 产生 whole-file String 的步骤

| 步骤 | 位置 | 说明 |
|---|---|---|
| `readTextFileChunked` 的 `parts.join('')` | TxtParser.ets:223 | 全文件一个 String。流式解码只是分块读，字符串仍整体拼接 |
| `normalizeNewlines(content)` | TxtParser.ets:47/127 | 全文本替换生成第 2 个全量 String（瞬时翻倍） |
| `ParsedBook.chapters[].content` | TxtParser.ets:89-125 | ChapterData.content 全量章节 HTML——**长期驻留**（解析产物返回后即被持有） |

> 旧实现（Phase 8 之前）通过 `readTextFileSync` 一次读入；现状改成了分块异步读，但**聚合结果同为全文件 String**——属于附录反作弊清单第 1 条"只把 readAll 放到后台线程"的变体。

## 3. 产生全量 paragraph 的步骤

- `TxtChapterDetector.detect`：`normalizedText.split('\n')` 生成全量行数组（TxtChapterDetector.ets:73），以及逐章 body（joinLines，TxtChapterDetector.ets:128）——行数组瞬时、body 字符串全量驻留（进入 ChapterData）。
- `TxtParagraphSplitter.split/toHtml`：逐章生成全量 `<p>` 段落文本 + HTML（TxtParser.ets:99, TxtParagraphSplitter.ets:23-46）。
- 引擎侧 `expandTxtToVChapters`：`extractParagraphs(ch.content)`（OhEngineCore.ets:813）再次对全部章节做段落切分 + `buildVChapters`（OhEngineCore.ets:818）。

## 4. 产生全量 vchapter 的步骤

- `expandTxtToVChapters`（OhEngineCore.ets:800-854）：每 5 章让步一次（setTimeout 0，为免 THREAD_BLOCK_6S），但**最终 vchapters[] 覆盖全书**，每个 vchapter 持有 `d.html`（全量文本）。这是当前最严重的全量驻留点：既大又"慢但全做"。

## 5. THREAD_BLOCK_6S 来源

- 主链路 `TxtParser.buildChapters`（detect + per-chapter split/toHtml + normalizeNewlines）在 `parser.parse` 的 await 返回后**同步**执行（TxtParser.ets:47），对 200MB 级文本为秒级阻塞。
- `expandTxtToVChapters` 虽每 5 章让步，但已由 Phase 8 Benchmark 实测出现 `THREAD_BLOCK_6S`（OhEngineCore.ets:796 注释引用 Benchmark 实测）。
- `chapterHtmlCache`/`chunkPlainTexts` 填充循环（OhEngineCore.ets:599-607）为全书无让步循环——大书此循环本身即二次阻塞。

## 6. 长期持有全文的对象（类名 / 字段名 / 生命周期）

| 持有者 | 字段 | 生命周期 | 量级 |
|---|---|---|---|
| `ParsedBook` | `chapters[].content` (ChapterData) | open 期间（parse 返回后→被拷贝进 cache 后 GC 前） | 全量 HTML |
| `OhEngineCore` → `PipelineManager` | `chapterHtmlCache: string[]` (PipelineManager.ets:88) | open → destroy | 全量 HTML（第 5 次驻留） |
| `OhEngineCore` → `PageManager` | `chunkPlainTexts: string[]` (PageManager.ets:105) | open → destroy。**注意：当前写入后无任何读取方**（全仓 grep 仅 push/clear，无 read） | 全量 plain text（第 6 次驻留，纯浪费） |
| `OhEngineCore` → `PageManager` | `chunkPlainTextLengths: number[]` (PageManager.ets:104) | open → destroy | 微小（数字） |
| `OhEngineCore` → `PageManager` | `chapterParagraphs: string[][]` (PageManager.ets:116) | 按需填充，open → destroy（lazy 但仍可增长） | 段落实文本，逐章 |
| `PageManager` | `oldChapterToVchapterStart/counts` (PageManager.ets:111-113) | open → destroy | 微小（vch 映射） |

## 7. L0 当前缓存什么

- L0 = `ParseCacheManager` 分块解析缓存（`ParseCacheManager.ets`）：仅 **EPUB** 启用（OhEngineCore.ets:547 `parser.format === BookFormat.EPUB && ParseCacheManager.isChunkedValid(...)`）。
- TXT **完全没有参与 L0**：TXT 不走 `saveParsedBookChunked`，索引（TOC/chapterIndex/plainTextLength 的 meta）与章节 JSON 均不存在。
- TXT 的磁盘层只有 L2 `PageCacheManager`（`<book>.pagecache` 目录，按 vch 章节号读写分页结果，OhEngineCore.ets:662）。**没有任何 TXT 的 byte-offset/行索引类缓存。**

## 8. ReadingAnchor 如何定位 TXT

- 身份模型（ReadingStateTypes.ets:5-16）：`ReadingAnchor = { chapterId, paragraphIndex, paragraphHash, charOffset }`。
- TXT 现状（Phase 8 D2 后）：`chapterId = 'vchapter_XXXXX'`（expandTxtToVChapters 产出的 id，VChapterTypes.ets:55 / OhEngineCore.ets:822）。
- `paragraphIndex` = vchapter 内段落下标；`paragraphHash` = extractParagraphs 结果的 fnv1a32（ReadingStateTypes.ets:70）；`charOffset` = 段落内 UTF-16 偏移（ReadingStateTypes.ets:41-42）。
- 恢复：`PageManager.restoreReadingState`（PageManager.ets:1193）→ `resolveChapterId`（PageManager.ets:1056，vchapter_XXXXX→ordinal）→ `getChapterParagraphs`（PageManager.ets:1017，extractParagraphs(html)）→ hash 校验/邻域搜索 → `navigateToChapterCharOffset`（PageManager.ets:1269，行文本片段定位；兜底 charRange 中点）。
- **无 byte offset 概念**；无「文件字节位置 → ReadingAnchor」映射。Phase 9 若引入 byte offset，必须与 UTF-16 charOffset 语义严格区分并保持 paragraph-relative 语义不变。

## 9. TextBreaker 的输入

- 输入：`PipelineManager.processNextInQueue`（PipelineManager.ets:514-515）→ `htmlParser.parse(html)` + `buildRenderTree`（DOM），其中 html 来自单章 `chapterHtmlCache/getChapterHtml`（PipelineManager.ets:475）。
- 即：TextBreaker 的输入是**单章 HTML**（经 DOM 解析后的 RenderNode 流），不要求全局连续文本——**它只消费单章内容**。
- 结论：lazy 化后只要 `getChapterHtml(chapterIndex)` 返回的仍是「该章同一段 HTML 串」，TextBreaker/分页/动画链路**零修改**。这是最小插入点的依据。

## 10. 最小修改点

- 唯一真实插入点：**`PipelineManager.chapterHtmlProvider`**（PipelineManager.ets:93，Phase 8 D1 已存在，EPUB 分块缓存在用——`getChapterHtml` 懒回填逻辑 PipelineManager.ets:254-273 已就位）：
  - `chapterHtmlCache[]` 预分配空串 + 注册 provider = 「按需取内容」的既有机制，TXT 直接复用即可。
- 上游必须替换：TXT 分支的 `parser.parse()` + `expandTxtToVChapters()` + `chapterHtmlCache/chunkPlainTexts` 全量填充（OhEngineCore.ets:587-607）→ 改为 `TxtDocument`（索引 + 按需读取）+ provider。
- 修改范围量化：引擎层 diff 应仅限 open() 的 TXT 分支与少量字段初始化；TextBreaker/分页/动画 diff = 0。

## 11. 现有 benchmark instrumentation

- 存在：`benchOpenStart/benchOpenMs/benchRestoreMs`（OhEngineCore.ets:131-136），destroy 时经 `logCacheHitSummary` 输出 openMs/restoreMs（OhEngineCore.ets:244）。
- **缺失**：T0–T3 分阶段打点（元数据/索引/目标块/首屏）、RSS 采样、主线程最长阻塞、跳转耗时、连续 100 页翻页延迟。
- Phase 9.8 将新增 `TxtBenchMarks` 轻量埋点（毫秒打点 + hilog），并用手动设备采样（hdc dumpsys meminfo）补 RSS。

---

## 附：反作弊自我对照

| 违禁项 | 现状结论 |
|---|---|
| 1. readAll 移到后台线程 | ⚠️ 部分违反：分块读在后台，但结果聚合为全文件 String |
| 2. 全文放进 L0 Cache | 违反：chapterHtmlCache 承载全量 HTML（新名字而已） |
| 3. 全文拆成很多 String（split('\n') 等） | 违反：TxtChapterDetector.split('\n') + 全量 paragraph/vch HTML |
| 4. 首屏后立即生成整本 cache | 未触发：热窗仅 ±2 章（layoutRangeSync，OhEngineCore.ets:717）✅ |
| 5. 只测 10MB | 既往 benchmark 覆盖 200MB（OhEngineCore.ets:796 注释）✅ |
| 6. 只看截图 | Phase 7/8 已有 logical-page-text-hash（OhEngineCore.ets:261）✅ |
| 7. 为 lazy 改分页算法 | 未发生 ✅ |

**Phase 9 目标：消除第 1/2/3 项；4/5/6/7 保持。**
