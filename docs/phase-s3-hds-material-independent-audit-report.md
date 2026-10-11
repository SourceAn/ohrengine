# Phase S.3 — HDS Material Independent Audit Report

> 独立二次审计（READ ONLY VISUAL AUDIT）。不默认采信 Phase S.1 / S.2 任何结论，全部核心实验在本机重新执行、重新测量。
> 设备：HUAWEI Mate 70 Pro+；证据归档：`docs/phase-s3-evidence/`。实验代码限于 `entry/src/main/ets/debug/`，审计结束后已恢复。
> 新增证据：**Case F（THICK 最强档大卡）** 与 **applyShadow 环带分析**，补上 S.2 未覆盖的两个判定漏洞。

---

## 1. Environment

| 项 | 值 |
|---|---|
| 设备 | HUAWEI Mate 70 Pro+（PLA-AL10） |
| OS / API | OpenHarmony-7.0.0.105（HarmonyOS 7）/ `const.ohos.apiversion`=26 |
| SDK | DevEco 内置 HarmonyOS SDK 26.0.0.32（Beta2），targetSdk 26.0.0，compatible 6.1.1(24) |
| 应用材质开关 | `ohos.arkui.UIMaterial.state=enable`；运行时 `getMaterialInfo()` = `state=1(ENABLE) type=2(IMMERSIVE)`（本次审计 hilog 再确认，见 `phase-s3-evidence/hilog.txt`） |
| 审计样本 | 12 张截图：base×3 背景、F(THICK)×3、B1、B2×2、D0、D1×2 |

---

## 2. Evidence Review

| 证据类型 | 可信度 | 能证明什么 / 不能证明什么 |
|---|---|---|
| 截图（snapshot_display） | **高** | 直接证明用户可见效果。本次用参数驱动冷启动采集，无 UI 注入误差 |
| 像素分析（趋势扣除 + 条纹波形 + 白纱回归） | **高** | 条纹方波→正弦 = 真 blur 的确定性特征；趋势扣除排除渐变背景假信号。S.2 曾出现的两类假信号（背景渐变、Dialog 透明容器透出页面控件）本次均以对照排除 |
| hilog `materialInfo` | 低（仅能力层） | 只证明应用级开关 ENABLE，**不能证明任何控件视觉生效**（本次再次验证：state=1 全程为 1，而组件级材质无一渲染） |
| dumpLayout | 中 | 证明节点/容器层级与坐标；不证明渲染结果 |

S.1 报告未在仓库归档（repo 内无该文件），其"三 Scope 效果一致、组件级已获材质"的观点只能按任务书转述参与对比，实测判定为**错误**（见 §4）。

---

## 3. Visual Verdict

### Q1 — 普通组件 systemMaterial()：**FAIL（全部档位）**

| 实验 | 指标 | 结果 | 判定 |
|---|---|---|---|
| A：Page 内 46vp 圆钮（ULTRA_THIN，生产同参） | 趋势扣除后 M−C 偏差 | M[3.4,4.2,4.4] vs C[4.4,4.7,5.6]（噪声级） | 无效果 |
| **F：1120×385px 大卡（THICK 最强档，纯净背景）** | 卡内条纹峰谷差 / 跳变 | M 54.0/45.6 vs C 53.6/48.5 —— 方波完整保留 | **无 blur** |
| F：M−C 均亮差 | 渐变/彩色/深色 | 3.64 / 0.94 / 3.08 | 无提亮/无色罩 |
| **F：applyShadow 环带** | 卡下缘紧邻 vs 远处背景 | 133.3 vs 134.9（彩色 110.4 vs 111.0，深色 74.3 vs 74.4） | **连阴影都没画**（SDK 文档称 applyShadow 在所有算力等级生效——仍未渲染，说明材质对象整体未被应用） |
| E1/E2：BottomBar 胶囊（THIN） | M−C 偏差 | ≤3.2 | 无效果 |

**关键推理（新增）**：S.2 只测了 ULTRA_THIN/THIN，理论上可被"档位太薄看不出来"反驳。本次 THICK 最强档 + 大面积 + 纯净背景 + applyShadow 环带四重排除后，**"组件级 ImmersiveMaterial 在该设备上完全不被渲染"成为唯一解释**。

### Q2 — CustomDialog 增强：**FAIL**

- 同一 Builder：Page（A）vs Dialog 透明容器（B2）：圆内条纹均保持方波（B2 跳变 44.7–75.3 量级保留），与 Page 无差异 → Dialog **不增强**。
- Dialog 默认容器（B1）：不透明白卡（参照 S.2 像素全零差分 + 本次 `B1_grad.jpeg`），其观感是容器背景，与材质无关。
- isModal true/false 无影响（S.2 C1/C2 已证）。

### Q3 — bindSheet 容器级材质：**PASS（唯一真实生效点）**

本次复测（`D1_grad/dark` vs `D0_grad`）：

| 指标 | D0（无 systemMaterial 对照） | D1（SheetOptions.systemMaterial） |
|---|---|---|
| Sheet 内均亮 | 243.3（不透明白卡） | 171.6（grad）/ 149.7（dark） |
| 条纹峰谷差 | **0.00**（背景完全不可见） | 7.50（grad）/ 10.0（dark） |
| 最大单步跳变 | 0.00 | **0.64**（raw 为 39.95） |
| 白纱回归 | α≈0.004，斜率 0.000 | α≈0.002，**斜率 0.123**，残差 RMS 1.18 |

判定链条：D0 证明 Sheet 默认背景=不透明白；D1 的"半透明白纱观感"无法用白色叠加解释（α≈0），只能解释为 **THIN 材质的真模糊层**（背景以 ~12% 对比度透出 + 亮度抬升）。肉眼复核（`D1_grad.jpeg`）：Sheet 上方条纹锐利、Sheet 内柔化成雾状——与像素结论一致。

---

## 4. API26 Behavior Conclusion

**API26（HarmonyOS 7）确实收紧了 ImmersiveMaterial 的应用范围，且边界非常清晰：**

```
MaterialState.ENABLE（应用级开关，hilog state=1 type=2）
        │
        ▼
系统容器级材质入口（bindSheet 的 SheetOptions.systemMaterial 等
SDK MaterialState.ENABLE 文档所列容器类：Dialog/Toast/Menu/Slider/
bindSheet/SelectionMenu…）
        │
        ▼  ✅ 真实渲染：blur + 背景采样 + 亮度响应
   真 HDS Immersive Material
        │
        ✗ 普通组件 .systemMaterial()（Button/Row/Stack/@Builder）
          ── 不渲染：无 blur、无高光、无 colorInvert、连 applyShadow 都不画
          ── 视觉等价于"什么都不设置" = 纯透明
```

- 这不是算力降级（Mate 70 Pro+ 为高算力机；且 applyShadow 按文档"全算力等级生效"也没画）。
- 不是参数问题（THICK 最强档 + materialColor 透明/微白 + lightEffect 均试过）。
- 与 SDK 文档语义吻合：ENABLE 状态的"默认材质生效清单"只包含系统容器类组件——**组件级通用属性在该设备上没有视觉实现**。
- isModal、OVERLAY/EMBEDDED、Dialog 容器类型均不改变上述边界。

**对两份报告的裁决**：Phase S.1（"三 Scope 一致、组件级已获材质"）**错误**；Phase S.2（"组件级透明退化、仅 Sheet 容器真实生效"）**正确**，本次以新增的 THICK/applyShadow 证据独立复现。

---

## 5. Final Architecture Recommendation

目标：最大化阅读器 UI 的 HDS 沉浸光感。

### ✅ 最推荐
1. **面板类 UI（设置/目录/搜索/选择菜单）迁移到 `bindSheet` + `SheetOptions.systemMaterial`** —— 唯一被三类独立实验（波形、回归、D0 对照）证实能产生真玻璃材质的容器。视觉收益真实、随背景变化。
2. **组件级材质全面回退 API24 平替**：把 `MaterialConfig` 的降级判据从"设备支持"改为"组件级材质实际有效"（本机恒 false），让 TopBar/BottomBar/胶囊/卡片回到「半透明底色 + backdropBlur」，先消除当前**全透明可读性风险**（这是现网正在发生的视觉回归，优先级最高）。

### ⚠️ 可接受（过渡）
3. TopBar/BottomBar 若必须保留悬浮形态：用 blurMaterial 平替（方案 2 即覆盖）；后续如华为开放组件级渲染再切回。

### ❌ 不推荐
4. **方案 A（继续组件级 systemMaterial）**：实测恒等于透明，零收益 + 可读性风险。
5. **方案 C（TopBar/BottomBar 用 CustomDialog）**：默认容器=不透明白卡（非玻璃）；透明容器=组件材质仍失效。两条路都拿不到材质，还引入模态交互成本。
6. **方案 D（Navigation/Popup/Menu）**：Navigation 不在 SDK ENABLE 生效清单，按证据预期无效（未实测，不推荐押注）；系统 Menu/SelectionMenu 属容器类**或**有效，但形态不适合 TopBar/BottomBar 自定义 UI。

---

## 附：本次审计可复现性

- POC：`entry/src/main/ets/debug/HdsMaterialScopePoc.ets`（审计后删除）
- 采集：`aa start --ps pocCase <base|F|B1|B2|C1|C2|D0|D1|D2|E2> --ps pocBg <gradient|colorful|dark> [--ps pocClean 1]`
- 复测脚本：`docs/phase-s3-evidence/audit.py`；运行时材料开关证据：`hilog.txt`
- 注意事项（踩坑记录）：POC 页必须在 `main_pages.json` 注册，否则 `loadContent` 报 errorCode 13 白屏；`snapshot_display` 仅支持 `.jpeg`。
