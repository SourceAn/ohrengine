# ADR: 翻页子系统替换迁移架构决策（冻结版）

> 状态：冻结（P0 冻结点）。本文件不引入新决策；执行期以主任务 `docs/tasks/pageflip/HOS-STPAGEFLIP-001.md` 决策表 D1-D9 与本 ADR 为准。
> 变更规则：任何决策变更须先修订主任务文档并重新评审，本文件随之更新。
> 源：主任务 HOS-STPAGEFLIP-001 v2.3 关键架构决策表（D1-D9 全文冻结）。

---

## 决策表（冻结版）

| ID | 决策 | 要点（冻结文本） |
|----|------|------------------|
| D1 | 约束修订 | P4 将 `constraints.md` §1.3 修订为"PageFlipEngine 是唯一翻页渲染路径（当前渲染后端 ArkTS Canvas 2D，扩展见 A8）；旧 GL 实现已归档"；§2 决策表新增反转记录；已知取舍（旧 GL 高光/褶皱/锥形收窄不保留，视觉基准只对齐 StPageFlip）写入修订说明。**P0 阶段禁止改动 §1.3 原文。** |
| D2 | iBooks 任务 | 批准即终止；P0 在 `docs/tasks/iBooks风格仿真翻页动画重构.md` 顶部加 superseded 横幅，正文与评审文档保留作历史。 |
| D3 | 移除时机与原子切换 | P0 只做分析/冻结/隔离点登记，**不移除运行入口**；物理归档 + Reader 切换在 P4 单次原子提交完成；**全程无双轨、无切换开关、无无动画中间态**。 |
| D4 | 1:1 移植 | 禁止重新设计/自行推导几何模型；交付物必须是 StPageFlip Port 而非 Inspired by；判定 = 映射表逐函数登记 + 数值一致（核心几何容差 1e-6，最终绘制顶点经变换链后容差 1e-4）；贝塞尔边缘仅 P5 可选增强且 ADR 先行。 |
| D5 | 坐标契约 | canonical：活动页局部 px，原点左上，书脊 x=0；右书脊镜像只在 Engine 边界发生一次；vp→px 只在 GestureController 出口一次；坐标变量带单位后缀（`xVp`/`xPx`）。 |
| D6 | 状态机与提交时机 | 唯一真源 FlipStateMachine（IDLE/DRAGGING/SETTLING_COMPLETE/SETTLING_REBOUND/CANCELLING，转移表见 P3）；**分页模型提交在视觉完成之后**（终帧渲染 → Bridge 回调 → turnPage）；阈值判定与末速度估算全在 Engine 内（末速度 px/ms，最近 5 触点环形缓冲，单调时钟）。 |
| D7 | 动画 API 边界 | 允许：Canvas2D/OffscreenCanvas、displaySync、PixelMap/ImageBitmap、onTouch 原始事件、Matrix、Path clip、Gradient、ImageKit 解码；禁止：animateTo/属性动画/transition/router 转场/Swiper/PageSlider/WebView 翻页；帧驱动仅 displaySync，IDLE 必须 stop。 |
| D8 | 页面显示归属 | PageFlipView 全时段拥有正文显示区（静态帧=当前页 PixelMap drawImage，无 GL 时代双表面切换窗口）；PageRenderer 退居纯内容生产方（LineBox→OffscreenCanvas→PixelMap，保留 0.5x 降采样）。 |
| D9 | 视觉参数表 | 全部视觉/几何调参常量集中 `FLIP_DEFAULTS`（初值照抄 StPageFlip）；改数值会变效果 = 必须入表；数学恒等常量不受限。 |

---

## 决策依据与已知取舍

- **为什么替换而非双轨**：项目决策层确定不做双轨运行、不保留两套翻页实现；最终项目内只允许一个有效翻页驱动 `PageFlipEngine`（A1）。GL 路径（`ohrengine-gl` native GLES + `PageFlipController`）自本任务批准起进入待归档状态，P4 原子提交中物理移除。
- **已知取舍（D1 修订说明素材）**：旧 GL 实现的高光、褶皱、锥形收窄效果**不保留**；视觉基准只对齐 StPageFlip Canvas 版（V1/V2），禁止以"缺少旧 shader 效果"为由返工。
- **1:1 移植边界（D4）**：几何主体必须逐函数对照 StPageFlip 移植（mapping 表冻结，见 `docs/ai/stpageflip_mapping.md`）；"贝塞尔折叠边缘"仅为 P5 可选增强且须 ADR 先行，默认基线恒为 1:1 StPageFlip 几何。
- **语言策略（A8）**：ArkTS 优先，本次渲染后端为 Canvas 2D；渲染后端经固定接口抽象 `PageFlipEngine → FlipRendererInterface → Canvas2D 实现 / 未来 Native 实现`；未来 Native Renderer 不得改变 FlipCalculation/FlipStateMachine/FlipAnimator 接口与语义，且须经 ADR 评审。
- **动画物理（主任务 Objective 4）**：完全由 `FlipAnimator` 自主计算（时间/速度/弹簧方程/进度/几何更新），不依赖任何高层动画 API（D7 禁止清单）。

---

## 评审记录（P0 Test Requirements）

| 评审人 | 日期 | 结论 |
|--------|------|------|
| OpenCode（受项目所有者委托执行 P0 评审） | 2026-08-11 | **PASS（冻结生效）**。核验记录：①三份冻结文档齐备（inventory 101 行/17 条隔离点 G1-G17 均带 文件:行 可复核；mapping 420 行/34 条目函数级契约五字段完整，抽查 calculateAngle 与 StPageFlip 源码一致；ADR D1-D9 全文在册）；②constraints.md §1.3 原文逐字未动（:34），§8 过程态说明已加（:99）；③iBooks 任务横幅（:5）、project_context §7（:75-76）已更新；④build-profile.json5:130 仍注册 ohrengine_gl、entry/oh-package.json5:15 仍依赖 ohrengine-gl、全库无 pageflip 运行引用（A9 未被破坏）；⑤git status 无 P0 白名单外新增变更（既有 M/D 为 HAR 拆分历史遗留，docs/ 整体未跟踪，与本任务无关）。P0 验收 E1-E6 全部达成，P1 冻结前提满足，允许动工。 |

> 评审记录由 P0 评审在 ADR 文末填写；评审通过前 P1 不得动工（主任务 P0 开始前提 + E6 冻结点）。

---

## 关联冻结文档

- 旧实现清单与处置映射：`docs/ai/legacy_pageflip_inventory.md`
- StPageFlip 源函数 → 新模块函数映射表（函数级契约）：`docs/ai/stpageflip_mapping.md`
- 主任务：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`
