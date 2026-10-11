# Task ID

HOS-STPAGEFLIP-001-P4 — 原子切换：旧实现归档 + Reader 接管 + 文档修订（从任务）

> 主任务：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`（A1-A9 / T1-T10 / D1-D9 以主任务为准）。
> 本阶段是全任务**唯一的切换点**：旧实现物理归档与 Reader 接管在同一原子提交内完成；全程无双轨、无切换开关、无无动画中间态（D3/A9）。

---

# 开始前提（全部满足才允许动工）

- P3 验收全项达成（E1-E5），`PageFlipEngine` 接口已冻结；
- P0 冻结的 `legacy_pageflip_inventory.md` 中"入口隔离点清单"评审复核仍准确（若期间相关代码有变更，先更新清单并复审）；
- P2 性能冒烟数据已知悉，决策层确认继续（冒烟数据不阻断，但必须已被看见）；
- 回滚方案就绪：本阶段全部变更收敛为一次原子提交（或等价可整体 revert 的提交集）。

# Objective

1. 按入口隔离点清单物理归档旧翻页实现（`git mv`，保留历史），移出构建与依赖；
2. Reader 切换：Index.ets 挂载 PageFlipView、ReaderGestureController 翻页路由改指 Bridge、PageRenderer 收窄为内容生产方；
3. 文档正式修订（D1/D2 落地）：constraints.md §1.3 改写 + §2 决策行、module_map/architecture/project_context 翻页相关内容更新；
4. 达成主任务全局验收 O1/O2/N1/F1-F4。

## 原子提交硬性要求（D3 的执行形态，本阶段最高优先级）

- **禁止**出现"commit A 删除 GL、commit B 接入 Canvas"式拆分——那会在 git 历史中留下"无翻页驱动"或"双驱动"的中间提交，D3 失效；
- 必须**单次提交**同时包含：旧实现归档（git mv + 构建/依赖移除）+ Reader 切换到 PageFlipEngine + 文档修订（constraints/module_map/architecture/project_context）；
- 提交前允许分文件 stage 与本地多轮验证，但合入主线的就是一个 commit；如评审认定体量必须拆分，则提交集中每个提交都必须可构建通过、且不存在"旧链路已删但新链路未接（或反之）"的半切换状态——该豁免须书面记录在提交说明中。

# Scope

## 归档（`git mv` → `archive/legacy-pageflip/`）

- `ohrengine-gl/`（整目录，含 cpp/CMake/module.json5）；`entry/src/main/ets/reader/PageFlipController.ets`；inventory 登记的其他翻页专属文件；
- 新建 `archive/legacy-pageflip/README.md`（来源/归档决策任务 ID/回滚方式/归档日期）。

## 修改

- `build-profile.json5`：移除 `ohrengine_gl` 注册；`entry/oh-package.json5`：移除 gl 依赖；lock 重新生成；
- `entry/src/main/ets/pages/Index.ets`：移除 XComponent/GL 挂载与 PageFlipController 装配；挂载 PageFlipView 取代 PageRenderer onscreen Canvas；
- `entry/src/main/ets/reader/ReaderGestureController.ets`：删除旧 curl 分支，翻页拖拽/点击路由 → Bridge；点按菜单/划选等其他分支行为不变；
- `entry/src/main/ets/reader/PageRenderer.ets`：仅收窄为内容生产方（保留/暴露离屏 PixelMap 渲染；移除随 GL 归档失效的翻页截图配合逻辑）；**禁止改动正文排版绘制质量逻辑**；
- `entry/src/main/ets/reader/PageFlipBridge.ets`：接线（内容生产：PageRenderer 离屏 → PageContentCache；手势路由；onFlipCommitted → `PageManager.turnPage`）；
- 文档：`constraints.md`（§1.3 修订为"PageFlipEngine 是唯一翻页渲染路径（当前渲染后端 ArkTS Canvas 2D，扩展见 A8）；旧 GL 实现已归档，不参与编译与运行" + §2 决策表新增反转行 + §8 移除迁移中过程态说明、登记已知取舍）、`module_map.md`（翻页层改写）、`architecture.md`（§6 翻页架构改写）、`project_context.md`（快速定位更新）。

## 禁止

- 禁止保留任何新旧切换开关/临时入口（A1/D3）；
- 禁止本阶段顺手做性能优化（P5）或视觉调参（D9 参数表外一律不许动）；
- 禁止触碰 Non Goals 所列模块与 PageManager 契约（A7）。

# 架构约束

- 主任务 A1-A9 全部适用，本阶段重点：A1（唯一驱动）、A2（archive 只读）、A6（文档与代码同提交）、A9（移除只发生在此处的原子提交）。

# 技术约束

- T1-T10 全部适用；切换后首验 T3 禁用 API grep（N2）与 O2 旧引用 grep。

# Non Goals

- 不做性能优化与视觉微调（P5）；不做贝塞尔增强；不做 harness 移除（仍留 debug 作回归工具）。

# Acceptance Criteria

- E1（= 主任务 O1/O2）：归档完整可追溯；`rg "PageFlipController|GlFlipEngine|ohrengine-gl|gl_flip" entry/src ohrengine-* --glob '!archive/**'` 无运行引用；构建配置无 gl 注册/依赖；
- E2（= 主任务 N1/N2）：Reader 翻页全部经 PageFlipEngine；禁用 API grep 为空；IDLE 零帧回调；
- E3（= 主任务 F1-F4）：回归矩阵全通过（EPUB/TXT/CBZ 打开、拖拽/点击/程序化翻页、RTL、字号/行距调整、横竖屏旋转、标注/划选/目录/进度导航、后台回前台）；页索引提交在终帧之后；turnPage 失败路径模型与画面最终一致；debug/release 双构建通过；既有+新增单测全绿；
- E4（= A6/D1）：constraints.md §1.3 修订与 §2 决策行、module_map/architecture/project_context 更新、archive README，与本阶段代码同一次提交；
- E5：无动画直翻中间态不存在（切换前后 Reader 均有翻页动画：切换前 GL、切换后 Engine；切换本身为单次提交）；
- E6（原子性核验）：`git log` 走查确认切换收敛为单次提交（或经书面豁免的等价提交集）；历史中不存在"GL 已删/Engine 未接"或"Engine 已接/GL 未删"的半切换提交。

# Test Requirements

- 全量既有 hypium 单测 + 新增三文件单测全绿；
- O2/N2 grep 命令执行结果截图/日志留档；
- 人工回归矩阵逐条核验并记录（含 RTL 书籍方向映射）；
- 切换提交前在本机完整跑通一次开书→翻页→字号调整→旋转→目录导航全流程。
