# Task ID

HOS-STPAGEFLIP-001-P5 — 性能优化、视觉微调与可选贝塞尔增强（从任务）

> 主任务：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`（A1-A9 / T1-T10 / D1-D9 以主任务为准）。
> 本阶段在 Reader 已切换完成的前提下做收敛优化；禁止改动几何模型语义（D4）与对外接口（0.10/A8）。

---

# 开始前提

- P4 验收全项达成（E1-E5），Reader 已由 PageFlipEngine 唯一驱动；
- P2 性能冒烟数据在册，作为优化基线。

# Objective

1. 达成主任务性能验收 P1-P3（目标值，实测记录）；
2. 产出 `docs/performance/pageflip-canvas-benchmark.md`（基线 vs 优化后，目标值 vs 实测值严格分列）；
3. 视觉手感微调：仅允许调整 `FLIP_DEFAULTS` 命名项（D9）；
4. 可选增强：贝塞尔折叠边缘——必须先产出 `docs/adr/ADR-PageFlip-Bezier折叠边缘设计.md` 并评审通过，才允许编码（D4）。

# Scope

## 允许修改

- `ohrengine-pageflip/` 内部实现（render/cache/animator 的优化）；
- `FLIP_DEFAULTS` 参数值；
- 新建：`docs/performance/pageflip-canvas-benchmark.md`、（可选）`docs/adr/ADR-PageFlip-Bezier折叠边缘设计.md` 及对应实现。

## 禁止

- 禁止改变 FlipCalculation 几何输出语义（同输入几何结果与 P1 基准一致，容差 T10）；
- 禁止改变 PageFlipEngine 对外接口与状态机语义（A8/0.10/D6）；
- 禁止引入 D7 禁止清单中的任何 API 作为"优化手段"；
- 禁止为达标悄悄降低渲染质量（如把阴影降级/删页背）——质量降级属需求变更，须先修订主任务并评审；
- Native 渲染后端不在本阶段实现（A8 预留，未来 ADR 另行评审）。

# Implementation Requirements

1. 优化方向（按 P2 冒烟数据选择，至少评估）：页内容降采样策略复核、静态底层页合成复用、渐变对象重建频率（按阴影角度/宽度量化分档缓存）、clip 路径构建复用、对象池覆盖热路径全部分配点、displaySync 期望帧率档位；
2. 埋点保留可开关：renderFrame 耗时/drawImage 次数/clip 次数/PixelMap 复制次数四项指标优化前后各测一组，写入 benchmark 文档；
3. 每项优化须可单独验证收益（benchmark 记录优化前后对比），禁止无数据打包提交"一堆优化"；
4. **优化不得反向污染架构**：任何"优化"若需要改动 FlipCalculation 几何语义、PageFlipEngine 接口、状态机语义、Renderer 职责边界（P2 第 2 条），一律禁止——那不是优化，是架构变更，须先修订主任务并评审；
5. **贝塞尔折叠边缘增强（可选）的门禁**：默认交付基线 = 1:1 StPageFlip 几何，任何情况下不被动摇；贝塞尔增强四门禁齐备才允许合入——①`docs/adr/ADR-PageFlip-Bezier折叠边缘设计.md` 评审通过；②benchmark 数据（增强对帧耗时的影响量化）；③视觉比对（对齐 V1 固定姿态程序，与基线成对截图）；④可回滚（FLIP_DEFAULTS 开关控制，**默认关闭**，主线默认渲染路径保持 1:1 模型）。四门禁缺一，增强代码不得进入主线。

# 架构约束

- 主任务 A1-A9；A8（渲染后端接口不得因优化改变）为本阶段重点。

# 技术约束

- T1-T10 全部适用；T7（热路径零分配）为本阶段重点核验项。

# Non Goals

- 不做新功能；不做 Native 后端；不做双页 spread；不动 Reader 其他模块。

# Acceptance Criteria

- E1（= 主任务 P1-P3）：拖拽与收尾帧 P95 < 16ms（displaySync IntervalInfo 帧间隔 + JS 绘制提交耗时双口径）；连续 20 次翻页无掉帧；IDLE 零帧回调；热路径每帧零分配；8 页 LRU 内存上界可证明；
- E2：benchmark 文档齐备：设备型号/API 版本/页面尺寸/采样方法、P2 冒烟基线 vs P5 优化后、目标值 vs 实测值分列；未达标项允许保留偏差+分析结论，但禁止把目标值当实测值引用；
- E3：优化后回归：主任务 F1-F4 关键路径抽验通过；V1 姿态比对无劣化（复测 50% 姿态）；
- E4（可选增强如执行）：四门禁核验——ADR 评审记录在先、benchmark 影响数据、V1 程序视觉比对、FLIP_DEFAULTS 开关默认关闭且主线默认路径仍为 1:1 StPageFlip 几何；缺任一门禁则增强代码不得合入；
- E5：既有+新增单测全绿；debug/release 双构建通过。

# Test Requirements

- 性能实测按 E1 口径执行并落盘；
- 优化前后两组埋点数据齐备；
- 回归抽验记录（翻页/字号/旋转/导航）。
