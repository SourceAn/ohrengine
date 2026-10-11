# Phase 8 报告（中间 8.1–8.3）：偏差修正 + vchapter + Checkpoint + 直开 + 多模态

> 依据《08-Phase8-*.md》。设备：<LAN-IP>（MRO-W00，HarmonyOS 6.1.0.135，**API24**）
> —— 工程 `compatibleSdkVersion` 由 26.0.0 调整为 **6.1.1(24)**（符合 00 的 API24 约束）。

## D1 ✅（L0 分块 + engine 按需加载）

### 修改
- `ParseCacheManager`：新增分块格式 `parse/meta.json`（format/strategy/book/cssTexts/
  imagePaths/chapters[title,href,plainTextLength]/fingerprint）+ `parse/chapter_{i}.json`
  （单章 title/href/content）；`isChunkedValid/loadParseMeta/loadParseChapter/
  saveParsedBookChunked/rehydrateBook`；旧 `.parsed.json` 迁移删除。
- `PipelineManager`：新增 `chapterHtmlProvider`（惰性注册）+ `getChapterHtml(chapterIndex)`
  （缓存命中→provider 按章加载→回填）；全部 `chapterHtmlCache[...]` 读点改走
  `getChapterHtml`（processNextInQueue/relayoutSingleChunk/layoutRangeSync/
  layoutAllChaptersSync/loadCssFromChapterHtml/PageManager 3 处）。
- `OhEngineCore.open`：EPUB 且 `isChunkedValid` → 只反序列化 meta + 章节索引
  （chunkPlainTexts 置空、Lengths 用 offset index）；`chapterHtmlCache` 预分配 ''
  + 注册 provider；miss 时 parse + `saveParsedBookChunked`。

### 修复（调试中发现的两个 mkdirSync + 一个 invalidate 链路坑）
1. `saveParsedBookChunked` / `ReadingStateStore.save` / `PageCacheManager.saveChapter`：
   HarmonyOS `mkdirSync(path,true)` 在**双级父目录缺失**时失败——逐级 stat/mkdir。
2. **`PageCacheManager.invalidate`**：原递归删整个缓存目录，**连带删除刚写入的 L0
   `parse/`**（首次打开时 saveChunked→invalidate(删目录)→L2 重写 的时序坑）。
   改为只删 L2 产物（meta.json/chapter_*.json），**保留 parse/**。
3. **`getChapterHtml` 空串不再命中**：chunked 命中预分配 `''` 被视为"未加载"，
   改走 provider（修复 EPUB 正文白屏回归）。

### 真机证据（3.7 API24）
- 首次打开：`.../cache/books/test.epub/parse/meta.json` + `parse/chapter_*.json` 生成；
  L2 `meta.json`+`chapter_*.json` 与 L0 共存（32 条目）。
- 二次打开：打开正常（走 chunked 命中，不整本反序列化）。
- 修复前后对比：修复前首次打开后 parse/ 被 invalidate 删除（白屏），修复后共存。

## D2 ✅（TXT vchapter）

- 新增 `VChapterTypes.ets`：`buildVChapters`（5000–10000 chars + 段落边界切分，
  确定性）、`vchapterId`（vchapter_XXXXX）、`oldChapterIndexFromId`。
- `OhEngineCore.expandTxtToVChapters`：TXT 全量 parse 后引擎层展开为 vchapter
  （href=vchapter_N，title 续章"（续）"）；`PageManager` 新增
  `oldChapterToVchapterStart/Counts` 映射（恢复时旧 chapter-N → vchapter 首段）。
- `PageManager.resolveChapterId`：支持 `vchapter_` 前缀解析 + 旧 chapter-N/page-N
  迁移映射。
- **真机证据**：reading_state 为 `{"chapterId":"vchapter_00000","visualPageIndex":1}`；
  TXT 打开/翻页/恢复正常；旧 chapter-N 状态不需手工迁移（resolve 自动）。

## D3 ✅（ImportCheckpoint 消费点）

- `ReaderHost.resolveBookSource`：`fpValid && (unzipDone || 非EPUB)` → 跳过重复解压
  （UNZIP_DONE checkpoint + fingerprint 双证；缺失 checkpoint 时回退旧行为）。
- **修复**：`markStage` 的 `mkdirSync(path,true)` 在目录已存在时抛 "File exists"
  被 catch 后**提前 return**（checkpoint 永不写入）→ stat+mklater 修复。
- **真机证据**：`test.epub_extracted/checkpoint.json`
  `{"stages":["UNZIP_DONE","PARSE_DONE","CACHE_DONE"]}`。

## 直开链路 ✅（§3）

- 事实确认：Bookshelf 与 DebugBookshelf **都** `pushUrl('pages/Index',{bookPath})`
  → Index → `ReaderHost(bookPath)`。加载/预处理职责在 ReaderHost（resolveBookSource+
  openAndLoad），**书架只是入口**；任意文件路径直开 = 同一条 ReaderHost 链。
- 同书一致性：同 bookPath → 同 cacheDir（basename）/ sourcePath / bookId（metadata），
  checkpoint stage / reading_state 一致。已在 3.7 设备经 DebugBookshelf（直开路径）
  验证 reading_state/bookId/checkpoint/parse/L2 全部生成且稳定。

## 多模态排版检验（8.3，5 场景）⚠️ 降级说明

- 视觉判定尝试：`screenshot-vision-analysis` skill → OpenRouter gpt-4o-mini
  **HTTP 402（Insufficient credits）** → 按 skill 规定**不臆造判定**，降级为：
  **本模型直接读图**（成功）+ 手动检查 + text-hash 对拍（后续 8.5 完成）。
- 截图证据（设备 snapshot_display 2800×1840 保存于本会话临时目录）：

| # | 场景 | 判定 | 说明 |
|---|---|---|---|
| 1 | TXT 首屏渲染（第1页） | ✅ PASS | 正文清晰、段落/对话引号正常、页码 1/3 |
| 2 | EPUB 插图+日文竖排文字 | ✅ PASS | 插图无损坏、竖排注音正常、页码 3/197 |
| 3 | 字号增大后重排 | ✅ PASS | 3/197→4/241（197→241 页 = 字号放大重排生效），新页正常 |
| 4 | TXT 正文章节边界（vchapter 下） | ✅ PASS | 第2页正文/对话/段落全正常，页码 2/3 |
| 5 | 连续翻页边界（无跳页/空白/重叠） | ✅ PASS | 1/3→2/3→3/3→回退 1/3，页码连续 |

- 总结：5/5 PASS；无 FAIL。OpenRouter 不可用的降级与 manual 判定已记录。

## 修改文件表

| 文件 | 变更 |
|---|---|
| `ohrengine-common/.../service/ParseCacheManager.ets` | 分块格式 + 4 新方法 + mkdir/invalidate 修复 |
| `ohrengine-common/.../service/PageCacheManager.ets` | invalidate 保留 parse/；saveChapter mkdir 逐级 |
| `ohrengine-common/.../service/ImportCheckpoint.ets` | markStage mkdir 修复（stat 先行） |
| `ohrengine-common/.../service/ReadingStateStore.ets` | mkdir 逐级 |
| `ohrengine-common/.../types/VChapterTypes.ets` | 新增 vchapter 切分/ID/旧章解析 |
| `ohrengine-common/index.ets` | 导出 ParseMeta/ParseChapterIndex/ParseChapterChunk/PARSE_CHUNK_DIR/VChapter 系列 |
| `ohrengine-ui-render/.../core/PipelineManager.ets` | `chapterHtmlProvider` + `getChapterHtml` + 读点迁移 |
| `ohrengine-ui-render/.../core/PageManager.ets` | getChapterHtml 读点迁移 + vchapter 映射字段/resolveChapterId |
| `ohrengine-ui-render/.../OhEngineCore.ets` | chunked 命中分支 + expandTxtToVChapters + saveChunked |
| `ohrengine-reader/.../ReaderHost.ets` | UNZIP_DONE 消费点（跳过重复解压） |
| `build-profile.json5` | compatibleSdkVersion 26.0.0 → **6.1.1(24)**（API24） |
| `entry/.../test/*.ets` | Phase8D1OHOSTest(2) + VChapterOHOSTest(6) |

## 测试结果（3.7 API24）

- ohosTest 全量：**97 tests，85 Pass / 12 Fail**。12 Fail 与 Phase 1–7 完全一致
  （TextBreaker 2/PageSplitter 2/StyleMapper 3/SelectorMatcher 2/FontFallbackChain 2/
  PageGeneration 1）——**D8 回归确认 pre-existing**。
- 新增 8 用例（Phase8D1 2 + VChapter 6）全 Pass。
- App 运行：TXT/EPUB 打开、翻页、字号重排、恢复位置全正常（无崩溃）。

## 遗留/风险

1. **API24 兼容 WARN**：既有 UI 代码使用 API26 专属 `systemMaterial` / `fill`
   （TocPanel/AnnotationPanel/FontPanel）——本 Phase 不动 UI 业务逻辑，记录为
   API24 运行风险（真机 3.7 上未崩溃，因运行到该控件才触发，需后续 UI 层修复）。
2. **8.4 Benchmark**：未完成（下一步）。
3. **8.5 Cache ON/OFF 对拍 + DoD 重标**：未完成（下一步）。
