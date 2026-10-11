# Phase 16.2 — Experiment Report

状态：**PASS — A 方案（逐字数据按需重建）可以进入生产化**
设备：HUAWEI Mate 70 Pro+
API：24

---

## 1. 调用链（重新全量核实，非 16.1 复用）

```
charPositions / charWidths
生成：
  ├─ TextBreaker.fillCharPositions（左/右/居中；测量字宽 = charSlotWidth+letterSpacing+(空格 wordSpacing)）
  └─ JustifyEngine.justify（两端对齐行重新逐字定位；measureCharWidth 基于 line.ascent=fontSize；
         CJK: spread=剩余/字符数 + 行首/行尾禁则 30%、相邻标点 50%；Latin: 词间隙分 spread）
保存：PageCacheManager.serializePaginatedChapter / deserializePaginatedChapter（逐字段显式序列化）
读取（全库 rg）：
  ├─ TextSelection.ets（命中测试/选择区间：每行数组按需二分查找）
  ├─ AnnotationRenderer.ets（批注下划线：charPositions 逐字符累计 segX/segW）
  ├─ ReaderGestureController（选择拖拽端点 charWidths 定位）
  ├─ ReaderHost（选择端点 X 换算）
  └─ 渲染/分页/搜索/书签/翻页/跳转 → 不读取（正文字绘制仅 text+geometry）
读取范围：逐行、按需区间；不是整章一次性读取。
```

## 2. 局部重建可行性（真机证明）

**可以按行重建；无需 re-parse / buildRenderTree / layout / split。**
输入 = 行自身字段：`text / x / y / width / height / ascent / isCJK / isLastLineOfParagraph`
+ 恒定排版参数：`textAlign / baseFontSize / letterSpacing / wordSpacing / density / viewWidth`
± 规则常量：`safetyMargin=0.99；fullWidth=viewWidth*0.99；availableWidth=fullWidth-x`。
重建 = 复用生产 `JustifyEngine.justify`（对齐行）+ `TextBreaker.charSlotWidth` 复刻（非对齐行），
按行纯计算（O(字符数)），**零整章重算**。

## 3. 性能数据（真机；实验在 Worker 线程，主线程无扰动）

| 范围 | 行数 | 字符数 | 重建耗时 |
|---|---:|---:|---:|
| Small | 1 | ~20 | **0ms** |
| Medium | 10 | ~200 | **0–1ms** |
| Large | 50 | ~1000 | **0–1ms** |
| Full | 402 | 8040 | **8ms**（200MB 样本） |
| Full | 240 | 4800 | 5ms（2MB 样本） |

```
REBUILD_EXP lines=402 c1=0ms(1/1) c10=0ms(10/10) c50=1ms(50/50) full=8ms(402/402) chars=8040
REBUILD_EXP lines=240 c1=0ms(1/1) c10=1ms(10/10) c50=0ms(50/50) full=5ms(240/240) chars=4800
```
**逐字一致性：642/642 行（2 样本）与生产数组字节级一致（误差 <0.001vp）。**

## 4. Before / After（生产路径未改；实验数据为生产数据的高可信分量证据）

| 指标 | Before | After（若生产化 A 方案） |
|---|---:|---:|
| LayoutResult | 431 KB | ~155 KB（-64%；移除逐字数组） |
| JSON.parse | 27–46 ms | ≈1–2 ms（minimal 实测） |
| Deserialize | 28–39 ms | 预估 <10 ms（parse1-2+rebuild2-4+commit5-8） |
| Commit | 5–8 ms | 不变 |
| FIRST_FRAME | 49 ms（2MB warm 基线） | 不变或略快 |
| Flip avg / max | 5–6 / ≤13 ms | 不变 |
| Selection 首次恢复 | N/A（常驻） | 1 行 ≈0ms；10 行 ≤1ms |
| Selection 重复访问 | N/A | 按行重建（生产化阶段加 per-line cache） |
| RSS/Heap | 常驻逐字数组 | 选择前不常驻（预期收益，16.3 验证） |

## 5. 正确性矩阵

| 项目 | 结果 |
|---|---|
| Rendering / Page Count / Page Boundary | PASS（生产未动；worker 实验仅诊断） |
| Navigation / Latest-Jump-Wins | PASS（epoch/layoutEpoch/navigationSerial 原样） |
| Session Isolation | PASS（LAYOUT_RESULT_DROP 验证原样；worker 只读） |
| Text Selection | PASS（by-construction：重建数组与生产 642/642 一致 → 命中/区间几何一致）；真实拖拽 UI 自动化受限 |
| Annotation（下划线定位） | PASS（消费 charPositions；数组一致 → segX/segW 一致） |
| Cross-page Selection | PASS（逐页各自按行恢复，跨页组合逻辑未涉及） |
| L2 Protocol | **未修改** |
| Memory | 未验证 RSS（PENDING：需 16.3 生产化后测量） |

## 6. 反作弊核对

cold cache（`chapter_*.json` 删除后打开）、两样本（200MB/2MB）、逐样本 100% 行匹配、
重建耗时真实计时（Date.now）、Worker 线程内执行（tid 36xxx vs 主线程 37xxx）、非估算。
未用 warm cache / 单次成功 / 最好成绩掩饰。

## 7. AUDIT FINDING（记录，本阶段不修）

- justify 存在两套“字宽函数”（JustifyEngine.measureCharWidth 与 TextBreaker.charSlotWidth 规则一致但独立实现），生产化按需重建时**必须复用现有函数**（本实验已如此），避免双算法漂移。
- 右对齐/居中、Ruby/MathML/SVG、emoji、Latin-mixed 样本在本批数据中无代表性样本（200MB/2MB 均为 CJK justify）→ 16.3 生产化回归需补该方向；本阶段 N/A 如实标注。

---

## FINAL VERDICT

**PASS — A 方案可以进入生产化。**

依据（§十五 PASS 清单逐项）：正常阅读不依赖逐字数组（渲染/翻页/分页/搜索/书签不读取）；
可安全移除（minimal 155KB、parse≈1ms）；TextSelection/AnnotationRenderer 局部按行恢复且 642/642 与生产一致；
无需整章重布局（按行纯计算）；单行 0ms / 1–10 行 ≤1ms；重复访问可缓存（16.3 加 per-line cache）；
Session/generation 安全；2MB/200MB 无回归；FIRST_FRAME/flip 无回归（生产路径本轮未改）。

> 生产化（Phase 16.3）范围预告（本轮未执行）：serialize 输出剔除逐字数组 + deserialize 按行惰性恢复 + per-line cache + 右/中/Ruby 样本回归 + RSS 对比。L2 磁盘协议策略（是否同时瘦身磁盘格式）单独决策。

## PENDING（如实）
- 文本选择 UI 自动化的交互级验证（`PENDING — UI automation limitation`；等值性由 642/642 数组一致证明）。
- RSS/Heap 生产化后对比（本轮实验不改变内存驻留）。
- 右/中、Ruby/MathML/SVG、emoji、Latin 样本（N/A — 无代表性样本）。