# Phase 16.3 — Productionization Report

状态：**PARTIAL**（核心生产化完成并有真机数据；复杂排版样本/交互级自动化缺口如实 PENDING）
设备：HUAWEI Mate 70 Pro+
API：24

---

## 1. 修改文件列表（最小、可回滚）

| file | change |
|---|---|
| ui-render/layout/LayoutChapterWorker.ets | Worker→Main 传输改**惰性序列化**（剔除 charPositions/charWidths；L2 磁盘仍走完整 saveChapter） |
| ui-render/OhEngineCore.ets | `ensureLineGeometry` / `ensureCurrentPageGeometry`（按行惰性恢复，复用生产 justify/fill） |
| ui-render/OhEngine.ets | facade 透传 |
| reader/ReaderGestureController.ets | 选择交互前 `ensurePageLinesGeometry`（Feature Flag 语义：无需开关即按需） |
| reader/ReaderHost.ets | 提供 ensure dep；选择菜单定位前按行 ensure |

**Feature Flag / 回滚**：本方案的“旧路径”天然保留——旧 L2 文件（带数组）反序列化后数组即常驻，`ensureLineGeometry` 命中直接返回；Worker 传输若回退为完整序列化则行为与 16.0 完全一致（单点回滚：`buildLazyJson` → `PageCacheManager.serializePaginatedChapter`）。

## 2. 修改前后数据流

```
Before: Worker → LayoutResult(431KB, 含逐字数组) → Main JSON.parse(27–46ms) → deserialize(28–39ms)
After : Worker → lazy LayoutResult(155KB) → Main JSON.parse(7–10ms) → deserialize(11–14ms)
        内存行无逐字数组；选择/批注入口 → ensureLineGeometry(line) → cache miss 单行重建并写回（该行此后 0 成本）
```

## 3. CharacterGeometryProvider（单一入口）

- 入口：`OhEngine.ensureLineGeometry(line)` / `ensureCurrentPageGeometry()`（选择长按/端点/菜单定位前调用）。
- hit：`line.charPositions.length>0` → 直接返回。
- miss：textAlign=justify 且非末行 → 复用 `JustifyEngine.justify(line, max(1, viewWidth*0.99-x), density)`；否则复刻 `TextBreaker.fillCharPositions`（charSlotWidth+letterSpacing+空格 wordSpacing）。写回行对象 = per-line cache（重复访问 0 成本；无独立缓存层，无 LRU 需求——PageCache 淘汰自然释放）。
- Session 安全：写回目标=当前会话行对象；生成期校验由既有 epoch/destroyed 保证（行对象随 clearAll 释放）。

## 4. per-line cache 设计

按行就地写回（无独立结构）；generation 天然隔离（行对象代际）；Session dispose 随 PageManager.clearAll 释放。§九要求“只缓存已用行”——仅选择触及行被恢复。

## 5. Before / After 性能（真机 pid 41166，cold cache）

| 指标 | Phase 16.0 | Phase 16.1 | **Phase 16.3 实测** |
|---|---:|---:|---:|
| LayoutResult（传输） | 431KB | 155KB | **155KB**（worker out=155778） |
| JSON.parse | 27–46ms | ~1ms(实验) | **7–10ms**（生产） |
| Deserialize | 28–39ms | 估<10 | **11–14ms（<16ms ✓）** |
| Commit | 5–8ms | 不变 | 不变（5–8ms） |
| FIRST_FRAME（200MB cold） | 832ms | — | ~（TXT-LAZY→FIRST_FRAME 正常，src=live） |
| FIRST_FRAME（2MB warm） | 49ms | — | 49ms |
| Flip avg/max | 5–6/≤13ms | — | 5–6 / 9–10ms，mut=0 |
| Selection 1 行恢复 | N/A | ≈0ms | 生产 ensure 路径（≈0ms） |
| Selection 10 行 | N/A | ≤1ms | REBUILD_EXP 10 行=1ms |
| Cache hit | N/A | N/A | 行写回后 0 成本（二次访问） |
| RSS no-selection | 基线 | 未测 | PENDING（本轮未采集工具受限） |

REBUILD_EXP（16.3 生产构建，golden=worker 内序列化前数组）：**402/402**（200MB）与 **240/240**（2MB）逐一致。

## 6. RSS / Heap

**PENDING** — `dumpsys`/`hidumper` 本设备 shell 不可用（沿用前几个阶段记录）；机制上：不选择时 worker 章行对象无数组（仅 TextSelection 触及行被恢复写回），常驻量收敛于“已选择行”。

## 7. 多排版正确性矩阵

| 项目 | 结果 |
|---|---|
| Rendering / Page Count / Boundary | PASS（生产未动渲染/分页） |
| Left Align | PASS-by-construction（provider 复用生产 fill；算法=16.2 等值证明路径）；真机对齐样本 N/A |
| Right / Center Align | PASS-by-construction（同 justify/fill 同源）；**真机样本 N/A — 无代表性右/中样本** |
| CJK + Latin 混排 | 部分仅 justify 样本（200MB/2MB 均 CJK）；Latin 特征 N/A |
| Emoji / Ruby / MathML / SVG | **N/A — 无代表性样本**（不伪造） |
| Text Selection | PASS（长按选择菜单“复制”在真机出现）；**worker 章（惰性行）交互级选择 PENDING**（导航自动化受限） |
| Annotation | PASS-by-construction（消费 charPositions；数组等值）；交互级 PENDING |
| Cross-page Selection | PENDING（自动化受限；算法逐页无关） |
| Navigation / Latest-Jump-Wins / Session | PASS（epoch/layoutEpoch/navigationSerial 未动） |
| **Old L2 Cache Compatibility** | **PASS**（2MB warm 旧数组缓存正常打开 =49ms src=L2；deserializer 未变） |
| Memory | PARTIAL（机制收敛；RSS 未采集） |

## 8. TextSelection / Annotation 数据

- 长按 → “复制”菜单出现（真机布局 dump 证据）；选择路径先 ensure 当前页，命中/菜单定位使用恢复后数组。
- AnnotationRenderer 未改动（读 charPositions；数组由 provider 保证存在/等价）。

## 9. 旧 L2 缓存兼容性

PASS：旧 chapter_*.json（含逐字数组）由既有 deserializer 读取，数组直接常驻（ensure hit）；无需用户清缓存。

## 10. Feature Flag / Rollback

“旧路径”通过保留完整序列化/deserializer 天然回滚（`buildLazyJson` 单点换回）；无独立开关变量（避免新增 flag 面；可接受）。

## 11. 压力测试（本批）

- Open→Back ×6（前批）；本轮 200MB→Exit→2MB ✓；快速翻页 ✓（avg5-6/max9-10/mut0）；长按选择 ✓；无 crash/OOM；SESSION_DISPOSE 闭环 ✓。
- 选择→翻页/切章、全量 ×50：PENDING（自动化时长）。

## 12. AUDIT FINDING（不顺手修）

- worker 惰性序列化与 L2 完整序列化并存（传输 vs 磁盘双格式由 `saveChapter`/`buildLazyJson` 分别定义）——语义一致，未来可统一（记录）。
- `JustifyEngine.measureCharWidth` 与 `TextBreaker.charSlotWidth` 双实现仍存在（provider 只复用不新增第三方）。

## 13. PENDING

RSS/Heap 采集；worker 章交互级选择/批注自动化；右/中/混排/Emoji/Ruby/MathML/SVG 真机样本；全量压力计数；L2 disk slimming（明确 NOT INCLUDED）。

## 14. FINAL VERDICT

**PARTIAL** — 核心目标已达成并有真机数字：Worker 传输 431→155KB（−64%），主线程 JSON.parse 27–46→7–10ms，**deserialize <16ms（11–14ms）**，逐字数组不再随正常阅读常驻，选择长按恢复路径真机可用，旧 L2 缓存兼容，无翻页/首屏/会话回归（flip avg5-6/max≤10/mut=0，2MB warm 49ms，200MB cold FIRST_FRAME ok，Open/Back×6 通过，200→2MB 通过）。

**不能宣称 PASS 的原因（如实）**：右/中/混排/Emoji/Ruby/SVG 无代表性真机样本；worker 惰性行交互级选择自动化未跑；RSS 未采集。按 §32 原则不强行 PASS。生产化核心链路（性能+正确性机制+回滚）已由数据与算法等值（642+/642 逐一致）支撑。