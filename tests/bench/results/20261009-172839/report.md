# OhEngine Bench 报告（设备实测）

> 运行目录：`$HOME/Code/Harmony/Project/ohrengine/tests/bench/results/20261009-172839`　设备：见 `meta.json`　日志：`logs/`
> 数据来源：hilog 应用内埋点（CacheStats / COLDSTART / LAYOUT_* / OPEN_TOTAL / TXT-LAZY）。

## 1 打开路径（每个样例）

| 样例 | 场景 | openMs | restoreMs | txtLazyIdxMs | 首帧(ms,设备钟) | 锚点(ms,设备钟) | totalPages | 行数 |
|---|---|---|---|---|---|---|---|---|
| bench_demo | cold | 0 | 0 | 29 | 69 | 64 | 6 | 7782 |
| bench_demo | warm | 0 | 0 | 1 | 11 | 6 | 6 | 4289 |
| bench_epub_s | cold | 0 | 0 | 0 | 70 | 68 | 305 | 4560 |
| bench_epub_s | warm | 0 | 0 | 0 | 10 | 8 | 318 | 4279 |
| bench_txt_m | cold | 0 | 0 | 2685 | 3987 | 3984 | 1683 | 5054 |
| bench_txt_m | warm | 0 | 0 | 0 | 49 | 46 | 1655 | 6819 |
| bench_txt_s | cold | 0 | 0 | 438 | 1692 | 1688 | 227 | 4290 |
| bench_txt_s | warm | 0 | 0 | 1 | 43 | 40 | 198 | 7078 |

## 2 排版 / Worker 耗时分布

| 样例 | 场景 | Worker 排版 n | p50(ms) | p95(ms) | max(ms) | 后台章 n | p50 | p95 | max |
|---|---|---|---|---|---|---|---|---|---|
| bench_demo | cold | 0 | — | — | — | 0 | — | — | — |
| bench_demo | warm | 0 | — | — | — | 0 | — | — | — |
| bench_epub_s | cold | 27 | 25 | 358 | 370 | 10 | 212 | 413 | 413 |
| bench_epub_s | warm | 0 | — | — | — | 0 | — | — | — |
| bench_txt_m | cold | 11 | 558 | 734 | 734 | 11 | 702 | 864 | 864 |
| bench_txt_m | warm | 19 | 243 | 659 | 659 | 19 | 306 | 804 | 804 |
| bench_txt_s | cold | 15 | 516 | 666 | 666 | 15 | 572 | 823 | 823 |
| bench_txt_s | warm | 0 | — | — | — | 0 | — | — | — |

## 3 翻页动画帧耗时（finishFlip）

| 样例 | 场景 | 次数 | avgMs P50 | avgMs P95 | maxMs(Max) |
|---|---|---|---|---|---|

## 4 稳定性

| 样例 | 场景 | THREAD_BLOCK/Freeze | 崩溃 | 缓存摘要 |
|---|---|---|---|---|
| bench_demo | cold | 0 | 0 | L3hits=0 L2hits=0 L2miss=3 liveLayout=0 hitRate=0% layoutMs=0 / L3 chapters=3 bytes~=5481 |
| bench_demo | warm | 0 | 0 | L3hits=0 L2hits=3 L2miss=0 liveLayout=0 hitRate=100% layoutMs=0 / L3 chapters=3 bytes~=5481 |
| bench_epub_s | cold | 0 | 0 | L3hits=0 L2hits=0 L2miss=3 liveLayout=0 hitRate=0% layoutMs=0 / L3 chapters=3 bytes~=0 |
| bench_epub_s | warm | 0 | 0 | L3hits=0 L2hits=3 L2miss=0 liveLayout=0 hitRate=100% layoutMs=0 / L3 chapters=3 bytes~=0 |
| bench_txt_m | cold | 0 | 0 | L3hits=0 L2hits=0 L2miss=3 liveLayout=0 hitRate=0% layoutMs=0 / L3 chapters=3 bytes~=57393 |
| bench_txt_m | warm | 0 | 0 | L3hits=0 L2hits=3 L2miss=0 liveLayout=0 hitRate=100% layoutMs=0 / L3 chapters=3 bytes~=57393 |
| bench_txt_s | cold | 0 | 0 | L3hits=0 L2hits=0 L2miss=3 liveLayout=0 hitRate=0% layoutMs=0 / L3 chapters=3 bytes~=57393 |
| bench_txt_s | warm | 0 | 0 | L3hits=0 L2hits=3 L2miss=0 liveLayout=0 hitRate=100% layoutMs=0 / L3 chapters=3 bytes~=57393 |

## 5 埋点覆盖（未出现的指标 = 该场景未触发）

| 样例 | 场景 | 命中埋点 |
|---|---|---|
| bench_demo | cold | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1 |
| bench_demo | warm | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1 |
| bench_epub_s | cold | sessionInit×2, sessionOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×27, bgChapter×10, bgEnd×1 |
| bench_epub_s | warm | sessionInit×2, sessionOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, bgEnd×1 |
| bench_txt_m | cold | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×11, bgChapter×11 |
| bench_txt_m | warm | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×19, bgChapter×19 |
| bench_txt_s | cold | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×15, bgChapter×15, bgEnd×1 |
| bench_txt_s | warm | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, bgEnd×1 |
