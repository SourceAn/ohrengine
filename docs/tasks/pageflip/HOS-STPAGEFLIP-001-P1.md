# Task ID

HOS-STPAGEFLIP-001-P1 — StPageFlip 数学模型 1:1 移植（纯函数，无 UI）（从任务）

> 主任务：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`（A1-A9 / T1-T10 / D1-D9 以主任务为准）。
> 本阶段只交付几何层纯函数与单测，**无任何 UI、无 Canvas、无手势**。

---

# 开始前提（全部满足才允许动工）

- P0 出口冻结点达成：三份冻结文档齐备并评审通过（P0 验收 E6）；
- `docs/ai/stpageflip_mapping.md` 处于冻结状态，本阶段严格按表执行；
- 旧翻页链路保持完整可运行（A9：本阶段不得触碰）。

# Objective

1. 新建 `ohrengine-pageflip` HAR 模块骨架（零模块依赖）；
2. 交付 `core/FlipTypes.ets`（类型 + `FLIP_DEFAULTS` 参数表）与 `core/FlipMath.ets`、`core/FlipCalculation.ets`；
3. 移植输出 `FlipState`：`{ angle, pageRect, topIntersect, sideIntersect, bottomIntersect, flippingClipArea[], bottomClipArea[], shadowStart, shadowAngle, progress }`（字段以 mapping 表为准）；
4. 单测证明与 StPageFlip 数值一致（容差按 T10 分级）。

# Scope

## 新建

```text
ohrengine-pageflip/ 全部模块骨架文件（oh-package.json5 / build-profile.json5 / hvigorfile.ts / src/main/module.json5 / src/main/ets/index.ets）
ohrengine-pageflip/src/main/ets/core/FlipTypes.ets
ohrengine-pageflip/src/main/ets/core/FlipMath.ets
ohrengine-pageflip/src/main/ets/core/FlipCalculation.ets
entry/src/ohosTest/ets/unit/FlipMath.test.ets
entry/src/ohosTest/ets/unit/FlipCalculation.test.ets
```

## 修改

- `build-profile.json5`：新增 `ohrengine_pageflip` 模块注册（注意：本阶段只增不删，`ohrengine_gl` 注册保留至 P4）；
- `entry/oh-package.json5`：新增 `ohrengine-pageflip` 依赖 + lock 重新生成；
- `docs/ai/stpageflip_mapping.md`：仅"验证结果"列允许回填（映射关系本身冻结，变更须先修订主任务）。

## 禁止

- 禁止创建 render/ components/ PageFlipEngine.ets（P2/P3 的事）；index.ets 本阶段只导出 core 类型；
- 禁止触碰 entry 阅读器任何运行代码；禁止触碰旧翻页链路（A9）；
- 禁止 import 任何其他 HAR 模块（零依赖）；几何层禁止 import ArkUI。

# Implementation Requirements

1. **1:1 移植（主任务 D4）**：逐函数按 mapping 表移植；交付物必须是 StPageFlip Port 而非 Inspired by。本阶段禁止/允许清单（穷尽式，不在"允许"列的一律禁止）：
   - **禁止**：增加贝塞尔/任何曲面变形；改变任何公式（含等价改写、运算顺序调整、系数"取整"）；重新设计数学模型；为"视觉更像 iBooks/旧 GL 效果"调整任何参数或几何输出；合并/拆分源函数导致映射表条目无法一一登记；引入源模型不存在的状态或分支。
   - **允许**：ArkTS 语法转换（类型显式化、const enum、严格空安全）；按 mapping 表的模块拆分；测试补充；`FLIP_DEFAULTS` 常量化（值不变，仅换位置）；注释说明"为什么"（T8）。
   - 判定标准唯一：映射表逐函数登记 + 数值一致（T10 容差）；登记不上或数值对不上的函数视为未完成，不得合入。
2. **坐标契约（D5）落地**：FlipCalculation 内部只使用 canonical 坐标（活动页局部 px、原点左上、书脊 x=0）；本阶段不实现镜像逻辑（镜像在 Engine 边界，P3）；公开接口参数单位 px，命名带单位后缀。
3. **退化行为对齐**：StPageFlip 在退化输入（触点过近/角度退化）时计算失败并返回 false，移植保持同语义（返回失败而非抛异常穿越层）。
4. **FLIP_DEFAULTS**：本阶段只落几何相关常量（热区比例可占位、阴影参数初值照抄 StPageFlip）；后续阶段只增不改语义。
5. **许可**：StPageFlip（MIT）仅供算法对照，禁止整文件复制（T9）；文件头注明对照来源。

# 架构约束

- 主任务 A1-A9 全部适用；A3（零依赖）、A4（1:1 移植）为本阶段重点；
- 几何层保持纯函数：同输入同输出，无隐藏状态，无 ArkUI 依赖，保证可 hypium 单测。

# 技术约束

- T1（strict-mode）、T8（日志/注释/禁 emoji）、T9（许可）、T10（容差分级）全部适用；
- 本阶段不涉及 T2-T7（无渲染无动画）。

# Non Goals

- 不做任何绘制/动画/手势；不做镜像；不做阴影视觉（仅输出阴影几何参数）；不做页面内容缓存；不做模块外集成。

# Acceptance Criteria

- E1：mapping 表中登记的 FlipCalculation/Helper 全部函数完成移植，目标文件/函数与表一致；走查确认无"禁止清单"行为（公式改写/新增曲面/参数私调等）；
- E2：单测全绿，覆盖：四角起手各 ≥3 代表触点、中心线限制触发、退化点返回失败、progress 值域、求交（平行/共线/端点/无交）、圆限制、旋转矩阵正交性；
- E3：数值一致性：核心几何输出（折叠角/页边交点/矩形四角）与 StPageFlip 同输入一致，容差 1e-6；经完整变换链的导出顶点容差 1e-4（T10）；mapping 表"验证结果"列回填完毕；
- E4：`ohrengine-pageflip` 可独立编译；debug 构建通过；既有单测全绿；
- E5：旧翻页链路运行能力未被破坏（A9 核验：构建产物中 gl 路径仍完整）；`git status` 无 Scope 白名单外变更。

# Test Requirements

- hypium 单测两文件全绿并纳入既有单测运行；
- 用例输入/期望值须可溯源到 mapping 表登记的 StPageFlip 行为（测试注释注明对应源函数）。
