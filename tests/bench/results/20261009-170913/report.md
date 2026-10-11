# OhEngine Bench 报告（设备实测）

> 运行目录：`tests/bench/results/20261009-170913`　设备：见 `meta.json`　日志：`logs/`
> 数据来源：hilog 应用内埋点（CacheStats / COLDSTART / LAYOUT_* / OPEN_TOTAL / TXT-LAZY）。

## 1 打开路径（每个样例）

| 样例 | 场景 | openMs | restoreMs | txtLazyIdxMs | 首帧(ms,设备钟) | 锚点(ms,设备钟) | totalPages | 行数 |
|---|---|---|---|---|---|---|---|---|
| bench_demo | cold | 0 | 0 | 35 | 99 | 85 | 6 | 3403 |
| bench_demo | warm | 0 | 0 | 1 | 24 | 9 | 6 | 2751 |
| bench_epub_s | cold | 0 | 0 | 0 | 148 | 145 | 305 | 3169 |
| bench_epub_s | warm | 0 | 0 | 0 | 27 | 24 | 318 | 2890 |
| bench_txt_m | cold | 0 | 0 | 3883 | 5176 | 5172 | 1683 | 3360 |
| bench_txt_m | warm | 0 | 0 | 2 | 198 | 187 | 1646 | 3462 |
| bench_txt_s | cold | 0 | 0 | 616 | 1955 | 1951 | 227 | 3127 |
| bench_txt_s | warm | 0 | 0 | 1 | 81 | 72 | 198 | 3688 |

## 2 排版 / Worker 耗时分布

| 样例 | 场景 | Worker 排版 n | p50(ms) | p95(ms) | max(ms) | 后台章 n | p50 | p95 | max |
|---|---|---|---|---|---|---|---|---|---|
| bench_demo | cold | 0 | — | — | — | 0 | — | — | — |
| bench_demo | warm | 0 | — | — | — | 0 | — | — | — |
| bench_epub_s | cold | 27 | 6 | 420 | 422 | 6 | 176 | 465 | 465 |
| bench_epub_s | warm | 0 | — | — | — | 0 | — | — | — |
| bench_txt_m | cold | 12 | 464 | 606 | 606 | 12 | 485 | 616 | 616 |
| bench_txt_m | warm | 22 | 441 | 511 | 655 | 22 | 463 | 541 | 685 |
| bench_txt_s | cold | 15 | 471 | 830 | 830 | 15 | 494 | 844 | 844 |
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
| bench_epub_s | cold | sessionInit×2, sessionOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×27, bgChapter×6, bgEnd×1 |
| bench_epub_s | warm | sessionInit×2, sessionOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, bgEnd×1 |
| bench_txt_m | cold | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×12, bgChapter×12 |
| bench_txt_m | warm | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×22, bgChapter×22 |
| bench_txt_s | cold | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, layoutWorker×15, bgChapter×15, bgEnd×1 |
| bench_txt_s | warm | sessionInit×2, sessionOpen×1, txtLazyOpen×1, openMs×1, cacheStats×1, t_anchor×1, openTotal×1, t_firstFrame×1, bgReflow×1, bgEnd×1 |
