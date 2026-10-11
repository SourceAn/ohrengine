# Phase S.4 — HDS Immersive Material Route Feasibility Validation

> 路线可行性验证：在不大规模重构、不修改生产代码的前提下，实测五条 HDS 沉浸光感接入路线，给出 API24 / API26 双版本均可落地的工程方案。
> 设备：HUAWEI Mate 70 Pro+（API 26 / OpenHarmony-7.0.0.105）。证据：`docs/phase-s4-evidence/`。POC 限于 `debug/`，验证后已恢复。

---

## 1. 测试环境

| 项 | 值 |
|---|---|
| API26 实机 | HUAWEI Mate 70 Pro+，`const.ohos.apiversion`=26，materialInfo `state=1(ENABLE) type=2(IMMERSIVE)` |
| API24 验证手段 | 无 API24 真机/可用模拟器实例（模拟器需 Device Manager GUI 创建）。API24 侧结论基于 **API24 SDK 声明文件核对**（`~/Library/Huawei/Sdk/openharmony_new/24`）+ 工程现有降级体系代码路径分析，**标记为待真机复核** |
| 方法 | 与 S.2/S.3 相同：M/C 成对对照 + 三背景 + 条纹方波波形（跳变保留=透明，跳变归零=真 blur）+ 趋势扣除；新增**交互注入验证**（`uitest uiInput swipe` 实测成功） |

---

## 2. Route Matrix

| 路线 | API26（实测） | API24（SDK 声明核对） | 是否可用 |
|---|---|---|---|
| **A 组件级 `.systemMaterial()`** | ❌ 四档位全灭 | ❌ **API 根本不存在**（`uiMaterial` 无声明、`systemMaterial` 0 处） | ✗ 双版本都不可用 |
| **B bindSheet + `SheetOptions.systemMaterial`** | ✅ 真玻璃（跳变 39.95→0.6~1.2） | ⚠️ `systemMaterial` 字段不存在，**但 `SheetOptions.blurStyle` 存在（5 处）** → 可用 blurStyle 达成近似玻璃 | ✅ 双版本可用（参数分支） |
| **C Dialog 容器（C1 默认 / C2 透明 / C3 Dialog级材质 / C4 透明+Dialog级材质）** | ❌ C3 容器内均亮 255.0、条纹 0.00（纯白卡）；C4 条纹方波保留（无玻璃） | ❌ `CustomDialogControllerOptions.systemMaterial` API24 不存在 | ✗ Dialog 级 `systemMaterial` 选项在 API26 上实测无效（**生产 WordLookupDialog 当前正在使用的正是这条失效路线**） |
| **D Sheet 容器 + 内部现有组件（最小迁移）** | ✅ 容器供玻璃，内部 Slider/胶囊/卡片透明叠放、清晰可读、**交互正常**（Slider 实测可拖动 40%→85%） | 同 B（blurStyle 分支） | ✅ 推荐：最小改动迁移形态 |
| **E API 版本兼容** | 见 §4 差异矩阵 | — | ✅ 统一为「Sheet 容器 + 版本分支材质参数」 |

### 各路线关键实测数据

**Route A（AM 矩阵，四档位 × 三背景）**：卡内条纹跳变 36.8~81.4，与无材质对照（44.1~84.6）同量级，方波完整保留 → ULTRA_THIN/THIN/REGULAR/THICK 无一渲染。REGULAR 档此前未测，本阶段补齐后 **A 路线在 API26 的死刑判决覆盖全部档位**。

**Route C（新增 C3/C4）**：
- C3（Dialog 级 `systemMaterial`，即生产 WordLookupDialog 用法）：容器内均亮 255.0、条纹峰谷差 0.00 → 就是一块白卡，材质选项无效；
- C4（透明容器 + Dialog 级材质）：按钮区条纹跳变 39.9/61.8（方波保留）→ 无玻璃。

**Route B/D（D3 面板副本）**：Sheet 内条纹跳变 0.60（grad）/1.15（dark）——真 blur 特征；内部完整面板副本（进度 Slider、字号行、四枚功能胶囊、信息卡片）全部正常显示、正常交互（`D3_slide.jpeg` 可见 Slider 手柄被注入拖动至 ~85%）。

---

## 3. 每条路线截图证据（`docs/phase-s4-evidence/`）

| 文件 | 证明内容 |
|---|---|
| `AM_grad/color/dark.jpeg` | Route A：四档位 + 对照，三背景下均无玻璃 |
| `C3_grad/dark.jpeg` | Dialog 级 systemMaterial → 纯白卡（生产查词弹窗现状） |
| `C4_grad/dark.jpeg` | 透明容器 + Dialog 级材质 → 仍无玻璃 |
| `D3_grad/dark.jpeg` | **Route B/D：Sheet 承载完整面板副本，统一磨砂玻璃** |
| `D3_slide.jpeg` | Sheet 内 Slider 交互注入成功（手柄 40%→85%） |
| `D0_grad.jpeg` / `D1_grad.jpeg` | Sheet 无材质（不透明白）vs 有材质（真 blur）对照 |
| `audit_s4.py` | 全部像素指标可复现脚本 |

---

## 4. API24 / API26 差异

| 能力 | API24（6.1.1） | API26（HarmonyOS 7） |
|---|---|---|
| `uiMaterial` / `ImmersiveMaterial` / 组件级 `systemMaterial` | **不存在**（编译期即不可用） | 存在但普通组件**不渲染**（实测） |
| `SheetOptions.systemMaterial` | **不存在** | 存在且**真实生效**（真 blur） |
| `SheetOptions.blurStyle` | **存在**（SDK 声明 5 处）→ API24 玻璃落点 | 存在（作为平替） |
| `CustomDialogControllerOptions.systemMaterial` | 不存在 | 存在但实测无效 |
| 工程现状 | `MaterialConfig.ensureDetected()` 在 API24 自动降级 blurMaterial 体系（设计正确） | `immersiveSupported=true` 误判组件级可用 → **全透明 P0** |

---

## 5. 推荐架构与最小迁移方案

### 推荐路线（最终输出）

```
推荐路线：Route B/D — 「Sheet 容器承载 + 版本分支材质参数」
原因：API26 实测唯一真实玻璃渲染点；API24 有 blurStyle 等价落点；
     内部组件零材质依赖、交互无损、迁移面最小。
API26 方案：bindSheet(..., { systemMaterial: <THIN ImmersiveMaterial> })
API24 方案：bindSheet(..., { blurStyle: BlurStyle.BACKGROUND_REGULAR,
                             backgroundColor: <半透明底色> })   // 待真机复核
风险：Sheet 交互形态与现有 Stack 浮层不同（高度/圆角/拖拽关闭/遮罩），
     需按面板逐个调 SheetOptions（detents/height/preferType）；
     API24 blurStyle 视觉与 API26 系统材质存在观感差异（可接受，两者本就不同代）。
```

### 需要修改范围（最小迁移清单，按收益排序）

1. **P0 修复（不动架构）**：`MaterialConfig` 判据从「设备支持」改为「组件级材质有效」（本机恒 false），让 TopBar/BottomBar/卡片/胶囊立即回到 API24 平替（半透明底 + backdropBlur），消除当前全透明。
2. **设置面板 / TOC → bindSheet（Route D）**：现有面板组件整体作为 sheet builder，材质参数走版本分支；WordLookupDialog 的 `systemMaterial` 选项实测无效，改为 Sheet 或普通白卡 Dialog。
3. **TopBar/BottomBar**：保持悬浮形态 + blurMaterial 平替（方案 1 覆盖）；不强行容器化。
4. **搜索/选择菜单**：系统 Menu/SelectionMenu 属 ENABLE 生效清单（容器类），可后续单独验证。

### 明确放弃

- Route A（组件级 systemMaterial）与 Route C（Dialog 容器路线）：双版本均无法获得 HDS 玻璃，实测封死。

---

## 附：交互验证说明

S.2 曾因 `uitest uiInput click` 坐标无效误判注入不可用；本阶段 `uiInput swipe`（px 坐标）实测成功（`D3_slide.jpeg`），Sheet 内控件手势响应无损。Sheet 下拉关闭、多档 detents 属常规能力，未逐项展开。
