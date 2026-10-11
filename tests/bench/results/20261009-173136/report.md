# OhEngine Bench 报告（设备实测）

> 运行目录：`$HOME/Code/Harmony/Project/ohrengine/tests/bench/results/20261009-173136`　设备：见 `meta.json`　日志：`logs/`
> 数据来源：hilog 应用内埋点（CacheStats / COLDSTART / LAYOUT_* / OPEN_TOTAL / TXT-LAZY）。

## 1 打开路径（每个样例）

| 样例 | 场景 | openMs | restoreMs | txtLazyIdxMs | 首帧(ms,设备钟) | 锚点(ms,设备钟) | totalPages | 行数 |
|---|---|---|---|---|---|---|---|---|
| bench_cbz | cold | 0 | 0 | 0 | 4 | 2 | 3 | 5152 |
| bench_cbz | warm | 0 | 0 | 0 | 4 | 2 | 3 | 6700 |
| bench_pdf | cold | — | — | — | — | — | — | 4063 |
| bench_pdf | warm | — | — | — | — | — | — | 4182 |
| bench_txt_l | cold | — | — | — | — | — | — | 4083 |
| bench_txt_l | warm | 0 | 0 | 2 | 74 | 69 | 6258 | 4807 |
| bench_txt_xl | cold | — | — | — | — | — | — | 13170 |
| bench_txt_xl | warm | — | — | — | — | — | — | 11200 |

## 2 排版 / Worker 耗时分布

| 样例 | 场景 | Worker 排版 n | p50(ms) | p95(ms) | max(ms) | 后台章 n | p50 | p95 | max |
|---|---|---|---|---|---|---|---|---|---|
| bench_cbz | cold | 0 | — | — | — | 0 | — | — | — |
| bench_cbz | warm | 0 | — | — | — | 0 | — | — | — |
| bench_pdf | cold | 0 | — | — | — | 0 | — | — | — |
| bench_pdf | warm | 0 | — | — | — | 0 | — | — | — |
| bench_txt_l | cold | 0 | — | — | — | 0 | — | — | — |
| bench_txt_l | warm | 18 | 511 | 713 | 713 | 18 | 558 | 855 | 855 |
| bench_txt_xl | cold | 0 | — | — | — | 0 | — | — | — |
| bench_txt_xl | warm | 0 | — | — | — | 0 | — | — | — |

## 3 翻页动画帧耗时（finishFlip）

| 样例 | 场景 | 次数 | avgMs P50 | avgMs P95 | maxMs(Max) |
|---|---|---|---|---|---|

## 4 稳定性

| 样例 | 场景 | THREAD_BLOCK/Freeze | 崩溃 | 缓存摘要 |
|---|---|---|---|---|
| bench_cbz | cold | 0 | 0 | L3hits=0 L2hits=0 L2miss=3 liveLayout=0 hitRate=0% layoutMs=0 / L3 chapters=0 bytes~=0 |
| bench_cbz | warm | 0 | 0 | L3hits=0 L2hits=0 L2miss=3 liveLayout=0 hitRate=0% layoutMs=0 / L3 chapters=0 bytes~=0 |
| bench_pdf | cold | 0 | 0 | — |
| bench_pdf | warm | 0 | 0 | — |
| bench_txt_l | cold | 0 | 0 | — |
| bench_txt_l | warm | 0 | 0 | L3hits=0 L2hits=3 L2miss=0 liveLayout=0 hitRate=100% layoutMs=0 / L3 chapters=3 bytes~=57393 |
| bench_txt_xl | cold | 0 | 0 | — |
| bench_txt_xl | warm | 0 | 0 | — |

## 5 埋点覆盖（未出现的指标 = 该场景未触发）

| 样例 | 场景 | 命中埋点 |
|---|---|---|
| bench_cbz | cold | sessionInit×2, sessionOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1 |
| bench_cbz | warm | sessionInit×2, sessionOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1 |
| bench_pdf | cold | sessionInit×1 |
| bench_pdf | warm | sessionInit×1 |
| bench_txt_l | cold | sessionInit×1, sessionOpen×1, txtLazyOpen×1 |
| bench_txt_l | warm | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×18, bgChapter×18 |
| bench_txt_xl | cold | sessionInit×1, sessionOpen×1 |
| bench_txt_xl | warm | sessionInit×1, sessionOpen×1 |
