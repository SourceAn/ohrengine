# OhEngine Bench 报告（设备实测）

> 运行目录：`$HOME/Code/Harmony/Project/ohrengine/tests/bench/results/20261009-175039`　设备：见 `meta.json`　日志：`logs/`
> 数据来源：hilog 应用内埋点（CacheStats / COLDSTART / LAYOUT_* / OPEN_TOTAL / TXT-LAZY）。

## 1 打开路径（每个样例）

| 样例 | 场景 | openMs | restoreMs | txtLazyIdxMs | 首帧(ms,设备钟) | 锚点(ms,设备钟) | totalPages | 行数 |
|---|---|---|---|---|---|---|---|---|
| bench_cbz | cold | 0 | 0 | 0 | 3 | 2 | 3 | 4247 |
| bench_cbz | warm | 0 | 0 | 0 | 4 | 2 | 3 | 7944 |
| bench_epub_s | cold | 0 | 0 | 0 | 70 | 68 | 305 | 4421 |
| bench_epub_s | warm | 0 | 0 | 0 | 10 | 8 | 318 | 6029 |

## 2 排版 / Worker 耗时分布

| 样例 | 场景 | Worker 排版 n | p50(ms) | p95(ms) | max(ms) | 后台章 n | p50 | p95 | max |
|---|---|---|---|---|---|---|---|---|---|
| bench_cbz | cold | 0 | — | — | — | 0 | — | — | — |
| bench_cbz | warm | 0 | — | — | — | 0 | — | — | — |
| bench_epub_s | cold | 27 | 28 | 360 | 373 | 10 | 215 | 418 | 418 |
| bench_epub_s | warm | 0 | — | — | — | 0 | — | — | — |

## 3 翻页动画帧耗时（finishFlip）

| 样例 | 场景 | 次数 | avgMs P50 | avgMs P95 | maxMs(Max) |
|---|---|---|---|---|---|

## 4 稳定性

| 样例 | 场景 | THREAD_BLOCK/Freeze | 崩溃 | 缓存摘要 |
|---|---|---|---|---|
| bench_cbz | cold | 0 | 0 | L3hits=0 L2hits=0 L2miss=3 liveLayout=0 hitRate=0% layoutMs=0 / L3 chapters=0 bytes~=0 |
| bench_cbz | warm | 0 | 0 | L3hits=0 L2hits=0 L2miss=3 liveLayout=0 hitRate=0% layoutMs=0 / L3 chapters=0 bytes~=0 |
| bench_epub_s | cold | 0 | 0 | L3hits=0 L2hits=0 L2miss=3 liveLayout=0 hitRate=0% layoutMs=0 / L3 chapters=3 bytes~=0 |
| bench_epub_s | warm | 0 | 0 | L3hits=0 L2hits=3 L2miss=0 liveLayout=0 hitRate=100% layoutMs=0 / L3 chapters=3 bytes~=0 |

## 5 埋点覆盖（未出现的指标 = 该场景未触发）

| 样例 | 场景 | 命中埋点 |
|---|---|---|
| bench_cbz | cold | sessionInit×2, sessionOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1 |
| bench_cbz | warm | sessionInit×2, sessionOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1 |
| bench_epub_s | cold | sessionInit×2, sessionOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×27, bgChapter×10, bgEnd×1 |
| bench_epub_s | warm | sessionInit×2, sessionOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, bgEnd×1 |
