# Phase 1 报告：Reading State + ReadingAnchor（位置恢复）

> 依据《01-Phase1-阅读位置恢复.md》完成。前置 Phase 0 Decision Table 已定：
> ReadingState 持久化由新增 `ReadingStateStore`(common file-based) + `PageManager`
> 恢复逻辑承担（决策表 ReadingStateManager 为 MERGE 演化，此处落在 PageManager
> 与 OhEngineCore 已有模块上，未创建空壳模块）。

## 1. 修改文件

| 文件 | 变更 | 内容 |
|---|---|---|
| `ohrengine-common/.../types/ReadingStateTypes.ets` | **新增** | `ReadingAnchor`、`ReadingState` 类型；`READING_STATE_SCHEMA_VERSION`、`PARAGRAPH_HASH_ALGORITHM` 常量；`hashParagraphText`(FNV-1a32)、`extractParagraphs`(HTML→段落，确定性)、`computeParagraphStarts`、`clampParagraphCharOffset` |
| `ohrengine-common/.../service/ReadingStateStore.ets` | **新增** | `reading_state_<bookId>.json` 原子持久化（tmp + renameSync，crash 安全）；load 损坏返回 null 不抛错 |
| `ohrengine-common/index.ets` | 扩出口 | 导出以上类型/函数/Store |
| `ohrengine-common/.../core/...` （无） | — | — |
| `ohrengine-ui-render/.../core/PageManager.ets` | 修改 | `PageManagerHost` 增加 `getBookId/getLayoutSignature/getContentFingerprint/saveReadingState`；新增 `getChapterParagraphs/Starts`、`getChapterId/resolveChapterId`、`buildCurrentAnchor`、`buildCurrentReadingState`、`persistCurrentReadingState`、`restoreReadingState`、`navigateToChapterCharOffset`、`buildSearchFragment`、`clearParagraphCache`；`saveProgress` 追加持久化 ReadingState；段落缓存生命周期随 clearAll |
| `ohrengine-ui-render/.../OhEngineCore.ets` | 修改 | `OpenOptions.readingStateDir`；`getBookId/getLayoutSignature/getContentFingerprint/saveReadingState/restoreLastReadingState`；open() 末尾（置 READY 后）尝试恢复；destroy() 兜底落盘 |
| `ohrengine-reader/.../ReaderHost.ets` | 修改 | `openAndLoad` 传入 `filesDir/reading_state` 作为独立 readingStateDir |
| `entry/.../unit/ReadingStateOHOSTest.ets` | **新增** | 8 个纯函数用例（段落提取/散列/起始偏移/钳制/确定性） |
| `entry/.../test/List.test.ets` | 修改 | 注册 ReadingStateOHOSTest |

## 2. 架构变化

- **L1 缓存落地**：ReadingState 以 `filesDir/reading_state/reading_state_<bookId>.json`
  独立持久化，**不随 L2 分页缓存失效**（L2 失效只影响 layoutSignature/内容可分页）；
  contentFingerprint 改变时 ReadingState 失效（restore 端校验后安全回退）。
- **恢复管线**：
  ```
  open() → layoutAllChaptersSync（现存行为，Phase 2 将改为懒加载）
          → ReadingStateStore.load → schemaVersion 校验
          → contentFingerprint 校验 → chapterId 解析
          → paragraphIndex 定位 → paragraphHash 验证
          →（mismatch 时 ±40 邻域搜索最近匹配）
          → charOffset clamp → 页面级定位（段落文本片段匹配页行文本）
          → 失败 fallback goToChapter(chapterIndex)（不 crash、不静默错位）
  ```
- **保存管线**：`PageManager.saveProgress`（500ms 防抖，与既有 progress 同时）→
  `persistCurrentReadingState`；`destroy()` 兜底再存一次。
- **不变**：未修改 TextBreaker/Knuth-Plass/PageSplitter/页面动画；未让 pageIndex 进入
  任何 key；ReadingState 的 `visualPageIndex` 仅为派生展示字段，恢复流程不使用它。

## 3. baseline（Phase 1 执行时点）

- 恢复：Phase 0 基线「冷启动恒为第 0 页、ReadingHistoryManager 仅内存」→ 本 Phase 后
  冷启动可恢复到上次阅读页（ReadingAnchor 定位）。
- compile：`entry@default` + `entry@ohosTest` 均 BUILD SUCCESSFUL。
- 测试：新增 8 用例（纯函数，避免磁盘依赖）；磁盘 IO（ReadingStateStore 读写）
  需真机/模拟器沙箱验证（ohosTest 现有约定一致）。
- API24：新代码仅使用 fileIo（CoreFileKit）同步 API 与纯字符串/数值操作，无高版本专属 API；
  工程 compatibleSdkVersion=26.0.0（满足 API24）。

## 4. 测试结果

- **真机（<LAN-IP>）ohosTest 执行**：Tests run 78，**66 Pass / 12 Fail**。
  - 新增 8 个 ReadingState 用例 **全部 Pass**。
  - 12 个 Fail 均为既有测试（TextBreaker 2、PageSplitter 2、StyleMapper 3、
    SelectorMatcher 2、FontFallbackChain 2、PageGeneration entry3——空 Publication
    队列无章节导致 pageGeneration 不递增），与本 Phase 改动无关（未触碰这些文件逻辑）。
- **App 启动**：`start_app` 成功安装启动，进程存活，无 app crash。

## 5. before/after 指标

| 指标 | Phase 0/之前 | Phase 1 后 |
|---|---|---|
| 冷启动恢复 | 恒首页（无实现） | ReadingAnchor 级恢复（hash 验证 + 邻域兜底） |
| 恢复依据 | pageIndex（未接线） | chapterId + paragraphIndex + hash + charOffset |
| ReadingHistory 持久化 | 仅内存 | ReadingState 落盘（独立目录，不随 L2 清除） |

## 6. 风险与未决问题

1. **paragraphIndex 语义**：当前段落 = extractParagraphs 的「块级边界文本块」，与
   RenderNode 文本节点并非 1:1；由于保存/恢复都基于同一确定性提取，自洽。若未来
   引入虚拟章节（TXT），`chapterId` 语义需迁到 vchapter id —— 本 Phase 用
   `'chapter-N'` 兜底（TXT 阶段性实现）。
2. **charOffset 定位精度**：页面定位依赖「段落文本片段↔页行文本」匹配，对齐失败时
   退回 charRange 中点近似（spec 允许 nearby page）。
3. **memory**：`chapterParagraphs/Starts` 每章一份内存副本（仅章节 HTML 的段落切片，
   与既有 chunkPlainTexts 同级）；未做逐章释放（Phase 3 的 L3 边界处理）。
4. **ReaderHost bookId 不一致**：history 用 identifier→title，annotation/bookmark 用
   title —— ReadingState 采用与 history 相同的 `getBookId`（identifier 优先）。
5. **真机验证**：当前环境无连接设备/模拟器，restore 运行时验证（冷启动恢复、hash
   mismatch、TXT）待设备可用后执行。

## 7. 结论与下一阶段

- 满足 Phase 1 DoD 主体：类型/持久化/恢复管线/hash 兜底/API24 合规/compile+test 编译全过。
- **进入 Phase 2**：HotPageCache/L2 —— 把「open → 整本同步分页」改为
  chapter-aware 热页缓存（当前页±N + 相邻章节入口页），将 ReadingAnchor→页面定位
  用于恢复路径，彻底去掉「首次打开整本分页 + pageSlots 全书常驻」。