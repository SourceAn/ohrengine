# Phase S.7 — HDS Material Host 架构决策验证（终版）

> 基于 S.2~S.6 六轮真机实验（HUAWEI Mate 70 Pro+ / API 26）+ API24 SDK 声明核对，给出 Material Host 矩阵、阅读器组件映射与最小改造方案。
> 本阶段补充采集了 Route A 双背景复核与近全屏变体；Popup/ContextMenu 的交互复测因设备进入锁定/占用状态未能完成（如实标注，入口存在性与部分实验已完成）。
> 生产代码零改动，环境已恢复。

---

## 1. Material Host Matrix

| Host | API24 接口 | API24 渲染 | API26 接口 | API26 渲染（实测） | 自定义承载能力 | 推荐等级 |
|---|---|---|---|---|---|---|
| **Sheet**（bindSheet + SheetOptions） | ❌ systemMaterial（0 处）✅ **blurStyle**（5 处）→ `blurStyle + 半透明底` 平替 | 待真机复核（blur 体系成熟，预期可用） | ✅ `SheetOptions.systemMaterial` | ✅ **真 blur**（条纹跳变 0.72~1.15，S.4 Slider 拖动/交互正常） | ★★★★★ 整面板原样承载 | **Rank 1** |
| **AlertDialog**（AlertDialog.show） | ❌ 无 systemMaterial / blurStyle 字段（均 0 处）→ 回落系统默认 Dialog 样式 | — | ✅ `systemMaterial` | ✅ **真 blur**（跳变 3.02，斜率 0.08，α≈0） | ★★ **无 builder**（双版本均 0 处），仅 message+按钮 | **Rank 2**（确认框/轻提示） |
| **Popup**（bindPopup + CustomPopupOptions） | ❌ systemMaterial 0 处 | — | ✅ 接口存在；渲染验证**未完成**（程序化与点击触发均未弹出，疑似 builder 传递/触发路径问题） | 待测 | ★★★ 待定（形态最贴近阅读器浮层） | Rank 3（补测后定） |
| **ContextMenu**（bindContextMenu + ContextMenuOptions） | ❌ 0 处 | — | ✅ 接口存在；长按注入验证被设备锁定中断 | 待测 | ★★★ 待定（划词菜单唯一候选） | Rank 3（补测后定） |
| **Overlay / Window 级** | ❌ | — | ❌ OverlayManager/子窗口无任何材质 API | — | ★ 不可用 | ✗（"独立 Material Layer"不存在，勿再寻找） |
| 组件级 `.systemMaterial()`（全档位含 Canvas） | ❌ API 不存在 | — | ✅ 存在 | ❌ 四档全不渲染（S.2/S.3/S.5 三轮确认） | — | ✗ |

**关键事实**：API24 的 HDS 形态是 `blurStyle`/backdropBlur 体系（blur 视觉成熟），API26 的 HDS 形态是容器级 `systemMaterial`（真系统材质）——**两代都有 HDS，只是入口不同**，架构上用「同一容器壳 + 版本分支参数」统一。

## 2. 阅读器组件映射方案

| 组件 | 推荐 Host | 原因 |
|---|---|---|
| **ControlPanel**（控制面板） | **Sheet Host** | ReaderControlMock 实证：面板原样放入即获全量玻璃；Slider/按钮/列表交互无损 |
| **TOC** | **Sheet Host** | TOC 列表/章节项在 Sheet 内实测清晰可读；Scroll 可滚动 |
| **BottomBar** | **Sheet Host（可配置近全屏/半屏/禁拖拽条）** 或保持悬浮+blur 平替 | Sheet 不支持顶部锚定，BottomBar 形态（底部悬浮胶囊）若追求系统材质需以底部 Sheet 变体承载；否则 blur 平替（视觉可用） |
| **TopBar** | 保持悬浮 + **blurMaterial 平替**（P0） | Sheet 无法顶部锚定；Navigation TitleBar 材质实测无效；组件级无效 |
| **SelectionMenu**（划词菜单） | **ContextMenu Host（待补测）**，fallback 自绘浮层 + blur 平替 | ContextMenuOptions.systemMaterial 是唯一原生候选；补测步骤已就绪（长按注入 + dump 校准） |
| **确认框/轻提示** | **AlertDialog Host** | 真材质已实证；仅文本+按钮，够用 |

## 3. 最终架构方案（可落地）

```
Reader Page
   ↓
【容器壳层】按场景选择 Host：
   ├─ Sheet Host（API26: SheetOptions.systemMaterial / API24: blurStyle+半透明底）
   │     └─ ControlPanel / TOC / 设置 / 大菜单（现有组件整体放入，零重写）
   ├─ AlertDialog Host（API26 only；API24 回默认样式）
   │     └─ 确认框 / 轻提示
   └─ blurMaterial 平替（API24 全部 + API26 的 TopBar/BottomBar 悬浮件）
         └─ 半透明底色 + backdropBlur（现有 MaterialConfig API24 路径即此）
```

## 4. 修改成本评估

- **是否需要重写组件？不需要。** ReaderControlMock（含导航钮/Slider/胶囊/设置卡/TOC）原样放入 Sheet 即获玻璃——已实证。
- **是否只需要增加 Host 外壳？是。** 每个面板一个 `bindSheet` 壳 + 一处版本分支（systemMaterial / blurStyle）。
- **可直接复用**：ControlPanel、TOC、设置面板的全部内部组件；确认框走 AlertDialog。
- **需要调整**：
  1. `MaterialConfig` 判据改为「组件级材质有效」（本机恒 false）→ 立即修复全透明 P0（一行级改动）；
  2. WordLookupDialog：`CustomDialogControllerOptions.systemMaterial` 实测无效 → 改 AlertDialog（文本场景）或 Sheet（富内容场景）；
  3. 悬浮 TopBar/BottomBar：确认其平替参数生效（现状已透明，需回归半透明+blur）。

## 5. 未完成项更新（S.6c 干净复测，2026-09-05 14:5x）

> 重要修正：S.5/S.6 的"Popup 不弹"部分数据无效——当时应用已处于**渲染冻结**状态（dump 可读组件树但帧不提交，状态栏时钟停走；force-stop 后截图恢复即证实）。干净重测结论如下：

- **Popup Host：FAIL（干净实验）**。`bindPopup` 两种模式（CustomPopupOptions.builder / PopupOptions.message，均带 systemMaterial）在**程序触发与按钮点击触发**下均不显示（实时帧截图 `HC_popup_retry.jpeg`：锚点可见、无 popup 窗口节点）。长按手势注入路径也已挂接。
- **ContextMenu Host：注入触发未成功**。`longClick` 注入后无菜单节点（`HD_menu_retry.jpeg`）。**需人工复核**：在 POC 页长按「长按我：模拟划词菜单」——若人工长按也不弹，则 ContextMenu 路线判定 FAIL；若人工可弹，需确认材质并检查注入工具差异。
- 深色背景下的自制材质（`fake_page_dark.jpeg`）：注：该图深色切换未生效（点击未命中），实际深色响应可通过书架入口手动切换"深色"按钮查看。

## 6. 追加：自制材质组件（不依赖 systemMaterial 的复刻实现）

---

## 6. 追加：自制材质组件（不依赖 systemMaterial 的复刻实现）

针对「组件级材质不渲染」的现实，按系统关闭钮（showClose）的视觉构成做了纯 ArkUI 复刻，三个粒度可复用：

| 系统特征 | 自制实现 |
|---|---|
| 渐变高光边缘环（上缘最亮） | 外层 `linearGradient(160°)` 描边层：浅底 `#CC→14→80 FFFFFF`，深底 `#66→4D FFFFFF` |
| 内凹 blur 面 | 内缩 2px 的 `backgroundBlurStyle(BACKGROUND_REGULAR)` + 极淡 tint |
| 顶部内侧反光 | 顶部 1/3 高度白色渐变条 |
| 投影 | `shadow(radius 6, offsetY 2)`，深浅分支 |
| 深浅自适应 | tint / 描边 / 文字色按深色分支 |

组件：`fakeGlassRound`（圆钮）/ `fakeGlassCapsule`（胶囊）/ `fakeGlassCard`（设置卡）——**纯 ArkUI、零 systemMaterial 依赖**，页面级（无任何 Host 借宿）直接可用，实拍见 `fake_page_grad.jpeg`：高光环、内凹面、卡片磨砂与深浅分支全部呈现。

**定位**：它不是"骗过系统"，而是系统玻璃的工程复刻——blur 部分是真实时采样（backdropBlur），光感/边缘是参数化模拟；与系统原生材质的差距在动态光效与 interactive 形变。适用于 TopBar/BottomBar 等无法容器化的悬浮件；能容器化的场景仍优先 Rank 1/2（系统原生材质 + 白送的 showClose 玻璃钮）。

### 工程注意事项

- 调试书架已新增常驻入口「🧪 HDS 材质 Host POC」→ `debug/HdsMaterialHostPoc`，路由永久注册，后续验证不再劫持 EntryAbility。
- 采集脚本曾全部误跳过的根因：**macOS BSD grep 不支持 BRE `\|`**，需 `grep -E`。
- 息屏后 `snapshot_display` 返回缓存帧、dump 仍可读组件树——**必须用"连拍两帧比对"识别冻结帧**，否则会误判；`power-shell wakeup` 后若仍无法到前台即停止（勿反复注入）。
- 用户使用设备期间严禁注入点击/截图（两次涉私截图已即时删除）。



---

## 【终版补充】官方约束确认 + Route H/I 验证通过（2026-09-05 16:1x）

用户提供官方约束文档后，确认了 API26 材质生效区域的**官方定义**，并按官方姿势重测：

### 官方生效区域（targetSdkVersion >= 26.0.0）

- 弹窗类组件/接口（AlertDialog/ActionSheet/CustomDialog/各 Picker/SelectionMenu/PromptAction/Popup/Tips/菜单/半模态转场）→ 全区域生效
- **Slider / Toggle / Select** → 全区域生效
- **Navigation / NavDestination 标题栏** 与 **横向 Tabs 中 barPosition=End 的底部 TabBar** → 区域内生效
- 其他所有组件 → 不生效

### Route H — Navigation 标题栏：**PASS ✅**

官方姿势：`.title(自定义标题Builder, { barStyle: BarStyle.STACK })`，材质标在 **Builder 内的组件**上（此前 S.5 用 `NavigationTitleOptions.systemMaterial` 是错误姿势）。

实测（`H_final.jpeg`/`H_btn_zoom.png`）：标题栏内自定义圆钮（‹/☰）呈现**清晰高光边缘环 + 玻璃面**，与系统关闭钮同款质感。→ **TopBar 的官方答案**。

### Route I — Tabs 底部 TabBar：**PASS ✅**

官方姿势：`Tabs({barPosition: BarPosition.End}) + .barFloatingStyle({systemMaterial}) + .barOverlap(true)`，tabBar 传自定义 Builder。

实测（`I_tabbar.jpeg`/`I_btn_zoom.png`）：胶囊玻璃 TabBar（高光边缘环+磨砂面）承载三个自定义圆钮（书/☰/我），全部获得真沉浸光感。→ **BottomBar 的官方答案**。

### 修正记录

- S.5 的"Navigation TitleBar FAIL / TabBar FAIL"为**错误姿势所致**（NavigationTitleOptions.systemMaterial 直传无效；TabBar 漏配 barOverlap）——以本节官方姿势为准。
- S.6c 的"HC popup FAIL"部分成立：builder 模式崩溃根因是**组件 @Builder 方法经 CustomPopupOptions 传递后 this 丢失**（TypeError: observeComponentCreation2 of undefined），改用**全局 @Builder 函数**可修复编译，但 message/builder 两种 popup 的 systemMaterial 实测均无效（斜率 0.83，无 blur）——Popup Host 仍不可用。
- "触摸拦截"根因：bindSheet 宿主 Column（100%×100%）需 `.hitTestBehavior(HitTestMode.None)`，否则拦截整页触摸——所有"按钮按不动"皆因此。

### 最终架构（全部实证）

```
阅读器改造路线（三通道全部真材质）：
├─ TopBar      → Navigation 标题栏（自定义标题 Builder + BarStyle.STACK）
├─ BottomBar   → Tabs 底部 TabBar（barFloatingStyle + barOverlap + 自定义 tabItem）
├─ ControlPanel/TOC → bindSheet（SheetOptions.systemMaterial）
├─ 确认框      → AlertDialog.show（systemMaterial）
└─ 页面级装饰件 → 自制 fakeGlass 组件（backdropBlur + 渐变高光环，V2 可加快照 vibrancy）
```

## 【附录】Route G — 供体组件"伪装"实验（保布局路线，2026-09-05 16:4x）

用户约束：不改布局/逻辑，仅原地加沉浸光感。官方白名单中 Slider/Toggle/Select 全区域生效——测试它们能否作为"材质供体"垫底或换壳：

| 供体 | 默认态 | 透明化后 | 判定 |
|---|---|---|---|
| Slider（裸/垫底） | 蓝色轨道遮盖 | **透明后材质不渲染**（直接消失） | ✗ 垫底方案失败 |
| Toggle.Button | 灰色胶囊（非玻璃） | — | ✗ |
| **Select** | **粉雾玻璃胶囊 + 高光圈 + 条纹柔化** | — | ✅ **唯一自带真玻璃壳的供体**（但为下拉选择器形态） |
| SegmentButton | 运行时 `SegmentButtonOptions.capsule` 静态方法缺失（d.ets 有声明，运行时 undefined is not callable） | — | ✗ 框架缺陷 |
| Chip | 无玻璃壳 | — | ✗ |

**结论**：保布局前提下，唯一"骗过系统"的供体是 **Select**——它的胶囊壳是真沉浸光感，可作为"玻璃菜单按钮"（点击弹出选项列表恰是菜单语义）。Slider/Toggle 的垫底欺骗不可行（透明即消失）。

**保布局的最终选择**（三选一）：
1. Select 伪装菜单按钮（唯一真材质，形态受限）
2. 自制 fakeGlass（视觉复刻，已实现，blur 强度达标但光感细节不及原生）
3. 向华为反馈组件级材质回归（官方文档承认 26.0.0 Beta 变更，targetSdk>=26 生效；可申请豁免或等待回调）


- `docs/phase-s7-evidence/HA_grad/dark.jpeg`：Sheet Host 承载 ReaderControlMock（近全屏、磨砂玻璃）
- `docs/phase-s7-evidence/HA2_full_grad.jpeg`、`HB_grad.jpeg`
- 像素复核：Sheet 跳变 0.72/1.15、Alert 跳变 3.02（真 blur 特征）
- 六轮历史证据：`docs/phase-s2-evidence/` ~ `docs/phase-s6-evidence/`（含各报告）
