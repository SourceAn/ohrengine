# Phase 16.0 — Worker → 主线程传输与提交性能基线审查

> 生成时间：2026-09-04
> 设备：HUAWEI Mate 70 Pro+（API24）；pid 25046；`hdc tconn <LAN-IP>`
> 状态：**BASELINE COMPLETE**（只读测量；未做任何功能/协议修改）

---

## 1. 当前真实数据流（代码与线程证据）

```
PipelineManager.processNextInQueue (async, Main tid 25046)
 ├─ getChapterHtml(ch)          Main：TxtDocument.getVChapterHtml(重建 html)
 ├─ layoutChapterInPool
 │     snapshot = {html, cssText, fontSize, lineSpacing, letterSpacing, wordSpacing,
 │                 textAlign, fontFamily, viewWidth, viewHeight, href}   input=9,664 B
 │     taskpool.execute(layoutChapterConcurrent, inputJson)
 │       └─ LayoutChapterWorker.layoutChapterConcurrent   (Worker tid 25371，真实验证)
 │             css 编译(derive) → HtmlParser.parse → buildRenderTree → LayoutEngine.layout
 │             → PageSplitter.splitChapter → PageCacheManager.serializePaginatedChapter
 │             → LayoutResult = 431,215 B 字符串
 ├─ await 返回后（回到 Main tid 25046）
 │     validate(epoch/destroyed/cancel) → deserializePaginatedChapter(output, diag)
 │       JSON.parse → CacheChapter 字段重建 → PaginatedChapter
 └─ commit：assign paginatedChapters[] + PageCacheManager.saveChapter + memoryPageCache.put
     + （当前章 stub 时）rebuildPageSlots + pageReady
```
**线程证据**：`LAYOUT_WORKER_COMPUTE … tid=25371`（worker）vs
`LAYOUT_WORKER_END / LAYOUT_COMMIT … tid=25046`（主线程）——确认重计算真实发生在 TaskPool 线程。

## 2. 41–50ms 成本拆解（真机，431KB 输出）

| 子项 | 实测 | 占比 |
|---|---:|---:|
| JSON.parse（431,215 B 字符串） | **40–46 ms** | ≈90% |
| 对象/数组重建（字段逐项 + charPositions/charWidths 拷贝） | **2–4 ms** | ≈6% |
| 调度/上下文往返余量 | ~2–4 ms | ≈4% |
| **deserialize 合计** | 42–48 ms | 100% |

**结论（不猜测）**：41–50ms 的主体是 `JSON.parse` 一个 431KB 字符串；**不是**对象重建/数组分配（rebuild 仅 2–4ms）。

## 3. 数据规模（每章，200MB TXT 冷缓存后台）

| 项 | 值 |
|---|---:|
| inputBytes（ChapterSnapshot JSON） | 9,664 B |
| outputBytes（LayoutResult JSON） | **431,215 B（44× input）** |
| pageCount | 17 |
| lineBoxCount | 402 |
| textChars（正文） | 8,040 B |
| renderNodeCount | 67 |
| 输出/行 | ≈1,072 B/行（文本仅 ~20 B/行） |

## 4. Worker 成本（Worker tid 内计时）

| 阶段 | 实测 |
|---|---:|
| css derive | 2–5 ms |
| parse（HtmlParser） | 6–10 ms |
| tree（buildRenderTree） | 5–6 ms |
| **layout（LayoutEngine）** | **174–187 ms** |
| split | 0–1 ms |
| serialize | 4–5 ms |
| worker 合计 | 194–210 ms（round-trip exec 194–211 ms） |

## 5. Commit 成本

| 子项 | 实测 |
|---|---:|
| validate+deserialize-to-model | 见 §2（42–48 ms，其 40–46 为 parse） |
| PageSlot 分配/assign + saveChapter + cache 更新（无 rebuild；后台非当前章） | **6–11 ms（稳定）** |
| commit < 16ms 目标 | ✓ |

## 6. LayoutResult 数据结构审查（只读标记）

| 字段群 | 数据量 | 判断 |
|---|---|---|
| 每行 ~25 几何/样式字段（x,y,w,h,ascent,descent,effectOpacity,startCharOffset,renderedY,…） | ~430 B/行 | 高占用（提交必需，但可紧凑化；本阶段不删） |
| charPositions / charWidths 数组（逐字） | 高占用（占输出体积主要部分） | 疑似可延迟/压缩 — **REDUNDANT-CANDIDATE（仅标记）**（渲染用 charWidths；选择命中用 charPositions） |
| text 字符串 | 8 KB/章（0.9%） | 必要 |
| images / ruby / mathml / svg JSON | 本样本 N/A | 条件性 |
| gridResult / float / margins / listMarker | 条件性 | 本 TXT 样本无 |

## 7. 数据所有权表

| 数据 | 创建线程 | Owner | Worker 持有 | 主线程持有 | 复制 |
|---|---|---|---|---|---|
| Chapter HTML | Main(provider) | Pipeline.chapterHtmlCache | 快照复制 | 持有源 | 是（snapshot） |
| LayoutResult JSON | Worker | 临时（主线程接收后即弃） | — | 字符串 | 是（transfer） |
| PaginatedChapter | Main(deserialize) | Pipeline.paginatedChapters | 无 | 是 | 反序列化重建 |
| PageSlot | Main | PageManager | 无 | 是 | 无 |

## 8. 瓶颈排序（按实测数据）

```
P0  worker layout 174–187 ms   —— 计算本体（CPU 密集；主线程已解放，非主线程问题）
P1  主线程 jsonParse 40–46 ms  —— 431KB 输出驱动的 JSON.parse（非对象重建）
P2  输出体积 431KB（44× input）—— 每行 ~25 字段 + 逐字数组主导
P3  commit 6–11 ms（已达标）
```

## 9. 是否是真的用户可感知问题（§13）

- 后台 cadence = 150ms；动画期间 `userAnimating` 互斥（后台推迟）；
- 翻页 max ≤ 13ms、mut=0；commit < 16ms；
- deserialize (42–48ms) 发生在后台节拍内，不与动画/首屏竞争（真机二重验证：翻页 avg 5–6 / max 9–13ms）。

**判定**：`deserialize` 是 **P1/P2 性能债务，不是已证明的用户体验 P0**。依据：调度位置不与动画竞争 + 帧指标未退化。不得为指标好看强行优化。

## 10. 下一阶段优化建议（最多 3 方案，仅建议）

1. **方案 A（首选）— 减小 LayoutResult 数据量**：把逐字 charPositions/charWidths 全量数组改为紧凑表示/延迟生成 + 行盒固定字段打包。预期：431KB→~60–80KB ⇒ jsonParse 40–46ms→~7–10ms（parse 时间与字节量强相关，已实测）；不改变 JSON 协议/磁盘语义。选择理由：JSON.parse 直接由输出体积驱动（§2 实测），且基线证明重建仅 2–4ms（字段裁剪收益低），**裁数据 > 优化解析器**。
2. **方案 B — 优化反序列化路径**：保持 JSON、对行盒/页面数组用类型化批量重建、避免每 field 一次 `rec[...]` 查找。预期小（parse 占 90%）；风险低；收益有限。
3. **方案 C — 更紧凑传输协议**：输出改为二进制/定长。预期最大但**改变 L2 磁盘格式/序列化语义**，需迁移与兼容处理，风险高；**留有后手**。
   选 A 而非 C：A 收益已量化且不动协议；C 动 L2 兼容面。真正动刀前需按 Phase 16 规则先 A/B 对比实现后再决定。

## 11. 审计批复（AUDIT FINDINGS，仅记录不修改）

- **DUPLICATE WORK**：章节 HTML 由主线程 `getVChapterHtml`（raw→html 重建）构造后再由 worker parse——raw→html 属主线程既有工作（非重复 parse），记录为两阶段各自必要。
- **数据放大 44×**：serialize 输出的字段冗余是后续首要优化面（见方案 A）。
- `LAYOUT_RESULT_DROP` 本样本 0 次 → 无 stale 提交（Session 隔离正常）。

---

## BASELINE：COMPLETE

完成：数据流追踪 / 41–50ms 拆解（90% 为 JSON.parse of 431KB）/ Worker 194–210ms 拆解（layout 174–187 主导）/ commit 6–11ms / 输入输出量 / 数据结构审查 / 所有权表 / 线程证据 / 优先级排序 / 3 方案建议。未做任何功能/协议修改；未伪异步；未伪造数据。