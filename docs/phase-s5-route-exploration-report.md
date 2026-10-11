# Phase S.5 — HDS Immersive Material Route Exploration & Minimal Validation

> 路线探索实验：不再复核已知结论，探索 S.4 未覆盖的容器/组件入口（Popup / Navigation TitleBar / Tabs 浮动 TabBar / Canvas / AlertDialog），寻找双版本可落地的沉浸光感方案。
> 设备：HUAWEI Mate 70 Pro+（API 26）。证据：`docs/phase-s5-evidence/`。POC 限于 `debug/`，验证后已恢复。

---

## 1. 本阶段新探索的入口与判定

判定方法与 S.2~S.4 一致：三背景 + 条纹方波波形（跳变保留=透明，跳变归零=真 blur）+ 白纱回归排除叠加假设。

| 探索点 | API 入口 | 像素判定 | 视觉判定 | 结论 |
|---|---|---|---|---|
| **AlertDialog 级材质** | `AlertDialog.show({ systemMaterial })` | grad：峰谷差 43.0→**17.2**、跳变→**3.53**、斜率 0.151、白纱 α≈0.002；dark：跳变→**3.06**、斜率 0.084 | 卡片呈磨砂观感、背景随深浅变化（均亮 154.7 vs 133.6） | **✅ PASS：第二个真实材质容器**（真 blur + 背景采样 + 深浅响应） |
| Navigation TitleBar | `.title(value, { systemMaterial })` | TitleBar 区条纹跳变 42.3/75.3 全保留，斜率 ~1.0 | 条纹锐利穿过标题区（`P2_*.jpeg`） | ❌ FAIL |
| Tabs 浮动 TabBar | `.barFloatingStyle({ systemMaterial })` | TabBar 区跳变 47.4/73.3 保留，斜率 ~0.97 | 无玻璃胶囊（`P3_*.jpeg`） | ❌ FAIL |
| Canvas 组件级 | `.systemMaterial(THICK)` | Canvas 区跳变 48.0/78.1 保留 | 无效果（`P4_*.jpeg`） | ❌ FAIL（Route A 补遗，与 S.3 一致） |
| CustomPopup 级材质 | `bindPopup(CustomPopupOptions{ systemMaterial })` | 未能弹出（程序化 show 与点击注入均未触发，节点树无 Popup） | — | ⚠️ **PARTIAL/待查**：入口存在（SDK 声明），渲染验证未完成 |

**核心新发现：`AlertDialog.show + systemMaterial` 是 Dialog 家族中唯一真实渲染 HDS 材质的入口**——同家族的 `CustomDialogControllerOptions.systemMaterial`（S.4 已证无效）与它的行为形成直接对照。

---

## 2. 全容器版图（S.2~S.5 汇总，API26 实测）

| 容器/入口 | 材质渲染 | 形态 |
|---|---|---|
| `bindSheet + SheetOptions.systemMaterial` | ✅ 真 blur（最强、可承载任意大面板） | 底部抽屉 |
| **`AlertDialog.show + systemMaterial`** | ✅ 真 blur（略弱于 Sheet：残留对比 15% vs 12%） | **居中浮窗** |
| CustomDialog / Dialog 级选项 / Popup* / Navigation TitleBar / 浮动 TabBar / 普通组件（全部档位含 Canvas） | ❌ 不渲染 | — |

*Popup 的 `CustomPopupOptions.systemMaterial` 与 `ContextMenuOptions.systemMaterial`（长按菜单）SDK 入口存在，本阶段未完成渲染验证，是**下一批最值得测的候选**——ContextMenu 形态直接对应阅读器划词菜单。

---

## 3. 推荐路线排名

```
Rank 1 — bindSheet 容器承载（不变）
  方案：设置/TOC/控制面板整体迁 Sheet；API26 用 SheetOptions.systemMaterial，
       API24 用 SheetOptions.blurStyle + 半透明底（SDK 已核对存在，真机待复核）
  收益：大面板全量获得真 HDS 玻璃；内部组件零改造、交互无损（S.4 实测）
  改动范围：各面板容器壳 + 材质参数版本分支

Rank 2 — AlertDialog.show + systemMaterial（本阶段新发现）
  方案：阅读器内"确认框 / 轻提示 / 简单菜单卡片"类浮层改用 AlertDialog
  收益：居中浮窗形态获得真 HDS 玻璃，替换当前白卡 C3 路线
  限制：内容定制弱（title/message/buttons），复杂自定义内容仍需 Rank 1
  改动范围：WordLookupDialog 等 Dialog 用法逐个替换

Rank 3 — 待验证候选（下一批实验，不建议直接投产）
  bindContextMenu + ContextMenuOptions.systemMaterial（划词菜单形态）
  bindPopup + CustomPopupOptions.systemMaterial（修复弹出问题后复测）
  两者的形态（锚定菜单/气泡）若生效，可覆盖"长按菜单/气泡提示"场景
```

**P0 修复不变**：`MaterialConfig` 判据改为「组件级材质有效」（实测恒 false），所有组件级调用回退 blurMaterial 平替——当前生产浮层全透明的状态必须先消除。

## 4. API24 / API26

| 入口 | API24 | API26 |
|---|---|---|
| SheetOptions.systemMaterial | 不存在 → 用 `blurStyle`（SDK 存在，待真机复核） | ✅ 生效 |
| AlertDialog.systemMaterial | 待核（API24 SDK alert_dialog 无该字段的可能性大 → 回落默认 Dialog 样式） | ✅ 生效 |
| 组件级/TitleBar/TabBar/Canvas | 不存在 | 存在但不渲染 |

双版本策略：容器承载统一，材质参数按 `canIUse('SystemCapability.ArkUI.ArkUI.Full')` + API 判据分支；API24 全部走 blur 体系。

## 5. 工程可行性

- 容器承载不破坏手势（Sheet 内 Slider 实测可拖动）；性能上 blur 层由系统渲染，代价与系统应用一致。
- 迁移是**逐面板渐进**的：先 Sheet 化一个面板（建议设置面板）验证视觉与交互，再批量。
- 未完成项：Popup 渲染问题排查（疑似程序化触发路径问题）、ContextMenu 验证、API24 真机复核。
