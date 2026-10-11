# OhEngine Bench 报告（设备实测）

> 运行目录：`$HOME/Code/Harmony/Project/ohrengine/tests/bench/results/20261009-170628`　设备：见 `meta.json`　日志：`logs/`
> 数据来源：hilog 应用内埋点（CacheStats / COLDSTART / LAYOUT_* / OPEN_TOTAL / TXT-LAZY）。

## 1 打开路径（每个样例）

| 样例 | 场景 | openMs | restoreMs | txtLazyIdxMs | 首帧(ms,设备钟) | 锚点(ms,设备钟) | totalPages | 行数 |
|---|---|---|---|---|---|---|---|---|
| bench_txt_s | cold | 0 | 0 | 615 | 1710 | 1706 | 227 | 3523 |
| bench_txt_s | warm | 0 | 0 | 0 | 32 | 28 | 198 | 2978 |

## 2 排版 / Worker 耗时分布

| 样例 | 场景 | LAYOUT_CHAPTER n | p50(ms) | p95(ms) | max(ms) | COLDSTART 后台章 n | p50 | p95 | max |
|---|---|---|---|---|---|---|---|---|---|
| bench_txt_s | cold | 0 | — | — | — | 15 | 309 | 604 | 604 |
| bench_txt_s | warm | 0 | — | — | — | 0 | — | — | — |

## 3 翻页动画帧耗时（finishFlip）

| 样例 | 场景 | 次数 | avgMs P50 | avgMs P95 | maxMs(Max) |
|---|---|---|---|---|---|

## 4 稳定性

| 样例 | 场景 | THREAD_BLOCK/Freeze | 崩溃 | 缓存摘要 |
|---|---|---|---|---|
| bench_txt_s | cold | 3 | 0 | L3hits=0 L2hits=0 L2miss=3 liveLayout=0 hitRate=0% layoutMs=0 / L3 chapters=3 bytes~=57393 |
| bench_txt_s | warm | 3 | 0 | L3hits=0 L2hits=3 L2miss=0 liveLayout=0 hitRate=100% layoutMs=0 / L3 chapters=3 bytes~=57393 |

## 5 埋点覆盖（未出现的指标 = 该场景未触发）

| 样例 | 场景 | 命中埋点 |
|---|---|---|
| bench_txt_s | cold | block×3, sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×15, bgChapter×15, bgEnd×1 |
| bench_txt_s | warm | sessionInit×2, block×3, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, bgEnd×1 |
