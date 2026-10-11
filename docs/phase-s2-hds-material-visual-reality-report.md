# Phase S.2 — HDS Material Visual Reality Report

> 多模态视觉实测复验：API 26 / HarmonyOS 7 下 ImmersiveMaterial 在不同 Scope 的真实渲染效果。
> 本报告只读验证，未修改任何生产实现；POC 页面验证后已恢复。
> 证据归档：`docs/phase-s2-evidence/`（截图 / 并排放大图 / hilog / 像素数据）。

---

## 1. Test Environment

| 项 | 值 |
|---|---|
| 设备型号 | HUAWEI Mate 70 Pro+（`const.product.model` = PLA-AL10，brand HUAWEI） |
| OS 版本 | `const.ohos.fullname` = OpenHarmony-7.0.0.105（HarmonyOS 7 / API 26） |
| API | `const.ohos.apiversion` = **26**（开机画面与屏上运行时双重确认） |
| 屏幕分辨率 | 1316 × 2832（snapshot_display 实测），密度标定 ≈ 3.507 px/vp |
| 编译环境 | DevEco Studio 内置 SDK API 26（26.0.0.32 Beta2），targetSdk 26，compatible 6.1.1(24) |
| 应用级材质开关 | module.json5 `ohos.arkui.UIMaterial.state=enable` |
| 运行时 materialInfo | hilog 实测 `state=1 (ENABLE) type=2 (IMMERSIVE)` |

**统一实验变量**：同一设备、同一 POC 页、同一 Builder 内容（M/C 成对并排、同尺寸/圆角/内边距）、同一三套背景（渐变 / 彩色 / 深色），背景叠加 42px 周期方波条纹 + 9fp 高频细文本作为 blur 检测基准。

**方法学要点**：
- 每个 Case 均设「M 有材质」+「C 无材质」对照（`systemMaterial(undefined)`），直接排除背景本身干扰。
- 采集采用 `aa start --ps pocCase/pocBg` 参数驱动冷启动，不依赖 UI 坐标注入（坐标注入在本机实测不可靠）。
- 像素分析先扣除背景水平渐变趋势再比较 M/C 偏差；blur 判据采用条纹方波波形分析（峰谷差 + 单步跳变），跳变归零 = 真模糊，跳变保留 = 透明。

---

## 2. Screenshot Evidence

截图全部在 `docs/phase-s2-evidence/`：

| 文件 | 内容 |
|---|---|
| `base_grad/color/dark.jpeg` | Case A（Page TopBar 对）+ Case E1（Page BottomBar 对），3 背景 |
| `B1_grad.jpeg` | CustomDialog modal 默认容器 → **不透明白卡，内容区全白** |
| `B2_grad/dark.jpeg` | CustomDialog modal 透明容器 → M/C 均纯透明 |
| `C1_grad.jpeg` / `C2_*` | non-modal，结论与 B1/B2 相同（isModal 不影响材质） |
| `D0_grad/dark.jpeg` | **bindSheet 无 systemMaterial 对照 → 纯不透明白卡** |
| `D1_grad/dark.jpeg` `D2_grad` | bindSheet + systemMaterial → **真实模糊材质层**（OVERLAY 与 EMBEDDED 渲染一致） |
| `E2_grad.jpeg` | Sheet 内 BottomBar：M 胶囊与 C 对照无差异 |
| `side_A_grad/dark.png` `side_B2_grad/dark.png` | M/C 圆形按钮 4x 并排放大（决定性肉眼证据） |

关键肉眼判读（`side_B2_grad.png`、`side_A_dark.png`）：背景 9fp 细文本与 21px 条纹穿过 M（有材质）按钮时**边缘完全锐利**，与 C（无材质）无可辨差异——无模糊、无提亮、无高光边、无阴影。

---

## 3. Pixel / Visual Analysis

### 3.1 组件级材质（Page / Dialog 内控件）—— 透明退化

扣除了背景水平渐变趋势后的 M/C 偏差（RGB 通道最大差）：

| Case | 渐变背景 | 彩色背景 | 深色背景 |
|---|---|---|---|
| A Page TopBar | **1.2** | **1.8** | **1.5** |
| B2 Dialog(透明容器) TopBar | ≈同 A（同向） | ≈同 A | ≈同 A |
| E1 Page BottomBar 胶囊 | 3.1 | 1.1 | 1.0 |
| E2 Sheet BottomBar 胶囊 | 3.2 | — | — |

（单位：8-bit 级数；JPEG 噪声底 ≈ 2–3。原始 `M_vs_C` 差值达 25+ 的假信号全部可归因于背景渐变的水平变化与页面控件透过透明对话框的污染，已用趋势扣除与纯净模式复测排除。）

### 3.2 条纹方波波形 —— blur 判定（决定性）

| 测试点 | 条纹峰谷差 | 最大单步跳变 | 判定 |
|---|---|---|---|
| 裸背景（raw） | 44.1 | 39.95 | 方波（锐利阶跃） |
| **A/B2/E2 内 M 或 C 按钮** | 46–106（随背景位置） | 40–84（量级保留） | **无模糊，纯透明** |
| **D1 bindSheet 容器（+systemMaterial）** | **7.5** | **0.64** | **真模糊**：方波→平滑正弦，背景仅以 ~12% 对比度透出 |
| D0 bindSheet（无 material 对照） | **0.00** | **0.00** | 不透明白卡（均亮 243.3），背景完全不可见 |

白色遮罩假设检验：对 sheet 内/外条纹做 `covered = α·255 + (1−α)·bg` 线性回归，D1 拟合 α≈0.002、残差 RMS 1.18 —— **D1 的效果不能用白色叠加解释，只能解释为模糊材质层**。

### 3.3 UI Dump / Hilog

- `materialInfo state=1 type=2`（ENABLE + IMMERSIVE）在 page-appear 与每个 Case 打开时均确认 —— **API 报告成功 ≠ 视觉成功**（本阶段核心警示成立）。
- dumpLayout 确认容器层级：Dialog 内容与 Sheet 内容均在独立窗口层节点下；Page Scope 控件与背景同树。
- D1 与 D2（OVERLAY / EMBEDDED）像素级无差异。

---

## 4. Scope Comparison

| Scope | 容器观感 | 容器内组件级材质 | 容器级材质（SheetOptions/DialogOptions.systemMaterial） |
|---|---|---|---|
| Page（Stack 内普通组件） | 无容器 | **无效 → 纯透明** | —（不适用） |
| CustomDialog modal 默认容器 | 不透明白色圆角卡 | 无效（卡内全白） | （生产 WordLookupDialog 用法即此形态） |
| CustomDialog non-modal | 同 modal | 无效 | — |
| CustomDialog 透明容器（customStyle） | 全透明 | **仍无效** | — |
| bindSheet 无 systemMaterial | 不透明白卡（243） | 无效 | — |
| **bindSheet + systemMaterial** | **真模糊材质层**（THIN 生效） | 无效（E2 内胶囊 M=C） | **✅ 唯一真实生效点** |

---

## 5. API26 Material Behavior Conclusion

1. **`state=ENABLE` + `type=IMMERSIVE` 只代表应用级开关打开，不代表任何具体控件产生了视觉材质。**
2. **组件级 `.systemMaterial()` 通用属性在本机（高算力 API 26 真机）对所有被测普通组件无任何视觉实现**：无模糊、无提亮、无高光、无阴影、无 colorInvert 反色。等效于 `opacity` 式的"什么都不做"。
3. **材质的真实实现只存在于容器级**：`bindSheet` 的 `SheetOptions.systemMaterial` 实测将默认不透明白底替换为真实模糊材质（背景以 ~12% 对比度透出 + 亮度抬升）。这与 SDK `MaterialState.ENABLE` 文档所列默认生效组件（Dialog/Toast/Menu/Slider/**bindSheet**/SelectionMenu 等系统容器类）完全吻合——这是 **API 设计语义**，不是算力降级或 bug。
4. Modal/非 Modal、OVERLAY/EMBEDDED 对材质渲染均无影响。

---

## 6. Correction to Phase S.1

Phase S.1 结论「Page / CustomDialog / bindSheet 中 ImmersiveMaterial 表现一致，Popup Scope 没有增强效果」**判定为部分错误**：

| Phase S.1 观点 | Phase S.2 实测修正 |
|---|---|
| 三种 Scope 表现一致 | ❌ 不一致：**只有 bindSheet 容器级材质真实渲染**；Page 与 Dialog 内组件级全部无效 |
| Sheet 白色半透明来自 Sheet 默认遮罩/背景 | ❌ D0 证明默认 Sheet 是**不透明白卡**；「白色半透明」恰是 systemMaterial 生效后的模糊材质观感（blur + 亮度抬升），来源判反了 |
| Dialog 与 Page 一致（均无效） | ✅ 成立（B2/C2 与 A 一致）；但需补充：Dialog **默认容器是不透明白卡**，其观感与材质无关 |
| hilog ENABLE 即成功 | ❌ ENABLE ≠ 视觉成功，本阶段核心警示成立 |

对用户原始四点肉眼观察的解释：
- TopBar modal / non-modal 透明 → 组件级材质无效（Q1=透明退化）；
- BottomBar Dialog 透明 → 同上，Dialog 不增强；
- Sheet 白色半透明 → **真 ImmersiveMaterial 在容器级生效**（不是遮罩）。

---

## 7. Final Architecture Recommendation

**Q1 = B（透明退化）；Q2 = 否；Q3 = A（真 ImmersiveMaterial，仅容器级）；Q4 = 部分成立（精确表述：不是"全面收紧"，而是"仅系统容器类实现材质，普通组件级无实现"）；Q5 结论如下——**

按**视觉收益真实存在**排序（不考虑改动成本）：

1. **方案 B —— 目录/设置迁移到 bindSheet：唯一被实测证实能产生真沉浸光感的路径。** SheetOptions.systemMaterial 渲染真实模糊玻璃层，背景内容透出且随背景变化（正弦波形证据）。收益真实、立即可见。
2. **生产修复（独立于迁移的 P0）**：当前 `MaterialConfig` 在 `isImmersiveSupported()==true` 时返回「透明底色 + 关闭 blur」，依赖组件级 systemMaterial 渲染——而实测组件级**不渲染**。因此**当前生产阅读器的 TopBar 圆钮、BottomBar 胶囊、TocPanel 胶囊、设置卡等全部处于纯透明状态**（这正是用户肉眼观察到的现象）。组件级材质路径应整体回退到 API24 平替（半透明底色 + backdropBlur），即把 `currentMenuMaterialMode()` 的判据从「设备支持」改为「组件级材质有效」——后者在本机恒为 false。
3. **方案 C（迁 TopBar/BottomBar 到 Dialog）：无收益。** Dialog 默认容器是不透明白卡（非沉浸玻璃），透明容器下组件材质同样失效——两条路都拿不到材质。
4. **方案 A（保持现状）：等于放弃玻璃质感**，浮层保持纯透明，仅剩图标可读。
5. **方案 D（Navigation/HdsNavigation）：未实测，预期无收益**——Navigation 不在 MaterialState.ENABLE 文档的默认生效组件清单中。

一句话：**把材质需求收敛到 Sheet 容器；其余组件级材质全部回退 blurMaterial 平替。**

---

## 附：复验可复现性

- POC 页面：`entry/src/main/ets/debug/HdsMaterialScopePoc.ets`（验证后已删除）
- 采集方式：`aa start --ps pocCase <base|B1|B2|C1|C2|D0|D1|D2|E2> --ps pocBg <gradient|colorful|dark> [--ps pocClean 1]`
- 分析脚本与原始数据：`docs/phase-s2-evidence/pixel_report.json`
