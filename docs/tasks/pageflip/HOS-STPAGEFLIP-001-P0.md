# Task ID

HOS-STPAGEFLIP-001-P0 — 旧翻页实现分析、依赖映射与决策冻结（从任务）

> 主任务：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`（全局约束 A1-A9 / T1-T10、决策表 D1-D9 以主任务为准，本文件不重复定义）。
> v2.2 关键变化：本阶段**只做分析与冻结，不移除任何运行入口、不删除任何运行能力**（主任务 A9/D3）。物理归档与切换在 P4 单次原子提交完成。

---

# 开始前提

- 主任务 HOS-STPAGEFLIP-001（v2.2 及以上版本）已批准；
- iBooks 重构任务相关方已知悉终止决定（D2）。

# Objective

1. 产出旧翻页实现的完整清单与处置映射（归档 or 保留改造）；
2. 产出 StPageFlip 源函数 → 新模块函数的移植映射表（冻结，P1/P2 按此执行）；
3. 将主任务 D1-D9 决策落成冻结版 ADR；
4. 登记旧实现全部"入口隔离点"（P4 原子切换时的精确移除位置清单）；
5. 终止 iBooks 重构任务（加横幅），登记迁移过程态说明。

# Scope

## 新建（仅文档与归档目录说明，本阶段不改任何运行代码）

- `docs/ai/legacy_pageflip_inventory.md`
- `docs/ai/stpageflip_mapping.md`
- `docs/adr/ADR-PageFlip迁移架构决策.md`

## 修改（仅文档）

- `docs/tasks/iBooks风格仿真翻页动画重构.md`：顶部加 superseded 横幅（"已被 HOS-STPAGEFLIP-001 v2 取代：GL 翻页路径将归档，不再重构"；正文与评审文档保留，不得删除）；
- `docs/ai/project_context.md` §7 文档地图：追加主任务入口；
- `docs/ai/constraints.md` §8 已知限制：追加"翻页子系统迁移中（HOS-STPAGEFLIP-001），GL 路径将于 P4 归档"过程态说明（**不得改动 §1.3 原文**，正式修订在 P4）。

## 明确不做（本阶段禁令）

- 不 `git mv` 任何文件；不改 `build-profile.json5` / `oh-package.json5`；不改 `Index.ets` / `ReaderGestureController.ets` / `PageFlipController.ets` 任何一行；
- 不创建 `ohrengine-pageflip` 模块骨架（那是 P1 的事）。

# Implementation Requirements

## 1. `legacy_pageflip_inventory.md` 必备内容

起始调研清单（必须以实际代码调研补全，不得照抄）：`PageFlipController.ets`、`ReaderGestureController.ets` 翻页分支、`Index.ets` XComponent 装配（:472 起）、`ohrengine-gl/`（GlFlipEngine.ets、cpp 全部、module.json5、构建文件）、`build-profile.json5:130-131`、`entry/oh-package.json5` 依赖项、翻页相关资源/签名/CMake 配置。

表格一——处置映射：`| 文件 | 职责 | 新 Engine 对应模块 | 处置（归档/保留改造/不动） |`
（PageRenderer.ets 预期处置 = 保留改造：退居纯内容生产方；PageManager = 不动。）

表格二——**入口隔离点清单**（P4 移除时的精确操作单）：`| 隔离点 | 文件:行 | 移除内容 | 移除后的临时行为 |`
逐条覆盖：XComponent 挂载、PageFlipController 实例化与调用、手势控制器中翻页分支、构建注册、依赖声明。每条须可独立核验。

## 2. `stpageflip_mapping.md` 必备内容

映射必须细化到**函数级契约**，禁止只写"旧函数 → 新模块"的粗粒度对应（粗粒度映射会导致 P1 执行时重新理解算法、进而自行发挥）。逐条目格式：

```text
| StPageFlip 源文件:源函数 | 目标文件:目标函数 | 输入类型 | 输出类型 | 坐标/单位约束 | 容差级别 | 数值验证用例 | 验证结果(P1/P2 回填) |
```

示例条目（格式基准，内容以实际调研为准）：

```text
src/Flip/FlipCalculation.ts : calculateAngle
  → core/FlipCalculation.ets : calculateAngle
  输入: FlipPoint（canonical px，活动页局部坐标）
  输出: number（弧度）
  约束: canonical px；禁 vp；corner=TOP/BOTTOM 分支语义与源码一致
  容差: 1e-6（核心几何级，主任务 T10）
  用例: 四角起手各 ≥3 代表触点 + 退化点返回失败
```

至少覆盖：`FlipCalculation.ts`（calc/calculateAngle/getPageRect/getRotatedPoint/calculateIntersectPoint/checkPositionAtCenterLine/getFlippingClipArea/getBottomClipArea/getShadowStartPoint/getShadowAngle/getFlippingProgress）、`Helper.ts`（求交/圆限制/角度/距离）、`CanvasRender.ts`（drawFrame/drawBookShadow/drawOuterShadow/drawInnerShadow/clear）、`ImagePage.ts`（draw/simpleDraw）。

同时登记：数值容差分级标准（主任务 T10：核心几何 1e-6，经完整变换链的最终绘制顶点 1e-4）；StPageFlip 许可证（MIT）与"禁止整文件复制"声明。

## 3. `ADR-PageFlip迁移架构决策.md`

将主任务决策表 D1-D9 全文落成 ADR 冻结版；执行期以此为准；任何变更须先修订主任务文档并重新评审（本文件自身不引入新决策）。

# 架构约束

- 主任务 A1-A9 全部适用；特别强调 **A9：本阶段禁止移除/破坏旧链路任何运行能力**；
- 本阶段只允许新建/修改上述三份新文档 + 三处既有文档的指定位置；`git status` 出现其他变更即越界。

# 技术约束

- 文档写作遵循项目既有风格；禁 emoji；引用代码位置须带文件路径与行号（行号以调研时 commit 为准并注明）。

# Non Goals

- 不做任何编码；不做任何归档物理操作；不做性能测量；不评审/改动 iBooks 任务正文内容（仅加横幅）。

# Acceptance Criteria

- E1：三份冻结文档齐备，内容覆盖上述必备条目；评审通过；
- E2：inventory 入口隔离点清单逐条可在代码中定位复核；
- E3：mapping 表覆盖本节第 2 条列出的全部源函数，且每条目均含输入类型/输出类型/坐标单位约束/容差级别/验证用例五项契约字段，无粗粒度条目；
- E4：iBooks 任务横幅、project_context §7、constraints.md §8 三处修改完成且 constraints.md §1.3 原文未动；
- E5：`git status` 无白名单外变更；debug/release 构建不受影响（本阶段本应零代码变更）；
- E6（冻结点）：E1-E5 未全部达成，P1 不得动工。

# Test Requirements

- 无代码测试；文档评审记录（评审人/日期/结论）附在 ADR 文末。
