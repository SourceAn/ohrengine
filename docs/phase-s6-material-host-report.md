# Phase S.6 — HDS Material Host Architecture Test

> 统一被测组件 `ReaderControlMock`（导航圆钮 / 胶囊 / Slider / 设置卡 / TOC 列表）分别放入四种 Material Host，验证「承载现有阅读器 UI 而无需重写组件」的可行性。
> 设备：HUAWEI Mate 70 Pro+（API 26）。证据与 POC 源码：`docs/phase-s6-evidence/`。
> ⚠️ 采集说明：HC/HD 序列采集中途设备被移作他用（前台切到其他应用），涉及私人界面的截图已即时删除且未查看、未归档；Route C/D 的完成度如实标注。

---

## 1. Route A — Sheet Material Host：**PASS（本阶段旗舰结论）**

`bindSheet(height:640, SheetOptions.systemMaterial=THIN)` 整体承载 `ReaderControlMock`：

- **视觉**（`HA_grad/HA_dark.jpeg`）：磨砂玻璃面（像素：Sheet 内条纹跳变 **0.72 / 1.15**，真 blur），顶部导航行（返回‹ + 章节标题 + 关闭）、42% Slider、目录/夜间/设置/朗读胶囊、字体/行距设置卡、TOC 三行列表——**全部清晰可读、无透明退化**（内部组件零材质依赖，玻璃由容器提供）。
- **交互**：Sheet 内 Slider/按钮可用性已在 S.4 实测（注入拖动 40%→85%）。
- **承载能力评分：★★★★★** —— 现有面板组件原样放入即可。
- 覆盖全屏：`height` 支持百分比/大数值，形态可从半屏到近全屏（detents 可调）；TopBar 形态不适用（Sheet 只能底部锚定），TopBar 建议维持悬浮胶囊 + blur 平替。
- API24：`SheetOptions.systemMaterial` 不存在 → `blurStyle` + 半透明底（SDK 已核对存在，真机待复核）。

## 2. Route B — AlertDialog Material Host：**PARTIAL**

- 材质本身 **PASS**：alert 区域条纹跳变 **3.02**、斜率 0.080、白纱 α≈0.002（`HB_grad.jpeg`，与 S.5 P5 一致）。
- 但 **API24/API26 的 AlertDialog 均无 builder/自定义内容能力**（SDK 0 处声明，本阶段核实）——**无法承载 ReaderControlMock**，只有 message + 按钮位。
- 承载能力评分：★★（对控制面板）/ ★★★★（对确认框、轻提示）。

## 3. Route C — Popup Material Host：**未完成（验证被中断）**

- 入口存在：`CustomPopupOptions.systemMaterial`（API26）；API24 common.d.ts 中 `systemMaterial` 0 处 → API24 无原生材质。
- S.5 发现程序化 `show=true` 不弹（节点树无 Popup）；S.6 已修复可疑点（builder 改为方法引用传递、点击/长按三种触发路径就绪），但采集中途设备被占用，**三种触发的渲染验证未完成**。
- 承载能力评分：**待定**（形态最贴近阅读器浮层，优先补测）。

## 4. Route D — ContextMenu Host：**未完成（验证被中断）**

- 入口存在：`ContextMenuOptions.systemMaterial`（API26）；API24 无。
- 长按注入（`uitest uiInput longClick`）已就绪，但首轮坐标偏移未命中锚点，重测被中断。这是**划词菜单（阅读器真实需求）唯一的原生材质候选**，必须补测。

## 5. Route E — Overlay / Window 级 Host：**FAIL（SDK 层面不存在）**

- `OverlayManager` / UIContext overlay 无任何 systemMaterial/材质参数；子窗口亦无材质 API。
- 结论：不存在「Page → Material Layer → Custom UI」的独立 Material Layer 组件。**窗口级材质只能借道系统容器**（Sheet / AlertDialog），这反过来确认 Rank 1/2 就是"Window 级 Material Host"的工程等价物。

---

## 最终架构建议（Host 排名）

```
Rank 1 — Sheet Material Host（设置/TOC/控制面板/大菜单）
  ★★★★★ | API26 systemMaterial / API24 blurStyle 降级
  改动范围：每面板一个容器壳；内部组件零重写
Rank 2 — AlertDialog Host（确认框/轻提示）
  材质真、但仅文本+按钮；替换现用白卡 Dialog
Rank 3 — Popup Host（浮层气泡，待补测）
Rank 3 — ContextMenu Host（划词菜单，待补测；两者 API24 均需 blur 平替）
不可用 — 组件级 systemMaterial（全档位）、Navigation TitleBar、TabBar、Canvas、Overlay 级
```

**P0 依旧**：`MaterialConfig` 判据改为「组件级材质有效」，全浮层先回 blurMaterial 平替消除透明回归。

## 未完成项与继续方式

- POC 源码已存档：`docs/phase-s6-evidence/HdsMaterialHostPoc.ets`（恢复：拷回 `entry/src/main/ets/debug/` + 注册 main_pages + EntryAbility 入口，与 S.2~S.5 相同三步）。
- 待补实验：① HC Popup 三种触发渲染验证；② HD ContextMenu 长按坐标校准后复测（锚点需以 dumpLayout 实时坐标为准）；③ API24 真机复核（blurStyle / 无材质降级路径）。
