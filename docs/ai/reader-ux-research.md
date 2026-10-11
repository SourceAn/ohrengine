# OhEngine 阅读器 UX 调研与 ArkTS 实现设计

> 任务：t1 — 调研开源阅读器逻辑并设计 ArkTS 实现方案
> 调研人：researcher（team reader-opt-team）
> 日期：2026-08
> 目标读者：engineer-core（自动翻页 P0 排查）、后续翻页补间/选词/书签迭代
> 代码基线：entry/src/main/ets/（Index.ets / reader/ / panels/）、ohrengine-ui-render、ohrengine-feature

---

## 0. 摘要

- **自动翻页**：现有 `setInterval(3000/autoSpeed)` 驱动 `engine.turnPage(FORWARD)` 的结构正确，但存在 5 条可复现的 P0 根因假设（见 §5），其中「`turnPage` 返回 false 即同步 `stopAutoTurn`」与「按钮点击事件在设置面板移除后穿透到 Canvas → `onAutoTurnTap` 立即暂停」两条与真机现象（点击开启后不翻页）最吻合。修复建议：链式 `setTimeout` + 每拍日志 + 事件穿透防护 + timer ID 边界修正。
- **横滑/上下滑动补间动画**：新增 `SlideTurnController`（复用 `PageRenderer.drawPageContent` 的 `visibleY0/visibleY1` 行裁剪与 `translate` 变换），驱动方式沿用 `FlipPageController.animateTo` 的 `setInterval(16ms)+Date.now` 模式（真机验证过的路径），后续可升级 `displaySync`（@kit.ArkGraphics2D，API 11+）与 VSync 对齐。
- **选词**：现有 HitTester + 420ms 长按 + 双向手柄扩选已接入手势，按 foliate/Readium 范式补齐：词边界扩展、44vp 命中手柄、双击选词。
- **书签/章节映射**：现有 `TocItem.href(去锚) → spine href → chapterIndex → pages[0]` 与 preferences JSON 存储为业界常见做法（等价于简化版 CFI），建议补充「章内 charOffset 定位」（PageManager 已有 `navigateToCharOffset`）与锚点保留。
- **鸿蒙 API 关键事实**：`js-apis-timer.md` 明确「定时器 ID 从 0 开始进程共享递增」「非精准计时器」「UI 退后台定时器冻结」；`displaySync` 提供 VSync 帧回调；`showAlertDialog`/`CustomDialogController` 在 UIContext 下可用；Canvas 绘制指令排队、变换接口与像素读取接口跨帧无效。

---

## 1. 调研点 1：自动翻页与翻页方式

### 1.1 FBReader（FBReaderJ，Android）

**开源做法**：翻页动画由 `View` 层的 `AnimationProvider` 抽象驱动，实现分四类：`NoneAnimationProvider`（瞬时换页）、`SlideAnimationProvider`（整页横滑补间）、`CurlAnimationProvider`（卷角）、`MorphingAnimationProvider`（旧式变形）；动画进度由 `View` 的 `invalidate`/`onDraw` 配合帧时钟推进（`AnimationProvider.setup/doStep` 模式：每帧计算 progress → 绘制旧页/新页双位图）。自动翻页在 Android 版主要服务于 TTS 跟读：每句朗读结束由 `Handler.postDelayed` **链式**调度下一次翻页（而非固定 `setInterval`），间隔随朗读语速动态调整，翻到末页时停止并复位。
相关链接：https://github.com/geometer/FBReaderJ （`src/org/geometerplus/android/fbreader/view/AnimationProvider.java` 等），https://fbreader.org/en/android/reading-aloud

**对本项目的启示**：
1. 动画=「当前页/目标页双内容 + 每帧插值 + 双缓冲绘制」的通用范式 —— 与现有 `FlipPageController` 完全同构，横滑补间照此扩展即可；
2. 自动翻页用**链式 delay**（每次执行完再排下一次）而不是固定 interval，可天然避免重入/堆积、每拍可动态读取最新速度与状态。

### 1.2 KOReader（Lua，e-ink + Android）

**开源做法**：
- **Autoturn 插件**（`frontend/plugins/autoturn.koplugin/main.lua`）：基于 `UIManager:scheduleIn(seconds, action)` 调度翻页；每次翻页前重新取用户设定间隔（可 10–240s 甚至更长）；通过 `ui.paging/rolling` 的 `onGotoViewRel` 执行翻页；翻到末页（`no next`）自动停并通知；**用户任何触摸/翻页事件会重置 Autoturn 计时**（滚屏防抖：重新 schedule，实现「只在你没翻页时自动翻」的阅读节奏）；滚动模式（ReaderRolling）下配置为「跟随滚动位置」。
- 翻页模式：Paging（整页翻，仿真/滑动由 `screen` 刷新策略 + 纹理位图完成）与 Rolling（连续滚动，正文可滚动长文档 + 透视/截断渲染）。

**对本项目的启示**：
1. **「用户手动翻页/触摸重置自动翻页计时」**是成熟交互，本项目目前只在唤栏时暂停/恢复，可加「下次翻页倒计时随交互重置」；
2. 翻到末尾自动停（本项目已有：`turnPage` 返回 false → `stopAutoTurn`）与该插件一致；
3. 间隔范围应放宽（KOReader 支持 240s+），本项目 0.5x–1.5x 速度档可保留。

### 1.3 Readium / foliate（WebView 系）

**开源做法**：
- **foliate / foliate-js**（https://github.com/johnfactotum/foliate-js）：基于 WebView 全页滚动 + CSS 多栏（`columns`）切分实现分页；滚动模式（continuous scroll）关闭 columns，正文随 `scrollTop` 连续流动；翻页=滚动到下一栏位置（`scrollTo` + `behavior:'smooth'` 提供滑动补间，即浏览器原生平滑滚动）；点击热区用 Web 事件监听判定。
- **Readium r2-navigator-js**（https://github.com/readium/r2-navigator-js）：TS 实现，分页/滚动双模式，翻页动画由 WebView 内 CSS transition 完成；`Locator` 模型（`href + locations.progression/position`）贯穿翻页/书签/进度，形成书签、进度、TOC 定位的统一引用体系。

**对本项目的启示**：
1. 分页模型下「滚动式连续阅读」需要引擎支持「整页内容滚动」，对固定分页的 OhEngine 成本高；**推荐整页滑动补间**（视觉上接近，实现是纯 Canvas 平移，见 §7）；
2. **Locator 统一引用模型**：本项目已有 `Locator{href, chapterIndex, paragraphIndex, wordIndex}` 雏形，书签/进度/笔记可统一扩展（见 §3）。

### 1.4 legado（开源阅读）

**开源做法**：Android 阅读器，正文 WebView 渲染；翻页模式四类：**覆盖**（无转场瞬时换页）、**仿真**（卷页位图动画）、**滑动**（整页横向滑入补间）、**滚动**（正文纵向连续滚动，自动翻页在滚动模式下退化为「定时滚一屏」）。自动翻页为定时器循环翻页，末页停止。
相关链接：https://github.com/gedoor/legado（历史版本）；模式说明见 https://cngithub.com/archives/legado-reader

**对本项目的启示**：翻转（SIMULATION）/滑动（HORIZONTAL/VERTICAL）/无动画（NONE）四模式与本项目 `ReaderTurnMode` 一一对应，模式集合是业界共识，不必增删；缺的只是 HORIZONTAL/VERTICAL 的滑动补间动画。

### 1.5 STPageFlip（已内嵌本项目）

- `entry/src/main/ets/reader/FlipPageController.ets` + `FlipGeometry.ets` 为 StPageFlip（MIT）1:1 移植（任务声明 + 代码头注释印证）。
- 动画驱动：`animateTo(L620-674)` = `setInterval(tick, 16)` + `Date.now()` 插值（`t = (now - animStartTime)/animDuration`，线性采样 `start + (dest-start)*e`），支持变速（加速时前移 `animStartTime`）；真机验证通过。
- 拖拽节流：`FOLD_RENDER_INTERVAL=16ms` 合并高频 Move（L120-127）。
- 末页处理：`beginFold`/`playFlip` 对不可翻方向返回 false（无翻页动画），由上层 `onQuickTurn` 路径的 `engine.turnPage` 返回 false 兜底。

### 1.6 本项目适用性结论 + ArkTS 设计（自动翻页）

**现状链路**（`entry/src/main/ets/pages/Index.ets`）：
```
ReaderSettingsPanel「开启」→ onStartAutoTurn → startAutoTurn()                       (L732-736 / L981)
  ├─ autoTurning=true; showAutoTurnBar=false; hideControls()
  └─ startAutoTurnTimer()                                                            (L997)
       interval = max(500, round(3000/autoSpeed))
       setInterval(cb)：
         若 pageDestroyed||!autoTurning||showAutoTurnBar → return
         ok = engine.turnPage(FORWARD)  → ok ? refreshPage() : stopAutoTurn()        (L1006-1017)
点击正文（autoTurning 时）→ handleAutoTurnTouch(Up) → onAutoTurnTap → 清 timer + 显示 AutoTurnBar  (L1027-1036)
AutoTurnBar「关闭控制面板」→ onResume → startAutoTurnTimer()（继续）                    (L782-786)
```

**设计建议（配合 P0 修复，见 §5）**：
1. **链式 `setTimeout` 替代 `setInterval`**：每次 `tick` 末尾 `scheduleNext()` 重新读 `autoSpeed` 计算 `delay = max(500, round(3000/autoSpeed))`，天然防重入、变速即时生效（去掉 `restartAutoTurnTimer` 的 clear+重建）；
2. **单例 timer ID 防护**：`autoTurnTimer` 初值 -1 且以 `>0` 判有效不可靠（ID 可从 0 开始，见 §5 假设 1），改为「记录最近调度时刻 + 一个 UUID 令牌」，回调闭包捕获令牌，`stop` 时令牌失效 → 即使泄漏的 timer 也不会再翻页；
3. **每拍打日志**（hilight 降频）：`autoTurn tick ok=true page=12/345 token=..`，真机复现「开启不翻页」时第一拍日志即能区分「timer 未跑/回调被拦/turnPage=false」三类；
4. **交互保持**：点击正文唤栏暂停（现有）、关闭控制面板继续（现有）、手动翻页重置节奏（可选增强）。

---

## 2. 调研点 2：文本选择的精准选词与拖动手柄

### 2.1 foliate / Readium 的选择实现

- foliate：WebView 内使用浏览器原生 `Selection/Range`（anchor/focus），长按/双击由 Web 事件判定后进入选择态；选区两端绘制圆形手柄（绝对定位元素），拖动手柄 = 修改 anchor/focus 并逐字符扩缩；`selectionchange` 事件驱动弹出菜单定位（选区上方，`getBoundingClientRect`）。词边界由 `textContent` 分词（空白/标点）。
- Readium r2-navigator-js：`selectionstart/selectionchange` 事件向宿主 App 发出 `Locator`（起止），移动端依赖 WebView 原生选择手柄，CSS `::selection` 高亮；App 侧菜单围绕选区。
- 移动端阅读器共同范式（微信读书/Apple Books）：手柄命中区 ≥44vp、手柄离屏边缘自动吸附、菜单浮在选区首行上方、拖动可跨页（本项目无滚动可省略跨页）。

### 2.2 本项目现状（`ohrengine-feature/src/main/ets/selection/TextSelection.ets` + `ReaderGestureController.ets`）

- `HitTester.hitTest(pageLines,x,y)`：行盒 + 每字符 `charPositions` 命中 → charOffset（L34）。
- 长按 420ms 触达选择（`ReaderGestureController` L117-127 `setTimeout`）；`SelectionGestureHandler.handleTouchMove` 双向扩选，`nearStartHandle`（L288-309）按「拖动点与起点/终点手柄距离」选侧，阈值无显式判定（直接选近侧）。
- `SelectionRenderer`（TextSelection.ets L146）绘制高亮；`SelectionContextMenu` 菜单锚点 = 选区首行上方（Index.updateSelectionMenu）。
- 无词边界扩展：长按点中汉字即单字选区（任务描述「长按 420ms 选词」实际可能只选中单字）。

### 2.3 适用性结论 + 设计

1. **词边界扩展（精准选词）**：`handleTouchDown` 命中 charOffset 后向两侧扩展——CJK：按「非空白且非标点」扩展（遇到 !？。，、；：""''() 等标点停止）；拉丁：按空白扩展。扩展边界需要 pageLines 的字符内容（LineBox 已有 `charWidths`/文本可取自引擎页），若无每字符文本则退化为「行内首尾 trim」。
2. **手柄可视化 + 大命中区**：`SelectionRenderer` 增加两端手柄绘制（圆形 22vp 半径 + 白描边 + 主题色填充，绘制位置 = `startLine.renderedY + charPositions[startLocal]`，Y 用行中心）；手势判定：`isNearHandle` 距离阈值放大到 24vp 且「手柄区域优先于翻页判定」（在 `handleTouch` 的 Down/Move 分支前插入手柄检查）。
3. **双击选词**（可选增强）：`ReaderGestureController` 记录上次 Up 的 (x,y,time)，双击（间隔 <300ms、位移 <10vp）→ 直接进入词选择（复用长按闭包路径）。
4. **拖动扩选阈值**：现无最小位移，建议 Move 距触发点 >8vp 才开始扩选（避免轻微抖动改选区）。

---

## 3. 调研点 3：书签与章节映射

### 3.1 开源常见做法

- **EPUB 标准 CFI**（Readium/foliate 使用）：`epubcfi(/6/14[chap05ref]!/4/2:5)` 精确定位到章节内元素/字符；foliate 书签即存 CFI 字符串。
- **KOReader**：书签存 XPointer（`epubcfi(...)` 或 `(href)#element-id`），按章聚合并提供书签列表跳转。
- **位置引用三要素共识**：`章节 href（去锚）+ 章内字符偏移/段落索引 + 锚点 id`；展示时按 href 聚合、按阅读顺序排序。

### 3.2 本项目现状

- `Bookmark`（ohrengine-feature/src/main/ets/bookmark/Bookmark.ets）+ `BookmarkStorage`（preferences JSON，按 `bookmarks_{bookId}` 键分组存储，L113-115）。
- 章节映射：`PageManager.goToTocItem`（ohrengine-ui-render/src/main/ets/core/PageManager.ets L302-329）= `item.href.split('#')[0]` 与 `publication.getChapterLink(i).href` 逐章匹配 → 命中章 → `pages[0]`（该章第一页槽），**锚点被丢弃**。
- 章内定位能力已存在：`PageManager.navigateToCharOffset(chapterIndex, charOff)`（L535 附近，被超链接跳转复用）。
- `TocPanel` 用 `bookmarkChapters: Set<number>`（章节索引）决定 ◆ 图标（L96-98）。

### 3.3 适用性结论 + 设计

1. 现有「href 去锚 → spine 索引」是**简化版 CFI（够用）**，保持；增加书签定位精度：Bookmark 携带 `chapterIndex + startCharOffset + href`（Locator 已含，`addAnnotationFromSelection` 已有同样字段，L1058-1063），跳转 = `goToTocItem` 或 `goToChapter(chapterIndex)` 成功后 `navigateToCharOffset(chapterIndex, startCharOffset)`。
2. **锚点保留**：`goToTocItem` 目前去锚失败于「章内锚点页」；建议增加 `href#anchor` 解析：命中章内元素 id → 找包含该 id 行（段落级）→ 定位页（需引擎暴露锚点→行映射，可作后续增强）。
3. 排序/去重：书签列表按 `(chapterIndex, startCharOffset)` 排序；唯一键 = `(bookId, chapterIndex, startCharOffset)`；同页多书签并列。
4. 展示增强：TocPanel ◆ 可升级为「数字徽标」（该章书签数），跳转后以 toast 提示书签已定位。

---

## 4. 调研点 4：鸿蒙 API 知识库要点（$HOME/harmony_docs/arkui-api/docs_md）

| 主题 | 文档 | 关键签名 / 注意点 | 本项目用点 |
|---|---|---|---|
| Slider | `ts-basic-components-slider.md` | `Slider({value,min,max,step,style: SliderStyle})`；`onChange((value: number, mode: SliderChangeMode) => void)`；value 支持 `$$` 双向绑定（API 10+）；`SliderStyle.OutSet/InSet/NONE(12+)`；默认无 padding，水平默认高 40vp | 翻页速度 0.5x–1.5x（AutoTurnBar 已用）、字号 12–32vp（FontPanel 已用）；注意 step∈[0.01, max-min] |
| 定时器 | `js-apis-timer.md` | `setTimeout(handler, delay, ...args): number`；`setInterval` 同；**定时器 ID 进程共享、从 0 开始顺序递增**；**非精准计时器（实际延迟有误差）**；**UI 界面退后台定时器被冻结**；delay<1 取 0、>2^31-1 溢出为 0 | 自动翻页（P0 排查依据 §5 假设 1/4）、FLIP 动画驱动 |
| 帧驱动动画 | `js-apis-graphics-displaysync.md`（@kit.ArkGraphics2D，API 11+） | `displaySync.create()`；`setExpectedFrameRateRange({expected,min,max})`（fps 非负整数，min≤expected≤max，越界抛 401）；`on('frame', cb)` 回调参数 `IntervalInfo{timestamp,targetTimestamp}`（纳秒单调递增）；`start()/stop()`；回调在 **UI 主线程**执行、建议只做轻量逻辑 | 补间动画帧驱动候选（§7），替代 setInterval 与 VSync 对齐 |
| Toast / 占位提示 | `arkts-apis-uicontext-promptaction.md`；`js-apis-promptaction.md` | `this.getUIContext().getPromptAction().showToast(options)`（同步）；`openToast`（异步，返回 toastId 可 `closeToast`）；全局 `promptAction.showToast` 自 API 18 废弃（UI 上下文不明确） | `showPlaceholderToast`（Index L581 已用）、书签/进度提示 |
| 设置持久化 | `js-apis-data-preferences.md`（@kit.ArkData） | `preferences.getPreferences(context, name): Promise<Preferences>`；`store.get(key, default)`、`put`+`flush` | BookmarkStorage / ThemePreferenceStorage / ReaderSettings 持久化（已用） |
| 笔记输入 | `ts-basic-components-textinput.md`；`arkts-apis-uicontext-uicontext.md` | `TextInput({placeholder, text, controller})`，API 10+ 支持 `$$` 双向绑定；`TextInputController`（光标/选择控制）；对话框：`uiContext.showAlertDialog(AlertDialogParamWithConfirm|WithButtons|WithOptions)`；`CustomDialogController`（项目已在用） | 笔记输入（AnnotationPanel 已有）、快速笔记 Dialog |
| Canvas 变换/绘制 | `ts-canvasrenderingcontext2d.md` | `translate/rotate/scale/setTransform` 与 `getPixelMap/getImageData/toDataURL` **在不同帧执行时，后者无变换效果**；绘制指令入队、**Canvas 不可见时频繁绘制会堆积指令队列（内存）**；路径接口仅对 CanvasRenderingContext2D 生效；宽高 >8000px 走 CPU 渲染 | 补间动画的跨帧变换安全（每帧重设变换，勿依赖上一帧状态）；翻页动画期间页面不可隐藏 |
| 性能/工具 | 项目已用 | `hilog` from `@kit.PerformanceAnalysisKit`；`batteryInfo`/`systemDateTime` from `@kit.BasicServicesKit`（entry/src/main/ets/utils/ReaderStatus.ets） | 诊断日志、状态条 |

---

## 5. 自动翻页 P0 根因假设清单（供 engineer-core 排查）

真机现象：点击「开启」后不翻页（疑似 `autoTurning` 立即失效或 `turnPage` 返回 false）。以下按可能性排序，每条含验证方法：

**H1 — 按钮点击事件穿透：设置面板移除后 Up 事件落到 Canvas → `onAutoTurnTap` 立即暂停（最吻合现象）**
`ReaderSettingsPanel「开启」onClick`（Up 触发）→ `showSettings=false`（面板从 UI 树移除）→ `startAutoTurn()` → `setInterval` 建立。若同一触摸序列的 Up 在面板移除后仍路由到下层 `Canvas.onTouch`，`gestureController.handleTouch(Up)` → `isAutoTurning()===true` → `handleAutoTurnTouch` → `onAutoTurnTap()` → `clearInterval(刚启动的 timer)` + `showAutoTurnBar=true`（Index L1027-1036）→ 自动翻页被**立即暂停**，且 UI 可能偶现控制栏闪现。
验证：在 Index L733（onStartAutoTurn）与 L1027（onAutoTurnTap）各加 hilog 时间戳，真机复现「开启」操作，若两条日志间隔 <300ms 且无手动点击正文，则 H1 成立。修复：`onAutoTurnTap` 增加 500ms 防抖（记录 `lastAutoTurnTapTime`，开启动作后短期忽略）；或 Down 事件即暂停（在 Down 时清除 timer、Up 仅唤栏）。

**H2 — `turnPage` 返回 false 立即 `stopAutoTurn`（同步灭活）**
`engine.turnPage` → `PageManager.turnPage`（L199）在 `host.isReady===false` 返回 false；`goToNextPage`（L351）在 `currentGlobalPage+1 >= pageSlots.length` 返回 false。若开启时引擎/分页未就绪（书刚打开、`pageSlots` 为空或 stub、`ensureChapterReady` 的同步 `relayoutSingleChunk` 失败/慢），第一拍就 false → `stopAutoTurn()` 同步置 `autoTurning=false` → 后续 tick 全部 `return`。现象正是「开启后一页不翻」。
验证：`startAutoTurnTimer` 回调首行打日志：`isReady / pageSlots.length / totalPages / turnPage结果`。修复：末页判定改为「peek next 为空才停」，其余 false（未就绪）只跳过本拍不灭活；或将 `stopAutoTurn` 延迟到连续 N 拍 false。

**H3 — timer ID 边界缺陷（ID=0 判定失效 + interval 泄漏并发）**
`js-apis-timer.md`：定时器 ID「从 0 开始顺序增加」。Index `autoTurnTimer=-1` 且所有清理分支 `if (this.autoTurnTimer > 0)`（L991-993 / L998-1000 / L1031-1033）——若本次 `setInterval` 返回 0（首个/复用后分配），清理与防重复全部失效：旧 interval 泄漏，与下次 `startAutoTurnTimer` 新建的并发双跑（两个回调都读最新 `autoTurning=true` → 双倍 `turnPage`）；`onAutoTurnTap` 的清除分支也失效。
验证：开启自动翻页后 hilog 打印 `autoTurnTimer` 值；连续开关两次观察是否双倍翻页。修复：改用「生产-消费令牌」（`turnSession++` 捕获进闭包，回调首行 `if (token !== this.session) return`）替代 ID 判空；`clearInterval` 一律无条件下发。

**H4 — 定时器受 UI 管控冻结/非精准 + 状态多次复位**
`js-apis-timer.md`：UI 退后台定时器冻结；非精准（误差）。若开启后页面短暂后台（拉起系统面板等）恢复，interval 可能补发多拍（连续快翻）或停摆。另检查窗口变化回调（`onWindowSizeChangeCb` L88）与 `persistSettings` 是否在任何路径误复位 `autoTurning`（当前未见显式复位，需 grep 全量确认 `autoTurning=false` 赋值点：仅 startAutoTurn/stopAutoTurn 两处）。
验证：开启后 hilog 每拍时间戳，比对间隔漂移；后台/前台切换后观察续跑行为。

**H5 — 速度 NaN/极端值导致 interval 非法**
`interval = Math.max(500, Math.round(3000/this.autoSpeed))`：若 `autoSpeed` 从 preferences 恢复为 NaN/0/Infinity，`round(NaN)=NaN` → `setInterval` delay=NaN → 行为未定义（文档：非数字按 0 处理 → **0ms 高频翻页**或不可用）。`autoSpeed` 的 Slider 范围 0.5–1.5 正常，但持久化恢复路径缺防御。
验证：打印恢复的 `autoSpeed`。修复：`Math.max(500, Math.round(3000 / (Number.isFinite(autoSpeed) && autoSpeed > 0 ? autoSpeed : 1)))`。

排查顺序建议：先 H1（日志打点最快），再 H2，再 H3/H4/H5。修复后须验证：开启→自动翻页→点击正文唤栏暂停→关闭控制面板继续→加速滑块即时变速→末页自动停→退出自动翻页，全链路 hilog 断言。

---

## 6. 横滑/上下滑动翻页的 Canvas 补间动画设计

### 6.1 目标

`ReaderTurnMode.HORIZONTAL` 与 `VERTICAL` 目前走 `onQuickTurn` 即时换页（ReaderGestureController L239），无过渡动画。补间动画目标：**手指拖拽跟手 + 松手补全/回弹**（iBooks/legado 滑动翻页范式），动画时长 ~300ms，与仿真翻页（400ms）观感一致。`NONE` 保持即时。

### 6.2 架构

新增 `entry/src/main/ets/reader/SlideTurnController.ets`（实现 `FlipGestureAdapter` 同款接口契约，可被 `ReaderGestureController` 以相同方式驱动）：

```
SlideTurnController（implements FlipGestureAdapter）
  ├─ beginFold(x,y,startX): 记录起点、peek 目标页（engine.peekPage(direction)）
  │    目标页不存在 → 返回 false（外层走即时翻页/不动作）
  ├─ updateFold(x,y): 实时 offset = 手指位移（clamp ±W），合并渲染（≥16ms 节流）
  ├─ endFold(): 按阈值/速度判定补全或回弹 → animateTo(targetOffset)
  ├─ playFlip(direction,x,y): 直接启动补全动画（无拖拽阶段）
  └─ animateTo()/tick(): setInterval(16ms)+Date.now 插值（照抄 FlipPageController.animateTo 模式）
```

接入点（Index.ets）：`gestureController` 的 `flip` 字段改注入「模式分派器」：`turnMode===SIMULATION → flipController`，`HORIZONTAL/VERTICAL → slideController`，`NONE → null`（保持即时）；或 `ReaderGestureController.turnPage` 内按 mode 分派（改造最小，推荐后者：L235-241 已有 mode 分支）。

### 6.3 绘制（复用 PageRenderer 管线）

坐标系沿用 `drawCurrentPageToContext`：背景铺满 → `translate(margins.left, margins.top+avoidAreaTopVp)` → 内容区坐标。

- **横滑**：在一帧内画两页——`fromPage` 平移 `(offset, 0)`；`toPage` 平移 `(offset ∓ contentWidth, 0)`（FORWARD：toPage 在右侧 `offset + W`）。
- **上下**：同上把 x 换 y（`visibleY0/visibleY1` 行裁剪参数**直接支持**纵向可见区，上下模式天然受益；横滑时传 `(-1, 1e9)` 不裁剪）。
- 伪代码（每帧一次 `render()`）：
```
drawFrame(offset) {
  ctx.save(); ctx.fillStyle = theme.backgroundColor; ctx.fillRect(0,0,canvasW,canvasH); ctx.restore();
  // fromPage（内容区原点已在 translate 后）
  ctx.save(); ctx.translate(offset, 0);
  drawPageContent(ctx, fromPage, 'vp', 1, -1, 1e9);
  ctx.restore();
  // toPage 相邻
  ctx.save(); ctx.translate(offset < 0 ? offset + W : offset - W, 0);
  drawPageContent(ctx, toPage, 'vp', 1, -1, 1e9);
  ctx.restore();
  // 可选：页面间边缘阴影（线性渐变 24vp 宽），clip 到页面矩形
}
```
注意（来自 ts-canvasrenderingcontext2d.md）：变换必须每帧**显式重设**（save/restore 包裹），不得依赖上一帧变换状态；动画期间 Canvas 必须可见（指令队列堆积风险）。

### 6.4 时序与判定

- 拖拽跟手：`updateFold` 时 `offset = clamp(手指当前x - 起点x, ±W)`；Move 合并节流 ≥16ms（照 FlipPageController.FOLD_RENDER_INTERVAL 模式）。
- 松手判定：`|offset| > W*0.35` 或 末段速度 > 0.8vp/ms → 补全至 `∓W`；否则回弹至 0。动画时长 `300ms`，缓动 `ease-out`（`e = 1-(1-t)^3`，可选恒线速 `e=t` 与 STPageFlip 对齐）。
- 动画结束：`onPageTurned(direction)` → `engine.turnPage` + `refreshPage()`（与 FlipPageController.finishFlip 契约一致）；动画期间 `engine` 当前页不动（同 FlipSession 语义），`onFlipStateChange(true/false)` 控制选择清除与控制层隐藏。
- 到边缘：`engine.peekPage(direction)` 为空 → `beginFold`/`playFlip` 返回 false，外层回弹动画（向 0 回弹，带 8% 阻尼橡皮筋状）或直接不响应。

### 6.5 帧驱动升级（可选，二期）

`setInterval(16ms)` 是已真机验证的路径，保留为基线；升级方案：`displaySync.create()` + `setExpectedFrameRateRange({expected:60, min:30, max:60})` + `on('frame', cb)`（cb 内 `Date.now()` 插值逻辑不变）+ `start()/stop()`；`stopAnimation` 时配套 `off('frame')` + `stop()`。收益：与 VSync 对齐、掉帧时系统调度更平滑；风险：API 11+，需 `import { displaySync } from '@kit.ArkGraphics2D'`。

### 6.6 与自动翻页的组合

- 自动翻页 tick：`turnMode===SIMULATION` → 保持现状直接 `engine.turnPage`（无动画，最快最稳）；`HORIZONTAL/VERTICAL` → 调 `slideController.playFlip(FORWARD, x, y)`（300ms 补间，视觉连续）；动画期间（`isActive()`）tick 跳过（下一拍 interval 不受影响）。
- P0 修复落地前，自动翻页一律走 `engine.turnPage` 直翻（最小改动面）。

---

## 7. 单手模式与翻页模式的交互矩阵

### 7.1 当前实现行为（ReaderGestureController.ets / Index.ets）

行为定义见：`tapZoneOf`（L278：<25% 左区、>75% 右区、中间 50% 中区）、`isSwipeTurn`（L244：SIM/横滑 横向 58vp 主导、VERTICAL 纵向 40vp 主导、NONE 横竖 40vp 任一）、`deriveSwipeDirection`（L260）、自动翻页激活拦截（L99-102）。

| 输入 \ 模式 | SIMULATION | HORIZONTAL | VERTICAL | NONE | 自动翻页激活时（任意模式） |
|---|---|---|---|---|---|
| 单击左区（<25%） | 上一页（动画） | 上一页（即时） | 上一页（即时） | 上一页（即时） | 暂停并唤起 AutoTurnBar |
| 单击中区（25–75%） | 切换控制层 | 切换控制层 | 切换控制层 | 切换控制层 | 暂停并唤起 AutoTurnBar |
| 单击右区（>75%） | 下一页（动画） | 下一页（即时） | 下一页（即时） | 下一页（即时） | 暂停并唤起 AutoTurnBar |
| 横滑（左，>58vp 主导） | 下一页（折叠动画） | 下一页（即时） | 不翻页 | 下一页（即时） | 忽略 |
| 横滑（右） | 上一页（折叠动画） | 上一页（即时） | 不翻页 | 上一页（即时） | 忽略 |
| 上滑（>40vp 主导） | 不翻页 | 不翻页 | 下一页（即时） | 下一页（dy 主导时） | 忽略 |
| 下滑 | 不翻页 | 不翻页 | 上一页（即时） | 上一页（dy 主导时） | 忽略 |
| 长按 420ms → 选词 + 双端手柄扩选 | 同左 | 同左 | 同左 | 同左 | 同左 |
| 单手模式开（单击任意位置） | 下一页（动画） | 下一页（即时） | 下一页（即时） | 下一页（即时） | 暂停并唤起 AutoTurnBar |

### 7.2 实施补间动画后的目标矩阵（变更点高亮）

| 输入 \ 模式 | SIMULATION | HORIZONTAL ▲ | VERTICAL ▲ | NONE |
|---|---|---|---|---|
| 单击左/中/右区 | 不变 | 不变 | 不变 | 不变 |
| 横滑（左/右） | 不变（折叠动画） | **拖拽跟手 → 松手补全/回弹（300ms）** | 不翻页 | 不变（即时） |
| 上滑/下滑 | 不翻页 | 不翻页 | **拖拽跟手 → 补全/回弹** | 不变（即时） |
| 拖动方向与之反的滑动（如 VERTICAL 下横滑） | — | 不翻页（保持） | 不翻页（保持） | 即时翻页（NONE 语义=都翻） |

设计决策：
- 拖拽跟手翻页只在 `HORIZONTAL/VERTICAL` 生效，与仿真（折叠）与 NONE（即时）形成三档体验梯度；
- 自动翻页 + HORIZONTAL/VERTICAL 走补间动画（§6.6），+ SIMULATION/NONE 直翻；
- 单手模式只影响「单击」语义，滑动/长按不受影响（保持现状）；
- 选中态（selection!==null）时任何翻页输入先清除选区（现有 L109-114 行为），补间动画沿用。

---

## 8. 附录：参考来源

- FBReaderJ：https://github.com/geometer/FBReaderJ （AnimationProvider：None/Slide/Curl/Morph 四类）；官方 TTS 跟读说明 https://fbreader.org/en/android/reading-aloud
- KOReader：autoturn 插件 `frontend/plugins/autoturn.koplugin/main.lua`（UIManager:scheduleIn 调度、手动翻页重置节奏）；用户指南 https://koreader.rocks/user_guide ；autoturn 需求讨论 https://github.com/koreader/koreader/issues/4984
- foliate / foliate-js：https://github.com/johnfactotum/foliate-js （scroll/paginated 双模式、anchor/Range 定位、selection 事件）
- Readium r2-navigator-js：https://github.com/readium/r2-navigator-js （Locator/selection 事件模型）
- legado：https://github.com/gedoor/legado （覆盖/仿真/滑动/滚动四翻页模式）
- STPageFlip（本项目内嵌）：Nodlik/StPageFlip MIT，1:1 移植于 entry/src/main/ets/reader/Flip*.ets
- 鸿蒙 API 知识库：$HOME/harmony_docs/arkui-api/docs_md（文件索引见 §4 表）