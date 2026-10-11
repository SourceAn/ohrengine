# Phase 25 Implementation Report — 导入书架 + 二次打开真实总页数

## 1. 交付目标
1. 重构调试书架：清空测试按钮页，参照正式书架实现「导入图书」。
2. 导入即开始缓存必要数据。
3. 图书第二次打开即显示真实总页数（EPUB《妹妹人生》318/318、TXT 同理），翻到末页退出后重开不变。

## 2. 已交付能力

### 2.1 导入书架（`entry/src/main/ets/debug/DebugBookshelf.ets` 重写）
- 清空原 8 个测试书按钮；UI 与交互参照 `pages/Bookshelf.ets`：标题栏 + 「导入图书」按钮 + 书籍列表 + 空书架态。
- 「导入图书」：系统文档选择器 `picker.DocumentViewPicker`（过滤器 `.epub/.txt/.cbz`）→ 文件名去编码 + 去重 → 分块流式拷入沙箱 `filesDir/books` → **自动打开阅读器**（阅读器会话执行全书后台分页缓存，即“导入即缓存”）。
- 行内二级文案显示缓存状态：`pgcount.json` 累计真实页数（>0 显示「已缓存分页：N 页（二次打开显示真实总页数）」；0 显示「首次打开将自动缓存分页」）。

### 2.2 真实总页数机制（引擎侧，格式无关 EPUB/TXT/CBZ）
- **新 sidecar `pgcount.json`（L2 缓存目录内，与 meta/chapter 同级）**：
  - `PageCacheManager.updatePageCount()`：每章分页写盘（saveChapter 同点）同步记录 chapterIndex→真实页数；layoutSignature 换代自动重置（防新旧代混用）。
  - `PageCacheManager.readPageCountIndex()` / `readChapterPageCount()`：读取/轻量回填（旧构建产出的完整 chapter 缓存无 pgcount 时，open 期一次性逐章补建，之后零扫描）。
  - `invalidate()` 同步清理 pgcount（与 meta/chapter 同生命周期）。
- **PageManager 三级页数**（`getChapterPageCount`）：已物化章真实页数 > L2 pgcount 页数 > 统一模型估算；`getDocumentTotalPages` 收敛为逐章 `getChapterPageCount` 求和。
- **open 期装载**：`OhEngineCore.loadPageCountIndex()` 在热窗同步后读取/回填 pgcount 并注入 PageManager；换书/签名变化（字号行距等设置变更）/destroy 均清空缓存表。
- 页码与总数同空间：ReaderHost 冷开/刷新改用 `getDocumentPageNumber()`（文档空间），此前用槽空间 `getGlobalPageNumber()`（未物化章 1 槽/章）导致“翻到书末显示 31 而非 318”。

### 2.3 修改文件清单
| 文件 | 改动 |
|---|---|
| `ohrengine-common/.../PageCacheManager.ets` | +PageCountIndex 类型、pgcount 读/写/原子替换、单章页数轻量读、invalidate 清理 |
| `ohrengine-common/Index.ets` | 导出 PageCountIndex 类型 |
| `ohrengine-ui-render/.../PipelineManager.ets` | 两个分页落盘点（增量写 + 全量同步）后调 `updatePageCount` |
| `ohrengine-ui-render/.../PageManager.ets` | cachedChapterCounts 字段/注入/清理；getChapterPageCount 三级页数（修 chunkToPages 塌缩回归）；getDocumentTotalPages 收敛 |
| `ohrengine-ui-render/.../OhEngineCore.ets` | `loadPageCountIndex()`（读+回填+注入）；open 热窗后调用；refreshPageCacheForSettingsChange 清空 |
| `ohrengine-reader/.../ReaderHost.ets` | openAndLoad/refreshPage 页码改文档空间；新增 `OPEN_TOTAL` 观测日志 |
| `entry/.../debug/DebugBookshelf.ets` | 整体重写为导入书架 |
| `entry/.../entryability/EntryAbility.ets`、`pages/Bookshelf.ets` | 恢复/新增 want 参数注入（bookPath 直达、debugShelf=1 直达调试书架）+ 可观测日志（EntryAbility 曾整体回退导致参数失效，本轮重加并经 AppStorage 中转） |

## 3. 真机验证证据（hilog）
```
PAGECOUNT_INDEX loaded=30 total=30 realPages=318 sig=229      ← 旧缓存一次性回填成功
OPEN_TOTAL page=318 total=318                                  ← 冷开（恢复在书末）即 318/318
（退出：READING_STATE_SAVE chid=text/part0028.html anchChid=part0028 slotCh=29 visual=30）
READING_RESTORE_PAGE_RESOLVE savedCh=part0028 resolvedCh=29 result=1 page=30
OPEN_TOTAL page=318 total=318                                  ← 退出重开仍 318/318（真实，非估算）
书架行：『test.epub · 已缓存分页：318 页（二次打开显示真实总页数）』
```
对照回归（修复前）：`OPEN_TOTAL page=318 total=40`（chunkToPages 槽空间塌缩）→ 修复后 318；页码侧此前冷开会显示 31/318（槽空间）→ 修复后 318/318。

## 4. 架构说明与约束遵守
- L2 缓存格式（meta/chapter 序列化）**未改**：pgcount 为并列新增 sidecar，读端缺失即退估算，向后兼容旧缓存。
- 页数权威语义未变：真实分页（物化/L2）永远优先于估算；pgcount 仅当 layoutSignature 与当前一致时生效。
- Worker JSON / LayoutResult / Lazy Geometry / Session 校验均未触碰。

## 5. 剩余风险 / 待验证
1. **TXT 真机导入 E2E 未跑通**：宿主无法向应用沙箱注入 TXT（公共存储在此设备不可达、旧 TXT 缓存已被 DiskCacheQuotaManager 配额清理、沙箱外路径 SELinux 拒绝）。TXT 与 EPUB 共用同一逐章落盘→pgcount→open 装载代码路径（Phase 24 已另证 TXT 146 章 L2 全命中），但建议用一台含真实 .txt 的设备走一遍「导入→阅读→退出→重开」确认 2MB lazy 章数书（数千页）open 期回填耗时可接受。
2. 大书（数千 vchapter）首次 open 的 pgcount 回填需逐章轻量解析，未做大书耗时实测（EPUB 30 章实测 ~1ms 级）。
3. 导入依赖系统文档选择器，仅 UIAbility 上下文可用（当前书架页即 UIAbility 页，满足）。
4. aa start 参数注入偶发不生效（仅 install 后冷启动/进程完全退出后可靠）——已用日志定位为平台 want 投递时序，不影响产品路径（书内导入不走该参数）。
