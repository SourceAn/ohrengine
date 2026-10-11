# Phase 24 Implementation Report

## 0. 结论摘要

Issue A/B/C 修复全部落地并通过真机验证。实施过程中通过诊断插桩发现并修复了两个此前未知的深层根因（段落缓存投毒、TXT vchapter id 撞号），它们共同导致「阅读位置保存静默失败」这一 Issue A 的核心症状。约束项（Worker JSON 协议 / LayoutResult 协议 / Lazy Geometry / L2 缓存格式 / Session 校验）均未触碰。

---

## 1. Modified Files

### 核心修复（Issue A — 恢复链路）

| 文件 | 修改 |
|---|---|
| `ohrengine-ui-render/src/main/ets/core/PageManager.ets` | **主战场**。①`getChapterParagraphs()`：预填充 `push([])` → `push(undefined)`，空结果不落缓存（根因 #1 修复）；②`getChapterParagraphStarts()` 同步修复；③`persistCurrentReadingState()`：增加 SAVE/SKIP 诊断日志；④`saveProgress()`：ReadingState 落盘提前并与 ReadingHistory 写入隔离（历史记录异常不阻断 L1 状态持久化）；⑤`buildCurrentAnchor()`：失败分支增加 ANCHOR_FAIL 日志 |
| `ohrengine-txt-exclusive/src/main/ets/TxtIndexBuilder.ets` | `closeVch()`/`emitEmptyVch()`：vchapter id 由每章归零的 `vchSeqInChapter` 改为全局连续的 `vchGlobal`（根因 #2 修复） |
| `ohrengine-txt-exclusive/src/main/ets/TxtDocument.ets` | 索引文件名 `txt-index.json` → `txt-index-v2.json`，使含撞号 id 的旧磁盘索引自然失效重建 |
| `ohrengine-common/src/main/ets/types/VChapterTypes.ets` | `buildVChapters()` 增加 `idStartIndex` 参数，id 序号全局连续（eager 路径同根因修复） |
| `ohrengine-ui-render/src/main/ets/OhEngineCore.ets` | `expandTxtToVChapters()` 调用传入全局 id 偏移 |

### Phase 24 主体修复（上一阶段已落地，本阶段验证）

| 文件 | 修改 |
|---|---|
| `PageManager.ets` | `getDocumentTotalPages()/getChapterPageCount()/getCurrentDocumentPageIndex()` 文档空间分页模型；`estimateChunkPageCount()/resolveCharsPerPage()/estimateDensityFactor()/invalidatePageEstimates()`（ESTIMATE_FRAGMENTATION_FACTOR=0.85 自校准）；`ensureChapterReady()` 重写（Issue C 主修复）；`commitNavigation()` stale-stub 同步重建 + P0_USER_JUMP/LOADING/FAILED 状态；`rebuildPageSlots()` 页身份快照重映射；`navigateToChapterCharOffset()` fragment 优先、visualPageIndex 仅兜底；`persistGuardUntil` 2s 恢复守卫（防退化棘轮）；`resetPageNavigationState()/resetCharIndices()` 拆分 clearAll |
| `OhEngineCore.ets` | `getCharsPerPage()`（统一分页模型参数）；`getMaterializedPages()/isChunkLoading()/isChunkLayoutFailed()/getDocumentPageNumber()`；open 入口清空 `paginatedChapters` + `resetCharIndices()` |
| `OhEngine.ets` | facade 透传上述新 API |
| `ReflowRouter.ets` / `ImageRouter.ets` | `render()` 改用 `resetPageNavigationState()`（不再清空 ReadingState） |
| `ohrengine-reader/PageRenderer.ets` | stub 页视觉表达：LOADING「正在加载…」/ FAILED「内容加载失败」（禁止裸空白） |
| `ReaderHost.ets` | 5 处页码改 `getDocumentPageNumber()`；`ReaderInfo.ets` 章内页码改独立计算 |
| `CbzParser.ets` | 修复预存 bug：`sort(this.naturalCompare)` this 丢失（阻塞真机验证，箭头函数修正） |
| `entry/EntryAbility.ets` + `entry/pages/Bookshelf.ets` | 调试设施：want 参数 `bookPath`（直达阅读器）与 `debugShelf=1`（直达调试书架），与既有 `pocCase` 注入模式一致，Release 产物无行为变化 |

## 2. Root Cause Fixed

### Issue A（进度保存/恢复不可靠）— 三层根因，全部修复

1. **段落缓存投毒（本次新发现，EPUB/TXT 通用）**：`getChapterParagraphs()` 的填充循环以空数组预填充低章索引，且 `cached !== undefined` 早退将 `[]` 视为权威缓存。恢复流程请求锚点章（如 ch29）时，所有 <29 的章节缓存被永久投毒为空 → 翻回低章时 `buildCurrentAnchor()` 返回 undefined → persist **静默跳过** → 位置永不落盘。修复：预填充 `undefined`（未计算语义）+ 空结果不缓存（可重试）。
2. **TXT vchapter id 撞号（本次新发现，TXT 专属）**：`TxtIndexBuilder.closeVch()` 用每章归零的 `vchSeqInChapter` 生成 id，所有旧章的首个 vchapter 都叫 `vchapter_00000`；`resolveChapterId()` 按尾部数字解析 → 恢复永远落到最前的同名章。修复：id 改用全局连续的 `vchGlobal`（eager 路径 `buildVChapters` 同步修复）+ 索引文件升版 v2 强制旧缓存失效。
3. **防抖丢失 + 退化棘轮（Phase 24 原有修复，验证有效）**：destroy 前兜底落盘 + 2s 恢复守卫阻断「降级恢复结果回写覆盖原始状态」。

### Issue B（总页数 31/31 vs 实际 318）
`pageSlots.length`（物化缓存）被当作文档坐标系。已建立 `documentTotalPages`（估算分页模型：章文本长度+排版参数+viewport+字体，碎片化先验 0.85 + 实/估密度自校准）与 `materializedPages` 分离，打开即显示 ~305/318 近收敛值，随物化推进收敛至精确值。

### Issue C（前进翻页空白页）
stale stub 页槽（章已物化但页槽未重建）导致。`ensureChapterReady()` 现在一律重建；未物化章走 P0_USER_JUMP 异步布局并表达 LOADING/FAILED 状态，`PageRenderer` 对 stub 渲染加载/失败提示而非空白。

## 3. Before / After Flow

**保存链路**
```
Before: 翻页 → updateReadingPosition → debounce(500ms) → saveProgress
        → persistCurrentReadingState → buildCurrentAnchor
        → getChapterParagraphs(低章) 返回投毒的 [] → anchor=undefined → 静默跳过 ✗
After:  同上链路 → 缓存未计算则按需加载（parse 文件就绪即成功）
        → anchor 确定性构造 → READING_STATE_SAVE（真机日志逐翻页可见）✓
        异常路径：无锚点 → READING_STATE_SAVE_SKIP 日志（不再静默）✓
```

**恢复链路（TXT）**
```
Before: 磁盘状态 anchor=vchapter_00000（撞号 id，实为 ch1）→ resolveChapterId→0 → 恢复 ch0 章首 ✗
After:  anchor=vchapter_00001 → resolvedCh=1 → 精确落位 ch1 pg0（11/3571）✓
```

**恢复链路（EPUB）**
```
Before: 保存的锚点是旧位置（保存静默失败），重开回到数小时前的位置 ✗
After:  savedCh=text/part0021 resolvedCh=22 savedPara=107 → ch22 pg8 精确落位（307/318）✓
        恢复期 2s 守卫拦截恢复触发的回写（READING_STATE_PRESERVE skip-persist）✓
```

## 4. Architecture Impact

- **分层无破坏**：PageManager 仍是持久化唯一 canonical owner；修复全部发生在缓存语义层（`undefined`=未计算 vs `[]`=确认空章）与 id 生成层，未引入新层级/新协议。
- **协议零改动**：Worker JSON、LayoutResult、Lazy Geometry、L2 缓存格式、Session 校验未触碰。L2 分页缓存按 chunkIndex+layoutSignature 键控，与 id 修复正交，旧缓存仍有效。
- **TXT 索引一次性重建**：`txt-index-v2.json` 使旧索引缓存废弃（cache 目录，代价 = 每本书一次流式重扫；200MB 书走 TaskPool 不冻 UI）。
- **可观测性提升**：持久化链路全程有日志（SAVE / SKIP / ANCHOR_FAIL / PARAS_EMPTY / PRESERVE），同类回归未来可直接从 hilog 定位。
- **调试设施**：`bookPath`/`debugShelf` want 参数复用既有 pocCase 注入模式，不影响 Release 行为。

## 5. Regression Evidence（真机，hilog）

**EPUB（test.epub，30 章，实际 318 页）**
- 打开恢复：`READING_RESTORE_PAGE_RESOLVE savedCh=text/part0021 resolvedCh=22 savedPara=107 result=1` → `COLDSTART ANCHOR_RESOLVED page=54 ch=22`，截图 307/318，内容与退出时同页（文本 hash 94569e6c 一致）。
- 翻页保存：10 次翻页产生 10 条 `READING_STATE_SAVE`（chid/para/visual 随位置递进，无 SKIP）。
- 总页数：打开 31/305（估算）→ 导航物化后 307/318（精确）。
- 无空白：全程 flipTurned 快照 `state=ready`，未见 stub 进入可视区；`LAYOUT_FAILED` 零次。

**TXT（benchmark 2MB lazy，146 vchapter）**
- 翻页保存：10 次前进翻页 → `READING_STATE_SAVE … anchChid=vchapter_00001 slotCh=1 visual=10`。
- 退出：`READING_POSITION_FLUSH page=11` → destroy 兜底 `READING_STATE_SAVE` → `SESSION_DISPOSE_END`。
- 重开恢复：`savedCh=vchapter_00001 resolvedCh=1 result=1 page=10` → 截图 11/3571，落位精确。
- 索引重建：v2 文件名生效，146 章 L2 缓存 100% 命中（`CacheStats[destroy] L2hits=146 L2miss=0`）。

**回归确认**
- FIRST_FRAME 冷启动、Flip 仿真翻页（finishFlip frames=24 avgMs≈5）、L2/L3 缓存命中（EPUB src=L2/L3 混合，TXT L2 100%）、Session dispose 闭环（START/END 成对、幂等）均正常。
- 恢复守卫：恢复后 2s 内出现 `READING_STATE_PRESERVE skip-persist`，窗口自愈，后续正常保存。

## 6. Remaining Risks

1. **打开瞬间页码为估算值**：冷启动 reflow 有 cap（~32 页槽），未物化章用估算，页码显示（如 55/387）随锚点章校准输入波动，导航后收敛精确。属显示精度问题，不影响恢复正确性；后续可让估算优先采用 L2 缓存页数进一步收紧。
2. **PDF 入口不可用**：解析器为桩实现（明确抛"不支持"，ENG-006），Issue A/B/C 修复对 PDF 未做真机验证。
3. **CBZ**：预存 sort bug 已修，本阶段未重跑 CBZ 翻页回归（修复仅影响文件排序，风险低）。
4. **旧格式 ReadingState**：含撞号 id 的历史 TXT 状态一次性失效（恢复到章首），随用户继续阅读自愈。
5. **估算自校准依赖已物化章密度**：锚点章为图片页时（如 EPUB 封面）校准样本含极小 charRange，可能放大估算偏差；clamp [0.5,2.5] 兜底。
